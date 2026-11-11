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

# A step that times out runs once more with half the budget (0.5s here).
# `retry_sleep` is how long the step takes on its second call; the first
# call always takes longer than the budget.
write_project() {
  local project=$1 retry_sleep=$2
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "retry"

[build]
members = ["src"]
tactic_timeout = 1.0
TOML
  cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

val calls = ref 0;
fun stall_tac g =
  (calls := !calls + 1;
   OS.Process.sleep (Time.fromReal (if !calls = 1 then 3.0 else $retry_sleep));
   ALL_TAC g);

Theorem t:
  T /\\ T
Proof
  CONJ_TAC >- (stall_tac >> simp[]) >> simp[]
QED

Theorem u:
  T
Proof
  simp[]
QED

val _ = export_theory();
SML
}

# (a) A step that stalled once passes on its retry; the proof goes on, and the
# theory's build log records the retry.
write_project "$tmpdir/stalled" 0.0
(cd "$tmpdir/stalled" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/stalled.log" 2>&1 ||
  { cat "$tmpdir/stalled.log" >&2; exit 1; }
require_grep "ATheory built" "$tmpdir/stalled.log"
build_log=$tmpdir/stalled/.holbuild/logs/current/retry/ATheory/build.log
require_grep "^holbuild tactic timeout retry passed: stall_tac (budget 1.0s; retry [0-9.]* ms wall; GC during first attempt [0-9.]* ms)$" "$build_log"
[[ $(grep -c "tactic timeout retry passed" "$build_log") -eq 1 ]] || { cat "$build_log" >&2; exit 1; }
require_grep $'^holbuild slow-proof-step\tt\t[0-9]*\tstep\tok\t[0-9.]*\t1000.000\tstall_tac$' "$build_log"

# (b) A step whose retry needs more than half the budget fails as it did
# without the retry: the full budget in the message and in the marker.
write_project "$tmpdir/slow" 0.7
if (cd "$tmpdir/slow" && "$HOLBUILD_BIN" --json build --retain-debug-artifacts ATheory) > "$tmpdir/slow.log" 2>&1; then
  echo "build succeeded although the retry exceeded half the budget" >&2
  cat "$tmpdir/slow.log" >&2
  exit 1
fi
require_grep "tactic timed out after 1.0s while building ATheory: stall_tac" "$tmpdir/slow.log"
require_grep "holbuild tactic timeout after 1.0s: stall_tac" "$tmpdir/slow.log"
require_grep '"kind":"tactic_timeout"' "$tmpdir/slow.log"
if grep -q "tactic timeout retry passed" "$tmpdir/slow.log"; then cat "$tmpdir/slow.log" >&2; exit 1; fi
require_grep $'^holbuild slow-proof-step\tt\t[0-9]*\tstep\tfailed\t[0-9.]*\t1000.000\tstall_tac$' \
  "$tmpdir/slow/.holbuild/logs/current/retry/ATheory/instrumented-failure.log"
