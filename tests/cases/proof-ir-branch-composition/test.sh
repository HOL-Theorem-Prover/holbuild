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
name = "proof-ir-branch-composition"

[build]
members = ["src"]
TOML

cat > "$project/src/BranchScript.sml" <<'SML'
Theory Branch

Theorem branch_then_suffix_plan:
  T /\ T
Proof
  CONJ_TAC >- (ALL_TAC >> ACCEPT_TAC TRUTH) >>
  ACCEPT_TAC TRUTH
QED

Theorem nested_branch_rhs_plan:
  (T /\ T) /\ T
Proof
  CONJ_TAC >- (CONJ_TAC >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH) >>
  ACCEPT_TAC TRUTH
QED

Theorem suffix_compound_each_plan:
  (T /\ T) /\ (T /\ T)
Proof
  CONJ_TAC >>
  (CONJ_TAC >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
QED

Theorem issue60_parenthesized_rhs_plan:
  (T /\ T) /\ (T /\ T)
Proof
  CONJ_TAC >>
  (CONJ_TAC >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH)
QED

Theorem branch_suffix_compound_each_plan:
  ((T /\ T) /\ T) /\ T
Proof
  CONJ_TAC >-
    (ALL_TAC >>
     (CONJ_TAC >- (CONJ_TAC >- ACCEPT_TAC TRUTH >> ACCEPT_TAC TRUTH) >>
      ACCEPT_TAC TRUTH)) >>
  ACCEPT_TAC TRUTH
QED

Theorem sibling_branches_plan:
  T /\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >- ACCEPT_TAC TRUTH
QED

Theorem thenl_cases_plan:
  T /\ T
Proof
  CONJ_TAC >| [ACCEPT_TAC TRUTH, ACCEPT_TAC TRUTH]
QED

Theorem thenl_suffix_each_plan:
  (T /\ T) /\ (T /\ T)
Proof
  CONJ_TAC >>
  (CONJ_TAC >| [ALL_TAC, ALL_TAC])
QED

Theorem by_wildcard_eq_plan:
  T
Proof
  `T = T` by REFL_TAC >>
  `_ = T` by REFL_TAC >>
  ACCEPT_TAC TRUTH
QED

Theorem by_sugar_plan:
  T
Proof
  `T` by ACCEPT_TAC TRUTH
QED

Theorem suffices_by_sugar_plan:
  T
Proof
  `T` suffices_by ACCEPT_TAC TRUTH >>
  ACCEPT_TAC TRUTH
QED
SML

check_plan() {
  local theorem=$1
  local expected=$tmpdir/$theorem.expected
  local actual=$tmpdir/$theorem.actual
  cat > "$expected"
  (cd "$project" && "$HOLBUILD_BIN" execution-plan BranchTheory:"$theorem") > "$actual" 2>&1
  if ! diff -u "$expected" "$actual"; then
    echo "proof-ir branch-composition plan mismatch for $theorem" >&2
    exit 1
  fi
}

check_plan branch_then_suffix_plan <<'EXPECTED'
holbuild proof-ir plan BranchTheory:branch_then_suffix_plan source=src/BranchScript.sml (6 steps)
  00 step CONJ_TAC
  01 select first solve
  02   step ALL_TAC
  03   step ACCEPT_TAC TRUTH
  04 end
  05 step ACCEPT_TAC TRUTH
EXPECTED

check_plan nested_branch_rhs_plan <<'EXPECTED'
holbuild proof-ir plan BranchTheory:nested_branch_rhs_plan source=src/BranchScript.sml (9 steps)
  00 step CONJ_TAC
  01 select first solve
  02   step CONJ_TAC
  03   select first solve
  04     step ACCEPT_TAC TRUTH
  05   end
  06   step ACCEPT_TAC TRUTH
  07 end
  08 step ACCEPT_TAC TRUTH
EXPECTED

check_plan suffix_compound_each_plan <<'EXPECTED'
holbuild proof-ir plan BranchTheory:suffix_compound_each_plan source=src/BranchScript.sml (8 steps)
  00 step CONJ_TAC
  01 each
  02   step CONJ_TAC
  03   select first solve
  04     step ACCEPT_TAC TRUTH
  05   end
  06   step ACCEPT_TAC TRUTH
  07 end
EXPECTED

check_plan issue60_parenthesized_rhs_plan <<'EXPECTED'
holbuild proof-ir plan BranchTheory:issue60_parenthesized_rhs_plan source=src/BranchScript.sml (8 steps)
  00 step CONJ_TAC
  01 each
  02   step CONJ_TAC
  03   select first solve
  04     step ACCEPT_TAC TRUTH
  05   end
  06   step ACCEPT_TAC TRUTH
  07 end
EXPECTED

check_plan branch_suffix_compound_each_plan <<'EXPECTED'
holbuild proof-ir plan BranchTheory:branch_suffix_compound_each_plan source=src/BranchScript.sml (16 steps)
  00 step CONJ_TAC
  01 select first solve
  02   step ALL_TAC
  03   each
  04     step CONJ_TAC
  05     select first solve
  06       step CONJ_TAC
  07       select first solve
  08         step ACCEPT_TAC TRUTH
  09       end
  10       step ACCEPT_TAC TRUTH
  11     end
  12     step ACCEPT_TAC TRUTH
  13   end
  14 end
  15 step ACCEPT_TAC TRUTH
EXPECTED

check_plan sibling_branches_plan <<'EXPECTED'
holbuild proof-ir plan BranchTheory:sibling_branches_plan source=src/BranchScript.sml (7 steps)
  00 step CONJ_TAC
  01 select first solve
  02   step ACCEPT_TAC TRUTH
  03 end
  04 select first solve
  05   step ACCEPT_TAC TRUTH
  06 end
EXPECTED

check_plan thenl_cases_plan <<'EXPECTED'
holbuild proof-ir plan BranchTheory:thenl_cases_plan source=src/BranchScript.sml (7 steps)
  00 step CONJ_TAC
  01 cases
  02   case 1
  03     step ACCEPT_TAC TRUTH
  04   case 2
  05     step ACCEPT_TAC TRUTH
  06 end
EXPECTED

check_plan thenl_suffix_each_plan <<'EXPECTED'
holbuild proof-ir plan BranchTheory:thenl_suffix_each_plan source=src/BranchScript.sml (10 steps)
  00 step CONJ_TAC
  01 each
  02   step CONJ_TAC
  03   cases
  04     case 1
  05       step ALL_TAC
  06     case 2
  07       step ALL_TAC
  08   end
  09 end
EXPECTED

check_plan by_wildcard_eq_plan <<'EXPECTED'
holbuild proof-ir plan BranchTheory:by_wildcard_eq_plan source=src/BranchScript.sml (11 steps)
  00 step by-subgoal `T = T`
  01 select first solve
  02   step REFL_TAC
  03 end
  04 each
  05   step by-subgoal `_ = T`
  06   select first solve
  07     step REFL_TAC
  08   end
  09 end
  10 step ACCEPT_TAC TRUTH
EXPECTED

check_plan by_sugar_plan <<'EXPECTED'
holbuild proof-ir plan BranchTheory:by_sugar_plan source=src/BranchScript.sml (4 steps)
  00 step by-subgoal `T`
  01 select first solve
  02   step ACCEPT_TAC TRUTH
  03 end
EXPECTED

check_plan suffices_by_sugar_plan <<'EXPECTED'
holbuild proof-ir plan BranchTheory:suffices_by_sugar_plan source=src/BranchScript.sml (5 steps)
  00 step qsuff_tac `T`
  01 select first solve
  02   step ACCEPT_TAC TRUTH
  03 end
  04 step ACCEPT_TAC TRUTH
EXPECTED
