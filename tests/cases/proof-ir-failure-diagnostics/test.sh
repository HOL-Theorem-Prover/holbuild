#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

write_manifest() {
  local project=$1
  local name=$2
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "$name"

[build]
members = ["src"]
TOML
}

# A failed-prefix resume can fail while closing a structural selector, outside
# the leaf-tactic failure reporting path.  The original exception must be
# accompanied by the same theorem, plan-position, and goal-state diagnostics
# that a normal proof-IR failure receives.
selector_project=$tmpdir/selector-project
mkdir -p "$selector_project/src"
write_manifest "$selector_project" "failed-prefix-selector-diagnostics"
cat > "$selector_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem selected_goals_diagnostic:
  T
Proof
  ALL_TAC >- (ALL_TAC >> FAIL_TAC "seed selected-goals failure")
QED

val _ = export_theory();
SML

selector_seed_log=$tmpdir/selector-seed.log
if (cd "$selector_project" && "$HOLBUILD_BIN" build ATheory) >"$selector_seed_log" 2>&1; then
  echo "expected selector diagnostic seed to fail" >&2
  exit 1
fi
require_grep "seed selected-goals failure" "$selector_seed_log"
require_file "$(find "$selector_project/.holbuild/checkpoints" -name 'selected_goals_diagnostic_failed_prefix.save' -print -quit)"

python3 - "$selector_project/src/AScript.sml" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().replace(
    'FAIL_TAC "seed selected-goals failure"', 'ALL_TAC'))
PY

selector_resume_log=$tmpdir/selector-resume.log
if (cd "$selector_project" && "$HOLBUILD_BIN" build ATheory) >"$selector_resume_log" 2>&1; then
  echo "expected resumed selector close to fail" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in selected_goals_diagnostic" "$selector_resume_log"
require_grep "theorem: selected_goals_diagnostic" "$selector_resume_log"
require_grep "fragment: branch close" "$selector_resume_log"
require_grep "plan position:" "$selector_resume_log"
require_grep "failed tactic input goals: 1" "$selector_resume_log"
require_grep "failed tactic top input goal:" "$selector_resume_log"
require_grep "selected goals were not solved" "$selector_resume_log"

selector_instrumented_log=$(awk -F'instrumented log: ' '/instrumented log: / {print $2}' "$selector_resume_log" | tail -n 1)
require_file "$selector_instrumented_log"
require_grep "holbuild failed theorem: selected_goals_diagnostic" "$selector_instrumented_log"
require_grep "holbuild plan position:" "$selector_instrumented_log"
require_grep "holbuild goal state at failed fragment: branch close" "$selector_instrumented_log"
require_grep "holbuild failed tactic input goal count: 1" "$selector_instrumented_log"
require_grep "holbuild failed tactic top input goal:" "$selector_instrumented_log"
require_grep "selected goals were not solved" "$selector_instrumented_log"

# Reproduce the other exception reported in the issue deterministically.  The
# checkpoint contains two open goals while inside `each`, with one goal outside
# the active focus.  Raising the recorded tail count models the inconsistent
# resume state which previously escaped with only an internal exception.
each_project=$tmpdir/each-project
mkdir -p "$each_project/src"
write_manifest "$each_project" "failed-prefix-each-diagnostics"
cat > "$each_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem each_focus_diagnostic:
  T /\ T
Proof
  CONJ_TAC >> (ALL_TAC >> FAIL_TAC "seed each-focus failure")
QED

val _ = export_theory();
SML

each_seed_log=$tmpdir/each-seed.log
if (cd "$each_project" && "$HOLBUILD_BIN" build ATheory) >"$each_seed_log" 2>&1; then
  echo "expected each diagnostic seed to fail" >&2
  exit 1
fi
require_grep "seed each-focus failure" "$each_seed_log"
each_checkpoint=$(find "$each_project/.holbuild/checkpoints" -name 'each_focus_diagnostic_failed_prefix.save' -print -quit)
require_file "$each_checkpoint"
require_file "$each_checkpoint.meta"

python3 - "$each_checkpoint.meta" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
lines = path.read_text().splitlines()
for i, line in enumerate(lines):
    if line.startswith("focus="):
        lines[i] = "focus=99"
        break
