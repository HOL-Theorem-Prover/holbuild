#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT

real_sha256sum=$(command -v sha256sum)
mkdir -p "$tmpdir/bin"
cat > "$tmpdir/bin/sha256sum" <<SH
#!/bin/sh
echo hash >> "$tmpdir/hashes"
exec "$real_sha256sum" "\$@"
SH
chmod +x "$tmpdir/bin/sha256sum"

cat > "$tmpdir/check.sml" <<'SML'
val root = valOf (OS.Process.getEnv "HOLBUILD_ROOT");
val tmp = valOf (OS.Process.getEnv "EXPORT_HASH_TMP");
val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";
fun assert msg ok = if ok then () else raise Fail msg;
fun write path char =
  let val out = TextIO.openOut path
  in TextIO.output(out, CharVector.tabulate (70000, fn _ => char)); TextIO.closeOut out end;
fun calls () =
  let val input = TextIO.openIn (tmp ^ "/hashes")
      val lines = TextIO.inputAll input before TextIO.closeIn input
  in length (String.tokens (fn c => c = #"\n") lines) end;
val _ = (let
  val path = tmp ^ "/library.sml"
  val _ = write path #"a"
  val old_time = OS.FileSys.modTime path
  val _ = OS.Process.sleep (Time.fromSeconds 2)
  val hash = HolbuildBuildExec.export_file_hash ()
  val first = hash path
  val _ = assert "stable file was not reused" (hash path = first andalso calls () = 1)
  val _ = write path #"b"
  val _ = OS.FileSys.setTime(path, SOME old_time)
  val _ = assert "same-size rewrite with restored mtime reused old bytes"
    (hash path <> first andalso calls () = 2)
  val fresh = tmp ^ "/fresh.sml"
  val _ = write fresh #"c"
  val recent = hash fresh
  val _ = assert "racy file reused a hash" (hash fresh = recent andalso calls () = 4)
  val _ = OS.FileSys.remove path
  val _ = write path #"d"
  val _ = OS.FileSys.setTime(path, SOME old_time)
  val _ = assert "replacement file reused an old identity" (hash path <> first andalso calls () = 5)
in print "export file hash tests passed\n" end)
handle e => (TextIO.output(TextIO.stdErr, General.exnMessage e ^ "\n");
             OS.Process.exit OS.Process.failure);
SML

# sha256sum calls count the hashes, so libcrypto is kept out.
HOLBUILD_TEST_LIBCRYPTO=libholbuild-test-no-such-crypto.so \
PATH="$tmpdir/bin:$PATH" EXPORT_HASH_TMP="$tmpdir" "${HOLBUILD_POLY:-poly}" \
  --gcthreads=1 --error-exit < "$tmpdir/check.sml" > "$tmpdir/check.log" 2>&1 || {
  cat "$tmpdir/check.log" >&2
  exit 1
}
require_grep 'export file hash tests passed' "$tmpdir/check.log"
