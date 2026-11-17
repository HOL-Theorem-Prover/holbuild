#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

shared_plan_requirement=()
if [[ -f "$HOLDIR/tools/parsing/ProofStepPlan.sig" ]]; then
  shared_plan_requirement=(HOLBUILD_REQUIRE_SHARED_PROOF_STEP_PLAN=1)
fi

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

make_project() {
  local p=$1
  local name=$2
  mkdir -p "$p/src"
  cat > "$p/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "$name"

[build]
members = ["src"]
TOML
}

runtime_project=$tmpdir/proof-step-runtime
make_project "$runtime_project" proof-step-runtime
cat > "$runtime_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem sequence_allgoals:
  T /\ T
Proof
  CONJ_TAC >> ACCEPT_TAC TRUTH
QED

(* Keep Q unopened: the shared-plan adapter must qualify the executable form
   of this operand-only Rename leaf rather than relying on script opens. *)
Theorem rename_operand_leaf:
  !x:bool. x ==> x
Proof
  rpt strip_tac >>
  rename [`x`] >>
  FIRST_ASSUM ACCEPT_TAC
QED

Theorem expanded_map_every_leaf:
  T /\ T
Proof
  CONJ_TAC >> MAP_EVERY (fn th => ACCEPT_TAC th) [TRUTH]
QED

Theorem suffices_by_leaf:
  T
Proof
  `T` suffices_by simp[] >>
  ACCEPT_TAC TRUTH
QED

Theorem branch_then1:
  T /\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >- ACCEPT_TAC TRUTH
QED

Theorem try_no_tac:
  T
Proof
  TRY NO_TAC >> ACCEPT_TAC TRUTH
QED

Theorem direct_tacs_to_lt:
  T
Proof
  ALL_TAC >>> TACS_TO_LT [ACCEPT_TAC TRUTH]
QED

Theorem select_then1_nested_body:
  T /\ T
