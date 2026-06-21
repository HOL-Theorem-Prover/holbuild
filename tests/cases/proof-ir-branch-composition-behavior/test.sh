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

write_project_toml() {
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

success_project=$tmpdir/success-project
write_project_toml "$success_project" "proof-ir-branch-composition-success"
cat > "$success_project/src/BranchScript.sml" <<'SML'
Theory Branch

Theorem branch_then_suffix_success:
  T /\ T
Proof
  CONJ_TAC >- (ALL_TAC >> ACCEPT_TAC TRUTH) >>
  ACCEPT_TAC TRUTH
QED

Theorem nested_branch_rhs_success:
  (T /\ T) /\ T
Proof
  CONJ_TAC >- (CONJ_TAC >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH) >>
  ACCEPT_TAC TRUTH
QED

Theorem suffix_compound_each_success:
  (T /\ T) /\ (T /\ T)
Proof
  CONJ_TAC >>
  (CONJ_TAC >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
QED

Theorem issue60_parenthesized_rhs_success:
  (T /\ T) /\ (T /\ T)
Proof
  CONJ_TAC >>
  (CONJ_TAC >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
QED

Theorem suffix_each_leaves_subgoals_success:
  (T /\ T) /\ (T /\ T)
Proof
  CONJ_TAC >>
  CONJ_TAC >>
  ACCEPT_TAC TRUTH
QED

Theorem branch_suffix_compound_each_success:
  ((T /\ T) /\ T) /\ T
Proof
  CONJ_TAC >-
    (ALL_TAC >>
     (CONJ_TAC >- (CONJ_TAC >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH) >>
      ACCEPT_TAC TRUTH)) >>
  ACCEPT_TAC TRUTH
QED

Theorem sibling_branches_success:
  T /\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >- ACCEPT_TAC TRUTH
QED

Theorem thenl_cases_success:
  T /\ T
Proof
  CONJ_TAC >| [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem thenl_cases_leave_subgoals_success:
  (T /\ T) /\ (T /\ T)
Proof
  CONJ_TAC >| [CONJ_TAC, CONJ_TAC] >>
  ACCEPT_TAC TRUTH
QED

Theorem thenl_cases_preserve_residual_order_success:
  (T /\ (0 = 0)) /\ ((1 = 1) /\ T)
Proof
  CONJ_TAC >| [CONJ_TAC, CONJ_TAC]
  >- ACCEPT_TAC TRUTH
  >- REFL_TAC
  >- REFL_TAC
  >- ACCEPT_TAC TRUTH
QED

Theorem thenl_suffix_each_success:
  (T /\ (0 = 0)) /\ ((1 = 1) /\ T)
Proof
  CONJ_TAC >>
  (CONJ_TAC >| [ALL_TAC, ALL_TAC])
  >- ACCEPT_TAC TRUTH
  >- REFL_TAC
  >- REFL_TAC
  >- ACCEPT_TAC TRUTH
QED

Theorem by_wildcard_eq_success:
  T
Proof
  `T = T` by REFL_TAC >>
  `_ = T` by REFL_TAC >>
  ACCEPT_TAC TRUTH
QED

Theorem by_wildcard_eq_chain_finisher_success:
  1 + 1 = SUC 1
Proof
  `1 + 1 = 2` by EVAL_TAC >>
  `_ = SUC 1` by EVAL_TAC >>
  (fn g as (asl, _) =>
     if length asl = 1 then ALL_TAC g
     else FAIL_TAC "by chain should leave exactly one assumption" g) >>
  pop_assum ACCEPT_TAC
QED

Theorem each_preserve_residual_order_success:
  (T /\ (0 = 0)) /\ ((1 = 1) /\ T)
Proof
  CONJ_TAC >>
  CONJ_TAC
  >- ACCEPT_TAC TRUTH
  >- REFL_TAC
  >- REFL_TAC
  >- ACCEPT_TAC TRUTH
QED

Theorem repeat_same_goal_count_progress_success:
  !x:num. x = x ==> x = x
Proof
  rpt strip_tac >> ASM_REWRITE_TAC[]
QED

Theorem by_sugar_success:
  T
Proof
  `T` by ACCEPT_TAC TRUTH
QED

Theorem suffices_by_sugar_success:
  T
Proof
  `T` suffices_by (DISCH_TAC >> ACCEPT_TAC TRUTH) >>
  ACCEPT_TAC TRUTH
QED

Theorem each_scope_discriminates:
  (P ==> P /\ T) /\ (Q ==> Q /\ T)
Proof
  CONJ_TAC >>
  (strip_tac >>
   CONJ_TAC >- FIRST_ASSUM ACCEPT_TAC >>
   ACCEPT_TAC TRUTH)
QED

Theorem branch_local_each_discriminates:
  ((P ==> P /\ T) /\ (Q ==> Q /\ T)) /\ T
Proof
  CONJ_TAC >-
    (CONJ_TAC >>
     (strip_tac >>
      CONJ_TAC >- FIRST_ASSUM ACCEPT_TAC >>
      ACCEPT_TAC TRUTH)) >>
  ACCEPT_TAC TRUTH
QED

Theorem cases_discriminates:
  T /\ (0 = 0)
Proof
  CONJ_TAC >| [
    ACCEPT_TAC TRUTH,
    REFL_TAC
  ]
QED
SML

steps_success_log=$tmpdir/success-steps.log
(cd "$success_project" && "$HOLBUILD_BIN" build BranchTheory) > "$steps_success_log" 2>&1
require_grep "BranchTheory built" "$steps_success_log"
require_file "$success_project/.holbuild/obj/src/BranchTheory.dat"

skip_project=$tmpdir/skip-project
cp -R "$success_project" "$skip_project"
rm -rf "$skip_project/.holbuild"
skip_success_log=$tmpdir/success-skip.log
(cd "$skip_project" && "$HOLBUILD_BIN" build --skip-proof-steps BranchTheory) > "$skip_success_log" 2>&1
require_grep "BranchTheory" "$skip_success_log"
require_file "$skip_project/.holbuild/obj/src/BranchTheory.dat"

repeat_limit_project=$tmpdir/repeat-limit-project
cp -R "$success_project" "$repeat_limit_project"
rm -rf "$repeat_limit_project/.holbuild"
repeat_limit_log=$tmpdir/repeat-limit.log
(cd "$repeat_limit_project" && HOLBUILD_PROOF_IR_REPEAT_LIMIT=1 "$HOLBUILD_BIN" build --force BranchTheory) > "$repeat_limit_log" 2>&1
require_grep "BranchTheory built" "$repeat_limit_log"
if grep -q 'proof-ir repeat exceeded' "$repeat_limit_log"; then
  echo "tactic-level rpt unexpectedly used structural repeat limit" >&2
  exit 1
fi

check_failure_project() {
  local name=$1
  local body=$2
  local expected1=$3
  local expected2=$4
  local project=$tmpdir/$name-project
  write_project_toml "$project" "$name"
  cat > "$project/src/FailScript.sml" <<SML
Theory Fail

Theorem before:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem target:
  T /\\ T
Proof
$body
QED

Theorem after:
  T
Proof
  ACCEPT_TAC TRUTH
QED
SML
  local log=$tmpdir/$name.log
  if (cd "$project" && "$HOLBUILD_BIN" build FailTheory) > "$log" 2>&1; then
    echo "expected $name to fail" >&2
    exit 1
  fi
  require_grep "$expected1" "$log"
  require_grep "$expected2" "$log"
}

check_failure_project \
  "branch-fail-tac" \
  '  CONJ_TAC >- FAIL_TAC "branch failure" >>
  ACCEPT_TAC TRUTH' \
  'FAIL_TAC "branch failure"' \
  'plan position: 02 step FAIL_TAC "branch failure"'

check_failure_project \
  "branch-no-tac" \
  '  CONJ_TAC >- NO_TAC >>
  ACCEPT_TAC TRUTH' \
  'NO_TAC' \
  'plan position: 02 step NO_TAC'

check_failure_project \
  "branch-unsolved-close" \
  '  CONJ_TAC >- ALL_TAC >>
  ACCEPT_TAC TRUTH' \
  'selected goals were not solved' \
  'plan position: 03 end'

cases_failure_project=$tmpdir/cases-failure-project
write_project_toml "$cases_failure_project" "cases-failure"
cat > "$cases_failure_project/src/CasesFailScript.sml" <<'SML'
Theory CasesFail

Theorem target:
  T /\ (0 = 0)
Proof
  CONJ_TAC >| [
    ACCEPT_TAC TRUTH,
    FAIL_TAC "case failure"
  ]
QED
SML
cases_failure_log=$tmpdir/cases-failure.log
if (cd "$cases_failure_project" && "$HOLBUILD_BIN" build CasesFailTheory) > "$cases_failure_log" 2>&1; then
  echo "expected cases failure project to fail" >&2
  exit 1
fi
require_grep 'FAIL_TAC "case failure"' "$cases_failure_log"
require_grep 'plan position: 05 step FAIL_TAC "case failure"' "$cases_failure_log"

timeout_project=$tmpdir/timeout-project
write_project_toml "$timeout_project" "proof-ir-branch-composition-timeout"
cat > "$timeout_project/src/TimeoutScript.sml" <<'SML'
Theory Timeout

fun slow_tac g = (OS.Process.sleep (Time.fromSeconds 5); ALL_TAC g)

Theorem branch_timeout:
  T /\ T
Proof
  CONJ_TAC >- slow_tac >>
  ACCEPT_TAC TRUTH
QED
SML

timeout_log=$tmpdir/timeout.log
if (cd "$timeout_project" && "$HOLBUILD_BIN" build --tactic-timeout 1 TimeoutTheory) > "$timeout_log" 2>&1; then
  echo "expected branch timeout build to fail" >&2
  exit 1
fi
require_grep "slow_tac" "$timeout_log"
require_grep "timed out" "$timeout_log"
require_grep "plan position: 02 step slow_tac" "$timeout_log"

each_timeout_project=$tmpdir/each-timeout-project
write_project_toml "$each_timeout_project" "proof-ir-each-timeout"
cat > "$each_timeout_project/src/EachTimeoutScript.sml" <<'SML'
Theory EachTimeout

fun slow_tac g = (OS.Process.sleep (Time.fromSeconds 5); ALL_TAC g)

Theorem each_timeout:
  (T /\ T) /\ (T /\ T)
Proof
  CONJ_TAC >>
  (CONJ_TAC >- slow_tac >>
   ACCEPT_TAC TRUTH)
QED
SML

each_timeout_log=$tmpdir/each-timeout.log
if (cd "$each_timeout_project" && "$HOLBUILD_BIN" build --tactic-timeout 1 EachTimeoutTheory) > "$each_timeout_log" 2>&1; then
  echo "expected each timeout build to fail" >&2
  exit 1
fi
require_grep "slow_tac" "$each_timeout_log"
require_grep "timed out" "$each_timeout_log"
require_grep "plan position: 04 step slow_tac" "$each_timeout_log"
