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

project=$tmpdir/project
counter=$tmpdir/slow-prefix-count.txt
mkdir -p "$project/src"
touch "$counter"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

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
require_grep "plan position: 02 list_tactic >> FAIL_TAC" "$first_log"
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
require_grep "plan position: 02 list_tactic >> FAIL_TAC" "$edited_log"
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
  !i:int. T
Proof
  strip_tac >>
  Cases_on `i < 0`
  >- (
    sg `0 <= -i` >- intLib.ARITH_TAC >>
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
require_grep "plan position: 04 branch_suffix" "$prefix_edit_first_log"
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
if grep -q "fragment: >> strip_tac" "$prefix_edit_second_log"; then
  echo "failed-prefix replay after prefix edit resumed from an inconsistent proof state" >&2
  exit 1
fi
if grep -q "branch suffix without active branch" "$prefix_edit_second_log"; then
  echo "failed-prefix replay after prefix edit lost branch state" >&2
  exit 1
fi
require_grep "plan position: 05 branch_suffix" "$prefix_edit_second_log"

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
