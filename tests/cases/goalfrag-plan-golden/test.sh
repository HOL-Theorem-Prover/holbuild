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
name = "golden"

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
  (cd "$project" && "$HOLBUILD_BIN" goalfrag-plan "ATheory:$theorem") > "$actual"
  diff -u "$expected" "$actual"
}

check_plan_file() {
  local theorem=$1
  local expected=$2
  local actual=$tmpdir/$theorem.actual
  (cd "$project" && "$HOLBUILD_BIN" goalfrag-plan "ATheory:$theorem") > "$actual"
  diff -u "$expected" "$actual"
}

cat >> "$project/src/AScript.sml" <<'SML'
Theorem grouped_prefix:
  T
Proof
  rpt gen_tac >> strip_tac >> qpat_x_assum `step s = _` mp_tac >> simp[]
QED
SML
check_plan grouped_prefix <<'EXPECTED'
holbuild goalfrag plan ATheory:grouped_prefix source=src/AScript.sml (4 steps)
  00 rpt gen_tac
  01 >> strip_tac
  02 >> qpat_x_assum `step s = _` mp_tac
  03 >> simp[]
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
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
SML
check_plan reverse_branch <<'EXPECTED'
holbuild goalfrag plan ATheory:reverse_branch source=src/AScript.sml (12 steps)
  00 simp[step_create_def]
  01 >> strip_tac
  02 >> rewrite_tac[Ntimes CONJ_ASSOC 3]
  03 >> conj_tac
  04 >> list_tac Tactical.REVERSE_LT
  05   >- {
  06     qpat_x_assum `proceed_create _ _ _ _ _ se = _` mp_tac
  07     >> rewrite_tac[proceed_create_def]
  08     >> strip_tac
  09     >> gvs[]
  10   }
  11 >> strip_tac
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
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
check_plan reverse_branch_suffix <<'EXPECTED'
holbuild goalfrag plan ATheory:reverse_branch_suffix source=src/AScript.sml (9 steps)
  00 CONJ_TAC
  01 >> CONJ_TAC
  02 >> list_tac Tactical.REVERSE_LT
  03   >- ACCEPT_TAC TRUTH
  04 >> simp[GSYM CONJ_ASSOC]
  05 >> CONJ_TAC
  06 >> list_tac Tactical.REVERSE_LT
  07   >- ACCEPT_TAC TRUTH
  08 >> ACCEPT_TAC TRUTH
EXPECTED

cat "$SCRIPT_DIR/step_create_push_structure.sml" >> "$project/src/AScript.sml"
check_plan_file step_create_push_structure "$SCRIPT_DIR/step_create_push_structure.expected"

cat >> "$project/src/AScript.sml" <<'SML'
Theorem reverse_thenl:
  T
