#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# With HOLBUILD_PROOF_THREADS above 1, a build with proof steps defers its
# theorems' proofs and proves them on several threads after the export.  It
# exports the same theory data as a build that proves them in place, fails
# a broken deferred proof with the diagnostics of an in-place build, and a
# later build resumes from a context saved while proofs were deferred.

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

make_project() {
  local project=$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "in-place-deferral"

[build]
members = ["src"]
TOML
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem first_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
Theorem add_one:
  1 + 1 = 2
Proof
  simp[]
QED
Theorem add_zero:
  !x. x + 0 = x
Proof
  simp[]
QED
Theorem add_zero_twice:
  !y. (y + 0) + 0 = y
Proof
  REWRITE_TAC [add_zero]
QED
Theorem times:
  2 * 3 = 6
Proof
  EVAL_TAC
QED
Theorem last_thm:
  T /\ T
Proof
  CONJ_TAC >> ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
}

edit() {
  python3 - "$1/src/AScript.sml" "$2" "$3" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
assert text.count(sys.argv[2]) == 1, sys.argv[2]
path.write_text(text.replace(sys.argv[2], sys.argv[3]))
PY
}

# --no-cache: the two projects' builds are the same actions.
build() {
  local project=$1 threads=$2 log=$3
  (cd "$project" && HOLBUILD_PROOF_THREADS=$threads "$HOLBUILD_BIN" -j4 build --no-cache ATheory) >"$log" 2>&1
}

data() { echo "$1/.holbuild/obj/src/ATheory.dat"; }

child_log() { echo "$1/.holbuild/logs/current/in-place-deferral/ATheory/build.log"; }

in_place=$tmpdir/in-place
deferred=$tmpdir/deferred
make_project "$in_place"
make_project "$deferred"

build "$in_place" 1 "$tmpdir/in-place.log" || { cat "$tmpdir/in-place.log" >&2; exit 1; }
build "$deferred" 4 "$tmpdir/deferred.log" || { cat "$tmpdir/deferred.log" >&2; exit 1; }
require_grep "holbuild: proved 5 deferred proofs of 5 on" "$(child_log "$deferred")"
if grep -q "deferred proofs" "$(child_log "$in_place")"; then
  echo "the one-thread build deferred its proofs" >&2
  exit 1
fi
cmp "$(data "$in_place")" "$(data "$deferred")" || { echo "the deferred build exported other theory data" >&2; exit 1; }
if grep -q holbuild_deferred_ "$(data "$deferred")"; then
  echo "the exported data names a deferred proof" >&2
  exit 1
fi

# An edit to add_zero_twice and a broken last proof: the deferred build
# resumes from the context saved after add_zero, proves add_zero_twice in
# place and the rest after the export, where last_thm fails on a thread and
# again here, with the goal state an in-place build prints.  Its context
# saved after times, while times was deferred, is committed: times passed.
for project in "$in_place" "$deferred"; do
  edit "$project" "REWRITE_TAC [add_zero]" "ALL_TAC >> REWRITE_TAC [add_zero]"
  edit "$project" "CONJ_TAC >> ACCEPT_TAC TRUTH" 'CONJ_TAC >> FAIL_TAC "late failure"'
done
if build "$in_place" 1 "$tmpdir/in-place-broken.log"; then echo "the broken build passed" >&2; exit 1; fi
if build "$deferred" 4 "$tmpdir/deferred-broken.log"; then echo "the broken deferred build passed" >&2; exit 1; fi
require_grep "late failure" "$tmpdir/deferred-broken.log"
require_grep "checkpoint after add_zero$" "$tmpdir/deferred-broken.log"
require_grep "holbuild: proved 1 deferred proofs of 2 on" "$(child_log "$deferred")"
goal_state() { sed -n '/goal state at failed fragment/,/end failed tactic top input goal/p' "$1"; }
[[ -n "$(goal_state "$(child_log "$in_place")")" ]] || { cat "$(child_log "$in_place")" >&2; echo "no goal state in place" >&2; exit 1; }
diff <(goal_state "$(child_log "$in_place")") <(goal_state "$(child_log "$deferred")") ||
  { echo "the deferred build printed another goal state" >&2; exit 1; }
if find "$deferred/.holbuild/checkpoints" -name 'last_thm_failed_prefix*' | grep -q .; then
  echo "a proof that failed after the export saved a failed-prefix checkpoint" >&2
  exit 1
fi

# Fixed, the deferred build resumes after times and exports the same data.
for project in "$in_place" "$deferred"; do
  edit "$project" 'CONJ_TAC >> FAIL_TAC "late failure"' "CONJ_TAC >> ACCEPT_TAC TRUTH"
done
build "$in_place" 1 "$tmpdir/in-place-fixed.log" || { cat "$tmpdir/in-place-fixed.log" >&2; exit 1; }
build "$deferred" 4 "$tmpdir/deferred-fixed.log" || { cat "$tmpdir/deferred-fixed.log" >&2; exit 1; }
require_grep "checkpoint after times$" "$tmpdir/deferred-fixed.log"
cmp "$(data "$in_place")" "$(data "$deferred")" || { echo "the resumed deferred build exported other theory data" >&2; exit 1; }
