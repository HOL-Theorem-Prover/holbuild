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

cat >> "$project/src/AScript.sml" <<'SML'
Theorem thenl_literal_plan:
  T /\ T
Proof
  CONJ_TAC THENL [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED
SML
check_plan thenl_literal_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:thenl_literal_plan source=src/AScript.sml (2 steps)
  00 CONJ_TAC
  01 >| [...]
EXPECTED

deprecated_plan_alias_log=$tmpdir/deprecated-plan-alias.log
(cd "$project" && "$HOLBUILD_BIN" goalfrag-plan --new-ir ATheory:thenl_literal_plan) > "$deprecated_plan_alias_log" 2>&1
require_grep "goalfrag-plan --new-ir is deprecated; use holbuild execution-plan THEORY:THEOREM" "$deprecated_plan_alias_log"
require_grep "holbuild proof-ir plan ATheory:thenl_literal_plan source=src/AScript.sml" "$deprecated_plan_alias_log"

cat >> "$project/src/AScript.sml" <<'SML'
Theorem allgoals_plan:
  T /\ T
Proof
  CONJ_TAC >>> ALLGOALS (ACCEPT_TAC TRUTH)
QED
SML
check_plan allgoals_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:allgoals_plan source=src/AScript.sml (2 steps)
  00 CONJ_TAC
  01 >> list_tac ALLGOALS (ACCEPT_TAC TRUTH)
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
  00 CONJ_TAC
  01 >> list_tac TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
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
  00 rpt CONJ_TAC
  01 >> list_tac NTH_GOAL (ACCEPT_TAC TRUTH) 2
  02 >> list_tac LASTGOAL (ACCEPT_TAC TRUTH)
  03 >> list_tac HEADGOAL (ACCEPT_TAC TRUTH)
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
  00 CONJ_TAC
  01 >> list_tac SPLIT_LT 1 (TACS_TO_LT [ACCEPT_TAC TRUTH], FIRST_LT ACCEPT_TAC TRUTH)
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem try_plan:
  T
Proof
  TRY NO_TAC >> ACCEPT_TAC TRUTH
QED
SML
check_plan try_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:try_plan source=src/AScript.sml (5 steps)
  00 TRY
  01   NO_TAC
  02   |
  03   ALL_TAC
  04 >> ACCEPT_TAC TRUTH
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
  00 REPEAT NO_TAC
  01 >> ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem reverse_plan:
  T /\ T
Proof
  REVERSE CONJ_TAC >- ACCEPT_TAC TRUTH >- ACCEPT_TAC TRUTH
QED
SML
check_plan reverse_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:reverse_plan source=src/AScript.sml (4 steps)
  00 CONJ_TAC
  01 >> list_tac REVERSE_LT
  02 >- ACCEPT_TAC TRUTH
  03 >- ACCEPT_TAC TRUTH
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
holbuild proof-ir plan ATheory:reverse_suffix_branch_plan source=src/AScript.sml (9 steps)
  00 CONJ_TAC
  01 >> CONJ_TAC
  02 >> list_tac REVERSE_LT
  03 >- ACCEPT_TAC TRUTH
  04 >> simp[GSYM CONJ_ASSOC]
  05 >> CONJ_TAC
  06 >> list_tac REVERSE_LT
  07 >- ACCEPT_TAC TRUTH
  08 >> ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem branch_sequence_plan:
  T /\ T
Proof
  CONJ_TAC >- (ALL_TAC >> ACCEPT_TAC TRUTH) >- ACCEPT_TAC TRUTH
QED
SML
check_plan branch_sequence_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:branch_sequence_plan source=src/AScript.sml (5 steps)
  00 CONJ_TAC
  01 >- ALL_TAC
  02    >> ACCEPT_TAC TRUTH
  03    >- solved
  04 >- ACCEPT_TAC TRUTH
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
holbuild proof-ir plan ATheory:branch_then1_lhs_sequence_plan source=src/AScript.sml (7 steps)
  00 CONJ_TAC
  01 >- ALL_TAC
  02    >> strip_tac
  03 >- ACCEPT_TAC TRUTH
  04    >> ACCEPT_TAC TRUTH
  05    >- solved
  06 >- ACCEPT_TAC TRUTH
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
holbuild proof-ir plan ATheory:branch_suffix_reverse_plan source=src/AScript.sml (7 steps)
  00 CONJ_TAC
  01 >- CONJ_TAC
  02    >> CONJ_TAC
  03    >> list_tac REVERSE_LT
  04    >> simp[]
  05    >- solved
  06 >- ACCEPT_TAC TRUTH
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
holbuild proof-ir plan ATheory:sibling_then1_chain_plan source=src/AScript.sml (5 steps)
  00 rpt CONJ_TAC
  01 >- ACCEPT_TAC TRUTH
  02 >- ACCEPT_TAC TRUTH
  03 >- ACCEPT_TAC TRUTH
  04 >- ACCEPT_TAC TRUTH
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
holbuild proof-ir plan ATheory:sibling_then1_branch_sequence_plan source=src/AScript.sml (6 steps)
  00 rpt CONJ_TAC
  01 >- ALL_TAC
  02    >> ACCEPT_TAC TRUTH
  03    >- solved
  04 >- ACCEPT_TAC TRUTH
  05 >- ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem suffix_by_plan:
  T
Proof
  ALL_TAC >> `T` by ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH
QED
SML
check_plan suffix_by_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:suffix_by_plan source=src/AScript.sml (4 steps)
  00 ALL_TAC
  01 >> `T`
  02   >- ACCEPT_TAC TRUTH
  03 >> ACCEPT_TAC TRUTH
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
holbuild proof-ir plan ATheory:nested_branch_by_plan source=src/AScript.sml (8 steps)
  00 CONJ_TAC
  01 >- `T`
  02 >- ACCEPT_TAC TRUTH
  03    >> ACCEPT_TAC TRUTH
  04    >- solved
  05 >> Q_TAC SUFF_TAC `T`
  06   >- simp[]
  07 >> ACCEPT_TAC TRUTH
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
holbuild proof-ir plan ATheory:qed_closes_branch_plan source=src/AScript.sml (3 steps)
  00 CONJ_TAC
  01 >- ACCEPT_TAC TRUTH
  02 >> ACCEPT_TAC TRUTH
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
  00 CONJ_TAC
  01 >> list_tac REVERSE_LT
  02 >> list_tac TRY_LT NO_LT
  03 >> list_tac REPEAT_LT NO_LT
  04 >> list_tac TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
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
  00 CONJ_TAC
  01 >> list_tac NULL_OK_LT (ROTATE_LT 1)
  02 >> list_tac TACS_TO_LT [DISCH_TAC >> ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
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
  00 ACCEPT_TAC TRUTH
  01 >> list_tac NULL_OK_LT (TACS_TO_LT [])
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem orelse_lt_plan:
  T /\ T
Proof
  CONJ_TAC >>> (NO_LT ORELSE_LT TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH])
QED
SML
check_plan orelse_lt_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:orelse_lt_plan source=src/AScript.sml (5 steps)
  00 CONJ_TAC
  01 >> list_tac ORELSE_LT
  02   NO_LT
  03   |
  04   TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem every_first_plan:
  T
Proof
  EVERY [TRY NO_TAC, FIRST [NO_TAC, ACCEPT_TAC TRUTH]]
QED
SML
check_plan every_first_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:every_first_plan source=src/AScript.sml (8 steps)
  00 TRY
  01   NO_TAC
  02   |
  03   ALL_TAC
  04 >> FIRST
  05   NO_TAC
  06   |
  07   ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem first_prove_plan:
  T
Proof
  FIRST_PROVE [NO_TAC, ACCEPT_TAC TRUTH]
QED
SML
check_plan first_prove_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:first_prove_plan source=src/AScript.sml (4 steps)
  00 FIRST_PROVE
  01   NO_TAC
  02   |
  03   ACCEPT_TAC TRUTH
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
  00 VALID (VALIDATE (GEN_VALIDATE true (CONJ_VALIDATE (CHANGED_TAC (ACCEPT_TAC TRUTH)))))
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
  00 ADD_SGS_TAC [`T`] (IF NO_TAC (FAIL_TAC "bad") (ACCEPT_TAC TRUTH))
  01 >> ACCEPT_TAC TRUTH
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
  00 rpt CONJ_TAC
  01 >> list_tac TRY_LT NO_LT
  02 >> list_tac ROTATE_LT 1
  03 >> list_tac SELECT_LT_THEN (ACCEPT_TAC TRUTH) (ALL_TAC)
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
  00 CONJ_TAC
  01 >> list_tac TRYALL (ACCEPT_TAC TRUTH)
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
  00 CONJ_TAC
  01 >> list_tac VALID_LT (VALIDATE_LT (GEN_VALIDATE_LT true (TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH])))
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
  00 CONJ_TAC
  01 >> list_tac SELECT_LT (ACCEPT_TAC TRUTH)
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem orelse_plan:
  T
