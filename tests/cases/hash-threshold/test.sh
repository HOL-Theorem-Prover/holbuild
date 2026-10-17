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
    assert ("string sha256 mismatch at " ^ Int.toString size) (HolbuildHash.string_sha256 (HolbuildHash.read_binary_all path) = sha256);
    assert ("large string sha256 mismatch at " ^ Int.toString size) (HolbuildHash.string_sha256_large (HolbuildHash.read_binary_all path) = sha256)
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

# string_sha256_large pipes the text to sha256sum, or to shasum when
# sha256sum is absent, and falls back to the SML digest on any failure.
sentinel256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
wc_bin=$(command -v wc)
poly_bin=$(command -v "${HOLBUILD_POLY:-poly}")

write_digest_shim() {
  local path=$1 body=$2
  printf '#!/bin/sh\n%s\n' "$body" > "$path"
  chmod +x "$path"
}

cat > "$tmpdir/string-large.sml" <<'SML'
val root =
  case OS.Process.getEnv "HOLBUILD_ROOT" of
      SOME path => path
    | NONE => raise Fail "HOLBUILD_ROOT not set";
val tmp =
  case OS.Process.getEnv "HASH_THRESHOLD_TEST_TMP" of
      SOME path => path
    | NONE => raise Fail "HASH_THRESHOLD_TEST_TMP not set";
val expected =
  case OS.Process.getEnv "STRING_LARGE_EXPECT" of
      SOME text => text
    | NONE => raise Fail "STRING_LARGE_EXPECT not set";

val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

fun fail message = (TextIO.output (TextIO.stdErr, message ^ "\n");
                    OS.Process.exit OS.Process.failure)
fun assert message condition = if condition then () else fail message

val small = HolbuildHash.read_binary_all (OS.Path.concat(tmp, "blob-5120.bin"))
val large = HolbuildHash.read_binary_all (OS.Path.concat(tmp, "blob-307200.bin"))
val want = if expected = "fallback" then HolbuildHash.string_sha256 large else expected
val got = HolbuildHash.string_sha256_large large

val _ = assert ("large string digest " ^ got ^ ", expected " ^ want) (got = want)
val _ = assert "small string digest changed"
          (HolbuildHash.string_sha256_large small = HolbuildHash.string_sha256 small)
val _ = print "string sha256 large test passed\n"
SML

run_string_large() {
  local label=$1 path=$2 expect=$3
  : > "$tmpdir/stdin-bytes.log"
  PATH="$path" HASH_THRESHOLD_TEST_TMP="$tmpdir" STRING_LARGE_EXPECT="$expect" \
    "$poly_bin" < "$tmpdir/string-large.sml" > "$tmpdir/string-large-$label.log" 2>&1 || {
      cat "$tmpdir/string-large-$label.log" >&2
      exit 1
    }
  require_grep "string sha256 large test passed" "$tmpdir/string-large-$label.log"
}

# The tool receives the whole text on stdin, and only large texts reach it.
counting="$tmpdir/shim-counting"
mkdir -p "$counting"
write_digest_shim "$counting/sha256sum" \
  "$wc_bin -c >> \"\$STDIN_BYTES_LOG\"; echo '$sentinel256  -'"
STDIN_BYTES_LOG="$tmpdir/stdin-bytes.log" run_string_large counting "$counting:$PATH" "$sentinel256"
if [ "$(tr -d ' ' < "$tmpdir/stdin-bytes.log")" != 307200 ]; then
  echo "sha256sum stdin byte counts: $(cat "$tmpdir/stdin-bytes.log"), expected one 307200" >&2
  exit 1
fi

# Without sha256sum on PATH, shasum -a 256 is used.
shasum_only="$tmpdir/shim-shasum"
mkdir -p "$shasum_only"
write_digest_shim "$shasum_only/shasum" \
  "[ \"\$1 \$2\" = '-a 256' ] || exit 2; $wc_bin -c >> \"\$STDIN_BYTES_LOG\"; echo '$sentinel256  -'"
STDIN_BYTES_LOG="$tmpdir/stdin-bytes.log" run_string_large shasum "$shasum_only" "$sentinel256"
require_grep 307200 "$tmpdir/stdin-bytes.log"

# Neither tool, a failing tool, an invalid digest, or a tool that exits
# before reading its input: the SML digest is used.
for case in none fails invalid early-exit; do
  dir="$tmpdir/shim-$case"
  mkdir -p "$dir"
  case $case in
    fails) write_digest_shim "$dir/sha256sum" "$wc_bin -c > /dev/null; exit 1" ;;
    invalid) write_digest_shim "$dir/sha256sum" "$wc_bin -c > /dev/null; echo 'not-a-digest  -'" ;;
    early-exit) write_digest_shim "$dir/sha256sum" "echo '$sentinel256  -'" ;;
  esac
  run_string_large "$case" "$dir" fallback
done
