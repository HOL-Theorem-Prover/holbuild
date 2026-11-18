#!/usr/bin/env bash
# An archive in a read-only directory imports into a writable cache: the
# extraction is staged in the cache's tmp directory, not beside the archive.
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { chmod -R u+w "$tmpdir" 2>/dev/null || true; cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT

source_cache=$tmpdir/source-cache
link_hol_toolchain_cache "$source_cache"
project=$tmpdir/project
mkdir -p "$project/src"
{ write_schema2_prelude; cat <<TOML
[project]
name = "import-readonly"

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

mkdir "$tmpdir/ro"
(cd "$project" && HOLBUILD_CACHE="$source_cache" "$HOLBUILD_BIN" export -o "$tmpdir/ro/a.hbx") > "$tmpdir/export.log" 2>&1
require_file "$tmpdir/ro/a.hbx"
chmod 0555 "$tmpdir/ro"
ls -A "$tmpdir/ro" > "$tmpdir/ro-before"

HOLBUILD_CACHE="$tmpdir/cache" "$HOLBUILD_BIN" import "$tmpdir/ro/a.hbx" > "$tmpdir/import.log" 2>&1 \
  || { cat "$tmpdir/import.log" >&2; exit 1; }
require_grep "imported 1 cache action" "$tmpdir/import.log"

ls -A "$tmpdir/ro" > "$tmpdir/ro-after"
cmp "$tmpdir/ro-before" "$tmpdir/ro-after" \
  || { echo "import changed the archive's directory" >&2; exit 1; }
if find "$tmpdir/cache/tmp" -mindepth 1 | grep -q .; then
  echo "import left staging files in the cache tmp directory" >&2
  exit 1
fi