Proof
  NO_TAC ORELSE ACCEPT_TAC TRUTH
QED
SML
check_plan orelse_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:orelse_plan source=src/AScript.sml (4 steps)
  00 ORELSE
  01   NO_TAC
  02   |
  03   ACCEPT_TAC TRUTH
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
holbuild proof-ir plan ATheory:suffices_plan source=src/AScript.sml (4 steps)
  00 strip_tac
  01 >> Q_TAC SUFF_TAC `F`
  02   >- simp[]
  03 >> FIRST_ASSUM ACCEPT_TAC
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
  00 ACCEPT_TAC TRUTH
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
  00 ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem map_first_plan:
  T
Proof
  MAP_FIRST ACCEPT_TAC [TRUTH]
QED
SML
check_plan map_first_plan <<'EXPECTED'
holbuild proof-ir plan ATheory:map_first_plan source=src/AScript.sml (2 steps)
  00 FIRST
  01   ACCEPT_TAC TRUTH
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
holbuild proof-ir plan ATheory:select_goals_plan source=src/AScript.sml (4 steps)
  00 CONJ_TAC
  01 >> list_tac Q.SELECT_GOALS_LT [`T`]
  02 >> ACCEPT_TAC TRUTH
  03 >> ACCEPT_TAC TRUTH
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
holbuild proof-ir plan ATheory:select_single_plan source=src/AScript.sml (4 steps)
  00 CONJ_TAC
  01 >> list_tac Q.SELECT_GOAL_LT `T`
  02 >> ACCEPT_TAC TRUTH
  03 >> ACCEPT_TAC TRUTH
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
holbuild proof-ir plan ATheory:select_then1_plan source=src/AScript.sml (3 steps)
  00 CONJ_TAC
  01 >> list_tac Q.SELECT_GOALS_LT_THEN1 [`T`] (ACCEPT_TAC TRUTH)
  02 >> ACCEPT_TAC TRUTH
EXPECTED
