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
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "removed-goalfrag-plan"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem simple:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML

log=$tmpdir/goalfrag-plan.log
if (cd "$project" && "$HOLBUILD_BIN" goalfrag-plan ATheory:simple) > "$log" 2>&1; then
  echo "expected removed goalfrag-plan command to fail" >&2
  exit 1
fi
require_grep "goalfrag-plan has been removed; use execution-plan THEORY:THEOREM" "$log"

plan_project=$tmpdir/execution-plan-coverage
mkdir -p "$plan_project/src"
cat > "$plan_project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "execution-plan-coverage"

[build]
members = ["src"]
TOML
cat > "$plan_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem grouped_prefix:
  T
Proof
  rpt gen_tac >> strip_tac >> qpat_x_assum `step s = _` mp_tac >> simp[]
QED

Theorem reverse_branch:
  T
Proof
  simp[step_create_def] >> strip_tac
  >> rewrite_tac[Ntimes CONJ_ASSOC 3]
  >> reverse conj_tac >- (
    qpat_x_assum `proceed_create _ _ _ _ _ se = _` mp_tac >>
    rewrite_tac[proceed_create_def] >>
    strip_tac >> gvs[] )
  >> strip_tac
QED

Theorem reverse_branch_suffix:
  T /\ T /\ T
Proof
  CONJ_TAC
  >> reverse CONJ_TAC >- (ACCEPT_TAC TRUTH)
  >> simp[GSYM CONJ_ASSOC]
  >> reverse CONJ_TAC >- (ACCEPT_TAC TRUTH)
  >> ACCEPT_TAC TRUTH
QED

SML
cat "$SCRIPT_DIR/step_create_push_structure.sml" >> "$plan_project/src/AScript.sml"
cat >> "$plan_project/src/AScript.sml" <<'SML'

Theorem reverse_thenl:
  T
Proof
  CONJ_TAC
  \\ Tactical.REVERSE (TRY CONJ_TAC) THENL
     [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem branch_list:
  T /\ T
Proof
  CONJ_TAC >| [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem first_try_repeat:
  T
Proof
  FIRST [NO_TAC, TRY NO_TAC, REPEAT NO_TAC, ACCEPT_TAC TRUTH]
QED

Theorem goal_selector_numbers:
  T /\ T /\ T
Proof
  rpt CONJ_TAC
  >>> NTH_GOAL (ACCEPT_TAC TRUTH) 2
  >>> SPLIT_LT 1 (ALL_LT, FIRST_LT ACCEPT_TAC TRUTH)
QED

Theorem map_aliases:
  T /\ T
Proof
  CONJ_TAC
  >- MAP_EVERY (fn th => ACCEPT_TAC th) [TRUTH]
  >> MAP_FIRST (fn th => ACCEPT_TAC th) [TRUTH]
QED

Theorem branch_and_by:
  T /\ T
Proof
  CONJ_TAC
  >- (`T` by ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
  \\ `T` suffices_by simp[]
  \\ ACCEPT_TAC TRUTH
QED

Theorem nested_combinators:
  T /\ T /\ T
Proof
  rpt strip_tac
  >> CONJ_TAC
  >- (TRY CONJ_TAC >> ACCEPT_TAC TRUTH)
  >> reverse CONJ_TAC
  >- (sg `T` >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
  >> ACCEPT_TAC TRUTH
QED

Theorem select_goals:
  T /\ T
Proof
  CONJ_TAC >>~ [`T`]
  \\ ACCEPT_TAC TRUTH
  \\ ACCEPT_TAC TRUTH
QED

Theorem select_single:
  T /\ T
Proof
  CONJ_TAC >~ `T`
  \\ ACCEPT_TAC TRUTH
  \\ ACCEPT_TAC TRUTH
QED

Theorem select_then1:
  T /\ T
Proof
  CONJ_TAC >>~- ([`T`], ACCEPT_TAC TRUTH)
  \\ ACCEPT_TAC TRUTH
QED

Theorem try_no_tac:
  T
Proof
  TRY NO_TAC >> ACCEPT_TAC TRUTH
QED

Theorem no_lt_orelse:
  T
Proof
  ALL_TAC >>> (NO_LT ORELSE_LT TACS_TO_LT [ACCEPT_TAC TRUTH])
QED

Theorem nth_goal_expr:
  T /\ T /\ T
Proof
  rpt CONJ_TAC >>> NTH_GOAL (ACCEPT_TAC TRUTH) (1 + 1) >>> TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem split_expr:
  T /\ T
Proof
  CONJ_TAC >>> SPLIT_LT (1 + 0) (TACS_TO_LT [ACCEPT_TAC TRUTH], TACS_TO_LT [ACCEPT_TAC TRUTH])
QED

Theorem try_then1_group:
  (T /\ T) /\ T
Proof
  CONJ_TAC >> TRY (CONJ_TAC >- ACCEPT_TAC TRUTH) >> ACCEPT_TAC TRUTH
QED

Theorem qed_closes_branch:
  T /\ T
Proof
  CONJ_TAC
  >- ACCEPT_TAC TRUTH
  >> (
    ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML

check_execution_plan() {
  local theorem=$1
  local actual=$tmpdir/$theorem.execution-plan
  (cd "$plan_project" && "$HOLBUILD_BIN" execution-plan "ATheory:$theorem") > "$actual" 2>&1
  require_grep "holbuild proof-ir plan ATheory:$theorem source=src/AScript.sml (" "$actual"
}

for theorem in \
  grouped_prefix reverse_branch reverse_branch_suffix step_create_push_structure \
  reverse_thenl branch_list first_try_repeat goal_selector_numbers map_aliases \
  branch_and_by nested_combinators select_goals select_single select_then1 \
  try_no_tac no_lt_orelse nth_goal_expr split_expr try_then1_group qed_closes_branch
 do
  check_execution_plan "$theorem"
done

require_grep "list_tac REVERSE_LT" "$tmpdir/reverse_branch.execution-plan"
require_grep "qpat_x_assum" "$tmpdir/reverse_branch.execution-plan"
require_grep "NTH_GOAL" "$tmpdir/goal_selector_numbers.execution-plan"
require_grep "SPLIT_LT" "$tmpdir/goal_selector_numbers.execution-plan"
require_grep 'sg `T`' "$tmpdir/branch_and_by.execution-plan"
require_grep "suffices_by" "$tmpdir/branch_and_by.execution-plan"
require_grep "SELECT_GOALS" "$tmpdir/select_goals.execution-plan"
require_grep "SELECT_GOAL" "$tmpdir/select_single.execution-plan"
require_grep "SELECT_GOALS_LT_THEN1" "$tmpdir/select_then1.execution-plan"
require_grep "FIRST" "$tmpdir/first_try_repeat.execution-plan"
require_grep "TRY" "$tmpdir/first_try_repeat.execution-plan"
require_grep "REPEAT" "$tmpdir/first_try_repeat.execution-plan"
