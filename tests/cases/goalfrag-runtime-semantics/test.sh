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

make_project() {
  local project=$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<'TOML'
[project]
name = "goalfrag-runtime"

[build]
members = ["src"]
TOML
}

run_new_ir_smoke_project() {
  local project=$tmpdir/new-ir
  make_project "$project"
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem sequence_allgoals:
  T /\ T
Proof
  CONJ_TAC >> ACCEPT_TAC TRUTH
QED

Theorem branch_then1:
  T /\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >- ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML
  (cd "$project" && HOLBUILD_ECHO_CHILD_LOGS=1 "$HOLBUILD_BIN" --holdir "$HOLDIR" build --skip-checkpoints --tactic-timeout 60) > "$tmpdir/new-ir.out" 2>&1
  require_file "$project/.holbuild/obj/src/ATheory.dat"
}

run_goalfrag_success_project() {
  local project=$tmpdir/success
  make_project "$project"
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

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
  (cd "$project" && HOLBUILD_ECHO_CHILD_LOGS=1 "$HOLBUILD_BIN" --holdir "$HOLDIR" build --goalfrag --skip-checkpoints --tactic-timeout 60) > "$tmpdir/success.goalfrag.out" 2>&1
  require_file "$project/.holbuild/obj/src/ATheory.sig"
  require_file "$project/.holbuild/obj/src/ATheory.sml"
  require_file "$project/.holbuild/obj/src/ATheory.dat"
  require_file "$project/.holbuild/obj/src/ATheory.ui"
  require_file "$project/.holbuild/obj/src/ATheory.uo"
  (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" goalfrag-plan ATheory:chained_then1_plain) > "$tmpdir/chained_then1.plan.out" 2>&1
  require_grep 'plain rpt CONJ_TAC' "$tmpdir/chained_then1.plan.out"
  (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --force --skip-goalfrag --skip-checkpoints) > "$tmpdir/success.plain.out" 2>&1
}

expect_parse_recovery_fails() {
  local name=$1
  local mode=$2
  local project=$tmpdir/$name
  make_project "$project"
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem parser_recovery:
  T
Proof
  ( ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML
  case "$mode" in
    new-ir)
      if (cd "$project" && HOLBUILD_ECHO_CHILD_LOGS=1 "$HOLBUILD_BIN" --holdir "$HOLDIR" build --skip-checkpoints --tactic-timeout 60) > "$tmpdir/$name.out" 2>&1; then
        echo "expected parser recovery build to fail for $name" >&2
        exit 1
      fi
      ;;
    goalfrag)
      if (cd "$project" && HOLBUILD_ECHO_CHILD_LOGS=1 "$HOLBUILD_BIN" --holdir "$HOLDIR" build --goalfrag --skip-checkpoints --tactic-timeout 60) > "$tmpdir/$name.out" 2>&1; then
        echo "expected GoalFrag parser recovery build to fail for $name" >&2
        exit 1
      fi
      ;;
    *) echo "unknown parser recovery mode: $mode" >&2; exit 2 ;;
  esac
  require_grep "HOL source parser recovered while instrumenting theorem boundaries" "$tmpdir/$name.out"
  require_grep "parse error: expected closing parenthesis" "$tmpdir/$name.out"
  require_grep "source: .*AScript.sml:" "$tmpdir/$name.out"
  require_grep "hol run failed while building theory script" "$tmpdir/$name.out"
  if grep -q "ATheory built" "$tmpdir/$name.out"; then
    echo "malformed parser-recovery source was reported as built for $name" >&2
    exit 1
  fi
}

expect_both_fail() {
  local name=$1
  local proof=$2
  local project=$tmpdir/$name
  make_project "$project"
  cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

$proof

val _ = export_theory();
SML
  if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --goalfrag --skip-checkpoints --tactic-timeout 60) > "$tmpdir/$name.goalfrag.out" 2>&1; then
    echo "expected goalfrag build to fail for $name" >&2
    exit 1
  fi
  if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --force --skip-goalfrag --skip-checkpoints) > "$tmpdir/$name.plain.out" 2>&1; then
    echo "expected plain build to fail for $name" >&2
    exit 1
  fi
}

run_repeated_label_source_location_project() {
  local project=$tmpdir/repeated-label-source-location
  make_project "$project"
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem repeated_label:
  !x:bool. T
Proof
  strip_tac >> strip_tac
QED

val _ = export_theory();
SML
  if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --goalfrag --skip-checkpoints --tactic-timeout 60) > "$tmpdir/repeated-label.goalfrag.out" 2>&1; then
    echo "expected repeated-label GoalFrag build to fail" >&2
    exit 1
  fi
  require_grep "plan position: 01 tactic strip_tac" "$tmpdir/repeated-label.goalfrag.out"
  require_grep "source: .*AScript.sml:7:16-25" "$tmpdir/repeated-label.goalfrag.out"
  if grep -q "source: .*AScript.sml:7:3-12" "$tmpdir/repeated-label.goalfrag.out"; then
    echo "GoalFrag failure source used first matching label instead of failed step span" >&2
    exit 1
  fi

  rm -rf "$project/.holbuild"
  if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --skip-checkpoints --tactic-timeout 60) > "$tmpdir/repeated-label.new-ir.out" 2>&1; then
    echo "expected repeated-label new-IR build to fail" >&2
    exit 1
  fi
  require_grep "plan position: 01 list_tactic >> strip_tac" "$tmpdir/repeated-label.new-ir.out"
  require_grep "source: .*AScript.sml:7:16-25" "$tmpdir/repeated-label.new-ir.out"
  if grep -q "source: .*AScript.sml:7:3-12" "$tmpdir/repeated-label.new-ir.out"; then
    echo "new-IR failure source used first matching label instead of failed step span" >&2
    exit 1
  fi
}

run_new_ir_smoke_project
run_goalfrag_success_project
expect_parse_recovery_fails parser-recovery-new-ir new-ir
expect_parse_recovery_fails parser-recovery-goalfrag goalfrag
run_repeated_label_source_location_project

expect_both_fail first_empty_then 'Theorem first_empty_then:
  T
Proof
  FIRST [] >> ACCEPT_TAC TRUTH
QED'
require_grep 'FIRST \[\]' "$tmpdir/first_empty_then.goalfrag.out"
require_grep 'NO_TAC' "$tmpdir/first_empty_then.plain.out"

expect_both_fail map_first_empty_then 'Theorem map_first_empty_then:
  T
Proof
  MAP_FIRST (fn th => ACCEPT_TAC th) [] >> ACCEPT_TAC TRUTH
QED'
require_grep 'MAP_FIRST' "$tmpdir/map_first_empty_then.goalfrag.out"
require_grep 'NO_TAC' "$tmpdir/map_first_empty_then.plain.out"
