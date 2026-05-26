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
export HOLBUILD_CACHE="$tmpdir/cache"
repo_root=$(cd "$SCRIPT_DIR/../../.." && pwd)

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<'TOML'
[project]
name = "replay"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;

val _ = new_theory "A";

Theorem simple_thm = TRUTH;

Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem b_thm:
  T /\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >- ACCEPT_TAC TRUTH
QED

Theorem c_thm:
  T
Proof[exclude_simps = bool_case_thm]
  ACCEPT_TAC TRUTH
QED

val prove_subgoal_tac =
  fn g => (ignore (Tactical.prove (``T``, ACCEPT_TAC TRUTH)); ALL_TAC g);

Theorem reentrant_prover:
  T
Proof
  prove_subgoal_tac
  \\ ACCEPT_TAC TRUTH
QED

Theorem reverse_cases:
  !b. b = T \/ b = F
Proof
  gen_tac
  \\ reverse (Cases_on `b`)
  >- (DISJ2_TAC \\ REFL_TAC)
  \\ DISJ1_TAC
  \\ REFL_TAC
QED

Theorem generated_thenl:
  T /\ T
Proof
  CONJ_TAC THENL
  let
    fun tac () = ACCEPT_TAC TRUTH
  in
    [tac (), tac ()]
  end
QED

Theorem by_after_split:
  T /\ T
Proof
  CONJ_TAC
  \\ `T` by ACCEPT_TAC TRUTH
  \\ ACCEPT_TAC TRUTH
QED

Theorem suffices_after_split:
  F ==> (T /\ T)
Proof
  strip_tac
  \\ CONJ_TAC
  \\ `F` suffices_by simp[]
  \\ FIRST_ASSUM ACCEPT_TAC
QED

Theorem unicode_quote_by:
  T
Proof
  ‘T’ by ACCEPT_TAC TRUTH
  \\ ACCEPT_TAC TRUTH
QED

Theorem quoted_keyword_tokens:
  T
Proof
  (ignore ``QED``; ignore ‘Proof’; ACCEPT_TAC TRUTH)
QED

Theorem reverse_multi_goal_validation:
  (T /\ T) /\ T