Proof
  CONJ_TAC >>~- ([`T`], sg `T` >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
QED

Theorem select_goal_keep:
  T /\ T
Proof
  CONJ_TAC >~ [`T`] >> ACCEPT_TAC TRUTH
QED

Theorem select_goals_keep:
  T /\ T
Proof
  CONJ_TAC >>~ [`T`] >> ACCEPT_TAC TRUTH
QED

Theorem select_goal_skips_nonmatch:
  (F ==> F) /\ T
Proof
  CONJ_TAC
  >~ [`T`]
  >- ACCEPT_TAC TRUTH
  >- (DISCH_TAC >> FIRST_ASSUM ACCEPT_TAC)
QED

Theorem select_goals_exact_matches:
  (F ==> F) /\ T /\ T
Proof
  rpt CONJ_TAC
  >>~- ([`T`], ACCEPT_TAC TRUTH)
  >> DISCH_TAC >> FIRST_ASSUM ACCEPT_TAC
QED

Theorem no_lt_orelse:
  T
Proof
  ALL_TAC >>> (NO_LT ORELSE_LT TACS_TO_LT [ACCEPT_TAC TRUTH])
QED

Theorem nth_goal_expr:
  T /\ T /\ T
Proof
  rpt CONJ_TAC >>> NTH_GOAL (ACCEPT_TAC TRUTH) (1 + 1) >>>
  TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem split_expr:
  T /\ T
Proof
  CONJ_TAC >>> SPLIT_LT (1 + 0)
    (TACS_TO_LT [ACCEPT_TAC TRUTH], TACS_TO_LT [ACCEPT_TAC TRUTH])
QED

Theorem try_then1_group:
  (T /\ T) /\ T
Proof
  CONJ_TAC >> TRY (CONJ_TAC >- ACCEPT_TAC TRUTH) >> ACCEPT_TAC TRUTH
QED

Theorem by_after_multiple_goals:
  p /\ q ==> p /\ q
Proof
  strip_tac
  \\ CONJ_TAC
  \\ `T` by ACCEPT_TAC TRUTH
  \\ FIRST_ASSUM ACCEPT_TAC
QED

Theorem repeat_case_atomic:
  (case x:'a option of NONE => T | SOME y => T)
Proof
  rpt CASE_TAC \\ simp[]
QED

Theorem first_per_goal:
  T /\ (F ==> F)
Proof
  CONJ_TAC
  \\ FIRST [ACCEPT_TAC TRUTH, DISCH_TAC \\ FIRST_ASSUM ACCEPT_TAC]
QED

(* Plain THENL does nothing on no goals; cases must not demand a match. *)
Theorem cases_on_no_goals:
  T
Proof
  simp[] >| [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem repeat_on_no_goals:
  T
Proof
  simp[] >> rpt strip_tac
QED

Theorem chained_then1_plain:
  T /\ T /\ T
Proof
  rpt CONJ_TAC
  >- ACCEPT_TAC TRUTH
  >- ACCEPT_TAC TRUTH
  >- ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML
(cd "$runtime_project" && env HOLBUILD_ECHO_CHILD_LOGS=1 "${shared_plan_requirement[@]}" "$HOLBUILD_BIN" build --skip-checkpoints --tactic-timeout 60) > "$tmpdir/runtime.out" 2>&1
require_file "$runtime_project/.holbuild/obj/src/ATheory.dat"
(cd "$runtime_project" && "$HOLBUILD_BIN" execution-plan ATheory:select_then1_nested_body) > "$tmpdir/select_then1_nested_body.plan.out" 2>&1
require_grep 'select matching-all \[`T`\] solve' "$tmpdir/select_then1_nested_body.plan.out"
require_grep 'step sg `T`' "$tmpdir/select_then1_nested_body.plan.out"
require_grep 'select first solve' "$tmpdir/select_then1_nested_body.plan.out"
if grep -q 'Q.SELECT_GOALS_LT_THEN1' "$tmpdir/select_then1_nested_body.plan.out"; then
  echo ">>~- was planned as opaque list-step instead of structural select" >&2
  exit 1
fi
(cd "$runtime_project" && "$HOLBUILD_BIN" execution-plan ATheory:select_goal_keep) > "$tmpdir/select_goal_keep.plan.out" 2>&1
require_grep 'select matching-first \[`T`\] keep' "$tmpdir/select_goal_keep.plan.out"
(cd "$runtime_project" && "$HOLBUILD_BIN" execution-plan ATheory:select_goals_keep) > "$tmpdir/select_goals_keep.plan.out" 2>&1
require_grep 'select matching-all \[`T`\] keep' "$tmpdir/select_goals_keep.plan.out"
(cd "$runtime_project" && "$HOLBUILD_BIN" execution-plan ATheory:select_goal_skips_nonmatch) > "$tmpdir/select_goal_skips_nonmatch.plan.out" 2>&1
require_grep 'select matching-first \[`T`\] keep' "$tmpdir/select_goal_skips_nonmatch.plan.out"
(cd "$runtime_project" && "$HOLBUILD_BIN" execution-plan ATheory:select_goals_exact_matches) > "$tmpdir/select_goals_exact_matches.plan.out" 2>&1
require_grep 'select matching-all \[`T`\] solve' "$tmpdir/select_goals_exact_matches.plan.out"
(cd "$runtime_project" && "$HOLBUILD_BIN" execution-plan ATheory:chained_then1_plain) > "$tmpdir/chained_then1.plan.out" 2>&1
require_grep 'rpt CONJ_TAC' "$tmpdir/chained_then1.plan.out"

parser_project=$tmpdir/parser-recovery
make_project "$parser_project" parser-recovery
cat > "$parser_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem parser_recovery:
  T
Proof
  ( ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML
if (cd "$parser_project" && HOLBUILD_ECHO_CHILD_LOGS=1 "$HOLBUILD_BIN" build --skip-checkpoints --tactic-timeout 60) > "$tmpdir/parser-recovery.out" 2>&1; then
  echo "expected parser recovery build to fail" >&2
  exit 1
fi
require_grep "HOL source parser recovered while instrumenting theorem boundaries" "$tmpdir/parser-recovery.out"
require_grep "parse error: expected closing parenthesis" "$tmpdir/parser-recovery.out"
require_grep "source: .*AScript.sml:" "$tmpdir/parser-recovery.out"
require_grep "hol run failed while building theory script" "$tmpdir/parser-recovery.out"

repeated_project=$tmpdir/repeated-label-source-location
make_project "$repeated_project" repeated-label-source-location
cat > "$repeated_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem repeated_label:
  !x:bool. T
Proof
  strip_tac >> strip_tac
QED

val _ = export_theory();
SML
if (cd "$repeated_project" && "$HOLBUILD_BIN" build --skip-checkpoints --tactic-timeout 60) > "$tmpdir/repeated-label.out" 2>&1; then
  echo "expected repeated-label proof-step build to fail" >&2
  exit 1
fi
require_grep "plan position: 01 step strip_tac" "$tmpdir/repeated-label.out"
require_grep "source: .*AScript.sml:7:16-25" "$tmpdir/repeated-label.out"
if grep -q "source: .*AScript.sml:7:3-12" "$tmpdir/repeated-label.out"; then
  echo "proof-step failure source used first matching label instead of failed step span" >&2
  exit 1
fi

first_empty_project=$tmpdir/first-empty-then
make_project "$first_empty_project" first-empty-then
cat > "$first_empty_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem first_empty_then:
  T
Proof
  FIRST [] >> ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
if (cd "$first_empty_project" && "$HOLBUILD_BIN" build --skip-checkpoints --tactic-timeout 60) > "$tmpdir/first_empty_then.out" 2>&1; then
  echo "expected FIRST [] build to fail" >&2
  exit 1
fi
require_grep 'FIRST \[\]' "$tmpdir/first_empty_then.out"

map_first_empty_project=$tmpdir/map-first-empty-then
make_project "$map_first_empty_project" map-first-empty-then
cat > "$map_first_empty_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem map_first_empty_then:
  T
Proof
  MAP_FIRST (fn th => ACCEPT_TAC th) [] >> ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
if (cd "$map_first_empty_project" && "$HOLBUILD_BIN" build --skip-checkpoints --tactic-timeout 60) > "$tmpdir/map_first_empty_then.out" 2>&1; then
  echo "expected MAP_FIRST [] build to fail" >&2
  exit 1
fi
require_grep 'MAP_FIRST' "$tmpdir/map_first_empty_then.out"

# Plain HOL evaluates a proof's whole tactic expression before applying it,
# so a broken leaf fails the proof even where it never runs on a goal: after
# the goal closes, or inside TRY. Both modes must fail each of these.
eager_project=$tmpdir/eager-evaluation
make_project "$eager_project" eager-evaluation
eager_theory() {
  printf 'open HolKernel Parse boolLib bossLib;\nval _ = new_theory "%s";\n%s\nval _ = export_theory();\n' \
    "$1" "$2" > "$eager_project/src/$1Script.sml"
}
eager_theory AfterClose 'Theorem after_close: T
Proof
  simp[] >> mp_tac (SPEC ``0:num`` TRUTH)
QED'
eager_theory InTry 'Theorem in_try: T
Proof
  TRY (mp_tac (SPEC ``0:num`` TRUTH)) >> simp[]
QED'
eager_theory InBranch 'Theorem in_branch: T /\ T
Proof
  CONJ_TAC >- (simp[] >> mp_tac (SPEC ``0:num`` TRUTH)) >> simp[]
QED'
eager_theory InTermination 'Definition count_down_def:
  count_down (n:num) = if n = 0 then 0 else count_down (n - 1)
Termination
  WF_REL_TAC `measure I` >> simp[] >> mp_tac (SPEC ``0:num`` TRUTH)
End'
eager_theory HeadOfNone 'Theorem head_of_none: T
Proof
  simp[] >>> HEADGOAL (ACCEPT_TAC TRUTH)
QED'
eager_theory InSelector 'fun bad_pat () : term quotation = raise Fail "bad selector pattern";
Theorem in_selector: T
Proof
  TRY (ALL_TAC >~ [bad_pat ()]) >> simp[]
QED'
eager_theory Control 'Theorem control: T /\ T
Proof
  CONJ_TAC >> simp[] >> mp_tac TRUTH
QED'
for mode in steps plain; do
  flags=(--skip-checkpoints --tactic-timeout 60)
  [[ $mode == plain ]] && flags=(--skip-checkpoints --skip-proof-steps)
  rm -rf "$eager_project/.holbuild"
  if (cd "$eager_project" && HOLBUILD_PIPELINE=off "$HOLBUILD_BIN" build "${flags[@]}") > "$tmpdir/eager-$mode.out" 2>&1; then
    echo "expected eager-evaluation build to fail with $mode" >&2
    cat "$tmpdir/eager-$mode.out" >&2
    exit 1
  fi
  require_grep '6 build failures:' "$tmpdir/eager-$mode.out"
  require_grep 'Term.dest_comb' "$tmpdir/eager-$mode.out"
  require_grep 'NTH_GOAL' "$tmpdir/eager-$mode.out"
  require_grep 'bad selector pattern' "$tmpdir/eager-$mode.out"
  if grep -q 'static error' "$tmpdir/eager-$mode.out"; then
    echo "eager-evaluation theories must fail when run, not to compile" >&2
    cat "$tmpdir/eager-$mode.out" >&2
    exit 1
  fi
  require_file "$eager_project/.holbuild/obj/src/ControlTheory.dat"
  for name in AfterClose InTry InBranch InTermination HeadOfNone InSelector; do
    if [[ -e "$eager_project/.holbuild/obj/src/${name}Theory.dat" ]]; then
      echo "$name built with $mode but must fail" >&2
      exit 1
    fi
  done
done

# A failed-prefix resume replays only the plan, not the proof text, so it
# compiles that text to evaluate it: an edit that adds a broken leaf after
# the goal closes must still fail the resumed proof.
resume_project=$tmpdir/eager-resume
make_project "$resume_project" eager-resume
cat > "$resume_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem resumed:
  T /\ T
Proof
  CONJ_TAC
  >- ACCEPT_TAC TRUTH
  >- FAIL_TAC "seed failure"
QED
val _ = export_theory();
SML
if (cd "$resume_project" && HOLBUILD_PIPELINE=off "$HOLBUILD_BIN" build --tactic-timeout 60) > "$tmpdir/eager-resume-seed.out" 2>&1; then
  echo "expected the seed build to fail" >&2
  exit 1
fi
require_grep 'seed failure' "$tmpdir/eager-resume-seed.out"
python3 - "$resume_project/src/AScript.sml" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
old = 'FAIL_TAC "seed failure"'
assert text.count(old) == 1
path.write_text(text.replace(old, '(simp[] >> mp_tac (SPEC ``0:num`` TRUTH))'))
PY
if (cd "$resume_project" && HOLBUILD_PIPELINE=off "$HOLBUILD_BIN" build --tactic-timeout 60) > "$tmpdir/eager-resume.out" 2>&1; then
  echo "expected the resumed build to fail" >&2
  cat "$tmpdir/eager-resume.out" >&2
  exit 1
fi
require_grep 'from: failed-prefix checkpoint in resumed' "$tmpdir/eager-resume.out"
require_grep 'not a comb' "$tmpdir/eager-resume.out"
