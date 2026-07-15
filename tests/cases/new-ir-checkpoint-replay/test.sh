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

project=$tmpdir/project
counter=$tmpdir/slow-prefix-count.txt
mkdir -p "$project/src"
touch "$counter"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "new-ir-replay"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val slow_prefix_counter = "$counter";
fun bump_counter () =
  let val out = TextIO.openAppend slow_prefix_counter
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun slow_tac g = (bump_counter(); OS.Process.sleep (Time.fromReal 0.25); ALL_TAC g);
Theorem slow_prefix_failure:
  T
Proof
  slow_tac >> slow_tac >> FAIL_TAC "first suffix failure"
QED
val _ = export_theory();
SML

first_log=$tmpdir/first.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$first_log" 2>&1; then
  echo "expected first new-ir proof to fail" >&2
  exit 1
fi
first_count=$(wc -c < "$counter" | tr -d ' ')
[[ "$first_count" = "2" ]] || { echo "expected first run to execute slow prefix twice, got $first_count" >&2; exit 1; }
require_grep "FAIL_TAC \"first suffix failure\"" "$first_log"
require_grep "failed tactic top input goal:" "$first_log"
require_grep 'plan position: 02 step FAIL_TAC "first suffix failure"' "$first_log"
require_grep "failed tactic input goals: 1" "$first_log"
require_file "$(find "$project/.holbuild/checkpoints" -name '*slow_prefix_failure_failed_prefix.save' -print -quit)"

