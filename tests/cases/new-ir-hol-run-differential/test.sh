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

make_project() {
  local project=$1
  local body=$2
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<'TOML'
[project]
name = "diff"

[build]
members = ["src"]

[run]
loads = ["ATheory"]
TOML
  cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
$body
val _ = export_theory();
val _ =
  List.app
    (fn (thm_name, th) =>
        print ("@@DUMP@@" ^ thm_name ^ "\t" ^ Parse.term_to_string (Thm.concl th) ^ "\n"))
    (DB.theorems "A");
SML
}

run_hol_run() {
  local project=$1
  local log=$2
  (cd "$project" && "$HOLDIR/bin/hol" run --noconfig --holstate "$HOLDIR/bin/hol.state" src/AScript.sml) > "$log" 2>&1
}

run_new_ir() {
  local project=$1
  local log=$2
  # Force ATheory itself so this remains a proof-IR execution test, but allow
  # cache reuse for the implicit HOL dependency context.  This test's oracle is
  # semantic equivalence, not cold-cache behaviour.
  (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --force --skip-checkpoints --tactic-timeout 60 ATheory) > "$log" 2>&1
}

extract_theory_summary() {
  local log=$1
  local dump=$2
  awk '/^@@DUMP@@/ { sub(/^@@DUMP@@/, ""); print }' "$log" | LC_ALL=C sort -t $'\t' -k1,1 > "$dump"
}

