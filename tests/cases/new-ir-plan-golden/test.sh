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
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "new-ir-plan"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
SML

check_plan() {
  local theorem=$1
  local expected=$tmpdir/$theorem.expected
  local actual=$tmpdir/$theorem.actual
  cat > "$expected"
  (cd "$project" && "$HOLBUILD_BIN" execution-plan ATheory:"$theorem") > "$actual" 2>&1
  if ! diff -u "$expected" "$actual"; then
    echo "new-ir plan mismatch for $theorem" >&2
    exit 1
  fi
}

check_plan_file() {
  local theorem=$1
  local expected=$2
  local actual=$tmpdir/$theorem.actual
  (cd "$project" && "$HOLBUILD_BIN" execution-plan ATheory:"$theorem") > "$actual" 2>&1
  if ! diff -u "$expected" "$actual"; then
    echo "new-ir plan mismatch for $theorem" >&2
    exit 1
  fi
}

cat >> "$project/src/AScript.sml" <<'SML'
Theorem thenl_literal_plan:
  T /\ T
Proof
  CONJ_TAC THENL [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED
SML
check_plan thenl_literal_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:thenl_literal_plan source=src/AScript.sml (7 steps)
  00 step CONJ_TAC
  01 cases
  02   case 1
  03     step ACCEPT_TAC TRUTH
  04   case 2
  05     step ACCEPT_TAC TRUTH
  06 end
EXPECTED

removed_plan_alias_log=$tmpdir/removed-plan-alias.log
if (cd "$project" && "$HOLBUILD_BIN" goalfrag-plan --new-ir ATheory:thenl_literal_plan) > "$removed_plan_alias_log" 2>&1; then
  echo "expected removed goalfrag-plan alias to fail" >&2
  exit 1
fi
require_grep "goalfrag-plan has been removed; use execution-plan THEORY:THEOREM" "$removed_plan_alias_log"

cat >> "$project/src/AScript.sml" <<'SML'
Theorem allgoals_plan:
  T /\ T
Proof
  CONJ_TAC >>> ALLGOALS (ACCEPT_TAC TRUTH)
QED
SML
check_plan allgoals_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:allgoals_plan source=src/AScript.sml (2 steps)
  00 step CONJ_TAC
  01 list-step ALLGOALS (ACCEPT_TAC TRUTH)
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem tacs_to_lt_plan:
  T /\ T
Proof
  CONJ_TAC >>> TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED
SML
check_plan tacs_to_lt_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:tacs_to_lt_plan source=src/AScript.sml (2 steps)
  00 step CONJ_TAC
  01 list-step TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem selectors_plan:
  T /\ T /\ T
Proof
  rpt CONJ_TAC
  >>> NTH_GOAL (ACCEPT_TAC TRUTH) 2
  >>> LASTGOAL (ACCEPT_TAC TRUTH)
  >>> HEADGOAL (ACCEPT_TAC TRUTH)
QED
SML
check_plan selectors_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:selectors_plan source=src/AScript.sml (4 steps)
  00 step rpt CONJ_TAC
  01 list-step NTH_GOAL (ACCEPT_TAC TRUTH) 2
  02 list-step LASTGOAL (ACCEPT_TAC TRUTH)
  03 list-step HEADGOAL (ACCEPT_TAC TRUTH)
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem split_first_lt_plan:
  T /\ T
Proof
  CONJ_TAC
  >>> SPLIT_LT 1 (TACS_TO_LT [ACCEPT_TAC TRUTH], FIRST_LT ACCEPT_TAC TRUTH)
QED
SML
check_plan split_first_lt_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:split_first_lt_plan source=src/AScript.sml (2 steps)
  00 step CONJ_TAC
  01 list-step SPLIT_LT 1 (TACS_TO_LT [ACCEPT_TAC TRUTH], FIRST_LT ACCEPT_TAC TRUTH)
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem try_plan:
  T
Proof
  TRY NO_TAC >> ACCEPT_TAC TRUTH
QED
SML
check_plan try_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:try_plan source=src/AScript.sml (4 steps)
  00 try
  01   step NO_TAC
  02 end
  03 step ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem repeat_plan:
  T
Proof
  REPEAT NO_TAC >> ACCEPT_TAC TRUTH
QED
SML
check_plan repeat_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:repeat_plan source=src/AScript.sml (2 steps)
  00 step REPEAT NO_TAC
  01 step ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem reverse_plan:
  T /\ T
Proof
  REVERSE CONJ_TAC >- ACCEPT_TAC TRUTH >- ACCEPT_TAC TRUTH
QED
SML
check_plan reverse_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:reverse_plan source=src/AScript.sml (7 steps)
  00 step REVERSE CONJ_TAC
  01 select first solve
  02   step ACCEPT_TAC TRUTH
  03 end
  04 select first solve
  05   step ACCEPT_TAC TRUTH
  06 end
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem reverse_suffix_branch_plan:
  T /\ T /\ T
Proof
  CONJ_TAC
  >> reverse CONJ_TAC >- (ACCEPT_TAC TRUTH)
  >> simp[GSYM CONJ_ASSOC]
  >> reverse CONJ_TAC >- (ACCEPT_TAC TRUTH)
  >> ACCEPT_TAC TRUTH
QED
SML
check_plan reverse_suffix_branch_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:reverse_suffix_branch_plan source=src/AScript.sml (11 steps)
  00 step CONJ_TAC
  01 step reverse CONJ_TAC
  02 select first solve
  03   step ACCEPT_TAC TRUTH
  04 end
  05 step simp[GSYM CONJ_ASSOC]
  06 step reverse CONJ_TAC
  07 select first solve
  08   step ACCEPT_TAC TRUTH
  09 end
  10 step ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem branch_sequence_plan:
  T /\ T
Proof
  CONJ_TAC >- (ALL_TAC >> ACCEPT_TAC TRUTH) >- ACCEPT_TAC TRUTH
QED
SML
check_plan branch_sequence_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:branch_sequence_plan source=src/AScript.sml (8 steps)
  00 step CONJ_TAC
  01 select first solve
  02   step ALL_TAC
  03   step ACCEPT_TAC TRUTH
  04 end
  05 select first solve
  06   step ACCEPT_TAC TRUTH
  07 end
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem branch_then1_lhs_sequence_plan:
  ((T \/ T) ==> T) /\ T
Proof
  CONJ_TAC
  >- (ALL_TAC >> strip_tac >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
  >- ACCEPT_TAC TRUTH
QED
SML
check_plan branch_then1_lhs_sequence_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:branch_then1_lhs_sequence_plan source=src/AScript.sml (12 steps)
  00 step CONJ_TAC
  01 select first solve
  02   step ALL_TAC
  03   step strip_tac
  04   select first solve
  05     step ACCEPT_TAC TRUTH
  06   end
  07   step ACCEPT_TAC TRUTH
  08 end
  09 select first solve
  10   step ACCEPT_TAC TRUTH
  11 end
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem branch_suffix_reverse_plan:
  ((T /\ T) /\ (T /\ T)) /\ T
Proof
  CONJ_TAC
  >- (CONJ_TAC >> reverse CONJ_TAC >> simp[])
  >- ACCEPT_TAC TRUTH
QED
SML
check_plan branch_suffix_reverse_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:branch_suffix_reverse_plan source=src/AScript.sml (9 steps)
  00 step CONJ_TAC
  01 select first solve
  02   step CONJ_TAC
  03   step reverse CONJ_TAC
  04   step simp[]
  05 end
  06 select first solve
  07   step ACCEPT_TAC TRUTH
  08 end
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem sibling_then1_chain_plan:
  T /\ T /\ T /\ T
Proof
  rpt CONJ_TAC
  >- ACCEPT_TAC TRUTH
  >- ACCEPT_TAC TRUTH
  >- ACCEPT_TAC TRUTH
  >- ACCEPT_TAC TRUTH
QED
SML
check_plan sibling_then1_chain_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:sibling_then1_chain_plan source=src/AScript.sml (13 steps)
  00 step rpt CONJ_TAC
  01 select first solve
  02   step ACCEPT_TAC TRUTH
  03 end
  04 select first solve
  05   step ACCEPT_TAC TRUTH
  06 end
  07 select first solve
  08   step ACCEPT_TAC TRUTH
  09 end
  10 select first solve
  11   step ACCEPT_TAC TRUTH
  12 end
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem sibling_then1_branch_sequence_plan:
  T /\ T /\ T
Proof
  rpt CONJ_TAC
  >- (ALL_TAC >> ACCEPT_TAC TRUTH)
  >- ACCEPT_TAC TRUTH
  >- ACCEPT_TAC TRUTH
QED
SML
check_plan sibling_then1_branch_sequence_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:sibling_then1_branch_sequence_plan source=src/AScript.sml (11 steps)
  00 step rpt CONJ_TAC
  01 select first solve
  02   step ALL_TAC
  03   step ACCEPT_TAC TRUTH
  04 end
  05 select first solve
  06   step ACCEPT_TAC TRUTH
  07 end
  08 select first solve
  09   step ACCEPT_TAC TRUTH
  10 end
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem suffix_by_plan:
  T
Proof
  ALL_TAC >> `T` by ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH
QED
SML
check_plan suffix_by_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:suffix_by_plan source=src/AScript.sml (8 steps)
  00 step ALL_TAC
  01 each
  02   step by-subgoal `T`
  03   select first solve
  04     step ACCEPT_TAC TRUTH
  05   end
  06 end
  07 step ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem nested_branch_by_plan:
  T /\ T
Proof
  CONJ_TAC
  >- (`T` by ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
  \\ `T` suffices_by simp[]
  \\ ACCEPT_TAC TRUTH
QED
SML
check_plan nested_branch_by_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:nested_branch_by_plan source=src/AScript.sml (15 steps)
  00 step CONJ_TAC
  01 select first solve
  02   step by-subgoal `T`
  03   select first solve
  04     step ACCEPT_TAC TRUTH
  05   end
  06   step ACCEPT_TAC TRUTH
  07 end
  08 each
  09   step qsuff_tac `T`
  10   select first solve
  11     step simp[]
  12   end
  13 end
  14 step ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem qed_closes_branch_plan:
  T /\ T
Proof
  CONJ_TAC
  >- ACCEPT_TAC TRUTH
  >> (
    ACCEPT_TAC TRUTH
QED
SML
check_plan qed_closes_branch_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:qed_closes_branch_plan source=src/AScript.sml (5 steps)
  00 step CONJ_TAC
  01 select first solve
  02   step ACCEPT_TAC TRUTH
  03 end
  04 step ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem try_repeat_reverse_lt_plan:
  T /\ T
Proof
  CONJ_TAC
  >>> REVERSE_LT
  >>> TRY_LT NO_LT
  >>> REPEAT_LT NO_LT
  >>> TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED
SML
check_plan try_repeat_reverse_lt_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:try_repeat_reverse_lt_plan source=src/AScript.sml (5 steps)
  00 step CONJ_TAC
  01 list-step REVERSE_LT
  02 list-step TRY_LT NO_LT
  03 list-step REPEAT_LT NO_LT
  04 list-step TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem null_ok_rotate_plan:
  T /\ (T ==> T)
Proof
  CONJ_TAC
  >>> NULL_OK_LT (ROTATE_LT 1)
  >>> TACS_TO_LT [DISCH_TAC >> ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED
SML
check_plan null_ok_rotate_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:null_ok_rotate_plan source=src/AScript.sml (3 steps)
  00 step CONJ_TAC
  01 list-step NULL_OK_LT (ROTATE_LT 1)
  02 list-step TACS_TO_LT [DISCH_TAC >> ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem null_ok_empty_plan:
  T
Proof
  ACCEPT_TAC TRUTH >>> NULL_OK_LT (TACS_TO_LT [])
QED
SML
check_plan null_ok_empty_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:null_ok_empty_plan source=src/AScript.sml (2 steps)
  00 step ACCEPT_TAC TRUTH
  01 list-step NULL_OK_LT (TACS_TO_LT [])
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem orelse_lt_plan:
  T /\ T
Proof
  CONJ_TAC >>> (NO_LT ORELSE_LT TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH])
QED
SML
check_plan orelse_lt_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:orelse_lt_plan source=src/AScript.sml (2 steps)
  00 step CONJ_TAC
  01 list-step NO_LT ORELSE_LT TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem every_first_plan:
  T
Proof
  EVERY [TRY NO_TAC, FIRST [NO_TAC, ACCEPT_TAC TRUTH]]
QED
SML
check_plan every_first_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:every_first_plan source=src/AScript.sml (11 steps)
  00 try
  01   step NO_TAC
  02 end
  03 each
  04   choice FIRST [NO_TAC, ACCEPT_TAC TRUTH]
  05     alternative 1
  06       step NO_TAC
  07     alternative 2
  08       step ACCEPT_TAC TRUTH
  09   end
  10 end
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem first_prove_plan:
  T
Proof
  FIRST_PROVE [NO_TAC, ACCEPT_TAC TRUTH]
QED
SML
check_plan first_prove_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:first_prove_plan source=src/AScript.sml (6 steps)
  00 choice FIRST_PROVE [NO_TAC, ACCEPT_TAC TRUTH]
  01   alternative 1
  02     step NO_TAC
  03   alternative 2
  04     step ACCEPT_TAC TRUTH
  05 end
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem validation_wrappers_plan:
  T
Proof
  VALID (VALIDATE (GEN_VALIDATE true (CONJ_VALIDATE (CHANGED_TAC (ACCEPT_TAC TRUTH)))))
QED
SML
check_plan validation_wrappers_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:validation_wrappers_plan source=src/AScript.sml (1 steps)
  00 step VALID (VALIDATE (GEN_VALIDATE true (CONJ_VALIDATE (CHANGED_TAC (ACCEPT_TAC TRUTH)))))
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem if_add_sgs_plan:
  T
Proof
  ADD_SGS_TAC [`T`] (IF NO_TAC (FAIL_TAC "bad") (ACCEPT_TAC TRUTH))
  >> ACCEPT_TAC TRUTH
QED
SML
check_plan if_add_sgs_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:if_add_sgs_plan source=src/AScript.sml (2 steps)
  00 step ADD_SGS_TAC [`T`] (IF NO_TAC (FAIL_TAC "bad") (ACCEPT_TAC TRUTH))
  01 step ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem every_lt_select_plan:
  T /\ T /\ T
Proof
  rpt CONJ_TAC
  >>> EVERY_LT [TRY_LT NO_LT, ROTATE_LT 1]
  >>> SELECT_LT_THEN (ACCEPT_TAC TRUTH) ALL_TAC
QED
SML
check_plan every_lt_select_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:every_lt_select_plan source=src/AScript.sml (4 steps)
  00 step rpt CONJ_TAC
  01 list-step TRY_LT NO_LT
  02 list-step ROTATE_LT 1
  03 list-step SELECT_LT_THEN (ACCEPT_TAC TRUTH) (ALL_TAC)
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem tryall_select_plan:
  T /\ T
Proof
  CONJ_TAC >>> TRYALL (ACCEPT_TAC TRUTH)
QED
SML
check_plan tryall_select_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:tryall_select_plan source=src/AScript.sml (2 steps)
  00 step CONJ_TAC
  01 list-step TRYALL (ACCEPT_TAC TRUTH)
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem list_validation_plan:
  T /\ T
Proof
  CONJ_TAC
  >>> VALID_LT (VALIDATE_LT (GEN_VALIDATE_LT true (TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH])))
QED
SML
check_plan list_validation_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:list_validation_plan source=src/AScript.sml (2 steps)
  00 step CONJ_TAC
  01 list-step VALID_LT (VALIDATE_LT (GEN_VALIDATE_LT true (TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH])))
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem select_lt_plan:
  T /\ T
Proof
  CONJ_TAC >>> SELECT_LT (ACCEPT_TAC TRUTH)
QED
SML
check_plan select_lt_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:select_lt_plan source=src/AScript.sml (2 steps)
  00 step CONJ_TAC
  01 list-step SELECT_LT (ACCEPT_TAC TRUTH)
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem orelse_plan:
  T
Proof
  NO_TAC ORELSE ACCEPT_TAC TRUTH
QED
SML
check_plan orelse_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:orelse_plan source=src/AScript.sml (6 steps)
  00 choice NO_TAC ORELSE ACCEPT_TAC TRUTH
  01   alternative 1
  02     step NO_TAC
  03   alternative 2
  04     step ACCEPT_TAC TRUTH
  05 end
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem suffices_plan:
  F ==> T
Proof
  strip_tac
  >> `F` suffices_by simp[]
  >> FIRST_ASSUM ACCEPT_TAC
QED
SML
check_plan suffices_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:suffices_plan source=src/AScript.sml (8 steps)
  00 step strip_tac
  01 each
  02   step qsuff_tac `F`
  03   select first solve
  04     step simp[]
  05   end
  06 end
  07 step FIRST_ASSUM ACCEPT_TAC
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem map_every_plan:
  T
Proof
  MAP_EVERY ACCEPT_TAC [TRUTH]
QED
SML
check_plan map_every_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:map_every_plan source=src/AScript.sml (1 steps)
  00 step ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem map_every_lowercase_plan:
  T
Proof
  map_every ACCEPT_TAC [TRUTH]
QED
SML
check_plan map_every_lowercase_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:map_every_lowercase_plan source=src/AScript.sml (1 steps)
  00 step ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem map_first_plan:
  T
Proof
  MAP_FIRST ACCEPT_TAC [TRUTH]
QED
SML
check_plan map_first_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:map_first_plan source=src/AScript.sml (4 steps)
  00 choice MAP_FIRST ACCEPT_TAC [TRUTH]
  01   alternative 1
  02     step ACCEPT_TAC TRUTH
  03 end
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem select_goals_plan:
  T /\ T
Proof
  CONJ_TAC >>~ [`T`]
  >> ACCEPT_TAC TRUTH
  >> ACCEPT_TAC TRUTH
QED
SML
check_plan select_goals_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:select_goals_plan source=src/AScript.sml (5 steps)
  00 step CONJ_TAC
  01 select matching-all [`T`] keep
  02 end
  03 step ACCEPT_TAC TRUTH
  04 step ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem select_single_plan:
  T /\ T
Proof
  CONJ_TAC >~ `T`
  >> ACCEPT_TAC TRUTH
  >> ACCEPT_TAC TRUTH
QED
SML
check_plan select_single_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:select_single_plan source=src/AScript.sml (5 steps)
  00 step CONJ_TAC
  01 select matching-first `T` keep
  02 end
  03 step ACCEPT_TAC TRUTH
  04 step ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem select_then1_plan:
  T /\ T
Proof
  CONJ_TAC >>~- ([`T`], ACCEPT_TAC TRUTH)
  >> ACCEPT_TAC TRUTH
QED
SML
check_plan select_then1_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:select_then1_plan source=src/AScript.sml (5 steps)
  00 step CONJ_TAC
  01 select matching-all [`T`] solve
  02   step ACCEPT_TAC TRUTH
  03 end
  04 step ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem grouped_prefix_plan:
  T
Proof
  rpt gen_tac >> strip_tac >> qpat_x_assum `step s = _` mp_tac >> simp[]
QED
SML
check_plan grouped_prefix_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:grouped_prefix_plan source=src/AScript.sml (4 steps)
  00 step rpt gen_tac
  01 step strip_tac
  02 step qpat_x_assum `step s = _` mp_tac
  03 step simp[]
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem first_try_repeat_plan:
  T
Proof
  FIRST [NO_TAC, TRY NO_TAC, REPEAT NO_TAC, ACCEPT_TAC TRUTH]
QED
SML
check_plan first_try_repeat_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:first_try_repeat_plan source=src/AScript.sml (12 steps)
  00 choice FIRST [NO_TAC, TRY NO_TAC, REPEAT NO_TAC, ACCEPT_TAC TRUTH]
  01   alternative 1
  02     step NO_TAC
  03   alternative 2
  04     try
  05       step NO_TAC
  06     end
  07   alternative 3
  08     step REPEAT NO_TAC
  09   alternative 4
  10     step ACCEPT_TAC TRUTH
  11 end
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem nth_goal_expr_plan:
  T /\ T /\ T
Proof
  rpt CONJ_TAC >>> NTH_GOAL (ACCEPT_TAC TRUTH) (1 + 1) >>> TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED
SML
check_plan nth_goal_expr_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:nth_goal_expr_plan source=src/AScript.sml (3 steps)
  00 step rpt CONJ_TAC
  01 list-step NTH_GOAL (ACCEPT_TAC TRUTH) (1 + 1)
  02 list-step TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem split_expr_plan:
  T /\ T
Proof
  CONJ_TAC >>> SPLIT_LT (1 + 0) (TACS_TO_LT [ACCEPT_TAC TRUTH], TACS_TO_LT [ACCEPT_TAC TRUTH])
QED
SML
check_plan split_expr_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:split_expr_plan source=src/AScript.sml (2 steps)
  00 step CONJ_TAC
  01 list-step SPLIT_LT (1 + 0) (TACS_TO_LT [ACCEPT_TAC TRUTH], TACS_TO_LT [ACCEPT_TAC TRUTH])
EXPECTED

cat "$SCRIPT_DIR/step_create_push_structure.sml" >> "$project/src/AScript.sml"
check_plan_file step_create_push_structure "$SCRIPT_DIR/step_create_push_structure.expected"

cat >> "$project/src/AScript.sml" <<'SML'
Theorem reverse_thenl_gap_plan:
  T
Proof
  CONJ_TAC
  \\ Tactical.REVERSE (TRY CONJ_TAC) THENL
     [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED
SML
check_plan reverse_thenl_gap_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:reverse_thenl_gap_plan source=src/AScript.sml (10 steps)
  00 step CONJ_TAC
  01 step Tactical.REVERSE (TRY CONJ_TAC)
  02 cases
  03   case 1
  04     step ACCEPT_TAC TRUTH
  05   case 2
  06     step ACCEPT_TAC TRUTH
  07   case 3
  08     step ACCEPT_TAC TRUTH
  09 end
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem map_aliases_gap_plan:
  T /\ T
Proof
  CONJ_TAC
  >- MAP_EVERY (fn th => ACCEPT_TAC th) [TRUTH]
  >> MAP_FIRST (fn th => ACCEPT_TAC th) [TRUTH]
QED
SML
check_plan map_aliases_gap_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:map_aliases_gap_plan source=src/AScript.sml (10 steps)
  00 step CONJ_TAC
  01 select first solve
  02   step (fn th => ACCEPT_TAC th) TRUTH
  03 end
  04 each
  05   choice MAP_FIRST (fn th => ACCEPT_TAC th) [TRUTH]
  06     alternative 1
  07       step (fn th => ACCEPT_TAC th) TRUTH
  08   end
  09 end
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem nested_combinators_gap_plan:
  T /\ T /\ T
Proof
  rpt strip_tac
  >> CONJ_TAC
  >- (TRY CONJ_TAC >> ACCEPT_TAC TRUTH)
  >> reverse CONJ_TAC
  >- (sg `T` >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
  >> ACCEPT_TAC TRUTH
QED
SML
check_plan nested_combinators_gap_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:nested_combinators_gap_plan source=src/AScript.sml (17 steps)
  00 step rpt strip_tac
  01 step CONJ_TAC
  02 select first solve
  03   try
  04     step CONJ_TAC
  05   end
  06   step ACCEPT_TAC TRUTH
  07 end
  08 step reverse CONJ_TAC
  09 select first solve
  10   step sg `T`
  11   select first solve
  12     step ACCEPT_TAC TRUTH
  13   end
  14   step ACCEPT_TAC TRUTH
  15 end
  16 step ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem no_lt_orelse_gap_plan:
  T
Proof
  ALL_TAC >>> (NO_LT ORELSE_LT TACS_TO_LT [ACCEPT_TAC TRUTH])
QED
SML
check_plan no_lt_orelse_gap_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:no_lt_orelse_gap_plan source=src/AScript.sml (2 steps)
  00 step ALL_TAC
  01 list-step NO_LT ORELSE_LT TACS_TO_LT [ACCEPT_TAC TRUTH]
EXPECTED
