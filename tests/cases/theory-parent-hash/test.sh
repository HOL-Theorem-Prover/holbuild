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
use_case_cache "$tmpdir/cache"

cat > "$tmpdir/parent-hash-parser-test.sml" <<'SML'
val root =
  case OS.Process.getEnv "HOLBUILD_ROOT" of
      SOME path => path
    | NONE => raise Fail "HOLBUILD_ROOT not set";

val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

fun fail message = (TextIO.output (TextIO.stdErr, message ^ "\n");
                    OS.Process.exit OS.Process.failure)
fun assert message condition = if condition then () else fail message

val hash_a = "0123456789abcdef0123456789abcdef01234567"
val hash_b = "abcdef0123456789abcdef0123456789abcdef01"
val hash_dup_first = "1111111111111111111111111111111111111111"
val hash_dup_second = "2222222222222222222222222222222222222222"
val invalid_hash = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"

val crafted_dat =
  String.concat
    ["noise before ",
     "(\"A\" . \"", hash_a, "\") ",
     "(\"B\"\n\t.\r \"", hash_b, "\") ",
     "(\"Bad\" . \"", invalid_hash, "\") ",
     "(\"Short\" . \"123\") ",
     "(\"Dup\" . \"", hash_dup_first, "\") ",
     "(\"Dup\" . \"", hash_dup_second, "\") ",
     "noise after"]

val hashes = HolbuildBuildExec.parse_dat_parent_hashes crafted_dat
fun recorded name = Binarymap.peek (hashes, name)

val _ = assert "A hash was not parsed" (recorded "A" = SOME hash_a)
val _ = assert "B hash with whitespace was not parsed" (recorded "B" = SOME hash_b)
val _ = assert "invalid hash should be skipped" (recorded "Bad" = NONE)
val _ = assert "short hash should be skipped" (recorded "Short" = NONE)
val _ = assert "duplicate parent should keep first occurrence" (recorded "Dup" = SOME hash_dup_first)
val _ = assert "unexpected parser map size" (Binarymap.numItems hashes = 3)

val _ = print "parent-hash parser unit tests passed\n"
SML

"${HOLBUILD_POLY:-poly}" < "$tmpdir/parent-hash-parser-test.sml" > "$tmpdir/parent-hash-parser-test.log" 2>&1 || {
  cat "$tmpdir/parent-hash-parser-test.log" >&2
  exit 1
}
grep -q "parent-hash parser unit tests passed" "$tmpdir/parent-hash-parser-test.log"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "parenthash"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "B";

Theorem b_thm:
  T
Proof
  ACCEPT_TAC ATheory.a_thm
QED

val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/initial.log" 2>&1
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_file "$project/.holbuild/obj/src/BTheory.dat"
b_metadata=$(find "$project/.holbuild/dep" -type f -path "*/src/BScript.sml.key" -print -quit)
if [[ -z "$b_metadata" ]]; then
  echo "missing BTheory metadata" >&2
  exit 1
fi
require_file "$b_metadata"
require_grep "^parent_hashes=v1$" "$b_metadata"
if ! grep -Eq '^parent_dat=A [0-9a-f]{40}$' "$b_metadata"; then
  echo "BTheory metadata did not record A parent hash" >&2
  exit 1
fi

python3 - <<PY
from pathlib import Path
path = Path("$b_metadata")
lines = [
    line for line in path.read_text().splitlines()
    if line != "parent_hashes=v1" and not line.startswith("parent_dat=")
]
path.write_text("\\n".join(lines) + "\\n")
PY
old_noop_log=$tmpdir/old-noop.json
(cd "$project" && "$HOLBUILD_BIN" --json build BTheory) > "$old_noop_log" 2>&1
python3 - <<PY
import json
from pathlib import Path
events = [json.loads(line) for line in Path("$old_noop_log").read_text().splitlines() if line.startswith("{")]
finished = [event for event in events if event.get("event") == "build_finished"]
if not finished:
    raise SystemExit("no build_finished event in old-format no-op log")
event = finished[-1]
if event.get("built") != 0 or event.get("from_cache") != 0 or event.get("unchanged") != 2:
    raise SystemExit(f"old-format metadata no-op counts were not 0 built / 0 restored / 2 unchanged: {event}")
PY
require_grep "^parent_hashes=v1$" "$b_metadata"
if ! grep -Eq '^parent_dat=A [0-9a-f]{40}$' "$b_metadata"; then
  echo "old-format metadata fallback did not refresh BTheory parent hash metadata" >&2
  exit 1
fi

noop_log=$tmpdir/noop.json
(cd "$project" && "$HOLBUILD_BIN" --json build BTheory) > "$noop_log" 2>&1
python3 - <<PY
import json
from pathlib import Path
events = [json.loads(line) for line in Path("$noop_log").read_text().splitlines() if line.startswith("{")]
finished = [event for event in events if event.get("event") == "build_finished"]
if not finished:
    raise SystemExit("no build_finished event in no-op log")
event = finished[-1]
if event.get("built") != 0 or event.get("from_cache") != 0 or event.get("unchanged") != 2:
    raise SystemExit(f"no-op build counts were not 0 built / 0 restored / 2 unchanged: {event}")
PY