python3 - <<PY
from pathlib import Path
path = Path("$project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "first suffix failure"', 'FAIL_TAC "edited suffix failure"'))
PY
edited_log=$tmpdir/edited.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$edited_log" 2>&1; then
  echo "expected edited suffix new-ir proof to fail" >&2
  exit 1
fi
edited_count=$(wc -c < "$counter" | tr -d ' ')
[[ "$edited_count" = "2" ]] || { echo "new-ir failed-prefix replay reran unchanged slow prefix after suffix edit; count $edited_count" >&2; exit 1; }
require_grep "from: failed-prefix checkpoint in slow_prefix_failure" "$edited_log"
require_grep "edited suffix failure" "$edited_log"
require_grep 'plan position: 02 step FAIL_TAC "edited suffix failure"' "$edited_log"
require_grep "failed tactic input goals: 1" "$edited_log"

python3 - <<PY
from pathlib import Path
path = Path("$project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "edited suffix failure"', 'ACCEPT_TAC TRUTH'))
PY
fixed_log=$tmpdir/fixed.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$fixed_log" 2>&1
fixed_count=$(wc -c < "$counter" | tr -d ' ')
[[ "$fixed_count" = "2" ]] || { echo "new-ir failed-prefix replay reran unchanged slow prefix after suffix fix; count $fixed_count" >&2; exit 1; }
require_grep "from: failed-prefix checkpoint in slow_prefix_failure" "$fixed_log"
require_grep "ATheory built" "$fixed_log"
require_file "$project/.holbuild/obj/src/ATheory.dat"

prefix_edit_project=$tmpdir/prefix-edit-project
mkdir -p "$prefix_edit_project/src"
cp "$project/holproject.toml" "$prefix_edit_project/holproject.toml"
cat > "$prefix_edit_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem replay_after_prefix_edit:
  !i:num. T
Proof
  strip_tac >>
  Cases_on `i = 0`
  >- (
    sg `1 = 1` >- simp[] >>
    NO_TAC
  )
  >> NO_TAC
QED
val _ = export_theory();
SML

prefix_edit_first_log=$tmpdir/prefix-edit-first.log
if (cd "$prefix_edit_project" && "$HOLBUILD_BIN" build ATheory) > "$prefix_edit_first_log" 2>&1; then
  echo "expected prefix-edit replay seed to fail" >&2
  exit 1
fi
require_grep "plan position: 07 step NO_TAC" "$prefix_edit_first_log"
require_file "$(find "$prefix_edit_project/.holbuild/checkpoints" -name '*replay_after_prefix_edit_failed_prefix.save' -print -quit)"

python3 - <<PY
from pathlib import Path
path = Path("$prefix_edit_project/src/AScript.sml")
path.write_text(path.read_text().replace('strip_tac >>', 'ALL_TAC >> strip_tac >>'))
PY
prefix_edit_second_log=$tmpdir/prefix-edit-second.log
if (cd "$prefix_edit_project" && "$HOLBUILD_BIN" build ATheory) > "$prefix_edit_second_log" 2>&1; then
  echo "expected edited prefix proof still to fail at NO_TAC" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in replay_after_prefix_edit" "$prefix_edit_second_log"
require_grep "restoring proof-ir prefix with 4 successful leaf steps" "$prefix_edit_second_log"
if grep -q "fragment: >> strip_tac" "$prefix_edit_second_log"; then
  echo "failed-prefix replay after prefix edit resumed from an inconsistent proof state" >&2
  exit 1
fi
if grep -q "branch suffix without active branch" "$prefix_edit_second_log"; then
  echo "failed-prefix replay after prefix edit lost branch state" >&2
  exit 1
fi
require_grep "plan position: 08 step NO_TAC" "$prefix_edit_second_log"

cases_replay_project=$tmpdir/cases-replay-project
cases_counter=$tmpdir/cases-count.txt
mkdir -p "$cases_replay_project/src"
touch "$cases_counter"
cp "$project/holproject.toml" "$cases_replay_project/holproject.toml"
cat > "$cases_replay_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val slow_prefix_counter = "$cases_counter";
fun bump_counter () =
  let val out = TextIO.openAppend slow_prefix_counter
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun slow_tac g = (bump_counter(); OS.Process.sleep (Time.fromReal 0.25); ALL_TAC g);
Theorem cases_replay:
  T /\\ T
Proof
  CONJ_TAC >| [
    slow_tac >> ACCEPT_TAC TRUTH,
    slow_tac >> FAIL_TAC "cases suffix failure"
  ]
QED
val _ = export_theory();
SML
cases_first_log=$tmpdir/cases-first.log
if (cd "$cases_replay_project" && "$HOLBUILD_BIN" build ATheory) > "$cases_first_log" 2>&1; then
  echo "expected cases replay seed to fail" >&2
  exit 1
fi
cases_first_count=$(wc -c < "$cases_counter" | tr -d ' ')
[[ "$cases_first_count" = "2" ]] || { echo "expected first cases run to execute slow prefix twice, got $cases_first_count" >&2; exit 1; }
require_grep 'plan position: 07 step FAIL_TAC "cases suffix failure"' "$cases_first_log"
python3 - <<PY
from pathlib import Path
path = Path("$cases_replay_project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "cases suffix failure"', 'FAIL_TAC "edited cases suffix failure"'))
PY
cases_second_log=$tmpdir/cases-second.log
if (cd "$cases_replay_project" && "$HOLBUILD_BIN" build ATheory) > "$cases_second_log" 2>&1; then
  echo "expected edited cases replay proof to fail" >&2
  exit 1
fi
cases_second_count=$(wc -c < "$cases_counter" | tr -d ' ')
[[ "$cases_second_count" = "2" ]] || { echo "cases failed-prefix replay reran unchanged case prefixes; count $cases_second_count" >&2; exit 1; }
require_grep "from: failed-prefix checkpoint in cases_replay" "$cases_second_log"
require_grep 'plan position: 07 step FAIL_TAC "edited cases suffix failure"' "$cases_second_log"

each_replay_project=$tmpdir/each-replay-project
each_counter=$tmpdir/each-count.txt
mkdir -p "$each_replay_project/src"
touch "$each_counter"
cp "$project/holproject.toml" "$each_replay_project/holproject.toml"
cat > "$each_replay_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val slow_prefix_counter = "$each_counter";
fun bump_counter () =
  let val out = TextIO.openAppend slow_prefix_counter
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun slow_tac g = (bump_counter(); OS.Process.sleep (Time.fromReal 0.25); ALL_TAC g);
Theorem each_replay:
  (T /\\ T) /\\ (T /\\ T)
Proof
  CONJ_TAC >>
  (slow_tac >> CONJ_TAC >- ACCEPT_TAC TRUTH >> FAIL_TAC "each suffix failure")
QED
val _ = export_theory();
SML
each_first_log=$tmpdir/each-first.log
if (cd "$each_replay_project" && "$HOLBUILD_BIN" build ATheory) > "$each_first_log" 2>&1; then
  echo "expected each replay seed to fail" >&2
  exit 1
fi
each_first_count=$(wc -c < "$each_counter" | tr -d ' ')
[[ "$each_first_count" = "1" ]] || { echo "expected first each run to execute slow prefix once before failure, got $each_first_count" >&2; exit 1; }
require_grep 'FAIL_TAC "each suffix failure"' "$each_first_log"
python3 - <<PY
from pathlib import Path
path = Path("$each_replay_project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "each suffix failure"', 'FAIL_TAC "edited each suffix failure"'))
PY
each_second_log=$tmpdir/each-second.log
if (cd "$each_replay_project" && "$HOLBUILD_BIN" build ATheory) > "$each_second_log" 2>&1; then
  echo "expected edited each replay proof to fail" >&2
  exit 1
fi
each_second_count=$(wc -c < "$each_counter" | tr -d ' ')
[[ "$each_second_count" = "1" ]] || { echo "each failed-prefix replay reran unchanged each prefix; count $each_second_count" >&2; exit 1; }
require_grep "from: failed-prefix checkpoint in each_replay" "$each_second_log"
require_grep 'FAIL_TAC "edited each suffix failure"' "$each_second_log"

unsafe_replay_project=$tmpdir/unsafe-replay-project
unsafe_counter=$tmpdir/unsafe-count.txt
mkdir -p "$unsafe_replay_project/src"
touch "$unsafe_counter"
cp "$project/holproject.toml" "$unsafe_replay_project/holproject.toml"
cat > "$unsafe_replay_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val slow_prefix_counter = "$unsafe_counter";
fun bump_counter () =
  let val out = TextIO.openAppend slow_prefix_counter
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun slow_tac g = (bump_counter(); OS.Process.sleep (Time.fromReal 0.25); ALL_TAC g);
Theorem unsafe_replay:
  T /\ T
Proof
  CONJ_TAC >> FAIL_TAC "unsafe suffix failure"
QED
val _ = export_theory();
SML
unsafe_first_log=$tmpdir/unsafe-first.log
if (cd "$unsafe_replay_project" && "$HOLBUILD_BIN" build ATheory) > "$unsafe_first_log" 2>&1; then
  echo "expected unsafe replay seed to fail" >&2
  exit 1
fi
python3 - <<PY
from pathlib import Path
path = Path("$unsafe_replay_project/src/AScript.sml")
path.write_text(path.read_text().replace('CONJ_TAC >> FAIL_TAC "unsafe suffix failure"', 'ALL_TAC >> FAIL_TAC "unsafe edited failure"'))
PY
unsafe_second_log=$tmpdir/unsafe-second.log
if (cd "$unsafe_replay_project" && "$HOLBUILD_BIN" build ATheory) > "$unsafe_second_log" 2>&1; then
  echo "expected unsafe edited proof to fail" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in unsafe_replay" "$unsafe_second_log"
require_grep 'plan position: 01 step FAIL_TAC "unsafe edited failure"' "$unsafe_second_log"
require_grep "T ∧ T" "$unsafe_second_log"

resume_project=$tmpdir/resume-project
resume_counter=$tmpdir/resume-count.txt
mkdir -p "$resume_project/src"
touch "$resume_counter"
cp "$project/holproject.toml" "$resume_project/holproject.toml"
cat > "$resume_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib markerLib;
val _ = new_theory "A";
val slow_prefix_counter = "$resume_counter";
fun bump_counter () =
  let val out = TextIO.openAppend slow_prefix_counter
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun slow_tac g = (bump_counter(); OS.Process.sleep (Time.fromReal 0.25); ALL_TAC g);
Theorem partial:
  T /\\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >- suspend "right"
QED
Resume partial[right,smlname=partial_right_resume]:
  slow_tac >> slow_tac >> FAIL_TAC "resume suffix failure"
QED
Finalise partial
val _ = concl partial_right_resume;
val _ = export_theory();
SML

resume_first_log=$tmpdir/resume-first.log
if (cd "$resume_project" && "$HOLBUILD_BIN" build ATheory) > "$resume_first_log" 2>&1; then
  echo "expected first Resume proof to fail" >&2
  exit 1
fi
resume_first_count=$(wc -c < "$resume_counter" | tr -d ' ')
[[ "$resume_first_count" = "2" ]] || { echo "expected first Resume run to execute slow prefix twice, got $resume_first_count" >&2; exit 1; }
require_grep "resume suffix failure" "$resume_first_log"
require_file "$(find "$resume_project/.holbuild/checkpoints" -name '*partial_right__failed_prefix.save' -print -quit)"

python3 - <<PY
from pathlib import Path
path = Path("$resume_project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "resume suffix failure"', 'ACCEPT_TAC TRUTH'))
PY
resume_fixed_log=$tmpdir/resume-fixed.log
(cd "$resume_project" && "$HOLBUILD_BIN" build ATheory) > "$resume_fixed_log" 2>&1
resume_fixed_count=$(wc -c < "$resume_counter" | tr -d ' ')
[[ "$resume_fixed_count" = "2" ]] || { echo "Resume failed-prefix replay reran unchanged slow prefix after suffix fix; count $resume_fixed_count" >&2; exit 1; }
require_grep "from: failed-prefix checkpoint in partial_right_" "$resume_fixed_log"
require_grep "ATheory built" "$resume_fixed_log"
require_file "$resume_project/.holbuild/obj/src/ATheory.dat"

shorten_project=$tmpdir/shorten-project
shorten_counter=$tmpdir/shorten-count.txt
mkdir -p "$shorten_project/src"
touch "$shorten_counter"
cp "$project/holproject.toml" "$shorten_project/holproject.toml"
python3 - <<PY
from pathlib import Path
project = Path("$shorten_project")
counter = Path("$shorten_counter")
long_prefix = " >> ".join(["slow_tac"] + ["ALL_TAC"] * 20 + ['FAIL_TAC "long suffix failure"'])
(project / "src" / "AScript.sml").write_text(f'''open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val slow_prefix_counter = "{counter}";
fun bump_counter () =
  let val out = TextIO.openAppend slow_prefix_counter
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun slow_tac g = (bump_counter(); ALL_TAC g);
Theorem shortened_replay:
  T
Proof
  {long_prefix}
QED
val _ = export_theory();
''')
PY

shorten_first_log=$tmpdir/shorten-first.log
if (cd "$shorten_project" && "$HOLBUILD_BIN" build ATheory) > "$shorten_first_log" 2>&1; then
  echo "expected shortened replay first build to fail" >&2
  exit 1
fi
shorten_first_count=$(wc -c < "$shorten_counter" | tr -d ' ')
[[ "$shorten_first_count" = "1" ]] || { echo "expected shortened replay first run to execute slow prefix once, got $shorten_first_count" >&2; exit 1; }
require_grep "long suffix failure" "$shorten_first_log"

python3 - <<PY
from pathlib import Path
path = Path("$shorten_project/src/AScript.sml")
text = path.read_text()
proof = text.index('Proof')
start = text.index('slow_tac', proof)
end = text.index('QED', start)
path.write_text(text[:start] + 'slow_tac >> FAIL_TAC "short suffix failure"\n' + text[end:])
PY
shorten_edit_log=$tmpdir/shorten-edit.log
if (cd "$shorten_project" && "$HOLBUILD_BIN" build ATheory) > "$shorten_edit_log" 2>&1; then
  echo "expected shortened replay edited build to fail" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in shortened_replay" "$shorten_edit_log"
require_grep "short suffix failure" "$shorten_edit_log"
if grep -q "CANT_BACKUP_ANYMORE" "$shorten_edit_log"; then
  echo "failed-prefix replay could not rewind retained proof history" >&2
  exit 1
fi

unsolved_project=$tmpdir/unsolved-project
mkdir -p "$unsolved_project/src"
cp "$project/holproject.toml" "$unsolved_project/holproject.toml"
cat > "$unsolved_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem unsolved_finish_replay:
  T
Proof
  ALL_TAC >> FAIL_TAC "saved failed-prefix before unsolved suffix"
QED
val _ = export_theory();
SML

unsolved_first_log=$tmpdir/unsolved-first.log
if (cd "$unsolved_project" && "$HOLBUILD_BIN" build ATheory) > "$unsolved_first_log" 2>&1; then
  echo "expected unsolved replay seed to fail" >&2
  exit 1
fi
require_grep "saved failed-prefix before unsolved suffix" "$unsolved_first_log"

python3 - <<PY
from pathlib import Path
path = Path("$unsolved_project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "saved failed-prefix before unsolved suffix"', 'ALL_TAC'))
PY
unsolved_edit_log=$tmpdir/unsolved-edit.log
if (cd "$unsolved_project" && "$HOLBUILD_BIN" build ATheory) > "$unsolved_edit_log" 2>&1; then
  echo "expected failed-prefix replay with unsolved suffix to fail" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in unsolved_finish_replay" "$unsolved_edit_log"
require_grep "fragment: unsolved_finish_replay finish" "$unsolved_edit_log"
require_grep "> 7 | QED" "$unsolved_edit_log"
require_grep "no theorem proved" "$unsolved_edit_log"
require_grep "failed tactic top input goal:" "$unsolved_edit_log"
require_grep "failed tactic input goals: 1" "$unsolved_edit_log"

stale_project=$tmpdir/stale-prefix-project
mkdir -p "$stale_project/src"
cp "$project/holproject.toml" "$stale_project/holproject.toml"
cat > "$stale_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem first_stale_prefix:
  T
Proof
  ALL_TAC >> FAIL_TAC "seed stale failed prefix"
QED
Theorem second_replay_target:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = raise Fail "late non-proof failure";
SML

stale_first_log=$tmpdir/stale-first.log
if (cd "$stale_project" && "$HOLBUILD_BIN" build ATheory) > "$stale_first_log" 2>&1; then
  echo "expected stale-prefix seed to fail" >&2
  exit 1
fi
require_grep "seed stale failed prefix" "$stale_first_log"

python3 - <<PY
from pathlib import Path
path = Path("$stale_project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "seed stale failed prefix"', 'ACCEPT_TAC TRUTH'))
PY
stale_second_log=$tmpdir/stale-second.log
if (cd "$stale_project" && "$HOLBUILD_BIN" build ATheory) > "$stale_second_log" 2>&1; then
  echo "expected late non-proof failure after stale-prefix replay" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in first_stale_prefix" "$stale_second_log"
require_grep "late non-proof failure" "$stale_second_log"

python3 - <<PY
from pathlib import Path
path = Path("$stale_project/src/AScript.sml")
path.write_text(path.read_text().replace('late non-proof failure', 'late non-proof failure edited'))
PY
stale_third_log=$tmpdir/stale-third.log
if (cd "$stale_project" && "$HOLBUILD_BIN" build ATheory) > "$stale_third_log" 2>&1; then
  echo "expected edited late non-proof failure" >&2
  exit 1
fi
require_grep "from: theorem-context checkpoint after second_replay_target" "$stale_third_log"
if grep -q "from: failed-prefix checkpoint in first_stale_prefix" "$stale_third_log"; then
  echo "stale earlier failed-prefix outranked later theorem-context checkpoint" >&2
  exit 1
fi
require_grep "late non-proof failure edited" "$stale_third_log"

# Regression for unsafe salvage inside structural cases: if the failed-prefix
# endpoint becomes stale, salvaging to an earlier leaf inside a cases frame must
# preserve the frame/focus metadata needed to continue in the current case.
structural_salvage_project=$tmpdir/structural-salvage-project
structural_salvage_counter=$tmpdir/structural-salvage-count.txt
mkdir -p "$structural_salvage_project/src"
touch "$structural_salvage_counter"
cp "$project/holproject.toml" "$structural_salvage_project/holproject.toml"
cat > "$structural_salvage_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val slow_prefix_counter = "$structural_salvage_counter";
fun bump_counter () =
  let val out = TextIO.openAppend slow_prefix_counter
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun slow_tac g = (bump_counter(); ALL_TAC g);
Theorem salvage_inside_cases:
  T /\\ T
Proof
  CONJ_TAC >| [
    ACCEPT_TAC TRUTH,
    slow_tac >> ALL_TAC >> FAIL_TAC "structural salvage old suffix"
  ]
QED
val _ = export_theory();
SML
structural_salvage_first_log=$tmpdir/structural-salvage-first.log
if (cd "$structural_salvage_project" && "$HOLBUILD_BIN" build ATheory) > "$structural_salvage_first_log" 2>&1; then
  echo "expected structural salvage seed to fail" >&2
  exit 1
fi
structural_salvage_first_count=$(wc -c < "$structural_salvage_counter" | tr -d ' ')
[[ "$structural_salvage_first_count" = "1" ]] || { echo "expected structural salvage seed to run slow_tac once, got $structural_salvage_first_count" >&2; exit 1; }
require_grep 'structural salvage old suffix' "$structural_salvage_first_log"
python3 - <<PY
from pathlib import Path
path = Path("$structural_salvage_project/src/AScript.sml")
path.write_text(path.read_text().replace('slow_tac >> ALL_TAC >> FAIL_TAC "structural salvage old suffix"',
                                      'slow_tac >> FAIL_TAC "structural salvage edited suffix"'))
PY
structural_salvage_second_log=$tmpdir/structural-salvage-second.log
if (cd "$structural_salvage_project" && "$HOLBUILD_BIN" build ATheory) > "$structural_salvage_second_log" 2>&1; then
  echo "expected structural salvage edited proof to fail" >&2
  exit 1
fi
structural_salvage_second_count=$(wc -c < "$structural_salvage_counter" | tr -d ' ')
[[ "$structural_salvage_second_count" = "1" ]] || { echo "structural failed-prefix salvage reran unchanged case leaf; count $structural_salvage_second_count" >&2; exit 1; }
require_grep "from: failed-prefix checkpoint in salvage_inside_cases" "$structural_salvage_second_log"
require_grep 'structural salvage edited suffix' "$structural_salvage_second_log"
if grep -q "case count mismatch\|structural frame mismatch\|focus close without active focus" "$structural_salvage_second_log"; then
  echo "structural failed-prefix salvage lost cases frame/focus state" >&2
  exit 1
fi

# Regression for overly-permissive salvage: a leaf with the same path/program but
# a changed source end should not be silently reused as a valid checkpoint prefix.
source_end_salvage_project=$tmpdir/source-end-salvage-project
source_end_salvage_counter=$tmpdir/source-end-salvage-count.txt
mkdir -p "$source_end_salvage_project/src"
touch "$source_end_salvage_counter"
cp "$project/holproject.toml" "$source_end_salvage_project/holproject.toml"
cat > "$source_end_salvage_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val slow_prefix_counter = "$source_end_salvage_counter";
fun bump_counter () =
  let val out = TextIO.openAppend slow_prefix_counter
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun slow_tac g = (bump_counter(); ALL_TAC g);
Theorem source_end_salvage:
  T
Proof
  slow_tac >> FAIL_TAC "source-end old suffix"
QED
val _ = export_theory();
SML
source_end_salvage_first_log=$tmpdir/source-end-salvage-first.log
if (cd "$source_end_salvage_project" && "$HOLBUILD_BIN" build ATheory) > "$source_end_salvage_first_log" 2>&1; then
  echo "expected source-end salvage seed to fail" >&2
  exit 1
fi
source_end_salvage_first_count=$(wc -c < "$source_end_salvage_counter" | tr -d ' ')
[[ "$source_end_salvage_first_count" = "1" ]] || { echo "expected source-end seed to run slow_tac once, got $source_end_salvage_first_count" >&2; exit 1; }
python3 - <<PY
from pathlib import Path
path = Path("$source_end_salvage_project/src/AScript.sml")
path.write_text(path.read_text().replace('slow_tac >> FAIL_TAC "source-end old suffix"',
                                      '   slow_tac >> FAIL_TAC "source-end edited suffix"'))
PY
source_end_salvage_second_log=$tmpdir/source-end-salvage-second.log
if (cd "$source_end_salvage_project" && "$HOLBUILD_BIN" build ATheory) > "$source_end_salvage_second_log" 2>&1; then
  echo "expected source-end edited proof to fail" >&2
  exit 1
fi
source_end_salvage_second_count=$(wc -c < "$source_end_salvage_counter" | tr -d ' ')
[[ "$source_end_salvage_second_count" = "2" ]] || { echo "source-end changed leaf was incorrectly salvaged without rerunning; count $source_end_salvage_second_count" >&2; exit 1; }
require_grep 'source-end edited suffix' "$source_end_salvage_second_log"

all_tac_span_project=$tmpdir/all-tac-span-project
all_tac_span_counter=$tmpdir/all-tac-span-count.txt
mkdir -p "$all_tac_span_project/src"
touch "$all_tac_span_counter"
cp "$project/holproject.toml" "$all_tac_span_project/holproject.toml"
cat > "$all_tac_span_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val slow_prefix_counter = "$all_tac_span_counter";
fun bump_counter () =
  let val out = TextIO.openAppend slow_prefix_counter
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun slow_tac g = (bump_counter(); ALL_TAC g);
Theorem all_tac_span_replay:
  T
Proof
  slow_tac >> ALL_TAC >> FAIL_TAC "all-tac span suffix"
QED
val _ = export_theory();
SML
all_tac_span_log=$tmpdir/all-tac-span.log
if (cd "$all_tac_span_project" && "$HOLBUILD_BIN" build ATheory) > "$all_tac_span_log" 2>&1; then
  echo "expected all-tac span proof to fail" >&2
  exit 1
fi
all_tac_span_meta=$(find "$all_tac_span_project/.holbuild/checkpoints" -name '*all_tac_span_replay_failed_prefix.save.meta' -print -quit)
require_file "$all_tac_span_meta"
python3 - "$all_tac_span_meta" <<'PY'
import sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text().splitlines()
all_tac_leaves = [line for line in lines if line.startswith('leaf=') and 'ALL_TAC' in line]
if not all_tac_leaves:
    raise SystemExit('failed-prefix metadata did not record the ALL_TAC leaf')
for line in all_tac_leaves:
    fields = line[len('leaf='):].split('\t')
    if len(fields) >= 2 and fields[1] == '0':
        raise SystemExit(f'ALL_TAC leaf recorded source end 0: {line}')
PY

by_chain_resume_project=$tmpdir/by-chain-resume-project
by_chain_resume_counter=$tmpdir/by-chain-resume-count.txt
mkdir -p "$by_chain_resume_project/src"
touch "$by_chain_resume_counter"
cp "$project/holproject.toml" "$by_chain_resume_project/holproject.toml"
cat > "$by_chain_resume_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val by_chain_resume_counter = "$by_chain_resume_counter";
fun bump_counter () =
  let val out = TextIO.openAppend by_chain_resume_counter
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun counted_tac g = (bump_counter(); ALL_TAC g);
Theorem by_chain_resume_inside_tac:
  1 + 1 = SUC 1
Proof
  \`1 + 1 = 2\` by (counted_tac >> FAIL_TAC "old by rhs failure") >>
  \`_ = SUC 1\` by EVAL_TAC >>
  (fn g as (asl, _) =>
     if length asl = 1 then ALL_TAC g
     else FAIL_TAC "resumed by chain should leave exactly one assumption" g) >>
  pop_assum ACCEPT_TAC
QED
val _ = export_theory();
SML
by_chain_resume_first_log=$tmpdir/by-chain-resume-first.log
if (cd "$by_chain_resume_project" && "$HOLBUILD_BIN" build ATheory) > "$by_chain_resume_first_log" 2>&1; then
  echo "expected by-chain resume seed proof to fail" >&2
  exit 1
fi
by_chain_resume_first_count=$(wc -c < "$by_chain_resume_counter" | tr -d ' ')
[[ "$by_chain_resume_first_count" = "1" ]] || { echo "expected by-chain seed to run counted_tac once, got $by_chain_resume_first_count" >&2; exit 1; }
require_grep 'old by rhs failure' "$by_chain_resume_first_log"
require_file "$(find "$by_chain_resume_project/.holbuild/checkpoints" -name '*by_chain_resume_inside_tac_failed_prefix.save' -print -quit)"
python3 - <<PY
from pathlib import Path
path = Path("$by_chain_resume_project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "old by rhs failure"', 'EVAL_TAC'))
PY
by_chain_resume_second_log=$tmpdir/by-chain-resume-second.log
(cd "$by_chain_resume_project" && "$HOLBUILD_BIN" build ATheory) > "$by_chain_resume_second_log" 2>&1
by_chain_resume_second_count=$(wc -c < "$by_chain_resume_counter" | tr -d ' ')
[[ "$by_chain_resume_second_count" = "1" ]] || { echo "by-chain failed-prefix replay reran unchanged counted_tac; count $by_chain_resume_second_count" >&2; exit 1; }
require_grep 'from: failed-prefix checkpoint in by_chain_resume_inside_tac' "$by_chain_resume_second_log"
require_grep 'ATheory built' "$by_chain_resume_second_log"