Proof
  CONJ_TAC
  \\ Tactical.REVERSE (TRY CONJ_TAC) THENL
     [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem reverse_multi_goal_order:
  (T /\ (F ==> F)) /\ T
Proof
  CONJ_TAC
  \\ reverse (TRY CONJ_TAC) THENL
     [DISCH_TAC \\ FIRST_ASSUM ACCEPT_TAC,
      ACCEPT_TAC TRUTH,
      ACCEPT_TAC TRUTH]
QED

Theorem branch_body_all_subgoals:
  (T /\ T) /\ T
Proof
  CONJ_TAC
  >- (TRY CONJ_TAC >> ACCEPT_TAC TRUTH)
  \\ ACCEPT_TAC TRUTH
QED

Theorem induction_shared_suffix:
  ∀xs:'a list. xs = xs
Proof
  Induct_on `xs` >> simp[]
QED

Theorem repeat_split:
  ∀p q. p ∧ q ⇒ p
Proof
  rpt gen_tac >> strip_tac >> first_assum ACCEPT_TAC
QED

val _ = export_theory();
SML

first_log=$tmpdir/first.log
(cd "$project" && \
  HOLBUILD_CHECKPOINT_TIMING=1 HOLBUILD_ECHO_CHILD_LOGS=1 "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) \
  > "$first_log" 2>&1
require_grep "holbuild checkpoint kind=deps_loaded" "$first_log"
require_grep "holbuild checkpoint kind=end_of_proof" "$first_log"
require_grep "holbuild checkpoint kind=theorem_context" "$first_log"
require_grep "holbuild checkpoint kind=final_context" "$first_log"
if grep -q '^[0-9][0-9]* subgoals:$' "$first_log"; then
  echo "proof IR child log leaked interactive goal-stack progress" >&2
  exit 1
fi
require_file "$project/.holbuild/obj/src/ATheory.sig"
require_file "$project/.holbuild/obj/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_grep "dependency_context_key=" "$project/.holbuild/dep/replay/src/AScript.sml.key"
if grep -q "theorem_boundary\|_end_of_proof.save\|deps_loaded=\|final_context=" "$project/.holbuild/dep/replay/src/AScript.sml.key"; then
  echo "successful metadata retained checkpoint paths" >&2
  exit 1
fi
# checkpoints persist after successful builds for incremental rebuilds
if ! find "$project/.holbuild/checkpoints" -path '*_context.save' -print -quit 2>/dev/null | grep -q .; then
  echo "successful theorem build should retain theorem context checkpoints" >&2
  exit 1
fi

second_log=$tmpdir/second.log
(cd "$project" && "$HOLBUILD_BIN" --verbose --holdir "$HOLDIR" build ATheory) > "$second_log"
require_grep "ATheory is up to date" "$second_log"

same_artifact_skip_goalfrag_log=$tmpdir/same-artifact-skip-goalfrag.log
(cd "$project" && "$HOLBUILD_BIN" --verbose --holdir "$HOLDIR" build --skip-goalfrag ATheory) > "$same_artifact_skip_goalfrag_log"
require_grep "ATheory is up to date" "$same_artifact_skip_goalfrag_log"

trace_project=$tmpdir/trace-project
mkdir -p "$trace_project/src"
cp "$project/holproject.toml" "$trace_project/holproject.toml"
cp "$project/src/AScript.sml" "$trace_project/src/AScript.sml"
plan_log=$tmpdir/goalfrag-plan.log
(cd "$trace_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" goalfrag-plan ATheory:b_thm) > "$plan_log" 2>&1
require_grep "holbuild goalfrag plan ATheory:b_thm source=src/AScript.sml (" "$plan_log"
require_grep "^[[:space:]]*00 .*CONJ_TAC" "$plan_log"
require_grep "^[[:space:]]*[0-9][0-9][[:space:]]*>-" "$plan_log"
require_grep "^[[:space:]]*[0-9][0-9] .*ACCEPT_TAC TRUTH" "$plan_log"
if grep -q "open_\|close_\|next_" "$plan_log"; then
  echo "goalfrag plan leaked structural IR names" >&2
  exit 1
fi
reverse_plan_log=$tmpdir/reverse-goalfrag-plan.log
(cd "$trace_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" goalfrag-plan ATheory:reverse_cases) > "$reverse_plan_log" 2>&1
require_grep "^[[:space:]]*00 gen_tac" "$reverse_plan_log"
require_grep "list_tac Tactical.REVERSE_LT" "$reverse_plan_log"
require_grep "^[[:space:]]*[0-9][0-9] .*DISJ1_TAC" "$reverse_plan_log"
repeat_plan_log=$tmpdir/repeat-goalfrag-plan.log
(cd "$trace_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" goalfrag-plan ATheory:repeat_split) > "$repeat_plan_log" 2>&1
require_grep "^[[:space:]]*[0-9][0-9] .*rpt" "$repeat_plan_log"
require_grep "^[[:space:]]*[0-9][0-9] .*gen_tac" "$repeat_plan_log"
if grep -q "rpt (\|^[[:space:]]*[0-9][0-9].*)$" "$repeat_plan_log"; then
  echo "goalfrag plan rendered repeat as fake numbered parens" >&2
  exit 1
fi
by_plan_log=$tmpdir/by-goalfrag-plan.log
(cd "$trace_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" goalfrag-plan ATheory:by_after_split) > "$by_plan_log" 2>&1
require_grep '^[[:space:]]*[0-9][0-9] .*sg `T`' "$by_plan_log"
require_grep "^[[:space:]]*[0-9][0-9][[:space:]]*>-" "$by_plan_log"
require_grep "^[[:space:]]*[0-9][0-9] .*ACCEPT_TAC TRUTH" "$by_plan_log"
if grep -q " by (" "$by_plan_log"; then
  echo "goalfrag plan kept by body opaque" >&2
  exit 1
fi
suffices_plan_log=$tmpdir/suffices-goalfrag-plan.log
(cd "$trace_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" goalfrag-plan ATheory:suffices_after_split) > "$suffices_plan_log" 2>&1
require_grep '^[[:space:]]*[0-9][0-9] .*`F` suffices_by simp\[\]' "$suffices_plan_log"
if grep -q "open_\|close_\|next_" "$reverse_plan_log"; then
  echo "goalfrag plan leaked structural IR names" >&2
  exit 1
fi
if grep -q "holbuild goalfrag before theorem=b_thm\|elapsed_ms=\|ATheory built\|ATheory inspected\|resuming ATheory" "$plan_log"; then
  echo "--goalfrag-plan executed the build instead of statically printing the plan" >&2
  exit 1
fi
trace_log=$tmpdir/goalfrag-trace.log
(cd "$trace_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --force --goalfrag --goalfrag-trace ATheory) > "$trace_log" 2>&1
require_grep "ATheory built" "$trace_log"
if grep -q "holbuild goalfrag plan theorem=\|holbuild goalfrag before theorem=" "$trace_log"; then
  echo "--goalfrag-trace should not dump successful proof traces to stdout" >&2
  exit 1
fi
require_grep "goalfrag trace log:" "$trace_log"
trace_child_log=$(find "$trace_project/.holbuild/logs" -name '*-ATheory-goalfrag-trace.log' -print -quit)
require_file "$trace_child_log"
require_grep "holbuild goalfrag plan theorem=a_thm steps=" "$trace_child_log"
require_grep "holbuild goalfrag plan theorem=b_thm steps=" "$trace_child_log"
require_grep "holbuild goalfrag before theorem=b_thm step=0" "$trace_child_log"
if grep -q '^[0-9][0-9]* subgoals:$' "$trace_child_log"; then
  echo "goalfrag child log leaked interactive goal-stack progress" >&2
  exit 1
fi
require_grep "holbuild goalfrag after theorem=b_thm step=0.*elapsed_ms=" "$trace_child_log"
force_log=$tmpdir/force.log
(cd "$trace_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --force ATheory) > "$force_log" 2>&1
require_grep "ATheory built" "$force_log"
if grep -q "ATheory is up to date\|ATheory restored from cache" "$force_log"; then
  echo "--force skipped source rebuild" >&2
  exit 1
fi

skip_goalfrag_project=$tmpdir/skip-goalfrag-project
mkdir -p "$skip_goalfrag_project/src"
cp "$project/holproject.toml" "$skip_goalfrag_project/holproject.toml"
cp "$project/src/AScript.sml" "$skip_goalfrag_project/src/AScript.sml"
(cd "$skip_goalfrag_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --skip-goalfrag ATheory)
require_file "$skip_goalfrag_project/.holbuild/obj/src/ATheory.sig"
require_file "$skip_goalfrag_project/.holbuild/obj/src/ATheory.sml"
require_file "$skip_goalfrag_project/.holbuild/obj/src/ATheory.dat"
if grep -q "theorem_boundary a_thm" "$skip_goalfrag_project/.holbuild/dep/replay/src/AScript.sml.key"; then
  echo "--skip-goalfrag should not create theorem boundaries" >&2
  exit 1
fi
# --skip-goalfrag does not create theorem context checkpoints,
# but deps/final-context checkpoints persist for incremental rebuilds

plain_replay_project=$tmpdir/plain-replay-project
mkdir -p "$plain_replay_project/src"
cp "$project/holproject.toml" "$plain_replay_project/holproject.toml"
cat > "$plain_replay_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
Theorem b_thm:
  T
Proof
  FAIL_TAC "expected replay seed failure"
QED
val _ = export_theory();
SML
plain_replay_failure_log=$tmpdir/plain-replay-failure.log
if (cd "$plain_replay_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$plain_replay_failure_log" 2>&1; then
  echo "expected replay seed proof to fail" >&2
  exit 1
fi
require_file "$(find "$plain_replay_project/.holbuild/checkpoints" -name '*a_thm_context.save' -print -quit)"
python3 - <<PY
from pathlib import Path
path = Path("$plain_replay_project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "expected replay seed failure"', 'ACCEPT_TAC TRUTH'))
PY
plain_replay_log=$tmpdir/plain-replay.log
(cd "$plain_replay_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --skip-goalfrag --no-cache ATheory) > "$plain_replay_log" 2>&1
if grep -q "from: theorem-context checkpoint after a_thm" "$plain_replay_log"; then
  echo "--skip-goalfrag reused goalfrag theorem checkpoint" >&2
  exit 1
fi
require_grep "ATheory built" "$plain_replay_log"

resume_replay_project=$tmpdir/resume-replay-project
mkdir -p "$resume_replay_project/src"
cp "$project/holproject.toml" "$resume_replay_project/holproject.toml"
cat > "$resume_replay_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib markerLib;
val _ = new_theory "A";
Theorem partial:
  T /\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >- suspend "right"
QED
Resume partial[right]:
  ACCEPT_TAC TRUTH
QED
Finalise partial
val _ = raise Fail "expected resume replay seed failure";
val _ = export_theory();
SML
resume_seed_log=$tmpdir/resume-replay-seed.log
if (cd "$resume_replay_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$resume_seed_log" 2>&1; then
  echo "expected resume replay seed proof to fail" >&2
  exit 1
fi
require_file "$(find "$resume_replay_project/.holbuild/checkpoints" -name '*partial_right__context.save' -print -quit)"
python3 - <<PY
from pathlib import Path
path = Path("$resume_replay_project/src/AScript.sml")
path.write_text(path.read_text().replace('raise Fail "expected resume replay seed failure"', '()'))
PY
resume_replay_log=$tmpdir/resume-replay.log
(cd "$resume_replay_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$resume_replay_log" 2>&1
require_grep "from: theorem-context checkpoint after partial_right_" "$resume_replay_log"
require_grep "continuing at: .*AScript.sml:" "$resume_replay_log"
require_grep "ATheory built" "$resume_replay_log"

failure_project=$tmpdir/failure-project
mkdir -p "$failure_project/src"
cp "$project/holproject.toml" "$failure_project/holproject.toml"
python3 - <<PY
from pathlib import Path
src = Path("$project/src/AScript.sml").read_text()
long_goal = "p" * 5000
b_thm = "Theorem b_thm:\n  T /" + chr(92) + " T\nProof\n  CONJ_TAC >- ACCEPT_TAC TRUTH >- ACCEPT_TAC TRUTH\nQED"
src = src.replace(b_thm, f'''Theorem b_thm:
  {long_goal}
Proof
  FAIL_TAC "expected failure"
QED''')
Path("$failure_project/src/AScript.sml").write_text(src)
PY

failure_log=$tmpdir/failure.log
if (cd "$failure_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$failure_log" 2>&1; then
  echo "expected failing proof to fail build" >&2
  exit 1
fi
require_grep "expected failure" "$failure_log"
require_grep "failed tactic top input goal:" "$failure_log"
require_grep "plan position: 00 tactic FAIL_TAC" "$failure_log"
require_grep "failed tactic input goals: 1" "$failure_log"
require_grep "top goal exceeded 4 KiB" "$failure_log"
require_grep "full top goal is in the instrumented log referenced below" "$failure_log"
require_grep "theorem: b_thm (line " "$failure_log"
require_grep "proof: line " "$failure_log"
require_grep "source: .*AScript.sml:" "$failure_log"
require_grep "child failure:" "$failure_log"
require_grep "FAIL_TAC \"expected failure\"" "$failure_log"
failure_child_log=$(find "$failure_project/.holbuild/logs" -name '*-ATheory-instrumented-failure.log' -print -quit)
require_file "$failure_child_log"
require_grep "holbuild goal state at failed fragment" "$failure_child_log"
require_grep "holbuild plan position: 00 tactic FAIL_TAC" "$failure_child_log"
require_grep "holbuild failed tactic input goal count: 1" "$failure_child_log"
require_grep "holbuild failed tactic top input goal:" "$failure_child_log"
require_grep "holbuild end failed tactic top input goal" "$failure_child_log"

synthetic_large_goal_log=$tmpdir/synthetic-large-goal.log
python3 - <<PY
from pathlib import Path
Path("$synthetic_large_goal_log").write_text(
    "holbuild failed tactic input goal count: 1\n"
    "holbuild failed tactic top input goal:\n" +
    "p" * 70000 + "\n")
PY
synthetic_large_goal_check=$tmpdir/synthetic-large-goal-check.sml
cat > "$synthetic_large_goal_check" <<SML
OS.FileSys.chDir "$repo_root";
use "sml/holbuild-script.sml";
fun require_substring needle text =
  if String.isSubstring needle text then ()
  else (TextIO.output(TextIO.stdErr, "missing substring: " ^ needle ^ "\\n");
        OS.Process.exit OS.Process.failure);
val summary =
  case HolbuildTheoryDiagnostics.summarize_goal_state_with_log_reference true "$synthetic_large_goal_log" of
      SOME text => text
    | NONE => (TextIO.output(TextIO.stdErr, "missing large-goal summary\\n");
               OS.Process.exit OS.Process.failure);
val _ = require_substring "failed tactic input goals: 1" summary;
val _ = require_substring "top goal exceeded 4 KiB; showing first 4096 bytes" summary;
val _ = require_substring "full top goal is in the instrumented log referenced below" summary;
val log_reference =
  HolbuildBuildExec.retained_log_reference
    (SOME (HolbuildBuildExec.RetainedLog "$synthetic_large_goal_log"));
val _ = require_substring "instrumented log warning: log is " log_reference;
val _ = require_substring "do not read the whole log" log_reference;
val _ = require_substring "only read targeted ranges if explicitly needed" log_reference;
val _ = OS.Process.exit OS.Process.success;
SML
HOLBUILD_HOLDIR="$HOLDIR" HOLDIR="$HOLDIR" poly < "$synthetic_large_goal_check" > "$tmpdir/synthetic-large-goal-check.log" 2>&1

multi_goal_project=$tmpdir/multi-goal-project
mkdir -p "$multi_goal_project/src"
cat > "$multi_goal_project/holproject.toml" <<'TOML'
[project]
name = "multi-goal"

[build]
members = ["src"]
TOML
cat > "$multi_goal_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem multi_goal_failure:
  T /\ T
Proof
  CONJ_TAC >> FAIL_TAC "multi goal failure"
QED

val _ = export_theory();
SML
multi_goal_log=$tmpdir/multi-goal.log
if (cd "$multi_goal_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$multi_goal_log" 2>&1; then
  echo "expected multi-goal proof to fail build" >&2
  exit 1
fi
require_grep "failed tactic input goals: 2" "$multi_goal_log"
require_grep "all failed tactic input goals are in the instrumented log" "$multi_goal_log"
if grep -q "holbuild all failed tactic input goals:" "$multi_goal_log"; then
  echo "parent output should not include full all-goals log" >&2
  exit 1
fi
multi_goal_child_log=$(find "$multi_goal_project/.holbuild/logs" -name '*-ATheory-instrumented-failure.log' -print -quit)
require_file "$multi_goal_child_log"
require_grep "holbuild failed tactic input goal count: 2" "$multi_goal_child_log"
require_grep "holbuild failed tactic top input goal:" "$multi_goal_child_log"
require_grep "holbuild all failed tactic input goals:" "$multi_goal_child_log"
require_grep "holbuild goal 1 of 2:" "$multi_goal_child_log"
require_grep "holbuild goal 2 of 2:" "$multi_goal_child_log"
require_grep "holbuild end all failed tactic input goals" "$multi_goal_child_log"

branch_input_project=$tmpdir/branch-input-project
mkdir -p "$branch_input_project/src"
cat > "$branch_input_project/holproject.toml" <<'TOML'
[project]
name = "branch-input"

[build]
members = ["src"]
TOML
cat > "$branch_input_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem branch_suffix_failure:
  (T /\ T) /\ T
Proof
  CONJ_TAC
  >- (CONJ_TAC >> FAIL_TAC "branch suffix failure")
  >- ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML
branch_input_log=$tmpdir/branch-input.log
if (cd "$branch_input_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$branch_input_log" 2>&1; then
  echo "expected branch-suffix proof to fail build" >&2
  exit 1
fi
require_grep "failed tactic input goals: 2" "$branch_input_log"
if grep -q "failed tactic input goals: 3" "$branch_input_log"; then
  echo "branch suffix reported unrelated tail goal as failed tactic input" >&2
  exit 1
fi
branch_input_child_log=$(find "$branch_input_project/.holbuild/logs" -name '*-ATheory-instrumented-failure.log' -print -quit)
require_file "$branch_input_child_log"
require_grep "holbuild failed tactic input goal count: 2" "$branch_input_child_log"
require_grep "holbuild goal 1 of 2:" "$branch_input_child_log"
require_grep "holbuild goal 2 of 2:" "$branch_input_child_log"
if grep -q "holbuild goal 3 of" "$branch_input_child_log"; then
  echo "child log included unrelated tail goal as failed tactic input" >&2
  exit 1
fi

multi_goal_large_project=$tmpdir/multi-goal-large-project
mkdir -p "$multi_goal_large_project/src"
cat > "$multi_goal_large_project/holproject.toml" <<'TOML'
[project]
name = "multi-goal-large"

[build]
members = ["src"]
TOML
python3 - <<PY
from pathlib import Path
long_var = "p" * 5000
Path("$multi_goal_large_project/src/AScript.sml").write_text(fr'''open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem multi_goal_large_failure:
  {long_var} /\\ {long_var}
Proof
  CONJ_TAC >> FAIL_TAC "multi goal large failure"
QED

val _ = export_theory();
''')
PY
multi_goal_large_log=$tmpdir/multi-goal-large.log
if (cd "$multi_goal_large_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$multi_goal_large_log" 2>&1; then
  echo "expected large multi-goal proof to fail build" >&2
  exit 1
fi
multi_goal_large_child_log=$(find "$multi_goal_large_project/.holbuild/logs" -name '*-ATheory-instrumented-failure.log' -print -quit)
require_file "$multi_goal_large_child_log"
require_grep "holbuild all failed tactic input goals:" "$multi_goal_large_child_log"
require_grep "holbuild failed tactic input goals truncated after 4096 bytes" "$multi_goal_large_child_log"
require_grep "holbuild end all failed tactic input goals" "$multi_goal_large_child_log"

a_thm_context=$(find "$failure_project/.holbuild/checkpoints" -name '*a_thm_context.save' -print -quit)
require_file "$a_thm_context"
b_thm_failed_prefix=$(find "$failure_project/.holbuild/checkpoints" -name '*b_thm_failed_prefix.save' -print -quit)
require_file "$b_thm_failed_prefix"
failure_again_log=$tmpdir/failure-again.log
if (cd "$failure_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$failure_again_log" 2>&1; then
  echo "expected repeated failing proof to fail build" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in b_thm" "$failure_again_log"
require_grep "matched proof prefix through: .*AScript.sml:" "$failure_again_log"
require_grep "replaying remaining proof from: .*AScript.sml:" "$failure_again_log"
require_grep "failed tactic top input goal:" "$failure_again_log"
require_grep "plan position: 00 tactic FAIL_TAC" "$failure_again_log"
require_grep "failed tactic input goals: 1" "$failure_again_log"
require_file "$a_thm_context"
require_file "$b_thm_failed_prefix"
failed_prefix_plan_log=$tmpdir/failed-prefix-plan.log
(cd "$failure_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --goalfrag --goalfrag-plan ATheory:b_thm) > "$failed_prefix_plan_log" 2>&1
require_grep "holbuild goalfrag plan ATheory:b_thm source=src/AScript.sml (" "$failed_prefix_plan_log"
require_grep "FAIL_TAC \"expected failure\"" "$failed_prefix_plan_log"
if grep -q "resuming ATheory\|ATheory inspected\|failed tactic top input goal" "$failed_prefix_plan_log"; then
  echo "--goalfrag-plan executed/replayed the build instead of statically printing the plan" >&2
  exit 1
fi
python3 - <<PY
from pathlib import Path
path = Path("$failure_project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "expected failure"', 'cheat'))
PY
failure_fixed_log=$tmpdir/failure-fixed.log
(cd "$failure_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$failure_fixed_log" 2>&1
require_grep "from: failed-prefix checkpoint in b_thm" "$failure_fixed_log"
require_grep "ATheory built" "$failure_fixed_log"
if [[ -e "$b_thm_failed_prefix" || -e "$b_thm_failed_prefix.ok" || \
      -e "$b_thm_failed_prefix.meta" || -e "$b_thm_failed_prefix.prefix" ]]; then
  echo "successful proof fix retained stale failed-prefix checkpoint" >&2
  exit 1
fi
if [[ -e "$failure_project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_context.save" || \
      -e "$failure_project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_context.save.ok" || \
      -e "$failure_project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_end_of_proof.save" || \
      -e "$failure_project/.holbuild/checkpoints/replay/src/AScript.sml.b_thm_end_of_proof.save.ok" ]]; then
  echo "stale b_thm checkpoint survived failed proof" >&2
  exit 1
fi

stale_prefix_project=$tmpdir/stale-prefix-project
mkdir -p "$stale_prefix_project/src"
cp "$project/holproject.toml" "$stale_prefix_project/holproject.toml"
cat > "$stale_prefix_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem first_failure:
  T
Proof
  ALL_TAC >> FAIL_TAC "first stale failure"
QED
Theorem second_failure:
  T
Proof
  FAIL_TAC "second current failure"
QED
val _ = export_theory();
SML
stale_first_log=$tmpdir/stale-prefix-first.log
if (cd "$stale_prefix_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$stale_first_log" 2>&1; then
  echo "expected first stale-prefix build to fail" >&2
  exit 1
fi
require_file "$(find "$stale_prefix_project/.holbuild/checkpoints" -name '*first_failure_failed_prefix.save' -print -quit)"
python3 - <<PY
from pathlib import Path
path = Path("$stale_prefix_project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "first stale failure"', 'ACCEPT_TAC TRUTH'))
PY
stale_second_log=$tmpdir/stale-prefix-second.log
if (cd "$stale_prefix_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$stale_second_log" 2>&1; then
  echo "expected second stale-prefix build to fail" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in first_failure" "$stale_second_log"
require_grep "theorem: second_failure (line " "$stale_second_log"
require_grep "failed tactic top input goal:" "$stale_second_log"
require_file "$(find "$stale_prefix_project/.holbuild/checkpoints" -name '*second_failure_failed_prefix.save' -print -quit)"
stale_third_log=$tmpdir/stale-prefix-third.log
if (cd "$stale_prefix_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$stale_third_log" 2>&1; then
  echo "expected third stale-prefix build to fail" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in second_failure" "$stale_third_log"
if grep -q "from: failed-prefix checkpoint in first_failure" "$stale_third_log"; then
  echo "stale earlier failed_prefix was selected over later failure" >&2
  exit 1
fi

slow_prefix_project=$tmpdir/slow-prefix-project
slow_prefix_counter=$tmpdir/slow-prefix-count.txt
mkdir -p "$slow_prefix_project/src"
touch "$slow_prefix_counter"
cp "$project/holproject.toml" "$slow_prefix_project/holproject.toml"
cat > "$slow_prefix_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val slow_prefix_counter = "$slow_prefix_counter";
fun bump_counter () =
  let val out = TextIO.openAppend slow_prefix_counter
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun slow_tac g = (bump_counter(); OS.Process.sleep (Time.fromReal 0.35); ALL_TAC g);
fun slow_tac_alt g = (bump_counter(); OS.Process.sleep (Time.fromReal 0.35); ALL_TAC g);
Theorem slow_prefix_failure:
  T
Proof
  slow_tac >> slow_tac >> FAIL_TAC "after slow prefix"
QED
val _ = export_theory();
SML
slow_prefix_first_log=$tmpdir/slow-prefix-first.log
if (cd "$slow_prefix_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$slow_prefix_first_log" 2>&1; then
  echo "expected slow-prefix proof to fail build" >&2
  exit 1
fi
first_slow_count=$(wc -c < "$slow_prefix_counter" | tr -d ' ')
[[ "$first_slow_count" = "2" ]] || { echo "expected first run to execute slow prefix twice, got $first_slow_count" >&2; exit 1; }
require_grep "slow_tac >> slow_tac >> FAIL_TAC" "$slow_prefix_first_log"
require_grep "failed tactic top input goal:" "$slow_prefix_first_log"
require_grep "failed tactic input goals: 1" "$slow_prefix_first_log"
slow_prefix_again_log=$tmpdir/slow-prefix-again.log
if (cd "$slow_prefix_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$slow_prefix_again_log" 2>&1; then
  echo "expected repeated slow-prefix proof to fail build" >&2
  exit 1
fi
second_slow_count=$(wc -c < "$slow_prefix_counter" | tr -d ' ')
[[ "$second_slow_count" = "2" ]] || { echo "failed-prefix replay reran slow prefix; count $second_slow_count" >&2; exit 1; }
require_grep "from: failed-prefix checkpoint in slow_prefix_failure" "$slow_prefix_again_log"
require_grep "failed tactic top input goal:" "$slow_prefix_again_log"
require_grep "failed tactic input goals: 1" "$slow_prefix_again_log"
python3 - <<PY
from pathlib import Path
path = Path("$slow_prefix_project/src/AScript.sml")
path.write_text(path.read_text().replace(
    'slow_tac >> slow_tac >> FAIL_TAC "after slow prefix"',
    'slow_tac >> slow_tac_alt >> ACCEPT_TAC TRUTH'))
PY
slow_prefix_changed_log=$tmpdir/slow-prefix-changed.log
(cd "$slow_prefix_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$slow_prefix_changed_log" 2>&1
changed_slow_count=$(wc -c < "$slow_prefix_counter" | tr -d ' ')
[[ "$changed_slow_count" = "3" ]] || { echo "failed-prefix replay reran unchanged slow prefix after mid-proof edit; count $changed_slow_count" >&2; exit 1; }
require_grep "from: failed-prefix checkpoint in slow_prefix_failure" "$slow_prefix_changed_log"
require_grep "ATheory built" "$slow_prefix_changed_log"

failed_root_project=$tmpdir/failed-root-project
failed_root_counter=$tmpdir/failed-root-dep-count.txt
mkdir -p "$failed_root_project/src"
touch "$failed_root_counter"
cat > "$failed_root_project/holproject.toml" <<'TOML'
[project]
name = "failed-root"
[build]
members = ["src"]
TOML
cat > "$failed_root_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val out = TextIO.openAppend "$failed_root_counter";
val _ = (TextIO.output(out, "x"); TextIO.closeOut out);
Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
cat > "$failed_root_project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open ATheory;
val _ = new_theory "B";
Theorem b_thm:
  T
Proof
  FAIL_TAC "bad root proof"
QED
val _ = export_theory();
SML
failed_root_first_log=$tmpdir/failed-root-first.log
if (cd "$failed_root_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build BTheory) > "$failed_root_first_log" 2>&1; then
  echo "expected failed root project to fail build" >&2
  exit 1
fi
first_dep_count=$(wc -c < "$failed_root_counter" | tr -d ' ')
[[ "$first_dep_count" = "1" ]] || { echo "expected dependency to build once, got $first_dep_count" >&2; exit 1; }
failed_root_again_log=$tmpdir/failed-root-again.log
if (cd "$failed_root_project" && "$HOLBUILD_BIN" --verbose --holdir "$HOLDIR" build BTheory) > "$failed_root_again_log" 2>&1; then
  echo "expected repeated failed root project to fail build" >&2
  exit 1
fi
second_dep_count=$(wc -c < "$failed_root_counter" | tr -d ' ')
[[ "$second_dep_count" = "1" ]] || { echo "no-change rebuild reran completed dependency; count $second_dep_count" >&2; exit 1; }
require_grep "ATheory is up to date" "$failed_root_again_log"
require_grep "from: failed-prefix checkpoint in b_thm" "$failed_root_again_log"

changed_prefix_project=$tmpdir/changed-prefix-project
mkdir -p "$changed_prefix_project/src"
cat > "$changed_prefix_project/holproject.toml" <<'TOML'
[project]
name = "changed-prefix"

[build]
members = ["src"]
TOML
cat > "$changed_prefix_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Datatype:
  foo = A | B | C | D
End

Theorem changed_prefix:
  !x:foo P Q. (!y. P y ==> Q y) ==> P x ==> Q x
Proof
  Induct >> rpt gen_tac >> strip_tac >> TRY NO_TAC
  >- (FAIL_TAC "intentional")
  >- (rpt strip_tac >> simp[])
  >- (rpt strip_tac >> simp[])
  >- (rpt strip_tac >> simp[])
QED

val _ = export_theory();
SML
changed_prefix_fail_log=$tmpdir/changed-prefix-fail.log
if (cd "$changed_prefix_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --force --no-cache --tactic-timeout 0 ATheory) > "$changed_prefix_fail_log" 2>&1; then
  echo "expected changed-prefix seed proof to fail" >&2
  exit 1
fi
require_grep "intentional" "$changed_prefix_fail_log"
require_file "$(find "$changed_prefix_project/.holbuild/checkpoints" -name '*changed_prefix_failed_prefix.save' -print -quit)"
python3 - <<PY
from pathlib import Path
path = Path("$changed_prefix_project/src/AScript.sml")
s = path.read_text()
s = s.replace('TRY NO_TAC\n', 'TRY (NO_TAC ORELSE ALL_TAC)\n')
s = s.replace('>- (FAIL_TAC "intentional")', '>- (rpt strip_tac >> simp[])')
path.write_text(s)
PY
changed_prefix_fixed_log=$tmpdir/changed-prefix-fixed.log
(cd "$changed_prefix_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --force --no-cache --tactic-timeout 0 ATheory) > "$changed_prefix_fixed_log" 2>&1
require_grep "from: failed-prefix checkpoint in changed_prefix" "$changed_prefix_fixed_log"
require_grep "ATheory built" "$changed_prefix_fixed_log"

priority_project=$tmpdir/priority-project
priority_counter=$tmpdir/priority-counter.txt
mkdir -p "$priority_project/src"
touch "$priority_counter"
cat > "$priority_project/holproject.toml" <<'TOML'
[project]
name = "priority"
[build]
members = ["src"]
[actions.CTheory]
always_reexecute = true
TOML
cat > "$priority_project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "B";
Theorem b_fail:
  T
Proof
  ALL_TAC >> FAIL_TAC "priority failure"
QED
val _ = export_theory();
SML
cat > "$priority_project/src/CScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "C";
val out = TextIO.openAppend "$priority_counter";
val _ = (TextIO.output(out, "x"); TextIO.closeOut out);
Theorem c_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
priority_first_log=$tmpdir/priority-first.log
if (cd "$priority_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" -j2 build BTheory CTheory) > "$priority_first_log" 2>&1; then
  echo "expected priority project first build to fail" >&2
  exit 1
fi
require_file "$(find "$priority_project/.holbuild/checkpoints" -name '*b_fail_failed_prefix.save' -print -quit)"
: > "$priority_counter"
priority_again_log=$tmpdir/priority-again.log
if (cd "$priority_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" -j2 build BTheory CTheory) > "$priority_again_log" 2>&1; then
  echo "expected priority project repeated build to fail" >&2
  exit 1
fi
priority_count=$(wc -c < "$priority_counter" | tr -d ' ')
[[ "$priority_count" = "0" ]] || { echo "scheduler ran unrelated always-reexecute target before failed_prefix; count $priority_count" >&2; exit 1; }
require_grep "from: failed-prefix checkpoint in b_fail" "$priority_again_log"

always_context_project=$tmpdir/always-context-project
always_context_counter=$tmpdir/always-context-counter.txt
mkdir -p "$always_context_project/src"
touch "$always_context_counter"
cat > "$always_context_project/holproject.toml" <<'TOML'
[project]
name = "always-context"
[build]
members = ["src"]
[actions.ATheory]
always_reexecute = true
TOML
cat > "$always_context_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val out = TextIO.openAppend "$always_context_counter";
val _ = (TextIO.output(out, "x"); TextIO.closeOut out);
Theorem first_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
Theorem second_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
always_context_first_log=$tmpdir/always-context-first.log
(cd "$always_context_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --no-cache ATheory) > "$always_context_first_log" 2>&1
require_grep "ATheory built" "$always_context_first_log"
require_file "$(find "$always_context_project/.holbuild/checkpoints" -name '*first_thm_context.save' -print -quit)"
python3 - <<PY
from pathlib import Path
p = Path("$always_context_project/src/AScript.sml")
p.write_text(p.read_text().replace('ACCEPT_TAC TRUTH\nQED\nval _ = export_theory();', 'FAIL_TAC "always context failure"\nQED\nval _ = export_theory();'))
PY
: > "$always_context_counter"
always_context_again_log=$tmpdir/always-context-again.log
if (cd "$always_context_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --no-cache ATheory) > "$always_context_again_log" 2>&1; then
  echo "expected always-context repeated build to fail" >&2
  exit 1
fi
require_grep "from: theorem-context checkpoint after first_thm" "$always_context_again_log"
always_context_count=$(wc -c < "$always_context_counter" | tr -d ' ')
[[ "$always_context_count" = "0" ]] || { echo "always_reexecute reran prefix before theorem-context replay; count $always_context_count" >&2; exit 1; }

branch_failure_project=$tmpdir/branch-failure-project
mkdir -p "$branch_failure_project/src"
cp "$project/holproject.toml" "$branch_failure_project/holproject.toml"
cat > "$branch_failure_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem branch_failure:
  T /\ T
Proof
  CONJ_TAC >- FAIL_TAC "branch side failed"
  \\ ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
branch_failure_log=$tmpdir/branch-failure.log
if (cd "$branch_failure_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --goalfrag --goalfrag-trace ATheory) > "$branch_failure_log" 2>&1; then
  echo "expected branch proof to fail build" >&2
  exit 1
fi
require_grep "holbuild goalfrag trace:" "$branch_failure_log"
require_grep "holbuild goalfrag after theorem=branch_failure.*status=failed.*elapsed_ms=" "$branch_failure_log"
require_grep "fragment: FAIL_TAC" "$branch_failure_log"
require_grep "branch side failed" "$branch_failure_log"
if grep -q "fragment: CONJ_TAC >- FAIL_TAC" "$branch_failure_log"; then
  echo "branch tactical was emitted as one atomic fragment" >&2
  exit 1
fi

grouped_failure_project=$tmpdir/grouped-failure-project
mkdir -p "$grouped_failure_project/src"
cp "$project/holproject.toml" "$grouped_failure_project/holproject.toml"
cat > "$grouped_failure_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem grouped_failure:
  !p:bool. p
Proof
  rpt gen_tac >> strip_tac
QED
val _ = export_theory();
SML
grouped_failure_log=$tmpdir/grouped-failure.log
if (cd "$grouped_failure_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --goalfrag ATheory) > "$grouped_failure_log" 2>&1; then
  echo "expected grouped proof to fail build" >&2
  exit 1
fi
require_grep "fragment: strip_tac" "$grouped_failure_log"
require_grep "source: .*AScript.sml:[0-9][0-9]*:18-27" "$grouped_failure_log"
if grep -q "fragment: rpt gen_tac >> strip_tac" "$grouped_failure_log"; then
  echo "grouped tactic was emitted as one atomic failed fragment" >&2
  exit 1
fi
python3 - <<PY
from pathlib import Path
lines = Path("$grouped_failure_log").read_text().splitlines()
for i, line in enumerate(lines):
    if line.startswith("> ") and "rpt gen_tac >> strip_tac" in line:
        assert i + 1 < len(lines) and "|                  ^^^^^^^^^" in lines[i + 1], lines[i + 1:i + 2]
        break
else:
    raise SystemExit("missing underlined grouped failure source row")
PY

close_paren_failure_project=$tmpdir/close-paren-failure-project
mkdir -p "$close_paren_failure_project/src"
cp "$project/holproject.toml" "$close_paren_failure_project/holproject.toml"
cat > "$close_paren_failure_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem close_paren_failure:
  T /\ T
Proof
  CONJ_TAC
  >- (
    ALL_TAC
  )
  >- ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
close_paren_failure_log=$tmpdir/close-paren-failure.log
if (cd "$close_paren_failure_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --goalfrag ATheory) > "$close_paren_failure_log" 2>&1; then
  echo "expected close-paren branch proof to fail build" >&2
  exit 1
fi
require_grep "fragment: close_paren" "$close_paren_failure_log"
require_grep "source: .*AScript.sml:7:6-9:4" "$close_paren_failure_log"
python3 - <<PY
from pathlib import Path
text = Path("$close_paren_failure_log").read_text()
if any(line.startswith(">") and "|   CONJ_TAC" in line for line in text.splitlines()):
    raise SystemExit("close_paren source location fell back to proof start")
if not any(line.startswith(">") and ("|   )" in line or "|     ALL_TAC" in line) for line in text.splitlines()):
    raise SystemExit("close_paren source location did not point at failing branch close/body")
PY

same_fragment_project=$tmpdir/same-fragment-project
mkdir -p "$same_fragment_project/src"
cp "$project/holproject.toml" "$same_fragment_project/holproject.toml"
cat > "$same_fragment_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem first_same_prefix:
  !x:bool. x = x
Proof
  gen_tac >> REFL_TAC
QED
Theorem second_same_prefix:
  !x:bool. x = x
Proof
  gen_tac >> FAIL_TAC "second failed"
QED
val _ = export_theory();
SML
same_fragment_log=$tmpdir/same-fragment.log
if (cd "$same_fragment_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --skip-checkpoints ATheory) > "$same_fragment_log" 2>&1; then
  echo "expected same-fragment proof to fail build" >&2
  exit 1
fi
require_grep "theorem: second_same_prefix" "$same_fragment_log"
if grep -q "theorem: first_same_prefix" "$same_fragment_log"; then
  echo "failed fragment was attributed to earlier theorem with same prefix" >&2
  exit 1
fi

malformed_project=$tmpdir/malformed-project
mkdir -p "$malformed_project/src"
cp "$project/holproject.toml" "$malformed_project/holproject.toml"
cat > "$malformed_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem ok_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
Theorem broken_thm:
  T
Proof
  ACCEPT_TAC TRUTH
Theorem after_broken:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
malformed_log=$tmpdir/malformed.log
if (cd "$malformed_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$malformed_log" 2>&1; then
  echo "expected malformed parser-recovery project to fail" >&2
  exit 1
fi
require_grep "HOL source parser recovered while instrumenting theorem boundaries for ATheory; using recovered theorem boundaries" "$malformed_log"
require_grep "HOL source parse error:" "$malformed_log"
require_grep "expected 'QED'" "$malformed_log"
require_grep "source: .*AScript.sml:" "$malformed_log"
require_grep "hol run failed while building theory script" "$malformed_log"
if grep -q "ATheory built" "$malformed_log"; then
  echo "malformed parser-recovery project was reported as built" >&2
  exit 1
fi

bad_decl_timeout_project=$tmpdir/bad-decl-timeout-project
bad_decl_timeout_marker=$tmpdir/bad-decl-timeout-raw-ran
mkdir -p "$bad_decl_timeout_project/src"
cp "$project/holproject.toml" "$bad_decl_timeout_project/holproject.toml"
cat > "$bad_decl_timeout_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
fun loop_tac g = loop_tac g;
Theorem stuck_before_bad_decl:
  T
Proof
  loop_tac
QED
val _ =
  let val out = TextIO.openOut "$bad_decl_timeout_marker"
  in TextIO.output(out, "raw execution reached\\n"); TextIO.closeOut out end;
  ) >>
  cheat
QED
val _ = export_theory();
SML
bad_decl_timeout_log=$tmpdir/bad-decl-timeout.log
set +e
(cd "$bad_decl_timeout_project" && timeout 15s "$HOLBUILD_BIN" --holdir "$HOLDIR" build --tactic-timeout 0.1 ATheory) > "$bad_decl_timeout_log" 2>&1
bad_decl_timeout_status=$?
set -e
if [ "$bad_decl_timeout_status" -eq 0 ]; then
  echo "expected bad-declaration project to fail" >&2
  exit 1
fi
if [ "$bad_decl_timeout_status" -eq 124 ]; then
  echo "bad-declaration parser recovery fell back to uninstrumented raw HOL and hung" >&2
  exit 1
fi
require_grep "HOL source parser recovered while instrumenting theorem boundaries for ATheory; using recovered theorem boundaries" "$bad_decl_timeout_log"
require_grep "HOL source parse error: bad declaration" "$bad_decl_timeout_log"
require_grep "tactic timed out after 0.1s while building ATheory: loop_tac" "$bad_decl_timeout_log"
if [ -e "$bad_decl_timeout_marker" ]; then
  echo "bad-declaration source ran past the instrumented looping proof" >&2
  exit 1
fi

timeout_project=$tmpdir/timeout-project
mkdir -p "$timeout_project/src"
cp "$project/holproject.toml" "$timeout_project/holproject.toml"
cat > "$timeout_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
fun loop_tac g = loop_tac g;
Theorem timeout_thm:
  T
Proof
  loop_tac
QED
val _ = export_theory();
SML

timeout_log=$tmpdir/timeout.log
if (cd "$timeout_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --tactic-timeout 0.1 ATheory) > "$timeout_log" 2>&1; then
  echo "expected looping tactic to time out" >&2
  exit 1
fi
require_grep "tactic timed out after 0.1s while building ATheory: loop_tac" "$timeout_log"
require_grep "instrumented log:" "$timeout_log"
if grep -q "plain-source fallback disabled" "$timeout_log"; then
  echo "timeout was reported as generic instrumentation failure" >&2
  exit 1
fi

goalfrag_shorten_project=$tmpdir/goalfrag-shorten-project
goalfrag_shorten_counter=$tmpdir/goalfrag-shorten-count.txt
mkdir -p "$goalfrag_shorten_project/src"
touch "$goalfrag_shorten_counter"
cp "$project/holproject.toml" "$goalfrag_shorten_project/holproject.toml"
python3 - <<PY
from pathlib import Path
project = Path("$goalfrag_shorten_project")
counter = Path("$goalfrag_shorten_counter")
long_prefix = " >> ".join(["slow_tac"] + ["ALL_TAC"] * 20 + ['FAIL_TAC "goalfrag long suffix failure"'])
(project / "src" / "AScript.sml").write_text(f'''open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val slow_prefix_counter = "{counter}";
fun bump_counter () =
  let val out = TextIO.openAppend slow_prefix_counter
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun slow_tac g = (bump_counter(); ALL_TAC g);
Theorem shortened_goalfrag_replay:
  T
Proof
  {long_prefix}
QED
val _ = export_theory();
''')
PY

goalfrag_shorten_first_log=$tmpdir/goalfrag-shorten-first.log
if (cd "$goalfrag_shorten_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --goalfrag ATheory) > "$goalfrag_shorten_first_log" 2>&1; then
  echo "expected goalfrag shortened replay first build to fail" >&2
  exit 1
fi
goalfrag_shorten_first_count=$(wc -c < "$goalfrag_shorten_counter" | tr -d ' ')
[[ "$goalfrag_shorten_first_count" = "1" ]] || { echo "expected goalfrag shortened replay first run to execute slow prefix once, got $goalfrag_shorten_first_count" >&2; exit 1; }
require_grep "goalfrag long suffix failure" "$goalfrag_shorten_first_log"
python3 - <<PY
from pathlib import Path
prefix_paths = list(Path("$goalfrag_shorten_project/.holbuild/checkpoints").glob("**/*shortened_goalfrag_replay_failed_prefix.save.prefix"))
if len(prefix_paths) != 1:
    raise SystemExit(f"expected one failed-prefix .prefix file, got {prefix_paths}")
prefix_paths[0].write_text("slow_tac")
PY

python3 - <<PY
from pathlib import Path
path = Path("$goalfrag_shorten_project/src/AScript.sml")
text = path.read_text()
proof = text.index('Proof')
start = text.index('slow_tac', proof)
end = text.index('QED', start)
path.write_text(text[:start] + 'slow_tac >> FAIL_TAC "goalfrag short suffix failure"\n' + text[end:])
PY
goalfrag_shorten_edit_log=$tmpdir/goalfrag-shorten-edit.log
if (cd "$goalfrag_shorten_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --goalfrag ATheory) > "$goalfrag_shorten_edit_log" 2>&1; then
  echo "expected goalfrag shortened replay edited build to fail" >&2
  exit 1
fi
goalfrag_shorten_edit_count=$(wc -c < "$goalfrag_shorten_counter" | tr -d ' ')
[[ "$goalfrag_shorten_edit_count" = "1" ]] || { echo "goalfrag shortened replay reran unchanged slow prefix; count $goalfrag_shorten_edit_count" >&2; exit 1; }
require_grep "from: failed-prefix checkpoint in shortened_goalfrag_replay" "$goalfrag_shorten_edit_log"
require_grep "goalfrag short suffix failure" "$goalfrag_shorten_edit_log"
if grep -q "CANT_BACKUP_ANYMORE" "$goalfrag_shorten_edit_log"; then
  echo "goalfrag failed-prefix replay could not rewind retained proof history" >&2
  exit 1
fi

goalfrag_resume_project=$tmpdir/goalfrag-resume-project
goalfrag_resume_counter=$tmpdir/goalfrag-resume-count.txt
mkdir -p "$goalfrag_resume_project/src"
touch "$goalfrag_resume_counter"
cp "$project/holproject.toml" "$goalfrag_resume_project/holproject.toml"
cat > "$goalfrag_resume_project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib markerLib;
val _ = new_theory "A";
val slow_prefix_counter = "$goalfrag_resume_counter";
fun bump_counter () =
  let val out = TextIO.openAppend slow_prefix_counter
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun slow_tac g = (bump_counter(); ALL_TAC g);
Theorem partial:
  T /\\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >- suspend "right"
QED
Resume partial[right,smlname=partial_right_goalfrag]:
  slow_tac >> slow_tac >> FAIL_TAC "goalfrag resume suffix failure"
QED
Finalise partial
val _ = concl partial_right_goalfrag;
val _ = export_theory();
SML

goalfrag_resume_first_log=$tmpdir/goalfrag-resume-first.log
if (cd "$goalfrag_resume_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --goalfrag ATheory) > "$goalfrag_resume_first_log" 2>&1; then
  echo "expected first GoalFrag Resume proof to fail" >&2
  exit 1
fi
goalfrag_resume_first_count=$(wc -c < "$goalfrag_resume_counter" | tr -d ' ')
[[ "$goalfrag_resume_first_count" = "2" ]] || { echo "expected first GoalFrag Resume run to execute slow prefix twice, got $goalfrag_resume_first_count" >&2; exit 1; }
require_grep "goalfrag is deprecated; proof IR is the default" "$goalfrag_resume_first_log"
require_grep "goalfrag resume suffix failure" "$goalfrag_resume_first_log"
require_file "$(find "$goalfrag_resume_project/.holbuild/checkpoints" -name '*partial_right__failed_prefix.save' -print -quit)"

python3 - <<PY
from pathlib import Path
path = Path("$goalfrag_resume_project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "goalfrag resume suffix failure"', 'ACCEPT_TAC TRUTH'))
PY
goalfrag_resume_fixed_log=$tmpdir/goalfrag-resume-fixed.log
(cd "$goalfrag_resume_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --goalfrag ATheory) > "$goalfrag_resume_fixed_log" 2>&1
goalfrag_resume_fixed_count=$(wc -c < "$goalfrag_resume_counter" | tr -d ' ')
[[ "$goalfrag_resume_fixed_count" = "2" ]] || { echo "GoalFrag Resume failed-prefix replay reran unchanged slow prefix after suffix fix; count $goalfrag_resume_fixed_count" >&2; exit 1; }
require_grep "goalfrag is deprecated; proof IR is the default" "$goalfrag_resume_fixed_log"
require_grep "from: failed-prefix checkpoint in partial_right_" "$goalfrag_resume_fixed_log"
require_grep "ATheory built" "$goalfrag_resume_fixed_log"
require_file "$goalfrag_resume_project/.holbuild/obj/src/ATheory.dat"
