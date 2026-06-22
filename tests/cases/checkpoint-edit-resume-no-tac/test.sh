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

write_project() {
  local project=$1
  local name=$2
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "$name"

[build]
members = ["src"]
TOML
}

# If an edit introduces NO_TAC before the saved failed-prefix point, holbuild
# must not silently resume past it from a stale failed-prefix checkpoint.
# The edited build should fail even though the suffix would now prove the goal.
direct_project=$tmpdir/direct-project
direct_counter=$tmpdir/direct-count.txt
touch "$direct_counter"
write_project "$direct_project" "checkpoint-edit-resume-no-tac-direct"
cat > "$direct_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val counter_path = "$direct_counter";
fun bump_counter () =
  let val out = TextIO.openAppend counter_path
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun counted_tac g = (bump_counter(); ALL_TAC g);
Theorem direct_no_tac_insert:
  T
Proof
  counted_tac >> ALL_TAC >> FAIL_TAC "direct old suffix"
QED
val _ = export_theory();
SML

direct_first_log=$tmpdir/direct-first.log
if (cd "$direct_project" && "$HOLBUILD_BIN" build ATheory) > "$direct_first_log" 2>&1; then
  echo "expected direct seed proof to fail" >&2
  exit 1
fi
require_grep "direct old suffix" "$direct_first_log"
direct_first_count=$(wc -c < "$direct_counter" | tr -d ' ')
[[ "$direct_first_count" = "1" ]] || { echo "expected direct seed to run counted_tac once, got $direct_first_count" >&2; exit 1; }
require_file "$(find "$direct_project/.holbuild/checkpoints" -name '*direct_no_tac_insert_failed_prefix.save' -print -quit)"

python3 - <<PY
from pathlib import Path
path = Path("$direct_project/src/AScript.sml")
path.write_text(path.read_text().replace(
    'counted_tac >> ALL_TAC >> FAIL_TAC "direct old suffix"',
    'counted_tac >> NO_TAC >> ACCEPT_TAC TRUTH'))
PY

direct_second_log=$tmpdir/direct-second.log
if (cd "$direct_project" && "$HOLBUILD_BIN" build ATheory) > "$direct_second_log" 2>&1; then
  echo "edited direct proof succeeded after NO_TAC was introduced before the resume point" >&2
  exit 1
fi
require_grep "NO_TAC" "$direct_second_log"
direct_second_count=$(wc -c < "$direct_counter" | tr -d ' ')
[[ "$direct_second_count" = "1" ]] || { echo "direct edit reran unchanged counted_tac instead of resuming after it; count $direct_second_count" >&2; exit 1; }
if grep -q "ATheory built" "$direct_second_log"; then
  echo "direct edited proof was built despite introduced NO_TAC" >&2
  exit 1
fi

# Replacing the first successful prefix leaf itself with NO_TAC should invalidate
# the failed-prefix state entirely, not replay from the old post-leaf state.
replace_project=$tmpdir/replace-project
replace_counter=$tmpdir/replace-count.txt
touch "$replace_counter"
write_project "$replace_project" "checkpoint-edit-resume-no-tac-replace"
cat > "$replace_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val counter_path = "$replace_counter";
fun bump_counter () =
  let val out = TextIO.openAppend counter_path
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun counted_tac g = (bump_counter(); ALL_TAC g);
Theorem replace_prefix_with_no_tac:
  T
Proof
  counted_tac >> FAIL_TAC "replace old suffix"
QED
val _ = export_theory();
SML

replace_first_log=$tmpdir/replace-first.log
if (cd "$replace_project" && "$HOLBUILD_BIN" build ATheory) > "$replace_first_log" 2>&1; then
  echo "expected replace seed proof to fail" >&2
  exit 1
fi
require_grep "replace old suffix" "$replace_first_log"
replace_first_count=$(wc -c < "$replace_counter" | tr -d ' ')
[[ "$replace_first_count" = "1" ]] || { echo "expected replace seed to run counted_tac once, got $replace_first_count" >&2; exit 1; }
require_file "$(find "$replace_project/.holbuild/checkpoints" -name '*replace_prefix_with_no_tac_failed_prefix.save' -print -quit)"

python3 - <<PY
from pathlib import Path
path = Path("$replace_project/src/AScript.sml")
path.write_text(path.read_text().replace(
    'counted_tac >> FAIL_TAC "replace old suffix"',
    'NO_TAC >> ACCEPT_TAC TRUTH'))
PY

replace_second_log=$tmpdir/replace-second.log
if (cd "$replace_project" && "$HOLBUILD_BIN" build ATheory) > "$replace_second_log" 2>&1; then
  echo "edited replace proof succeeded after prefix leaf was replaced by NO_TAC" >&2
  exit 1
fi
require_grep "NO_TAC" "$replace_second_log"
replace_second_count=$(wc -c < "$replace_counter" | tr -d ' ')
[[ "$replace_second_count" = "1" ]] || { echo "replace edit unexpectedly ran counted_tac after it was replaced by NO_TAC; count $replace_second_count" >&2; exit 1; }