# Dump the holbuild result through holbuild's own run context.  Loading
# source-built HOL artifacts directly into prebuilt hol.state is not a valid
# oracle; [run].loads above asks holbuild to load ATheory in the context it
# built.
dump_holbuild_summary() {
  local name=$1
  local project=$2
  local log=$3
  local dump=$4
  local script=$project/.holbuild-dump-ATheory.sml
  cat > "$script" <<'SML'
val thms = DB.theorems "A";
val _ =
  List.app
    (fn (thm_name, th) =>
        print ("@@DUMP@@" ^ thm_name ^ "\t" ^ Parse.term_to_string (Thm.concl th) ^ "\n"))
    thms;
SML
  set +e
  (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" run .holbuild-dump-ATheory.sml) > "$log" 2>&1
  local status=$?
  set -e
  if [[ "$status" != 0 ]]; then
    echo "holbuild theory summary command failed for $project" >&2
    tail -80 "$log" >&2
    exit 1
  fi
  extract_theory_summary "$log" "$dump"
  if [[ ! -s "$dump" ]]; then
    echo "empty holbuild theory summary for $project" >&2
    tail -80 "$log" >&2
    exit 1
  fi
}

compare_success_summaries() {
  local name=$1
  local hol_log=$2
  local project=$3
  local hol_dump=$tmpdir/$name.hol-run.ATheory.summary
  local ir_dump=$tmpdir/$name.new-ir.ATheory.summary
  extract_theory_summary "$hol_log" "$hol_dump"
  if [[ ! -s "$hol_dump" ]]; then
    echo "empty direct HOL theory summary for $name" >&2
    tail -80 "$hol_log" >&2
    exit 1
  fi
  dump_holbuild_summary "$name" "$project" "$tmpdir/$name.new-ir.dump.log" "$ir_dump"
  if ! cmp -s "$hol_dump" "$ir_dump"; then
    echo "exported ATheory theorem summary mismatch for $name" >&2
    diff -u "$hol_dump" "$ir_dump" >&2 || true
    exit 1
  fi
}

check_case() {
  local name=$1
  local body=$2
  local project=$tmpdir/$name
  local hol_log=$tmpdir/$name.hol-run.log
  local ir_log=$tmpdir/$name.new-ir.log
  make_project "$project" "$body"

  set +e
  run_hol_run "$project" "$hol_log"
  local hol_status=$?
  set -e

  rm -rf "$project/.hol" "$project/.holbuild" "$project"/src/ATheory.{sig,sml,dat,ui,uo}

  set +e
  run_new_ir "$project" "$ir_log"
  local ir_status=$?
  set -e

  if [[ "$hol_status" != "$ir_status" ]]; then
    echo "hol run/new-ir status mismatch for $name: hol=$hol_status new_ir=$ir_status" >&2
    echo "--- hol run tail ---" >&2
    tail -60 "$hol_log" >&2
    echo "--- new-ir tail ---" >&2
    tail -80 "$ir_log" >&2
    exit 1
  fi

  if [[ "$hol_status" == 0 ]]; then
    compare_success_summaries "$name" "$hol_log" "$project"
  fi
}

check_case initial_success_suite 'Theorem existential_name_provider:
  ?sab:bool. sab
Proof
  qexists_tac `T` >> simp[]
QED

Theorem existential_name_consumer:
  T
Proof
  mp_tac existential_name_provider >> strip_tac >> Cases_on `sab` >> gvs[]
QED

Theorem sequence_success:
  T ∧ T
Proof
  CONJ_TAC >> ACCEPT_TAC TRUTH
QED

Theorem solved_before_suffix_then1_success:
  T
Proof
  rw[] >> `T` by ACCEPT_TAC TRUTH
QED

Theorem then1_success:
  T ∧ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >- ACCEPT_TAC TRUTH
QED

Theorem sibling_then1_chain_success:
  T ∧ T ∧ T ∧ T
Proof
  rpt CONJ_TAC
  >- ACCEPT_TAC TRUTH
  >- ACCEPT_TAC TRUTH
  >- ACCEPT_TAC TRUTH
  >- ACCEPT_TAC TRUTH
QED

Theorem sibling_then1_branch_sequence_success:
  T ∧ T ∧ T
Proof
  rpt CONJ_TAC
  >- (ALL_TAC >> ACCEPT_TAC TRUTH)
  >- ACCEPT_TAC TRUTH
  >- ACCEPT_TAC TRUTH
QED

Theorem branch_sequence_solves_last_goal_success:
  T
Proof
  ALL_TAC >- (ALL_TAC >> ACCEPT_TAC TRUTH)
QED

'

check_case branch_then1_lhs_sequence_failure 'Theorem thm:
  ((T ∨ T) ⇒ T) ∧ T
Proof
  CONJ_TAC
  >- (ALL_TAC >> strip_tac >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
  >- ACCEPT_TAC TRUTH
QED'

check_case remaining_success_suite 'Theorem branch_suffix_reverse_success:
  ((T ∧ T) ∧ (T ∧ T)) ∧ T
Proof
  CONJ_TAC
  >- (CONJ_TAC >> reverse CONJ_TAC >> simp[])
  >- ACCEPT_TAC TRUTH
QED

Theorem thenl_success:
  T ∧ T
Proof
  CONJ_TAC THENL [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem bar_thenl_success:
  T ∧ T
Proof
  CONJ_TAC >| [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem dynamic_thenl_success:
  T ∧ T
Proof
  CONJ_TAC THENL
  let
    fun tac () = ACCEPT_TAC TRUTH
  in
    [tac (), tac ()]
  end
QED

Theorem then_lt_tacs_to_lt_success:
  T ∧ T
Proof
  CONJ_TAC >>> TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem allgoals_success:
  T ∧ T
Proof
  CONJ_TAC >>> ALLGOALS (ACCEPT_TAC TRUTH)
QED

Theorem nth_goal_success:
  T ∧ T ∧ T
Proof
  rpt CONJ_TAC
  >>> NTH_GOAL (ACCEPT_TAC TRUTH) 2
  >>> TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem head_last_goal_success:
  T ∧ T
Proof
  CONJ_TAC
  >>> LASTGOAL (ACCEPT_TAC TRUTH)
  >>> HEADGOAL (ACCEPT_TAC TRUTH)
QED

Theorem split_lt_success:
  T ∧ T
Proof
  CONJ_TAC
  >>> SPLIT_LT 1 (TACS_TO_LT [ACCEPT_TAC TRUTH], TACS_TO_LT [ACCEPT_TAC TRUTH])
QED

Theorem first_lt_success:
  T ∧ T
Proof
  CONJ_TAC
  >>> FIRST_LT (ACCEPT_TAC TRUTH)
  >>> ALLGOALS (ACCEPT_TAC TRUTH)
QED

Theorem list_try_repeat_reverse_success:
  T ∧ T
Proof
  CONJ_TAC
  >>> REVERSE_LT
  >>> TRY_LT NO_LT
  >>> REPEAT_LT NO_LT
  >>> TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem null_ok_empty_success:
  T
Proof
  ACCEPT_TAC TRUTH >>> NULL_OK_LT (TACS_TO_LT [])
QED

Theorem rotate_lt_success:
  T ∧ (T ==> T)
Proof
  CONJ_TAC
  >>> NULL_OK_LT (ROTATE_LT 1)
  >>> TACS_TO_LT [DISCH_TAC >> ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem orelse_lt_success:
  T ∧ T
Proof
  CONJ_TAC >>> (NO_LT ORELSE_LT TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH])
QED

Theorem every_first_success:
  T
Proof
  EVERY [TRY NO_TAC, FIRST [NO_TAC, ACCEPT_TAC TRUTH]]
QED

Theorem first_prove_success:
  T
Proof
  FIRST_PROVE [NO_TAC, ACCEPT_TAC TRUTH]
QED

Theorem validation_wrappers_success:
  T
Proof
  VALID (VALIDATE (GEN_VALIDATE true (CONJ_VALIDATE (CHANGED_TAC (ACCEPT_TAC TRUTH)))))
QED

Theorem if_add_sgs_success:
  T
Proof
  ADD_SGS_TAC [`T`] (IF NO_TAC (FAIL_TAC "bad") (ACCEPT_TAC TRUTH))
  >> ACCEPT_TAC TRUTH
QED

Theorem every_lt_select_success:
  T ∧ T ∧ T
Proof
  rpt CONJ_TAC
  >>> EVERY_LT [TRY_LT NO_LT, ROTATE_LT 1]
  >>> SELECT_LT_THEN (ACCEPT_TAC TRUTH) ALL_TAC
QED

Theorem tryall_select_success:
  T ∧ T
Proof
  CONJ_TAC >>> TRYALL (ACCEPT_TAC TRUTH)
QED

Theorem list_validation_success:
  T ∧ T
Proof
  CONJ_TAC
  >>> VALID_LT (VALIDATE_LT (GEN_VALIDATE_LT true (TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH])))
QED

Theorem select_lt_success:
  T ∧ T
Proof
  CONJ_TAC >>> SELECT_LT (ACCEPT_TAC TRUTH)
QED

Theorem reverse_then1_success:
  T ∧ T
Proof
  reverse CONJ_TAC >- ACCEPT_TAC TRUTH >- ACCEPT_TAC TRUTH
QED

Theorem reverse_suffix_branch_success:
  (T ∧ T) ∧ (T ∧ T)
Proof
  CONJ_TAC >> reverse CONJ_TAC >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH
QED

Theorem try_first_repeat_success:
  T ∧ T ∧ T
Proof
  REPEAT CONJ_TAC >> TRY NO_TAC >> FIRST [NO_TAC, ACCEPT_TAC TRUTH]
QED

Theorem orelse_success:
  T
Proof
  NO_TAC ORELSE ACCEPT_TAC TRUTH
QED

Theorem by_success:
  T
Proof
  `T` by ACCEPT_TAC TRUTH
  >> ACCEPT_TAC TRUTH
QED

Theorem suffix_by_success:
  T
Proof
  ALL_TAC >> `T` by ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH
QED

Theorem suffices_by_success:
  F ==> (T ∧ T)
Proof
  strip_tac
  >> CONJ_TAC
  >> `F` suffices_by simp[]
  >> FIRST_ASSUM ACCEPT_TAC
QED

Theorem suffices_by_partial_success:
  F ==> T ∧ T
Proof
  strip_tac
  >> `F` suffices_by simp[]
  >> CONJ_TAC
  >> FIRST_ASSUM ACCEPT_TAC
  >> FIRST_ASSUM ACCEPT_TAC
QED

Theorem nested_suffices_by_success:
  T
Proof
  `T` by (`T` suffices_by (ACCEPT_TAC TRUTH) >> ACCEPT_TAC TRUTH)
  >> ACCEPT_TAC TRUTH
QED

Theorem nested_branch_by_success:
  T /\ T
Proof
  CONJ_TAC
  >- (`T` by ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
  \\ `T` suffices_by simp[]
  \\ ACCEPT_TAC TRUTH
QED

Theorem map_every_success:
  T
Proof
  MAP_EVERY (fn th => ACCEPT_TAC th) [TRUTH]
QED

Theorem map_every_lowercase_success:
  T
Proof
  map_every (fn th => ACCEPT_TAC th) [TRUTH]
QED

Theorem map_first_success:
  T
Proof
  MAP_FIRST (fn th => ACCEPT_TAC th) [TRUTH]
QED

Theorem select_goals_success:
  T ∧ T
Proof
  CONJ_TAC >>~ [`T`]
  >> ACCEPT_TAC TRUTH
  >> ACCEPT_TAC TRUTH
QED

Theorem select_single_success:
  T ∧ T
Proof
  CONJ_TAC >~ `T`
  >> ACCEPT_TAC TRUTH
  >> ACCEPT_TAC TRUTH
QED

Theorem select_then1_success:
  T ∧ T
Proof
  CONJ_TAC >>~- ([`T`], ACCEPT_TAC TRUTH)
  >> ACCEPT_TAC TRUTH
QED

Theorem unsafe_then1_chain_success:
  T ∧ T ∧ T ∧ T
Proof
  rpt CONJ_TAC
  >- ACCEPT_TAC TRUTH
  >- ACCEPT_TAC TRUTH
  >- ACCEPT_TAC TRUTH
  >- ACCEPT_TAC TRUTH
QED

Theorem unsafe_then1_suffix_precedence:
  (T ==> T) ∧ T
Proof
  CONJ_TAC
  >- (impl_tac >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
  >> ACCEPT_TAC TRUTH
QED

'

check_case invalid_intermediate_failure 'val bad_tac = fn g => ([g], fn _ => TRUTH);

Theorem thm:
  T
Proof
  bad_tac >> ACCEPT_TAC TRUTH
QED'

check_case invalid_intermediate_then1_failure 'val bad_tac = fn g => ([g], fn _ => TRUTH);

Theorem invalid_intermediate_then1:
  T ∧ T
Proof
  CONJ_TAC >- (bad_tac >> ACCEPT_TAC TRUTH) >- ACCEPT_TAC TRUTH
QED

'

check_case then_suffix_after_solved_failure 'Theorem thm:
  T
Proof
  ACCEPT_TAC TRUTH >> FAIL_TAC "should be skipped over []"
QED'

check_case parser_recovery_failure 'Theorem parser_recovery:
  T
Proof
  ( ACCEPT_TAC TRUTH
QED'

check_case parser_recovery_compat 'Theorem parser_recovery:
  T
Proof
  ( ACCEPT_TAC TRUTH
QED'
require_grep "HOL source parser recovered while instrumenting theorem boundaries for ATheory; using recovered theorem boundaries" "$tmpdir/parser_recovery_compat.new-ir.log"

check_case resume_suite 'open markerLib;

Theorem partial:
  T ∧ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >- suspend "right"
QED

Resume partial[right]:
  ACCEPT_TAC TRUTH
QED

Finalise partial'

check_case first_empty_failure 'Theorem thm:
  T
Proof
  FIRST [] >> ACCEPT_TAC TRUTH
QED'

check_case map_first_empty_failure 'Theorem thm:
  T
Proof
  MAP_FIRST (fn th => ACCEPT_TAC th) [] >> ACCEPT_TAC TRUTH
QED'

check_case thenl_length_failure 'Theorem thm:
  T ∧ T
Proof
  CONJ_TAC THENL [ACCEPT_TAC TRUTH]
QED'
