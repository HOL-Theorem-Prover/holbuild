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

# The same branch-composition shapes should execute successfully both through
# proof steps and through ordinary HOL execution with proof steps skipped.
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

# Branch failure cases should fail at the branch-local step/close, not leak the
# selected branch state into the following suffix.
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

# Timeout attribution should point at the branch-local slow tactic.
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

# Failed-prefix replay should resume cleanly after a branch has closed.  The
# edited suffix must not re-enter a stale branch/focus state.
replay_project=$tmpdir/replay-project
write_project_toml "$replay_project" "proof-ir-branch-composition-replay"
cat > "$replay_project/src/ReplayScript.sml" <<'SML'
Theory Replay

Theorem before:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem target:
  T /\ T
Proof
  CONJ_TAC >- (ALL_TAC >> ACCEPT_TAC TRUTH) >>
  FAIL_TAC "edit me"
QED

Theorem after:
  T
Proof
  ACCEPT_TAC TRUTH
QED
SML

replay_first_log=$tmpdir/replay-first.log
if (cd "$replay_project" && "$HOLBUILD_BIN" build ReplayTheory) > "$replay_first_log" 2>&1; then
  echo "expected first replay seed build to fail" >&2
  exit 1
fi
require_grep 'FAIL_TAC "edit me"' "$replay_first_log"
require_grep "plan position: 05 step FAIL_TAC" "$replay_first_log"
require_file "$(find "$replay_project/.holbuild/checkpoints" -name '*target_failed_prefix.save' -print -quit)"

python3 - <<PY
from pathlib import Path
path = Path("$replay_project/src/ReplayScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "edit me"', 'ACCEPT_TAC TRUTH'))
PY
replay_fixed_log=$tmpdir/replay-fixed.log
(cd "$replay_project" && "$HOLBUILD_BIN" build ReplayTheory) > "$replay_fixed_log" 2>&1
require_grep "from: failed-prefix checkpoint in target" "$replay_fixed_log"
require_grep "ReplayTheory built" "$replay_fixed_log"
require_file "$replay_project/.holbuild/obj/src/ReplayTheory.dat"
if grep -q "branch suffix without active branch\|selected goals were not solved\|stale branch" "$replay_fixed_log"; then
  echo "failed-prefix replay resumed with stale branch/focus state" >&2
  exit 1
fi

# Prefix edits should rewind across branch-structure boundaries rather than
# trusting the old failed-prefix depth blindly.
rewind_project=$tmpdir/rewind-project
write_project_toml "$rewind_project" "proof-ir-branch-composition-rewind"
cat > "$rewind_project/src/RewindScript.sml" <<'SML'
Theory Rewind

Theorem target:
  T /\ T
Proof
  CONJ_TAC >- (ALL_TAC >> ACCEPT_TAC TRUTH) >>
  FAIL_TAC "suffix"
QED
SML

rewind_first_log=$tmpdir/rewind-first.log
if (cd "$rewind_project" && "$HOLBUILD_BIN" build RewindTheory) > "$rewind_first_log" 2>&1; then
  echo "expected first rewind seed build to fail" >&2
  exit 1
fi
require_grep 'FAIL_TAC "suffix"' "$rewind_first_log"
require_file "$(find "$rewind_project/.holbuild/checkpoints" -name '*target_failed_prefix.save' -print -quit)"

python3 - <<PY
from pathlib import Path
path = Path("$rewind_project/src/RewindScript.sml")
path.write_text(path.read_text().replace('CONJ_TAC >- (ALL_TAC >> ACCEPT_TAC TRUTH) >>\n  FAIL_TAC "suffix"',
                                  'CONJ_TAC >- ACCEPT_TAC TRUTH >>\n  FAIL_TAC "suffix after prefix edit"'))
PY
rewind_second_log=$tmpdir/rewind-second.log
if (cd "$rewind_project" && "$HOLBUILD_BIN" build RewindTheory) > "$rewind_second_log" 2>&1; then
  echo "expected edited-prefix rewind proof still to fail at suffix" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in target" "$rewind_second_log"
require_grep 'FAIL_TAC "suffix after prefix edit"' "$rewind_second_log"
if grep -q "branch suffix without active branch\|selected goals were not solved\|stale branch" "$rewind_second_log"; then
  echo "failed-prefix replay after prefix edit resumed from inconsistent branch/focus state" >&2
  exit 1
fi
