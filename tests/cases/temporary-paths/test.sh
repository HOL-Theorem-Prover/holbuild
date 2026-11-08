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

fun parts () =
  case String.fields (fn c => c = #"-") (HolbuildTempPath.suffix ()) of
      [pid, token, counter] =>
        if pid <> "" andalso size token = 16 andalso
           List.all Char.isHexDigit (String.explode token) andalso
           Option.isSome (Int.fromString counter) then (pid, token, counter)
        else raise Fail "invalid temporary suffix format"
    | _ => raise Fail "missing process token in temporary suffix";
val (pid, token, first) = parts ();
val (_, same_token, second) = parts ();
val _ = if token = same_token andalso first <> second then ()
        else raise Fail "suffixes must share one process token and have unique counters";
val names = List.tabulate (1000, fn _ => HolbuildTempPath.near "shared/file" ".tmp");
val _ = if Redblackset.numItems (Redblackset.addList (Redblackset.empty String.compare, names)) = 1000
        then () else raise Fail "temporary names collided";

(* A precreated symlink at the first directory candidate must be skipped. *)
val root = valOf (OS.Process.getEnv "TMPDIR");
val planted = OS.Path.concat (root, "holbuild-" ^
  pid ^ "-" ^ token ^ "-" ^ Int.toString (!HolbuildTempPath.counter + 1));
val _ = Posix.FileSys.symlink {old = "/", new = planted};
val remote_path = HolbuildRemoteCache.temp_path "probe";
val private_dir = OS.Path.dir remote_path;
val mode = Posix.FileSys.ST.mode (Posix.FileSys.stat private_dir);
val _ = if private_dir = root orelse private_dir = planted orelse
           Posix.FileSys.S.toWord mode <> Posix.FileSys.S.toWord Posix.FileSys.S.irwxu then
          raise Fail "remote temporary files lack a private 0700 directory"
        else ();
val _ = OS.FileSys.remove planted;

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
(* Missing, unreadable, or short entropy uses a fixed-width clock fallback. *)
structure Time =
struct
  open Time
  fun now () = fromSeconds 1
end;
structure BinIO =
struct
  open BinIO
  val failure = ref "open"
  fun openIn path =
    if !failure = "open" then raise OS.SysErr ("unavailable", NONE) else BinIO.openIn path
  fun inputN args =
    if !failure = "read" then raise OS.SysErr ("unreadable", NONE)
    else Word8Vector.fromList [0w0]
end;
use "sml/temp_path.sml";
val _ = List.app (fn mode =>
  (BinIO.failure := mode;
   if HolbuildTempPath.new_token () = "000000003B9ACA00" then ()
   else raise Fail ("clock fallback failed: " ^ mode))) ["open", "read", "short"];
val _ = print "temporary path tests passed\n";
SML
mkdir -p "$tmpdir/shared"
TMPDIR="$tmpdir/shared" TEMP_PATH_TEST_CACHE="$tmpdir/cache" "${HOLBUILD_POLY:-poly}" --script "$tmpdir/check.sml" > "$tmpdir/check.log" 2>&1 || {
  cat "$tmpdir/check.log" >&2
  exit 1
}
require_grep 'temporary path tests passed' "$tmpdir/check.log"
if [[ -n "$(ls -A "$tmpdir/shared")" ]]; then
  echo "private temporary directory was not cleaned up at exit" >&2
  exit 1
fi

# Export once, run twice: the process token must not be frozen into the binary.
cat > "$tmpdir/export.sml" <<'SML'
open Thread;
use "sml/temp_path.sml";
fun main () = print (HolbuildTempPath.suffix () ^ "\n");
PolyML.export (valOf (OS.Process.getEnv "TEMP_PATH_EXPORT"), main);
SML
TEMP_PATH_EXPORT="$tmpdir/token.o" "${HOLBUILD_POLY:-poly}" --script "$tmpdir/export.sml" > "$tmpdir/export.log" 2>&1 || {
  cat "$tmpdir/export.log" >&2
  exit 1
}
"${POLYC:-polyc}" -o "$tmpdir/token" "$tmpdir/token.o"
first_token=$("$tmpdir/token" | cut -d- -f2)
second_token=$("$tmpdir/token" | cut -d- -f2)
[[ "$first_token" =~ ^[0-9A-Fa-f]{16}$ && "$first_token" != "$second_token" ]] || {
  echo "exported executable reused its process token" >&2
  exit 1
}