python3 - <<PY
from pathlib import Path
path = Path("$project/src/AScript.sml")
text = path.read_text()
insert = """
Theorem a_thm_2:
  T
Proof
  ACCEPT_TAC TRUTH
QED

"""
marker = "val _ = export_theory();"
if marker not in text:
    raise SystemExit("export marker missing from AScript.sml")
path.write_text(text.replace(marker, insert + marker, 1))
PY
edit_log=$tmpdir/edit.json
(cd "$project" && "$HOLBUILD_BIN" --json build BTheory) > "$edit_log" 2>&1
python3 - <<PY
import json
from pathlib import Path
events = [json.loads(line) for line in Path("$edit_log").read_text().splitlines() if line.startswith("{")]
finished = [event for event in events if event.get("event") == "build_finished"]
if not finished:
    raise SystemExit("no build_finished event in edit log")
event = finished[-1]
if event.get("built") != 2 or event.get("from_cache") != 0 or event.get("unchanged") != 0:
    raise SystemExit(f"single-file edit did not rebuild exactly ATheory and BTheory: {event}")
PY

python3 - <<PY
from pathlib import Path
import re
path = Path("$b_metadata")
text = path.read_text()
changed = re.sub(r'^parent_dat=A [0-9a-f]{40}$',
                 'parent_dat=A 0000000000000000000000000000000000000000',
                 text, count=1, flags=re.MULTILINE)
if changed == text:
    raise SystemExit('BTheory metadata did not record A parent hash')
path.write_text(changed)
PY

stale_log=$tmpdir/stale.log
(cd "$project" && "$HOLBUILD_BIN" build --no-cache BTheory) > "$stale_log" 2>&1
require_grep "BTheory built" "$stale_log"
if grep -q "BTheory is up to date\|link_parents" "$stale_log"; then
  echo "stale theory parent metadata hash was accepted" >&2
  exit 1
fi

# A v1 marker is not sufficient: every current parent must have a valid entry.
python3 - <<PY
from pathlib import Path
path = Path("$b_metadata")
lines = [line for line in path.read_text().splitlines()
         if not line.startswith("parent_dat=A ")]
path.write_text("\\n".join(lines) + "\\n")
PY
missing_parent_log=$tmpdir/missing-parent.log
(cd "$project" && "$HOLBUILD_BIN" build --no-cache BTheory) > "$missing_parent_log" 2>&1
require_grep "BTheory built" "$missing_parent_log"

# Metadata must also agree with the child artifact, rather than masking a
# replaced or truncated .dat file.
python3 - <<PY
from pathlib import Path
import re
path = Path("$project/.holbuild/obj/src/BTheory.dat")
text = path.read_text()
changed = re.sub(r'("A"\\s*\\.\\s*")[0-9a-f]{40}',
                 r'\\g<1>0000000000000000000000000000000000000000', text,
                 count=1)
if changed == text:
    raise SystemExit("BTheory.dat did not contain A parent hash")
path.write_text(changed)
PY
replaced_child_log=$tmpdir/replaced-child.log
(cd "$project" && "$HOLBUILD_BIN" build --no-cache BTheory) > "$replaced_child_log" 2>&1
require_grep "BTheory built" "$replaced_child_log"

# An action dependency can impose build order without being exported as a HOL
# theory parent.  Such a dependency must not invalidate BTheory on every run
# or make its cache entry unusable.
ordering_project=$tmpdir/ordering-project
mkdir -p "$ordering_project/src"
cat > "$ordering_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "ordering-parent-hash"

[build]
members = ["src"]

[actions.BTheory]
deps = ["ATheory"]
TOML
cat > "$ordering_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val _ = export_theory();
SML
cat > "$ordering_project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "B";
val _ = export_theory();
SML

(cd "$ordering_project" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/ordering-initial.log" 2>&1
ordering_metadata=$(find "$ordering_project/.holbuild/dep" -type f -path "*/src/BScript.sml.key" -print -quit)
require_file "$ordering_metadata"
if grep -q '^parent_dat=A ' "$ordering_metadata"; then
  echo "ordering-only dependency was recorded as a theory parent" >&2
  exit 1
fi

ordering_noop_log=$tmpdir/ordering-noop.json
(cd "$ordering_project" && "$HOLBUILD_BIN" --json build BTheory) > "$ordering_noop_log" 2>&1
python3 - <<PY
import json
from pathlib import Path
events = [json.loads(line) for line in Path("$ordering_noop_log").read_text().splitlines() if line.startswith("{")]
event = [event for event in events if event.get("event") == "build_finished"][-1]
if event.get("built") != 0 or event.get("from_cache") != 0 or event.get("unchanged") != 2:
    raise SystemExit(f"ordering-only dependency prevented a no-op: {event}")
PY

rm "$ordering_project/.holbuild/obj/src/BTheory.dat"
ordering_restore_log=$tmpdir/ordering-restore.json
(cd "$ordering_project" && "$HOLBUILD_BIN" --json build BTheory) > "$ordering_restore_log" 2>&1
python3 - <<PY
import json
from pathlib import Path
events = [json.loads(line) for line in Path("$ordering_restore_log").read_text().splitlines() if line.startswith("{")]
event = [event for event in events if event.get("event") == "build_finished"][-1]
if event.get("built") != 0 or event.get("from_cache") != 1 or event.get("unchanged") != 1:
    raise SystemExit(f"ordering-only dependency prevented a cache restore: {event}")
PY
