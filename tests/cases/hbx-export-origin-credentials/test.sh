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

source_cache=$tmpdir/source-cache
link_hol_toolchain_cache "$source_cache"

project=$tmpdir/project
mkdir -p "$project/src"
{ write_schema2_prelude; cat <<TOML
[project]
name = "hbxorigin"

[build]
members = ["src"]
TOML
} > "$project/holproject.toml"
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
init_git_repo "$project" > /dev/null
SECRET=sentinel-secret-7f3a
git -C "$project" remote add origin "https://user:$SECRET@example.org/project.git"

(cd "$project" && HOLBUILD_CACHE="$source_cache" "$HOLBUILD_BIN" build --tactic-timeout 0 ATheory) > "$tmpdir/build.log" 2>&1
require_grep "ATheory built" "$tmpdir/build.log"

archive=$tmpdir/a.hbx
metadata=$tmpdir/a.hbx.json
(cd "$project" && HOLBUILD_CACHE="$source_cache" "$HOLBUILD_BIN" export -o "$archive" --metadata-out "$metadata" ATheory) > "$tmpdir/export.log" 2>&1
require_file "$archive"
require_file "$metadata"

tar -xOf "$archive" holbuild-cache/manifest > "$tmpdir/archive.manifest"
tar -xOf "$archive" holbuild-package/manifest > "$tmpdir/capsule.manifest"
require_grep '^source_repo=https://example.org/project.git$' "$tmpdir/archive.manifest"
require_grep '"source_repo": "https://example.org/project.git"' "$metadata"
if grep -q "$SECRET" "$tmpdir/archive.manifest" "$tmpdir/capsule.manifest" "$metadata"; then
  echo "origin credential leaked into the exported manifest or sidecar" >&2
  exit 1
fi
