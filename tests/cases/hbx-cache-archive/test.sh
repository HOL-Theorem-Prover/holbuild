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
import_cache=$tmpdir/import-cache
link_hol_toolchain_cache "$source_cache"
link_hol_toolchain_cache "$import_cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "hbxarchive"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML

build_log=$tmpdir/build.log
(cd "$project" && HOLBUILD_CACHE="$source_cache" "$HOLBUILD_BIN" build ATheory) > "$build_log" 2>&1
require_grep "ATheory built" "$build_log"

manifest=$(find "$source_cache/actions" -mindepth 2 -maxdepth 2 -name manifest | head -n 1)
require_file "$manifest"
action_key=$(basename "$(dirname "$manifest")")
archive=$tmpdir/a.hbx

cat > "$tmpdir/archive-copy.sml" <<'SML'
use "sml/holbuild-script.sml";

val source_cache = Option.valOf (OS.Process.getEnv "SOURCE_CACHE");
val import_cache = Option.valOf (OS.Process.getEnv "IMPORT_CACHE");
val archive = Option.valOf (OS.Process.getEnv "HBX_ARCHIVE");
val action_key = Option.valOf (OS.Process.getEnv "ACTION_KEY");

val source = HolbuildFSCacheBackend.filesystem source_cache;
val destination = HolbuildFSCacheBackend.filesystem import_cache;
val _ = HolbuildFSCacheBackend.ensure_layout destination;

val source_backend : HolbuildCacheTransfer.source =
  {get_action = HolbuildFSCacheBackend.get_action source,
   fetch_blob = HolbuildFSCacheBackend.fetch_blob source};
val destination_backend : HolbuildCacheTransfer.destination =
  {put_action = HolbuildFSCacheBackend.put_action destination,
   publish_blob = HolbuildFSCacheBackend.publish_blob destination};

val _ = HolbuildCacheArchive.create {archive_path = archive,
                                     source = source_backend,
                                     keys = [action_key]};
val _ = HolbuildCacheArchive.with_reader
          {archive_path = archive,
           f = fn archive_source =>
                 HolbuildCacheTransfer.copy_entries
                   {source = archive_source,
                    destination = destination_backend,
                    tmp_dir = HolbuildFSCacheBackend.tmp_dir destination}
                   [action_key]};
SML
(
  cd "$HOLBUILD_ROOT"
  SOURCE_CACHE="$source_cache" IMPORT_CACHE="$import_cache" HBX_ARCHIVE="$archive" ACTION_KEY="$action_key" \
    poly --script "$tmpdir/archive-copy.sml"
)

require_file "$archive"
require_file "$import_cache/actions/$action_key/manifest"

rm -rf "$project/.holbuild"
restore_log=$tmpdir/restore.log
(cd "$project" && HOLBUILD_CACHE="$import_cache" HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" build ATheory) > "$restore_log" 2>&1
require_grep "cache hit: ATheory" "$restore_log"
require_grep "ATheory restored from cache" "$restore_log"
require_file "$project/.holbuild/obj/src/ATheory.dat"
