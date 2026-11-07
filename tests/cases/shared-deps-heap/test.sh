#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"
store=$tmpdir/cache/checkpoint-store

# Two worktrees of one project share the host's deps heaps.
make_tree() {
  local project=$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "heaps"

[build]
members = ["src"]
TOML
  cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Theorem a_thm:
  T
Proof
  simp[]
QED
SML
  cat > "$project/src/helperLib.sml" <<'SML'
structure helperLib = struct val helper_thm = boolTheory.TRUTH end
SML
  cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors A
Libs helperLib

Theorem b_thm:
  T
Proof
  ACCEPT_TAC helperLib.helper_thm
QED
SML
}
outputs() { (cd "$1/.holbuild/obj/src" && sha256sum ATheory.sig ATheory.sml ATheory.dat BTheory.sig BTheory.sml BTheory.dat); }
deps_heap() { find "$1/.holbuild/checkpoints/heaps/src/$2Script.sml.deps" -name deps_loaded.save | head -n 1; }

first=$tmpdir/first
second=$tmpdir/second
make_tree "$first"
make_tree "$second"

# The first tree's build adds its deps heaps to the store, by hard link.
(cd "$first" && "$HOLBUILD_BIN" build --no-cache BTheory) > "$tmpdir/first.log" 2>&1 \
  || { cat "$tmpdir/first.log" >&2; exit 1; }
first_outputs=$(outputs "$first")
first_heap=$(deps_heap "$first" B)
[[ -n "$first_heap" ]] || { echo "the first tree saved no deps heap for B" >&2; exit 1; }
stored=$(find "$store" -name deps_loaded.save -samefile "$first_heap")
[[ -n "$stored" ]] || { echo "B's deps heap is not linked into the store" >&2; find "$store" >&2; exit 1; }

# With the first tree gone, the second resumes from the store's heaps and
# builds the same outputs: nothing in the heap points into the deleted tree.
rm -rf "$first"
(cd "$second" && "$HOLBUILD_BIN" build --no-cache BTheory) > "$tmpdir/second.log" 2>&1 \
  || { cat "$tmpdir/second.log" >&2; exit 1; }
grep -A1 '^resuming BTheory' "$tmpdir/second.log" | grep -q 'from: deps-loaded checkpoint' \
  || { echo "the second tree did not resume B from the shared deps heap" >&2; cat "$tmpdir/second.log" >&2; exit 1; }
[[ "$(deps_heap "$second" B)" -ef "$stored" ]] \
  || { echo "the second tree's deps heap is a copy, not the store's" >&2; exit 1; }
if [[ "$first_outputs" != "$(outputs "$second")" ]]; then
  echo "a shared deps heap changed theory outputs" >&2
  exit 1
fi

# A stored heap whose parent isn't this build's base state is not used.
third=$tmpdir/third
make_tree "$third"
printf 'not a heap\n' > "$tmpdir/bogus" && cp "$tmpdir/bogus" "$stored.tmp-bogus"
mv "$stored.tmp-bogus" "$stored"
(cd "$third" && "$HOLBUILD_BIN" build --no-cache BTheory) > "$tmpdir/third.log" 2>&1 \
  || { cat "$tmpdir/third.log" >&2; exit 1; }
if grep -A1 '^resuming BTheory' "$tmpdir/third.log" | grep -q 'from: deps-loaded checkpoint'; then
  echo "the third tree resumed from a bogus stored heap" >&2
  exit 1
fi
[[ "$(deps_heap "$third" B)" -ef "$stored" ]] \
  || { echo "a successful build did not replace the bogus stored heap" >&2; exit 1; }

# gc removes families no build used within the retention window. It runs
# on its own cache, so it can't touch the suite's shared toolchains.
gc_cache=$tmpdir/gc-cache
mkdir -p "$gc_cache"
cp -a "$store" "$gc_cache/"
family=$(dirname "${stored#"$store/"}")
touch -d '60 days ago' "$gc_cache/checkpoint-store/$family"
HOLBUILD_CACHE=$gc_cache "$HOLBUILD_BIN" gc --cache-only --days 30 > "$tmpdir/gc.log" 2>&1 \
  || { cat "$tmpdir/gc.log" >&2; exit 1; }
[[ ! -e "$gc_cache/checkpoint-store/$family" ]] || { echo "gc kept a stale store family" >&2; exit 1; }
require_grep "checkpoint store gc: removed families=1" "$tmpdir/gc.log"
