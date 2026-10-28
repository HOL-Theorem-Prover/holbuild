#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"
tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
cat > "$tmpdir/check.sml" <<'SML'
val _ = OS.FileSys.chDir (valOf (OS.Process.getEnv "HOLBUILD_ROOT"));
use "sml/holbuild-script.sml";

(* tmpName creates a file and changes the process umask in Poly/ML.  Name-only
   operations must never call it, even if they clean up the file afterwards. *)
structure OS =
struct
  open OS
  structure FileSys =
  struct
    open FileSys
    fun tmpName () : string = raise Fail "temporary name generation called tmpName"
  end
end;
use "sml/stat_cache.sml";
use "sml/fs_cache_backend.sml";
use "sml/remote_cache.sml";
use "sml/cache_archive.sml";
use "sml/build_exec.sml";

val failures = ref ([] : string list);
fun check label operation =
  operation () handle e => failures := (label ^ ": " ^ General.exnMessage e) :: !failures;
fun check_name label generate = check label (fn () =>
  let val path = generate ()
  in
    if OS.FileSys.access (path, []) then raise Fail ("name generation created " ^ path)
    else ()
  end);
val _ = check_name "stat cache" (fn () => HolbuildStatCache.tmp_path_for "stat");
val _ = check_name "remote cache" (fn () => HolbuildRemoteCache.temp_path "remote");
val _ = check_name "archive directory" (fn () => HolbuildCacheArchive.temp_dir_near "archive");
val _ = check_name "archive file" (fn () => HolbuildCacheArchive.temp_file_near "archive");
val _ = check_name "build" (fn () => HolbuildBuildExec.temp_near "build");
val cache = HolbuildFSCacheBackend.filesystem (valOf (OS.Process.getEnv "TEMP_PATH_TEST_CACHE"));
val _ = HolbuildFSCacheBackend.ensure_layout cache;
val _ = check "filesystem cache" (fn () =>
  HolbuildFSCacheBackend.write_action cache {key = "temporary-path-test", text = "manifest"});
val _ = if null (!failures) then () else raise Fail (String.concatWith "\n" (rev (!failures)));
val _ = print "temporary path tests passed\n";
SML
TEMP_PATH_TEST_CACHE="$tmpdir/cache" "${HOLBUILD_POLY:-poly}" --script "$tmpdir/check.sml" > "$tmpdir/check.log" 2>&1 || {
  cat "$tmpdir/check.log" >&2
  exit 1
}
require_grep 'temporary path tests passed' "$tmpdir/check.log"