# Same hazard inside a structural branch: salvaging to a stale branch leaf must
# not skip an edited NO_TAC in the branch before a now-successful suffix.
struct_project=$tmpdir/struct-project
struct_counter=$tmpdir/struct-count.txt
touch "$struct_counter"
write_project "$struct_project" "checkpoint-edit-resume-no-tac-struct"
cat > "$struct_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val counter_path = "$struct_counter";
fun bump_counter () =
  let val out = TextIO.openAppend counter_path
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun counted_tac g = (bump_counter(); ALL_TAC g);
Theorem structural_no_tac_insert:
  T /\\ T
Proof
  CONJ_TAC >| [
    ACCEPT_TAC TRUTH,
    counted_tac >> ALL_TAC >> FAIL_TAC "structural old suffix"
  ]
QED
val _ = export_theory();
SML

struct_first_log=$tmpdir/struct-first.log
if (cd "$struct_project" && "$HOLBUILD_BIN" build ATheory) > "$struct_first_log" 2>&1; then
  echo "expected structural seed proof to fail" >&2
  exit 1
fi
require_grep "structural old suffix" "$struct_first_log"
struct_first_count=$(wc -c < "$struct_counter" | tr -d ' ')
[[ "$struct_first_count" = "1" ]] || { echo "expected structural seed to run counted_tac once, got $struct_first_count" >&2; exit 1; }
require_file "$(find "$struct_project/.holbuild/checkpoints" -name '*structural_no_tac_insert_failed_prefix.save' -print -quit)"

python3 - <<PY
from pathlib import Path
path = Path("$struct_project/src/AScript.sml")
path.write_text(path.read_text().replace(
    'counted_tac >> ALL_TAC >> FAIL_TAC "structural old suffix"',
    'counted_tac >> NO_TAC >> ACCEPT_TAC TRUTH'))
PY

struct_second_log=$tmpdir/struct-second.log
if (cd "$struct_project" && "$HOLBUILD_BIN" build ATheory) > "$struct_second_log" 2>&1; then
  echo "edited structural proof succeeded after NO_TAC was introduced before the branch resume point" >&2
  exit 1
fi
require_grep "NO_TAC" "$struct_second_log"
struct_second_count=$(wc -c < "$struct_counter" | tr -d ' ')
[[ "$struct_second_count" = "1" ]] || { echo "structural edit reran unchanged counted_tac instead of resuming after it; count $struct_second_count" >&2; exit 1; }

# Multiple live subgoals: after CONJ_TAC, THEN-style composition applies the
# later tactics to both conjuncts.  A stale resume after ALL_TAC would skip the
# edited NO_TAC and let ACCEPT_TAC solve both subgoals.
multigoal_project=$tmpdir/multigoal-project
multigoal_counter=$tmpdir/multigoal-count.txt
touch "$multigoal_counter"
write_project "$multigoal_project" "checkpoint-edit-resume-no-tac-multigoal"
cat > "$multigoal_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val counter_path = "$multigoal_counter";
fun bump_counter () =
  let val out = TextIO.openAppend counter_path
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun counted_tac g = (bump_counter(); ALL_TAC g);
Theorem multigoal_no_tac_insert:
  T /\\ T
Proof
  CONJ_TAC >> counted_tac >> ALL_TAC >> FAIL_TAC "multigoal old suffix"
QED
val _ = export_theory();
SML

multigoal_first_log=$tmpdir/multigoal-first.log
if (cd "$multigoal_project" && "$HOLBUILD_BIN" build ATheory) > "$multigoal_first_log" 2>&1; then
  echo "expected multigoal seed proof to fail" >&2
  exit 1
fi
require_grep "multigoal old suffix" "$multigoal_first_log"
multigoal_first_count=$(wc -c < "$multigoal_counter" | tr -d ' ')
[[ "$multigoal_first_count" = "2" ]] || { echo "expected multigoal seed to run counted_tac on both subgoals, got $multigoal_first_count" >&2; exit 1; }
require_file "$(find "$multigoal_project/.holbuild/checkpoints" -name '*multigoal_no_tac_insert_failed_prefix.save' -print -quit)"

python3 - <<PY
from pathlib import Path
path = Path("$multigoal_project/src/AScript.sml")
path.write_text(path.read_text().replace(
    'CONJ_TAC >> counted_tac >> ALL_TAC >> FAIL_TAC "multigoal old suffix"',
    'CONJ_TAC >> counted_tac >> NO_TAC >> ACCEPT_TAC TRUTH'))
PY

multigoal_second_log=$tmpdir/multigoal-second.log
if (cd "$multigoal_project" && "$HOLBUILD_BIN" build ATheory) > "$multigoal_second_log" 2>&1; then
  echo "edited multigoal proof succeeded after NO_TAC was introduced with multiple live subgoals" >&2
  exit 1
fi
require_grep "NO_TAC" "$multigoal_second_log"
multigoal_second_count=$(wc -c < "$multigoal_counter" | tr -d ' ')
[[ "$multigoal_second_count" = "2" ]] || { echo "multigoal edit reran unchanged counted_tac applications instead of resuming after them; count $multigoal_second_count" >&2; exit 1; }

