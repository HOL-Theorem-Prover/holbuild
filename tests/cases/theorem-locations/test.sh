#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

# Theorem locations in the theory database must name the source script and
# its lines, not holbuild's instrumented stage copy of it.

write_project() {
  local project=$1
  mkdir -p "$project/src"
  {
    write_schema2_prelude
    cat <<'TOML'
[project]
name = "locs"

[build]
members = ["src"]
TOML
  } > "$project/holproject.toml"
  # triple_def and the `Theorem ... =` forms follow a QED directly, so only
  # the pragma after that QED places them.
  cat > "$project/src/locScript.sml" <<'SML'
Theory loc
Ancestors arithmetic

Definition double_def:
  double n = n + n
End

Theorem double_0:
  double 0 = 0
Proof
  simp[double_def]
QED

Definition triple_def:
  triple n = n + n + n
End

Theorem double_0_again = double_0

Definition countdown_def:
  countdown n = if n = 0 then 0 else countdown (n - 1)
Termination
  WF_REL_TAC `measure I`
End

Theorem double_1:
  double 1 = 2
Proof
  simp[double_def]
QED

Theorem double_1_again = double_1

Theorem double_2:
  double 2 = 4
Proof
  simp[double_def]
QED
SML
  cat > "$project/probe.sml" <<'SML'
load "locTheory";
fun show n =
  case DB.lookup {Thy = "loc", Name = n} of
      SOME (_, {loc = DB.Located {scriptpath, linenum, ...}, ...}) =>
        print ("location " ^ n ^ " " ^ scriptpath ^ ":" ^ Int.toString linenum ^ "\n")
    | _ => print ("location " ^ n ^ " unknown\n");
val _ = List.app show
  ["double_def", "double_0", "triple_def", "double_0_again", "countdown_def",
   "double_1", "double_1_again", "double_2"];
SML
}

edit_source() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
from pathlib import Path
path, old, new = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
assert old in text, old
path.write_text(text.replace(old, new))
PY
}

expected_locations() {
  local double_2_line=$1
  cat <<TXT
location double_def \$(locs)/src/locScript.sml:4
location double_0 \$(locs)/src/locScript.sml:8
location triple_def \$(locs)/src/locScript.sml:14
location double_0_again \$(locs)/src/locScript.sml:18
location countdown_def \$(locs)/src/locScript.sml:20
location double_1 \$(locs)/src/locScript.sml:26
location double_1_again \$(locs)/src/locScript.sml:32
location double_2 \$(locs)/src/locScript.sml:$double_2_line
TXT
}

check_locations() {
  local project=$1
  local double_2_line=$2
  local label=$3
  local log=$tmpdir/$label-probe.log
  (cd "$project" && "$HOLBUILD_BIN" run probe.sml) > "$log" 2>&1
  if ! diff <(grep '^location ' "$log") <(expected_locations "$double_2_line"); then
    echo "$label: theorem locations differ from the source (log: $log)" >&2
    exit 1
  fi
}

double_2_proof=$'Theorem double_2:\n  double 2 = 4\nProof\n  simp[double_def]\nQED'

project=$tmpdir/project
write_project "$project"
(cd "$project" && "$HOLBUILD_BIN" build locTheory) > "$tmpdir/build.log" 2>&1
check_locations "$project" 34 full

# Resuming from a checkpoint after double_1 replays only the tail of the
# script, so the pragma at the resume point places double_1_again; two
# inserted lines move double_2 down.
edit_source "$project/src/locScript.sml" "$double_2_proof" \
  $'(* moved *)\n\nTheorem double_2:\n  double 2 = 4\nProof\n  rw[double_def]\nQED'
(cd "$project" && "$HOLBUILD_BIN" build locTheory) > "$tmpdir/resume.log" 2>&1
require_grep "checkpoint after double_1" "$tmpdir/resume.log"
check_locations "$project" 36 resume

# A theorem finished from a failed-prefix checkpoint is saved by holbuild's
# replay code rather than by the script's own Theorem declaration.
failed=$tmpdir/failed
write_project "$failed"
edit_source "$failed/src/locScript.sml" "$double_2_proof" \
  $'Theorem double_2:\n  double 2 = 4\nProof\n  REWRITE_TAC [double_def] >> FAIL_TAC "expected failure"\nQED'
if (cd "$failed" && "$HOLBUILD_BIN" build locTheory) > "$tmpdir/failed.log" 2>&1; then
  echo "expected failing proof to fail the build" >&2
  exit 1
fi
edit_source "$failed/src/locScript.sml" 'FAIL_TAC "expected failure"' 'simp[]'
(cd "$failed" && "$HOLBUILD_BIN" build locTheory) > "$tmpdir/failed-fixed.log" 2>&1
require_grep "from: failed-prefix checkpoint in double_2" "$tmpdir/failed-fixed.log"
check_locations "$failed" 34 failed-prefix

# Without proof-step instrumentation the stage copy is the plain script.
plain=$tmpdir/plain
write_project "$plain"
(cd "$plain" && "$HOLBUILD_BIN" build --no-cache --skip-proof-steps --skip-checkpoints locTheory) > "$tmpdir/plain.log" 2>&1
check_locations "$plain" 34 plain

# Poly reports static errors at source lines, which the diagnostic quotes.
broken=$tmpdir/broken
write_project "$broken"
edit_source "$broken/src/locScript.sml" $'End\n\nTheorem double_1:' $'End\nval _ = 1 + "a";\nTheorem double_1:'
if (cd "$broken" && "$HOLBUILD_BIN" build --no-cache locTheory) > "$tmpdir/broken.log" 2>&1; then
  echo "expected static error to fail the build" >&2
  exit 1
fi
require_grep "^locScript.sml:25: error: Type error" "$tmpdir/broken.log"
require_grep "source: .*/src/locScript.sml:25$" "$tmpdir/broken.log"
require_grep '^> 25 | val _ = 1 + "a";$' "$tmpdir/broken.log"