else:
    raise SystemExit("failed-prefix metadata has no focus field")
path.write_text("\n".join(lines) + "\n")
PY

each_resume_log=$tmpdir/each-resume.log
if (cd "$each_project" && "$HOLBUILD_BIN" build ATheory) >"$each_resume_log" 2>&1; then
  echo "expected resumed each focus to fail" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in each_focus_diagnostic" "$each_resume_log"
require_grep "theorem: each_focus_diagnostic" "$each_resume_log"
require_grep "fragment:" "$each_resume_log"
require_grep "plan position:" "$each_resume_log"
require_grep "failed tactic input goals:" "$each_resume_log"
require_grep "failed tactic top input goal:" "$each_resume_log"
require_grep "focus tail count exceeds open goals:" "$each_resume_log"
require_grep "tail count 99, open goals 2" "$each_resume_log"

each_instrumented_log=$(awk -F'instrumented log: ' '/instrumented log: / {print $2}' "$each_resume_log" | tail -n 1)
require_file "$each_instrumented_log"
require_grep "holbuild failed theorem: each_focus_diagnostic" "$each_instrumented_log"
require_grep "holbuild plan position:" "$each_instrumented_log"
require_grep "holbuild goal state at failed fragment:" "$each_instrumented_log"
require_grep "holbuild failed tactic input goal count:" "$each_instrumented_log"
require_grep "holbuild failed tactic top input goal:" "$each_instrumented_log"
require_grep "focus tail count exceeds open goals:" "$each_instrumented_log"
require_grep "tail count 99, open goals 2" "$each_instrumented_log"

# When every alternative of a proof-IR choice fails, report the final
# alternative's leaf and its intermediate input goal.  Restoring the choice's
# initial runtime state must not reduce the diagnostic to the outer ORELSE and
# its pre-choice goal.
choice_project=$tmpdir/choice-project
mkdir -p "$choice_project/src"
write_manifest "$choice_project" "proof-ir-choice-failure-diagnostics"
cat > "$choice_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem exhausted_choice_diagnostic:
  T ==> T
Proof
  FAIL_TAC "first choice failure"
  ORELSE (DISCH_TAC >> FAIL_TAC "final choice failure")
QED

val _ = export_theory();
SML

choice_log=$tmpdir/choice.log
if (cd "$choice_project" && "$HOLBUILD_BIN" build ATheory) >"$choice_log" 2>&1; then
  echo "expected exhausted proof-IR choice to fail" >&2
  exit 1
fi
require_grep "theorem: exhausted_choice_diagnostic" "$choice_log"
require_grep 'fragment: FAIL_TAC "final choice failure"' "$choice_log"
require_grep 'plan position:.*step FAIL_TAC "final choice failure"' "$choice_log"
require_grep "failed tactic input goals: 1" "$choice_log"
require_grep "final choice failure" "$choice_log"

choice_instrumented_log=$(awk -F'instrumented log: ' '/instrumented log: / {print $2}' "$choice_log" | tail -n 1)
require_file "$choice_instrumented_log"
require_grep "holbuild failed theorem: exhausted_choice_diagnostic" "$choice_instrumented_log"
require_grep 'holbuild goal state at failed fragment: FAIL_TAC "final choice failure"' "$choice_instrumented_log"
require_grep 'holbuild plan position:.*step FAIL_TAC "final choice failure"' "$choice_instrumented_log"
require_grep "holbuild failed tactic input goal count: 1" "$choice_instrumented_log"
require_grep "final choice failure" "$choice_instrumented_log"

python3 - "$choice_instrumented_log" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
start = "holbuild failed tactic top input goal:\n"
end = "holbuild end failed tactic top input goal"
if start not in text or end not in text.split(start, 1)[1]:
    raise SystemExit("missing failed top-goal markers in exhausted-choice log")
goal = text.split(start, 1)[1].split(end, 1)[0].strip()
if "T ⇒ T" in goal or "0.  T" not in goal or not goal.endswith("T"):
    raise SystemExit(
        "exhausted choice did not report the final alternative's assumption-bearing input goal:\n"
        f"{goal}\n"
    )
PY
