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

make_project() {
  local project=$1
  local body=$2
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "diff"

[build]
members = ["src"]
TOML
  cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
$body
val _ = export_theory();
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
  (cd "$project" && "$HOLBUILD_BIN" build --force --no-cache --skip-checkpoints --tactic-timeout 60 ATheory) > "$log" 2>&1
}

copy_hol_run_artifacts() {
  local project=$1
  local dest=$2
  mkdir -p "$dest"
  cp "$project/.hol/objs"/ATheory.{dat,sml,sig} "$dest/"
}

normalize_generated_sml() {
  sed -E \
    -e 's#holpathdb\.subst_pathvars "[^"]*ATheory\.dat"#holpathdb.subst_pathvars "<ATheory.dat>"#' \
    -e 's#hash = "[0-9a-f]+"#hash = "<dat-hash>"#' \
    "$1"
}

compare_generated_sml() {
  local name=$1
  local hol_sml=$2
  local ir_sml=$3
  local hol_norm=$tmpdir/$name.hol-run.ATheory.sml.norm
  local ir_norm=$tmpdir/$name.new-ir.ATheory.sml.norm
  normalize_generated_sml "$hol_sml" > "$hol_norm"
  normalize_generated_sml "$ir_sml" > "$ir_norm"
  if ! cmp -s "$hol_norm" "$ir_norm"; then
    echo "normalized generated ATheory.sml mismatch for $name" >&2
    diff -u "$hol_norm" "$ir_norm" >&2 || true
    exit 1
  fi
}

prepare_load_root() {
  local artifacts=$1
  local root=$2
  mkdir -p "$root/.hol/objs"
  cp "$artifacts"/ATheory.{dat,sml,sig} "$root/.hol/objs/"
  sed -E \
    "s#holpathdb\.subst_pathvars \"[^\"]*ATheory\.dat\"#holpathdb.subst_pathvars \"$root/ATheory.dat\"#" \
    "$artifacts/ATheory.sml" > "$root/.hol/objs/ATheory.sml"
}

dump_theory_summary() {
  local name=$1
  local kind=$2
  local artifacts=$3
  local log=$4
  local dump=$5
  local root=$tmpdir/$name.$kind.loadroot
  local script=$tmpdir/$name.$kind.dump-ATheory.sml
  prepare_load_root "$artifacts" "$root"
  cat > "$script" <<SML
open HolKernel Parse boolLib bossLib;
val _ = let val out = HOLFileSys.openOut "$root/ATheory.ui" in HOLFileSys.output(out, "$root/ATheory.sig\n"); HOLFileSys.closeOut out end;
val _ = let val out = HOLFileSys.openOut "$root/ATheory.uo" in HOLFileSys.output(out, "$root/ATheory.sml\n"); HOLFileSys.closeOut out end;
val result =
  (load "$root/ATheory";
   SOME (DB.theorems "A"))
  handle e => (print ("@@DUMP_ERROR@@ " ^ General.exnMessage e ^ "\\n"); NONE);
val _ =
  case result of
    NONE => OS.Process.exit OS.Process.failure
  | SOME thms =>
      (List.app
         (fn (thm_name, th) =>
             print ("@@DUMP@@" ^ thm_name ^ "\t" ^ term_to_string (concl th) ^ "\\n"))
         thms;
       OS.Process.exit OS.Process.success);
SML
  "$HOLDIR/bin/hol" --noconfig --holstate "$HOLDIR/bin/hol.state" < "$script" > "$log" 2>&1
  grep '^@@DUMP@@' "$log" | sed 's/^@@DUMP@@//' > "$dump"
  if [[ ! -s "$dump" ]]; then
    echo "empty theory summary for $artifacts" >&2
    tail -80 "$log" >&2
    exit 1
  fi
}

compare_dat_semantics() {
  local name=$1
  local hol_dir=$2
  local ir_dir=$3
  local hol_dump=$tmpdir/$name.hol-run.ATheory.dat.dump
  local ir_dump=$tmpdir/$name.new-ir.ATheory.dat.dump
  dump_theory_summary "$name" hol-run "$hol_dir" "$tmpdir/$name.hol-run.dump.log" "$hol_dump"
  dump_theory_summary "$name" new-ir "$ir_dir" "$tmpdir/$name.new-ir.dump.log" "$ir_dump"
  if ! cmp -s "$hol_dump" "$ir_dump"; then
    echo "loaded ATheory.dat theorem summary mismatch for $name" >&2
    diff -u "$hol_dump" "$ir_dump" >&2 || true
    exit 1
  fi
}

compare_success_artifacts() {
  local name=$1
  local hol_artifacts=$2
  local project=$3
  local ir_flat=$tmpdir/$name.new-ir-artifacts
  mkdir -p "$ir_flat"
  cp "$project/.holbuild/obj/src"/ATheory.{sml,sig} "$ir_flat/"
  cp "$project/.holbuild/obj/src"/ATheory.dat "$ir_flat/"

  cmp "$hol_artifacts/ATheory.sig" "$ir_flat/ATheory.sig" || {
    echo "generated ATheory.sig mismatch for $name" >&2
    exit 1
  }
  compare_generated_sml "$name" "$hol_artifacts/ATheory.sml" "$ir_flat/ATheory.sml"
  compare_dat_semantics "$name" "$hol_artifacts" "$ir_flat"
}

check_case() {
  local name=$1
  local body=$2
  local project=$tmpdir/$name
  local hol_log=$tmpdir/$name.hol-run.log
  local ir_log=$tmpdir/$name.new-ir.log
  local hol_artifacts=$tmpdir/$name.hol-run-artifacts
  make_project "$project" "$body"

  set +e
  run_hol_run "$project" "$hol_log"
  local hol_status=$?
  set -e
  if [[ "$hol_status" == 0 ]]; then
    copy_hol_run_artifacts "$project" "$hol_artifacts"
  fi

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
    compare_success_artifacts "$name" "$hol_artifacts" "$project"
  fi
}

check_case success_suite 'val bad_tac = fn g => ([g], fn _ => TRUTH);

Theorem existential_name_provider:
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

Theorem branch_then1_lhs_sequence_success:
  ((T ∨ T) ⇒ T) ∧ T
Proof
  CONJ_TAC
  >- (ALL_TAC >> strip_tac >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
  >- ACCEPT_TAC TRUTH
QED

Theorem branch_suffix_reverse_success:
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

Theorem invalid_intermediate:
  T
Proof
  bad_tac >> ACCEPT_TAC TRUTH
QED

Theorem invalid_intermediate_then1:
  T ∧ T
Proof
  CONJ_TAC >- (bad_tac >> ACCEPT_TAC TRUTH) >- ACCEPT_TAC TRUTH
QED

Theorem then_suffix_after_solved:
  T
Proof
  ACCEPT_TAC TRUTH >> FAIL_TAC "should be skipped over []"
QED

Theorem parser_recovery:
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
