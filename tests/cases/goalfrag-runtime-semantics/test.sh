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
name = "removed-goalfrag-runtime"

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

log=$tmpdir/goalfrag.log
if (cd "$project" && "$HOLBUILD_BIN" build --goalfrag ATheory) > "$log" 2>&1; then
  echo "expected removed --goalfrag option to fail" >&2
  exit 1
fi
require_grep "goalfrag has been removed; proof steps are enabled by default" "$log"

make_project() {
  local p=$1
  local name=$2
  mkdir -p "$p/src"
  cat > "$p/holproject.toml" <<TOML
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
(cd "$runtime_project" && HOLBUILD_ECHO_CHILD_LOGS=1 "$HOLBUILD_BIN" build --skip-checkpoints --tactic-timeout 60) > "$tmpdir/runtime.out" 2>&1
require_file "$runtime_project/.holbuild/obj/src/ATheory.dat"
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
require_grep "plan position: 01 list_tactic >> strip_tac" "$tmpdir/repeated-label.out"
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