Proof
  CONJ_TAC
  \\ Tactical.REVERSE (TRY CONJ_TAC) THENL
     [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED
SML
check_plan reverse_thenl <<'EXPECTED'
holbuild goalfrag plan ATheory:reverse_thenl source=src/AScript.sml (1 steps)
  00 CONJ_TAC
       \\ Tactical.REVERSE (TRY CONJ_TAC) THENL
          [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem branch_list:
  T /\ T
Proof
  CONJ_TAC >| [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED
SML
check_plan branch_list <<'EXPECTED'
holbuild goalfrag plan ATheory:branch_list source=src/AScript.sml (2 steps)
  00 CONJ_TAC
  01 >> list_tac Tactical.NULL_OK_LT (Tactical.TACS_TO_LT ([ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]))
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem first_try_repeat:
  T
Proof
  FIRST [NO_TAC, TRY NO_TAC, REPEAT NO_TAC, ACCEPT_TAC TRUTH]
QED
SML
check_plan first_try_repeat <<'EXPECTED'
holbuild goalfrag plan ATheory:first_try_repeat source=src/AScript.sml (8 steps)
  00 FIRST
  01   NO_TAC
  02   |
  03   TRY NO_TAC
  04   |
  05   REPEAT NO_TAC
  06   |
  07   ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem goal_selector_numbers:
  T /\ T /\ T
Proof
  rpt CONJ_TAC
  >>> NTH_GOAL (ACCEPT_TAC TRUTH) 2
  >>> SPLIT_LT 1 (ALL_LT, FIRST_LT ACCEPT_TAC TRUTH)
QED
SML
check_plan goal_selector_numbers <<'EXPECTED'
holbuild goalfrag plan ATheory:goal_selector_numbers source=src/AScript.sml (3 steps)
  00 rpt CONJ_TAC
  01 >> list_tac NTH_GOAL (ACCEPT_TAC TRUTH) 2
  02 >> list_tac SPLIT_LT 1 (ALL_LT, FIRST_LT ACCEPT_TAC TRUTH)
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem map_aliases:
  T /\ T
Proof
  CONJ_TAC
  >- MAP_EVERY (fn th => ACCEPT_TAC th) [TRUTH]
  >> MAP_FIRST (fn th => ACCEPT_TAC th) [TRUTH]
QED
SML
check_plan map_aliases <<'EXPECTED'
holbuild goalfrag plan ATheory:map_aliases source=src/AScript.sml (3 steps)
  00 CONJ_TAC
  01   >- MAP_EVERY (fn th => ACCEPT_TAC th) [TRUTH]
  02 >> MAP_FIRST (fn th => ACCEPT_TAC th) [TRUTH]
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem branch_and_by:
  T /\ T
Proof
  CONJ_TAC
  >- (`T` by ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
  \\ `T` suffices_by simp[]
  \\ ACCEPT_TAC TRUTH
QED
SML
check_plan branch_and_by <<'EXPECTED'
holbuild goalfrag plan ATheory:branch_and_by source=src/AScript.sml (8 steps)
  00 CONJ_TAC
  01   >- {
  02     sg `T`
  03       >- ACCEPT_TAC TRUTH
  04     >> ACCEPT_TAC TRUTH
  05   }
  06 >> `T` suffices_by simp[]
  07 >> ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
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
SML
check_plan nested_combinators <<'EXPECTED'
holbuild goalfrag plan ATheory:nested_combinators source=src/AScript.sml (14 steps)
  00 rpt strip_tac
  01 >> CONJ_TAC
  02   >- {
  03     TRY CONJ_TAC
  04     >> ACCEPT_TAC TRUTH
  05   }
  06 >> CONJ_TAC
  07 >> list_tac Tactical.REVERSE_LT
  08   >- {
  09     sg `T`
  10       >- ACCEPT_TAC TRUTH
  11     >> ACCEPT_TAC TRUTH
  12   }
  13 >> ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem select_goals:
  T /\ T
Proof
  CONJ_TAC >>~ [`T`]
  \\ ACCEPT_TAC TRUTH
  \\ ACCEPT_TAC TRUTH
QED
SML
check_plan select_goals <<'EXPECTED'
holbuild goalfrag plan ATheory:select_goals source=src/AScript.sml (4 steps)
  00 CONJ_TAC
  01 >> list_tac Q.SELECT_GOALS_LT [`T`]
  02 >> ACCEPT_TAC TRUTH
  03 >> ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem select_single:
  T /\ T
Proof
  CONJ_TAC >~ `T`
  \\ ACCEPT_TAC TRUTH
  \\ ACCEPT_TAC TRUTH
QED
SML
check_plan select_single <<'EXPECTED'
holbuild goalfrag plan ATheory:select_single source=src/AScript.sml (4 steps)
  00 CONJ_TAC
  01 >> list_tac Q.SELECT_GOAL_LT `T`
  02 >> ACCEPT_TAC TRUTH
  03 >> ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem select_then1:
  T /\ T
Proof
  CONJ_TAC >>~- ([`T`], ACCEPT_TAC TRUTH)
  \\ ACCEPT_TAC TRUTH
QED
SML
check_plan select_then1 <<'EXPECTED'
holbuild goalfrag plan ATheory:select_then1 source=src/AScript.sml (3 steps)
  00 CONJ_TAC
  01 >> list_tac Q.SELECT_GOALS_LT_THEN1 [`T`] (
       ACCEPT_TAC TRUTH
     )
  02 >> ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem try_no_tac:
  T
Proof
  TRY NO_TAC >> ACCEPT_TAC TRUTH
QED
SML
check_plan try_no_tac <<'EXPECTED'
holbuild goalfrag plan ATheory:try_no_tac source=src/AScript.sml (2 steps)
  00 TRY NO_TAC
  01 >> ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem direct_tacs_to_lt:
  T
Proof
  ALL_TAC >>> TACS_TO_LT [ACCEPT_TAC TRUTH]
QED
SML
check_plan direct_tacs_to_lt <<'EXPECTED'
holbuild goalfrag plan ATheory:direct_tacs_to_lt source=src/AScript.sml (2 steps)
  00 ALL_TAC
  01 >> list_tac Tactical.TACS_TO_LT ([ACCEPT_TAC TRUTH])
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem select_then1_nested_body:
  T /\ T
Proof
  CONJ_TAC >>~- ([`T`], sg `T` >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
QED
SML
check_plan select_then1_nested_body <<'EXPECTED'
holbuild goalfrag plan ATheory:select_then1_nested_body source=src/AScript.sml (2 steps)
  00 CONJ_TAC
  01 >> list_tac Q.SELECT_GOALS_LT_THEN1 [`T`] (
       sg `T` >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH
     )
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem first_empty_then:
  T
Proof
  FIRST [] >> ACCEPT_TAC TRUTH
QED
SML
check_plan first_empty_then <<'EXPECTED'
holbuild goalfrag plan ATheory:first_empty_then source=src/AScript.sml (2 steps)
  00 FIRST []
  01 >> ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem map_first_empty_then:
  T
Proof
  MAP_FIRST (fn th => ACCEPT_TAC th) [] >> ACCEPT_TAC TRUTH
QED
SML
check_plan map_first_empty_then <<'EXPECTED'
holbuild goalfrag plan ATheory:map_first_empty_then source=src/AScript.sml (2 steps)
  00 MAP_FIRST (fn th => ACCEPT_TAC th) []
  01 >> ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem no_lt_orelse:
  T
Proof
  ALL_TAC >>> (NO_LT ORELSE_LT TACS_TO_LT [ACCEPT_TAC TRUTH])
QED
SML
check_plan no_lt_orelse <<'EXPECTED'
holbuild goalfrag plan ATheory:no_lt_orelse source=src/AScript.sml (2 steps)
  00 ALL_TAC
  01 >> list_tac NO_LT ORELSE_LT TACS_TO_LT [ACCEPT_TAC TRUTH]
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem nth_goal_expr:
  T /\ T /\ T
Proof
  rpt CONJ_TAC >>> NTH_GOAL (ACCEPT_TAC TRUTH) (1 + 1) >>> TACS_TO_LT [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED
SML
check_plan nth_goal_expr <<'EXPECTED'
holbuild goalfrag plan ATheory:nth_goal_expr source=src/AScript.sml (3 steps)
  00 rpt CONJ_TAC
  01 >> list_tac NTH_GOAL (ACCEPT_TAC TRUTH) (1 + 1)
  02 >> list_tac Tactical.TACS_TO_LT ([ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH])
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem split_expr:
  T /\ T
Proof
  CONJ_TAC >>> SPLIT_LT (1 + 0) (TACS_TO_LT [ACCEPT_TAC TRUTH], TACS_TO_LT [ACCEPT_TAC TRUTH])
QED
SML
check_plan split_expr <<'EXPECTED'
holbuild goalfrag plan ATheory:split_expr source=src/AScript.sml (2 steps)
  00 CONJ_TAC
  01 >> list_tac SPLIT_LT (1 + 0) (TACS_TO_LT [ACCEPT_TAC TRUTH], TACS_TO_LT [ACCEPT_TAC TRUTH])
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem try_then1_group:
  (T /\ T) /\ T
Proof
  CONJ_TAC >> TRY (CONJ_TAC >- ACCEPT_TAC TRUTH) >> ACCEPT_TAC TRUTH
QED
SML
check_plan try_then1_group <<'EXPECTED'
holbuild goalfrag plan ATheory:try_then1_group source=src/AScript.sml (3 steps)
  00 CONJ_TAC
  01 >> TRY (CONJ_TAC >- ACCEPT_TAC TRUTH)
  02 >> ACCEPT_TAC TRUTH
EXPECTED

cat >> "$project/src/AScript.sml" <<'SML'
Theorem qed_closes_branch:
  T /\ T
Proof
  CONJ_TAC
  >- ACCEPT_TAC TRUTH
  >> (
    ACCEPT_TAC TRUTH
QED
SML
check_plan qed_closes_branch <<'EXPECTED'
holbuild goalfrag plan ATheory:qed_closes_branch source=src/AScript.sml (3 steps)
  00 CONJ_TAC
  01   >- ACCEPT_TAC TRUTH
  02 >> ACCEPT_TAC TRUTH
EXPECTED

