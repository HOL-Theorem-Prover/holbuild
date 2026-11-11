#!/usr/bin/env bash
# Exporting leaves only the archive in its directory: the staging cache's GC
# growth must not be journaled after the stage is removed.
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT

source_cache=$tmpdir/source-cache
link_hol_toolchain_cache "$source_cache"
project=$tmpdir/project
mkdir -p "$project/src"
{ write_schema2_prelude; cat <<TOML
[project]
name = "export-stage"

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
(cd "$project" && HOLBUILD_CACHE="$source_cache" "$HOLBUILD_BIN" build --tactic-timeout 0 ATheory) > "$tmpdir/build.log" 2>&1
require_grep 'ATheory \(built\|restored from cache\)' "$tmpdir/build.log"

mkdir "$tmpdir/out"
(cd "$project" && HOLBUILD_CACHE="$source_cache" "$HOLBUILD_BIN" export -o "$tmpdir/out/a.hbx") > "$tmpdir/export.log" 2>&1 \
  || { cat "$tmpdir/export.log" >&2; exit 1; }
require_file "$tmpdir/out/a.hbx"

echo a.hbx > "$tmpdir/expected"
ls -A "$tmpdir/out" > "$tmpdir/actual"
cmp "$tmpdir/expected" "$tmpdir/actual" \
  || { echo "export left more than the archive in its directory:" >&2; find "$tmpdir/out" >&2; exit 1; }