# Focused subgoal: the failed-prefix point is inside a >- branch while another
# sibling subgoal remains to be discharged.  Resuming past an edited NO_TAC in
# the focused branch could otherwise prove the branch and continue to the
# sibling as if the edited failure had not happened.
focused_project=$tmpdir/focused-project
focused_counter=$tmpdir/focused-count.txt
touch "$focused_counter"
write_project "$focused_project" "checkpoint-edit-resume-no-tac-focused"
cat > "$focused_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val counter_path = "$focused_counter";
fun bump_counter () =
  let val out = TextIO.openAppend counter_path
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun counted_tac g = (bump_counter(); ALL_TAC g);
Theorem focused_no_tac_insert:
  T /\\ T
Proof
  CONJ_TAC >-
    (counted_tac >> ALL_TAC >> FAIL_TAC "focused old suffix") >-
    ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML

focused_first_log=$tmpdir/focused-first.log
if (cd "$focused_project" && "$HOLBUILD_BIN" build ATheory) > "$focused_first_log" 2>&1; then
  echo "expected focused seed proof to fail" >&2
  exit 1
fi
require_grep "focused old suffix" "$focused_first_log"
focused_first_count=$(wc -c < "$focused_counter" | tr -d ' ')
[[ "$focused_first_count" = "1" ]] || { echo "expected focused seed to run counted_tac once, got $focused_first_count" >&2; exit 1; }
require_file "$(find "$focused_project/.holbuild/checkpoints" -name '*focused_no_tac_insert_failed_prefix.save' -print -quit)"

python3 - <<PY
from pathlib import Path
path = Path("$focused_project/src/AScript.sml")
path.write_text(path.read_text().replace(
    'counted_tac >> ALL_TAC >> FAIL_TAC "focused old suffix"',
    'counted_tac >> NO_TAC >> ACCEPT_TAC TRUTH'))
PY

focused_second_log=$tmpdir/focused-second.log
if (cd "$focused_project" && "$HOLBUILD_BIN" build ATheory) > "$focused_second_log" 2>&1; then
  echo "edited focused proof succeeded after NO_TAC was introduced in focused branch" >&2
  exit 1
fi
require_grep "NO_TAC" "$focused_second_log"
focused_second_count=$(wc -c < "$focused_counter" | tr -d ' ')
[[ "$focused_second_count" = "1" ]] || { echo "focused edit reran unchanged counted_tac instead of resuming after it; count $focused_second_count" >&2; exit 1; }

# Dynamic-combinator variant: editing the successful leaf under ORELSE to a
# failing alternative must not be skipped by failed-prefix replay.
dynamic_project=$tmpdir/dynamic-project
dynamic_counter=$tmpdir/dynamic-count.txt
touch "$dynamic_counter"
write_project "$dynamic_project" "checkpoint-edit-resume-no-tac-dynamic"
cat > "$dynamic_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val counter_path = "$dynamic_counter";
fun bump_counter () =
  let val out = TextIO.openAppend counter_path
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun counted_tac g = (bump_counter(); ALL_TAC g);
Theorem dynamic_no_tac_replace:
  T
Proof
  (NO_TAC ORELSE counted_tac) >> ALL_TAC >> FAIL_TAC "dynamic old suffix"
QED
val _ = export_theory();
SML

dynamic_first_log=$tmpdir/dynamic-first.log
if (cd "$dynamic_project" && "$HOLBUILD_BIN" build ATheory) > "$dynamic_first_log" 2>&1; then
  echo "expected dynamic seed proof to fail" >&2
  exit 1
fi
require_grep "dynamic old suffix" "$dynamic_first_log"
dynamic_first_count=$(wc -c < "$dynamic_counter" | tr -d ' ')
[[ "$dynamic_first_count" = "1" ]] || { echo "expected dynamic seed to run counted_tac once, got $dynamic_first_count" >&2; exit 1; }
require_file "$(find "$dynamic_project/.holbuild/checkpoints" -name '*dynamic_no_tac_replace_failed_prefix.save' -print -quit)"

python3 - <<PY
from pathlib import Path
path = Path("$dynamic_project/src/AScript.sml")
path.write_text(path.read_text().replace(
    '(NO_TAC ORELSE counted_tac) >> ALL_TAC >> FAIL_TAC "dynamic old suffix"',
    '(NO_TAC ORELSE NO_TAC) >> ACCEPT_TAC TRUTH'))
PY

dynamic_second_log=$tmpdir/dynamic-second.log
if (cd "$dynamic_project" && "$HOLBUILD_BIN" build ATheory) > "$dynamic_second_log" 2>&1; then
  echo "edited dynamic proof succeeded after ORELSE prefix was changed to NO_TAC" >&2
  exit 1
fi
require_grep "NO_TAC" "$dynamic_second_log"
dynamic_second_count=$(wc -c < "$dynamic_counter" | tr -d ' ')
[[ "$dynamic_second_count" = "1" ]] || { echo "dynamic edit unexpectedly ran counted_tac after it was replaced by NO_TAC; count $dynamic_second_count" >&2; exit 1; }
