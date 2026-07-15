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

cat > "$tmpdir/fs-cache-backend-test.sml" <<'SML'
val root =
  case OS.Process.getEnv "HOLBUILD_ROOT" of
      SOME path => path
    | NONE => raise Fail "HOLBUILD_ROOT not set";
val tmp =
  case OS.Process.getEnv "FS_CACHE_BACKEND_TEST_TMP" of
      SOME path => path
    | NONE => raise Fail "FS_CACHE_BACKEND_TEST_TMP not set";
val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

fun fail message = (TextIO.output (TextIO.stdErr, message ^ "\n");
                    OS.Process.exit OS.Process.failure)
fun assert message condition = if condition then () else fail message
fun join (a, b) = OS.Path.concat (a, b)
fun write_text path text =
  let val out = TextIO.openOut path
  in TextIO.output (out, text); TextIO.closeOut out end

val cache = HolbuildFSCacheBackend.filesystem (join (tmp, "cache"));
val _ = HolbuildFSCacheBackend.ensure_layout cache;
val source = join (tmp, "source");
val _ = write_text source "valid cache blob\n";
val hash = HolbuildHash.file_sha1 source;
val _ =
  case HolbuildFSCacheBackend.publish_blob cache {hash = hash, src = source} of
      HolbuildCacheBackend.Published => ()
    | result => fail "could not seed filesystem cache";

(* A fetch result is trusted by generic cache transfer callers, so a corrupt
   content-addressed source must not be reported as Hit. *)
val _ = write_text (HolbuildFSCacheBackend.blob_path cache hash) "corrupt\n";
val corrupt_dst = join (tmp, "corrupt-dst");
val _ =
  case HolbuildFSCacheBackend.fetch_blob cache {hash = hash, dst = corrupt_dst} of
      HolbuildCacheBackend.Corrupt _ => ()
    | _ => fail "corrupt cache blob was accepted as a hit";
val _ = assert "corrupt fetch wrote a destination" (not (OS.FileSys.access (corrupt_dst, []) handle OS.SysErr _ => false));

val _ =
  case HolbuildFSCacheBackend.publish_blob cache {hash = hash, src = source} of
      HolbuildCacheBackend.Published => ()
    | result => fail "could not repair filesystem cache";
val dst = join (tmp, "dst");
val _ =
  case HolbuildFSCacheBackend.fetch_blob cache {hash = hash, dst = dst} of
      HolbuildCacheBackend.Hit => ()
    | _ => fail "valid cache blob was not fetched";
val _ = assert "materialized blob hash mismatch" (HolbuildHash.file_sha1 dst = hash);
val _ = print "filesystem cache backend tests passed\n";
SML

FS_CACHE_BACKEND_TEST_TMP="$tmpdir" "${HOLBUILD_POLY:-poly}" < "$tmpdir/fs-cache-backend-test.sml" > "$tmpdir/fs-cache-backend-test.log" 2>&1 || {
  cat "$tmpdir/fs-cache-backend-test.log" >&2
  exit 1
}

grep -q "filesystem cache backend tests passed" "$tmpdir/fs-cache-backend-test.log"
