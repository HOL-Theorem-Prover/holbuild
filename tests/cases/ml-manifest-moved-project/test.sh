#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"
unset HOLBUILD_REMOTE_CACHE_URL

# An ML library's load manifests (.ui/.uo) name absolute paths: its source and
# the objects of the project libraries it loads.  Its input key doesn't cover
# them, so once the sources move (a project moved, or HOL's own libraries in a
# toolchain directory replaced by another of the same HOL) the next build must
# rewrite the manifests rather than keep ones naming the old paths.

old=$tmpdir/old
mkdir -p "$old/src"
cat > "$old/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "${HOLBUILD_TEST_HOL_GIT:-https://github.com/HOL-Theorem-Prover/HOL.git}"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "ml-manifest-moved"

[build]
members = ["src"]
TOML
cat > "$old/src/fooLib.sig" <<'SML'
signature fooLib = sig val x : int end
SML
cat > "$old/src/fooLib.sml" <<'SML'
structure fooLib :> fooLib = struct val x = 1 end
SML
cat > "$old/src/barLib.sml" <<'SML'
structure barLib = struct val y = fooLib.x + 1 end
SML

(cd "$old" && "$HOLBUILD_BIN" build barLib) > "$tmpdir/old-build.log" 2>&1

new=$tmpdir/new
mv "$old" "$new"
(cd "$new" && "$HOLBUILD_BIN" build barLib) > "$tmpdir/new-build.log" 2>&1

for manifest in fooLib.ui fooLib.uo barLib.uo .hol/objs/fooLib.ui .hol/objs/fooLib.uo .hol/objs/barLib.uo; do
  path=$new/.holbuild/obj/src/$manifest
  require_file "$path"
  if grep -Fq "$old/" "$path"; then
    echo "$manifest still names the project's old directory after the move:" >&2
    cat "$path" >&2
    exit 1
  fi
done
grep -Fqx "$new/src/barLib.sml" "$new/.holbuild/obj/src/barLib.uo" || {
  echo "barLib.uo doesn't name the moved source:" >&2
  cat "$new/.holbuild/obj/src/barLib.uo" >&2
  exit 1
}

cat > "$tmpdir/use.sml" <<'SML'
load "barLib";
val _ = if barLib.y = 2 then print "BAR_OK\n" else raise Fail "barLib.y";
SML
(cd "$new" && "$HOLBUILD_BIN" run "$tmpdir/use.sml") > "$tmpdir/run.log" 2>&1 || {
  cat "$tmpdir/run.log" >&2
  exit 1
}
grep -Fq BAR_OK "$tmpdir/run.log" || {
  echo "loading barLib in the moved project failed:" >&2
  cat "$tmpdir/run.log" >&2
  exit 1
}

# Unmoved, the manifests stay as they are.
(cd "$new" && "$HOLBUILD_BIN" build barLib) > "$tmpdir/again-build.log" 2>&1
if grep -Eq '(fooLib|barLib) built' "$tmpdir/again-build.log"; then
  echo "an unchanged ML library was rebuilt:" >&2
  cat "$tmpdir/again-build.log" >&2
  exit 1
fi
