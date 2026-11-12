#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT

# Sources-only export discovers sources without running the analyser or HOL.
export HOLBUILD_CACHE=$tmpdir/cache
write_fake_hol "$tmpdir/hol"
export HOLBUILD_TEST_HOL_GIT=$tmpdir/hol
HOLBUILD_TEST_HOL_REV=$(init_git_repo "$tmpdir/hol")
export HOLBUILD_TEST_HOL_REV
write_fake_poly "$tmpdir/fakebin"
export PATH=$tmpdir/fakebin:$PATH

project=$tmpdir/project
mkdir -p "$project"/{src,extra,nested/empty,excluded,undeclared}
{ write_schema2_prelude; cat <<'TOML'
[project]
name = "capsule-members"

[build]
members = ["src", "extra", "nested/empty", "excluded"]
exclude = ["excluded"]
TOML
} > "$project/holproject.toml"
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val _ = export_theory();
SML
touch "$project/extra/.gitkeep"
printf 'data\n' > "$project/extra/data.txt"
printf 'structure Excluded = struct end\n' > "$project/excluded/Excluded.sml"
printf 'undeclared\n' > "$project/undeclared/data.txt"

hb() { (cd "$1" && shift && "$HOLBUILD_BIN" "$@"); }
hb "$project" export --sources-only -o "$tmpdir/sources.hbx" > "$tmpdir/export.log" 2>&1

extracted=$tmpdir/extracted
mkdir -p "$extracted"
tar -xf "$tmpdir/sources.hbx" -C "$extracted" --strip-components=2 holbuild-package/source
hb "$extracted" export --sources-only -o "$tmpdir/roundtrip.hbx" > "$tmpdir/extracted.log" 2>&1 || {
  cat "$tmpdir/extracted.log" >&2
  exit 1
}
require_file "$extracted/src/AScript.sml"
cmp "$tmpdir/sources.hbx" "$tmpdir/roundtrip.hbx"
for member in src extra nested/empty excluded; do
  [[ -d "$extracted/$member" ]] || { echo "missing member directory: $member" >&2; exit 1; }
done
for file in extra/.gitkeep extra/data.txt excluded/Excluded.sml undeclared; do
  require_no_file "$extracted/$file"
done

# Member directories use the same normalized modes under a restrictive umask.
(umask 077; hb "$project" export --sources-only -o "$tmpdir/restrictive.hbx" > "$tmpdir/restrictive.log" 2>&1)
cmp "$tmpdir/sources.hbx" "$tmpdir/restrictive.hbx"
