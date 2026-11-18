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

# Blobs as bazel-remote's zstd storage serves them (the remote cache test
# server encodes the same way), and a frame without its content size, as
# zstd writes from a pipe.
python3 - "$SCRIPT_DIR/../../fixtures" "$tmpdir" <<'PY'
import os
import pathlib
import sys

fixtures, out = map(pathlib.Path, sys.argv[1:3])
sys.path.insert(0, str(fixtures))
from zstd_frames import zstd_encode  # noqa: E402

for name, data in [("empty", b""), ("small", b"abc"),
                   ("frames", os.urandom(3 << 20) + bytes(range(256)) * 4000)]:
    (out / name).write_bytes(data)
    (out / f"{name}.zst").write_bytes(zstd_encode(data))
PY
printf 'no content size' | zstd -q -c > "$tmpdir/unsized.zst"
cp "$tmpdir/small" "$tmpdir/plain.zst"

cat > "$tmpdir/zstd-decode.sml" <<'SML'
val root =
  case OS.Process.getEnv "HOLBUILD_ROOT" of
      SOME path => path
    | NONE => raise Fail "HOLBUILD_ROOT not set";
val dir =
  case OS.Process.getEnv "ZSTD_DECODE_DIR" of
      SOME path => path
    | NONE => raise Fail "ZSTD_DECODE_DIR not set";

val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

fun fail message = (TextIO.output (TextIO.stdErr, message ^ "\n");
                    OS.Process.exit OS.Process.failure)

fun path name = OS.Path.concat (dir, name)

fun decode name threads =
  HolbuildZstd.decode_file {src = path (name ^ ".zst"), dst = path (name ^ ".out"), threads = threads}

fun refused name =
  (decode name 4; fail (name ^ " decoded")) handle HolbuildZstd.Error _ => ()

val _ =
  case OS.Process.getEnv "ZSTD_DECODE_EXPECT" of
      SOME "unavailable" =>
        if HolbuildZstd.available () then fail "libzstd loaded" else refused "small"
    | _ =>
        (List.app (fn (name, threads) =>
           (decode name threads;
            if HolbuildHash.read_binary_all (path name) = HolbuildHash.read_binary_all (path (name ^ ".out"))
            then ()
            else fail (name ^ " decoded wrongly with " ^ Int.toString threads ^ " threads")))
           [("empty", 4), ("small", 4), ("frames", 1), ("frames", 4), ("frames", 16)];
         refused "unsized";
         refused "plain")
val _ = print "zstd decode test passed\n"
SML

run_check() {
  ZSTD_DECODE_DIR="$tmpdir" "${HOLBUILD_POLY:-poly}" < "$tmpdir/zstd-decode.sml" > "$tmpdir/$1.log" 2>&1 || {
    cat "$tmpdir/$1.log" >&2
    exit 1
  }
  require_grep "zstd decode test passed" "$tmpdir/$1.log"
}

run_check libzstd
HOLBUILD_TEST_LIBZSTD=libholbuild-test-no-such-zstd.so ZSTD_DECODE_EXPECT=unavailable run_check without-libzstd
