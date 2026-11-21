#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A script holding tens of MB of string literals, with theorems after them,
# made the HOL analyser hold about 90 times the script's size: it copied the
# source up to each theorem boundary to hash it, parsed the script twice, and
# kept every literal of the dependency scan in memory.  The real analyser
# must answer for such a script within a small multiple of its size, with
# prefix hashes that are the SHA-256 of the source before each boundary.  A
# parse error must still give the recovered boundaries, with the
# terminations' error instead of terminations, from one request.

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

mkdir -p "$tmpdir/toolchain"
write_schema2_prelude > "$tmpdir/toolchain/holproject.toml"
cat >> "$tmpdir/toolchain/holproject.toml" <<'TOML'
[project]
name = "large-script-analyser"
TOML
holdir=$(cd "$tmpdir/toolchain" && "$HOLBUILD_BIN" buildhol 2>&1 | tail -n 1)

cat > "$tmpdir/analyser-path.sml" <<'SML'
val _ = OS.FileSys.chDir (valOf (OS.Process.getEnv "HOLBUILD_ROOT"));
use "sml/holbuild-script.sml";
val _ = print ("analyser=" ^ HolbuildHolSharedCache.analyser_path_for_holdir
                               (valOf (OS.Process.getEnv "LARGE_SCRIPT_HOLDIR")) ^ "\n");
SML
analyser=$(LARGE_SCRIPT_HOLDIR="$holdir" "${HOLBUILD_POLY:-poly}" < "$tmpdir/analyser-path.sml" 2>&1 |
             sed -n 's/^analyser=//p')
require_file "$analyser"

python3 - "$analyser" "$tmpdir" <<'PY'
import hashlib, os, pathlib, subprocess, sys

analyser, tmp = sys.argv[1], pathlib.Path(sys.argv[2])

def theorems(prefix, count):
    return "".join(f"Theorem {prefix}{i}:\n  T\nProof\n  simp []\nQED\n\n" for i in range(count))

termination = ("Definition count_down_def:\n"
               "  count_down (n:num) = if n = 0 then 0 else count_down (n - 1)\n"
               "Termination\n  WF_REL_TAC `measure I`\nEnd\n\n")
chunk = ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" * 1024)
literals = ",\n".join(f'"{chunk[i % 64:] + chunk[:i % 64]}"' for i in range(512))
big = ("open HolKernel Parse boolLib bossLib;\n\nval _ = new_theory \"Big\";\n\n" +
       theorems("before_", 5) +
       "val payload = String.concat [\n" + literals + "];\n\n" +
       termination + theorems("after_", 40) + "val _ = export_theory ();\n")
(tmp / "BigScript.sml").write_text(big)
broken = ("open HolKernel Parse boolLib bossLib;\n\nval _ = new_theory \"Broken\";\n\n" +
          theorems("good_", 2) + termination + "Theorem missing_qed:\n  T\nProof\n  simp []\n\n" +
          theorems("later_", 2) + "val _ = export_theory ();\n")
(tmp / "BrokenScript.sml").write_text(broken)

def unescape(field):
    out, i = [], 0
    while i < len(field):
        if field[i] == "\\" and i + 1 < len(field):
            out.append({"n": "\n", "t": "\t", "s": " ", "\\": "\\"}.get(field[i + 1], field[i + 1]))
            i += 2
        else:
            out.append(field[i])
            i += 1
    return "".join(out)

def analyse(name, wants):
    request = tmp / f"{name}.request"
    response = tmp / f"{name}.response"
    source = tmp / f"{name.split('-')[0]}Script.sml"
    request.write_text(f"version 1\ncommand analyse\nfile 1 {source} {' '.join(wants)}\nend\n")
    proc = subprocess.Popen([analyser, "--minheap", "128", "--request", str(request),
                             "--response", str(response)], stderr=subprocess.PIPE)
    stderr = proc.stderr.read().decode()
    _, status, usage = os.wait4(proc.pid, 0)
    proc.returncode = os.waitstatus_to_exitcode(status)
    records = []
    if proc.returncode == 0:
        records = [[unescape(f) for f in line.split(" ")] for line in response.read_text().splitlines()]
    return proc.returncode, stderr, records, usage.ru_maxrss * 1024

def fail(message):
    sys.exit(f"large-script-analyser: {message}")

data = big.encode()
status, stderr, records, peak = analyse("Big", ["boundaries-recovering", "terminations-strict"])
if status != 0:
    fail(f"span request failed ({status}): {stderr}")
boundaries = [r for r in records if r[0] == "boundary"]
if [b[2] for b in boundaries] != [f"before_{i}" for i in range(5)] + [f"after_{i}" for i in range(40)]:
    fail(f"unexpected boundaries {[b[2] for b in boundaries]}")
for b in boundaries:
    if b[10] != hashlib.sha256(data[:int(b[6])]).hexdigest():
        fail(f"prefix hash of {b[2]} is not the SHA-256 of the source before {b[6]}")
if [r[1] for r in records if r[0] == "termination"] != ["count_down_def"]:
    fail("termination missing")
print(f"span request: {len(data)} bytes, peak RSS {peak} bytes")
if peak > 6 * len(data) + 256 * 2**20:
    fail(f"span request peak RSS {peak} for a {len(data)}-byte script")

status, stderr, records, peak = analyse("Big-deps", ["deps"])
if status != 0:
    fail(f"deps request failed ({status}): {stderr}")
print(f"deps request: peak RSS {peak} bytes")
if peak > 6 * len(data) + 256 * 2**20:
    fail(f"deps request peak RSS {peak} for a {len(data)}-byte script")

status, stderr, records, _ = analyse("Broken", ["boundaries-recovering", "terminations-strict"])
if status != 0:
    fail(f"recovering span request failed on a parse error ({status}): {stderr}")
names = [r[2] for r in records if r[0] == "boundary"]
if names != ["good_0", "good_1", "later_0", "later_1"]:
    fail(f"unexpected recovered boundaries {names}")
if not any(r[0] == "parse-error" for r in records):
    fail("parse error not reported")
if any(r[0] == "termination" for r in records):
    fail("terminations reported after a parse error")
errors = [r for r in records if r[0] == "terminations-error"]
if len(errors) != 1 or "HOL source parse error" not in errors[0][1]:
    fail(f"terminations error missing: {errors}")

status, stderr, _, _ = analyse("Broken-strict", ["terminations-strict"])
if status == 0 or "HOL source parse error" not in stderr:
    fail("strict terminations request accepted a parse error")
PY
