#!/usr/bin/env bash
set -euo pipefail

_HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT

# Export the real driver helpers so each read starts in a fresh runtime,
# without the heap growth caused by compiling the driver first.
cat > "$tmpdir/probe.sml" <<'SML'
val root = valOf (OS.Process.getEnv "HOLBUILD_ROOT");
val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";
fun check message condition = if condition then () else raise Fail message;
fun probe () =
  case CommandLine.arguments () of
      ["read", path] =>
        let
          val text = HolbuildBuildExec.read_text path
          val hashes = HolbuildBuildExec.parse_dat_parent_hashes text
        in
          check "large data file truncated" (size text = 3200000 orelse size text = 3500000);
          check "parent hash lost across a read boundary"
            (Binarymap.peek (hashes, "Parent") = SOME "0123456789abcdef0123456789abcdef01234567")
        end
    | ["rewrite", src, dst] =>
        let
          val replace = HolbuildBuildExec.replace_all
          val _ = check "empty needle" (replace "" "x" "abc" = "abc")
          val _ = check "no match" (replace "z" "x" "abc" = "abc")
          val _ = check "adjacent matches" (replace "aa" "b" "aaaaa" = "bba")
          val _ = check "delete matches" (replace "aa" "" "aaaaa" = "a")
          val _ = check "replacement rescanned" (replace "a" "aa" "a" = "aa")
          val _ = HolbuildBuildExec.copy_rewriting_path
            {src = src, dst = dst, replacements = [("TOKEN", "relocated/path")]}
          (* An 8 MB initializer must not retain hundreds of MB of character
             list cells while concatenating the relocated result. *)
          val _ = check "SML relocation expanded the heap beyond 128 MiB"
            (#sizeHeap (PolyML.Statistics.getLocalStats ()) < 128 * 1024 * 1024)
        in () end
    | _ => raise Fail "expected read PATH or rewrite SRC DST";
val _ = PolyML.export (valOf (OS.Process.getEnv "HOLBUILD_RESTORE_PROBE") ^ ".o", probe);
SML

export HOLBUILD_RESTORE_PROBE="$tmpdir/probe"
"${HOLBUILD_POLY:-poly}" -q --error-exit --gcthreads=1 --use "$tmpdir/probe.sml" </dev/null
"${HOLBUILD_POLYC:-polyc}" -o "$tmpdir/probe" "$tmpdir/probe.o"

python3 - "$tmpdir" <<'PY'
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
parent = b'("Parent" . "0123456789abcdef0123456789abcdef01234567")'
for size in (3200000, 3500000):
    data = b"x" * 65530 + parent
    source = root / "LargeTheory.dat"
    source.write_bytes(data + b"x" * (size - len(data)))
    # Poly/ML 5.9.2's inputAll abort is sensitive to GC scheduling. Repeating
    # fresh processes covers the observed large-object failure band.
    for _ in range(10):
        subprocess.run([str(root / "probe"), "--gcthreads=8", "read", str(source)],
                       check=True, timeout=60)
source = root / "LargeTheory.sml"
destination = root / "restored" / "LargeTheory.sml"
text = b"TOKENTOKEN" + b"x" * 8000000 + b"TOKEN"
source.write_bytes(text)
subprocess.run([str(root / "probe"), "--gcthreads=2", "rewrite", str(source), str(destination)],
               check=True, timeout=60)
if destination.read_bytes() != text.replace(b"TOKEN", b"relocated/path"):
    raise SystemExit("large initializer relocation changed unrelated bytes")
PY
