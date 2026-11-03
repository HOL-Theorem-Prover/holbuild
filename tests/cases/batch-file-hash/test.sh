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

mkdir -p "$tmpdir/files"
python3 - "$tmpdir/files" <<'PY'
import pathlib
import sys

files = pathlib.Path(sys.argv[1])
# More files than one sha1sum chunk, plus names sha1sum escapes in its output.
for i in range(300):
    (files / f"f{i:03}.sml").write_bytes(bytes((j * 31 + i) % 256 for j in range(i * 7)))
(files / "with space.sml").write_text("space\n")
(files / "back\\slash.sml").write_text("backslash\n")
(files / "new\nline.sml").write_text("newline\n")
PY

cat > "$tmpdir/batch-file-hash.sml" <<'SML'
val root =
  case OS.Process.getEnv "HOLBUILD_ROOT" of
      SOME path => path
    | NONE => raise Fail "HOLBUILD_ROOT not set";
val dir =
  case OS.Process.getEnv "BATCH_FILE_HASH_DIR" of
      SOME path => path
    | NONE => raise Fail "BATCH_FILE_HASH_DIR not set";

val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

fun fail message = (TextIO.output (TextIO.stdErr, message ^ "\n");
                    OS.Process.exit OS.Process.failure)

fun list_files () =
  let
    val stream = OS.FileSys.openDir dir
    fun loop acc =
      case OS.FileSys.readDir stream of
          NONE => rev acc before OS.FileSys.closeDir stream
        | SOME name => loop (OS.Path.concat(dir, name) :: acc)
  in loop [] end

val paths = list_files ()
val batched = HolbuildHash.files_sha1 paths
val expected =
  case OS.Process.getEnv "BATCH_FILE_HASH_EXPECT" of
      SOME digest => map (fn _ => digest) paths
    | NONE => map (fn path => SHA1_ML.sha1_file {filename = path}) paths
val _ = if length paths < 300 then fail "expected at least 300 files" else ()
val _ =
  ListPair.appEq
    (fn (path, (b, e)) => if b = e then () else fail ("digest mismatch for " ^ path ^ ": " ^ b ^ " vs " ^ e))
    (paths, ListPair.zipEq (batched, expected))
val _ = print "batch file hash test passed\n"
SML

run_check() {
  BATCH_FILE_HASH_DIR="$tmpdir/files" "${HOLBUILD_POLY:-poly}" < "$tmpdir/batch-file-hash.sml" > "$tmpdir/$1.log" 2>&1 || {
    cat "$tmpdir/$1.log" >&2
    exit 1
  }
  require_grep "batch file hash test passed" "$tmpdir/$1.log"
}

run_check with-sha1sum

# A sha1sum that reports a fixed digest per argument, escaping names the way
# GNU sha1sum does, shows that the batch output is used and kept in order.
sentinel=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
fakedir="$tmpdir/fake"
mkdir -p "$fakedir"
cat > "$fakedir/sha1sum" <<SH
#!/usr/bin/env bash
[ "\$1" = "--" ] && shift
for f in "\$@"; do
  case "\$f" in
    *\\*|*\$'\n'*) printf '\\%s  %s\n' $sentinel "\${f//\$'\n'/\\n}" ;;
    *) printf '%s  %s\n' $sentinel "\$f" ;;
  esac
done
SH
chmod +x "$fakedir/sha1sum"
PATH="$fakedir:$PATH" BATCH_FILE_HASH_EXPECT=$sentinel run_check fake-sha1sum

# Without a working sha1sum every chunk falls back to hashing file by file.
shimdir="$tmpdir/shim"
mkdir -p "$shimdir"
printf '#!/bin/sh\nexit 1\n' > "$shimdir/sha1sum"
chmod +x "$shimdir/sha1sum"
PATH="$shimdir:$PATH" run_check failing-sha1sum
