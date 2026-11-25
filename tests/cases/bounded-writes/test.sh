#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# Linux sizes the page-cache folio of a buffered write by the write's length,
# so no single write(2) or pwrite64(2) of a file may exceed 64 KiB: multi-MiB
# text through the whole-text writers, a multi-MiB cache blob restored by
# fetch_blob, and a decoded zstd blob of 1 MiB frames.
if [[ $(uname -s) != Linux ]]; then
  echo 'SKIP bounded-writes (traces Linux write sizes with strace)'
  exit 0
fi
command -v strace > /dev/null || { echo "strace is required" >&2; exit 1; }

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
mkdir -p "$tmpdir"/out/{build-exec,build-exec-atomic,stat-cache,remote-cache,blob,zstd} "$tmpdir/cache"

python3 - "$SCRIPT_DIR/../../fixtures" "$tmpdir" <<'PY'
import os
import pathlib
import sys

fixtures, out = map(pathlib.Path, sys.argv[1:3])
sys.path.insert(0, str(fixtures))
from zstd_frames import zstd_encode  # noqa: E402

data = os.urandom(3 << 20)
(out / "blob").write_bytes(data)
(out / "blob.zst").write_bytes(zstd_encode(data))
PY

cat > "$tmpdir/bounded-writes.sml" <<'SML'
val root = valOf (OS.Process.getEnv "HOLBUILD_ROOT");
val dir = valOf (OS.Process.getEnv "BOUNDED_WRITES_DIR");
val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

fun path name = OS.Path.concat (dir, name)
fun fail message = (TextIO.output (TextIO.stdErr, message ^ "\n");
                    OS.Process.exit OS.Process.failure)

val text = CharVector.tabulate (3 * 1048576 + 17, fn i => Char.chr (97 + i mod 26))
val _ = HolbuildBuildExec.write_text (path "out/build-exec/file") text
val _ = HolbuildBuildExec.write_text_atomic (path "out/build-exec-atomic/file") text
val _ = HolbuildStatCache.write_text_atomically (path "out/stat-cache/file") text
val _ = HolbuildRemoteCache.write_text (path "out/remote-cache/file") text
val _ = List.app (fn name =>
          if HolbuildBuildExec.read_text (path ("out/" ^ name ^ "/file")) = text then ()
          else fail (name ^ " wrote different text"))
        ["build-exec", "build-exec-atomic", "stat-cache", "remote-cache"]

(* Without libcrypto, fetch_blob links a blob this size instead of copying it. *)
val _ = if HolbuildHash.uses_libcrypto () then ()
        else (print "SKIP bounded-writes (fetch_blob copies blobs only with libcrypto)\n";
              OS.Process.exit OS.Process.success)
val cache = HolbuildFSCacheBackend.filesystem (path "cache")
val _ = HolbuildFSCacheBackend.ensure_layout cache
val hash = HolbuildHash.file_sha256 (path "blob")
val _ =
  case HolbuildFSCacheBackend.publish_blob cache {hash = hash, src = path "blob"} of
      HolbuildCacheBackend.Published => ()
    | _ => fail "could not publish the blob"
val _ =
  case HolbuildFSCacheBackend.fetch_blob cache {hash = hash, dst = path "out/blob/fetched"} of
      HolbuildCacheBackend.Hit => ()
    | _ => fail "could not fetch the blob"

val _ = HolbuildZstd.decode_file {src = path "blob.zst", dst = path "out/zstd/decoded", threads = 2}

val _ = List.app (fn name =>
          if HolbuildHash.read_binary_all (path name) = HolbuildHash.read_binary_all (path "blob") then ()
          else fail (name ^ " differs from the blob"))
        ["out/blob/fetched", "out/zstd/decoded"]
val _ = print "bounded writes wrote\n"
SML

BOUNDED_WRITES_DIR="$tmpdir" strace -f -qq -s 0 -y -e trace=write,pwrite64 -o "$tmpdir/strace.log" \
  "${HOLBUILD_POLY:-poly}" < "$tmpdir/bounded-writes.sml" > "$tmpdir/check.log" 2>&1 || {
  cat "$tmpdir/check.log" >&2
  exit 1
}
if grep -q "^SKIP" "$tmpdir/check.log"; then
  grep "^SKIP" "$tmpdir/check.log"
  exit 0
fi
require_grep "bounded writes wrote" "$tmpdir/check.log"

python3 - "$tmpdir/out" "$tmpdir/strace.log" <<'PY'
import re
import sys

out, log = sys.argv[1:3]
call = re.compile(r'^(?:\d+\s+)?(write|pwrite64)\(\d+<([^>]*)>, ""\.*, (\d+)')
largest = {}
written = {}
for line in open(log):
    match = call.match(line)
    if not match or not match.group(2).startswith(out + "/"):
        continue
    group = match.group(2)[len(out) + 1:].split("/")[0]
    size = int(match.group(3))
    largest[group] = max(largest.get(group, 0), size)
    written[group] = written.get(group, 0) + size
failed = False
for group in ["build-exec", "build-exec-atomic", "stat-cache", "remote-cache", "blob", "zstd"]:
    if written.get(group, 0) < 3 << 20:
        print(f"{group}: traced only {written.get(group, 0)} bytes of writes", file=sys.stderr)
        failed = True
    elif largest[group] > 65536:
        print(f"{group}: a write of {largest[group]} bytes", file=sys.stderr)
        failed = True
sys.exit(1 if failed else 0)
PY
