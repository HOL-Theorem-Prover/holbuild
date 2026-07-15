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

python3 - "$tmpdir" <<'PY'
import pathlib
import sys

tmp = pathlib.Path(sys.argv[1])
sizes = [0, 1, 17, 4096, 5120, 65536, 196607, 196608, 307200]
for size in sizes:
    data = bytes((i * 37 + size) % 256 for i in range(size))
    (tmp / f"blob-{size}.bin").write_bytes(data)
PY

cat > "$tmpdir/hash-threshold-test.sml" <<'SML'
val root =
  case OS.Process.getEnv "HOLBUILD_ROOT" of
      SOME path => path
    | NONE => raise Fail "HOLBUILD_ROOT not set";
val tmp =
  case OS.Process.getEnv "HASH_THRESHOLD_TEST_TMP" of
      SOME path => path
    | NONE => raise Fail "HASH_THRESHOLD_TEST_TMP not set";

val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

fun fail message = (TextIO.output (TextIO.stdErr, message ^ "\n");
                    OS.Process.exit OS.Process.failure)
fun assert message condition = if condition then () else fail message
fun join (a, b) = OS.Path.concat(a, b)

fun command_hash tool path =
  let
    val out = OS.FileSys.tmpName ()
    val command = tool ^ " " ^ HolbuildHash.quote path ^ " > " ^ HolbuildHash.quote out
    val status = OS.Process.system command
    val text = if OS.Process.isSuccess status then HolbuildHash.read_all out
               else fail (tool ^ " failed for " ^ path)
    val _ = HolbuildHash.remove_quietly out
  in
    case HolbuildHash.first_token text of
        SOME hash => String.map Char.toLower hash
      | NONE => fail (tool ^ " produced no hash for " ^ path)
  end
  handle e => (raise e)

fun check_size size =
  let
    val path = join(tmp, "blob-" ^ Int.toString size ^ ".bin")
    val sha1 = command_hash "sha1sum" path
    val sha256 = command_hash "sha256sum" path
  in
    assert ("sha1 mismatch at " ^ Int.toString size) (HolbuildHash.file_sha1 path = sha1);
    assert ("string sha1 mismatch at " ^ Int.toString size) (HolbuildHash.string_sha1 (HolbuildHash.read_binary_all path) = sha1);
    assert ("sha256 mismatch at " ^ Int.toString size) (HolbuildHash.file_sha256 path = sha256);
    assert ("string sha256 mismatch at " ^ Int.toString size) (HolbuildHash.string_sha256 (HolbuildHash.read_binary_all path) = sha256)
  end

val sizes = [0, 1, 17, 4096, 5120, 65536, 196607, 196608, 307200]
val _ = List.app check_size sizes

val small_path = join(tmp, "blob-5120.bin")
val threshold_minus_one = join(tmp, "blob-196607.bin")
val threshold = join(tmp, "blob-196608.bin")
val benchmark_path = join(tmp, "blob-307200.bin")

val _ = assert "5 KB file should use small-file path" (not (HolbuildHash.large_file small_path))
val _ = assert "threshold - 1 should use small-file path" (not (HolbuildHash.large_file threshold_minus_one))
val _ = assert "threshold should use large-file path" (HolbuildHash.large_file threshold)
val _ = assert "300 KB file should use large-file path" (HolbuildHash.large_file benchmark_path)

val _ = print "hash threshold and corpus tests passed\n"
SML

HASH_THRESHOLD_TEST_TMP="$tmpdir" "${HOLBUILD_POLY:-poly}" < "$tmpdir/hash-threshold-test.sml" > "$tmpdir/hash-threshold-test.log" 2>&1 || {
  cat "$tmpdir/hash-threshold-test.log" >&2
  exit 1
}

grep -q "hash threshold and corpus tests passed" "$tmpdir/hash-threshold-test.log"

shimdir="$tmpdir/shim"
mkdir -p "$shimdir"
cat > "$shimdir/sha1sum" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "$HASH_THRESHOLD_SHA1_LOG"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  %s\n' "$1"
SH
chmod +x "$shimdir/sha1sum"

cat > "$tmpdir/hash-path-selection.sml" <<'SML'
val root =
  case OS.Process.getEnv "HOLBUILD_ROOT" of
      SOME path => path
    | NONE => raise Fail "HOLBUILD_ROOT not set";
val tmp =
  case OS.Process.getEnv "HASH_THRESHOLD_TEST_TMP" of
      SOME path => path
    | NONE => raise Fail "HASH_THRESHOLD_TEST_TMP not set";

val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

fun fail message = (TextIO.output (TextIO.stdErr, message ^ "\n");
                    OS.Process.exit OS.Process.failure)
fun assert message condition = if condition then () else fail message
fun join (a, b) = OS.Path.concat(a, b)

val small = join(tmp, "blob-5120.bin")
val large = join(tmp, "blob-307200.bin")
val sentinel = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
val small_hash = HolbuildHash.file_sha1 small
val large_hash = HolbuildHash.file_sha1 large

val _ = assert "5 KB SHA1 unexpectedly used external path" (small_hash <> sentinel)
val _ = assert "300 KB SHA1 did not use external path" (large_hash = sentinel)
val _ = print "hash path selection test passed\n"
SML

: > "$tmpdir/sha1-path.log"
PATH="$shimdir:$PATH" HASH_THRESHOLD_TEST_TMP="$tmpdir" HASH_THRESHOLD_SHA1_LOG="$tmpdir/sha1-path.log" \
  "${HOLBUILD_POLY:-poly}" < "$tmpdir/hash-path-selection.sml" > "$tmpdir/hash-path-selection.log" 2>&1 || {
    cat "$tmpdir/hash-path-selection.log" >&2
    exit 1
  }

grep -q "hash path selection test passed" "$tmpdir/hash-path-selection.log"

if grep -q "blob-5120.bin" "$tmpdir/sha1-path.log"; then
  echo "5 KB file unexpectedly called sha1sum" >&2
  exit 1
fi
require_grep "blob-307200.bin" "$tmpdir/sha1-path.log"
