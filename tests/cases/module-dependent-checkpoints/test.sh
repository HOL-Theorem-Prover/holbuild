#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT

# With a Poly/ML that has saveChildWithModules, a deps_loaded checkpoint
# refers to the theory modules it loaded instead of copying them.  When one
# of them is gone, holbuild warns, drops the checkpoint and preloads afresh.
echo 'val _ = PolyML.SaveState.saveChildWithModules;' > "$tmpdir/probe.sml"
if ! "$HOLDIR/bin/hol" run --noconfig "$tmpdir/probe.sml" > /dev/null 2>&1; then
  echo 'module-dependent checkpoints unsupported by this Poly/ML'
  exit 0
fi
use_case_cache "$tmpdir/cache"
project=$tmpdir/project
mkdir -p "$project/src"
write_schema2_prelude > "$project/holproject.toml"
cat >> "$project/holproject.toml" <<'TOML'
[project]
name = "module-checkpoints"
[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Definition a_value_def:
  a_value = T
End
SML
cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors A

Theorem b_first:
  a_value
Proof
  simp[a_value_def]
QED

Theorem b_second:
  a_value /\ T
Proof
  simp[a_value_def]
QED
SML

build() {
  (cd "$project" && "$HOLBUILD_BIN" --cache-dir ../cache -j1 build BTheory) > "$1" 2>&1 ||
    { cat "$1" >&2; return 1; }
}
# Changes B's last proof line without changing a line number or an output.
edit_b() { sed -i "s/^  simp\[a_value_def\].*\$/  simp[a_value_def] (* $1 *)/" "$project/src/BScript.sml"; }
checkpoints=$project/.holbuild/checkpoints/module-checkpoints/src
deps_heap() { find "$checkpoints/BScript.sml.deps" -name deps_loaded.save | head -n 1; }
header() { od -An -tu4 -j8 -N8 "$1" | tr -s ' '; }
module_cache=$HOLBUILD_CACHE/theory-modules

# B's preload writes A's module; the next fresh preload loads it.
build "$tmpdir/first.log"
for ext in dat sig sml; do cp "$project/.holbuild/obj/src/BTheory.$ext" "$tmpdir/BTheory.$ext"; done
test "$(find "$module_cache" -name '*-A-*.pmo' | wc -l)" -eq 1
rm -rf "$checkpoints/BScript.sml.deps" "$checkpoints/BScript.sml.theorems" "$HOLBUILD_CACHE/checkpoint-store"
edit_b one
build "$tmpdir/module.log"
heap=$(deps_heap)
[[ "$(header "$heap")" == " 4 104" ]] || { echo "deps_loaded is not module-dependent: $(header "$heap")" >&2; exit 1; }

# A's module goes: the resume falls back with the distinct warning.
find "$module_cache" -name '*-A-*.pmo' -delete
edit_b two
build "$tmpdir/missing.log"
require_grep 'holbuild: warning: module-dependent checkpoint skipped: .*-A-.*\.pmo missing' "$tmpdir/missing.log"
for ext in dat sig sml; do cmp "$tmpdir/BTheory.$ext" "$project/.holbuild/obj/src/BTheory.$ext"; done
