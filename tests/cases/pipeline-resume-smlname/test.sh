#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"
unset HOLBUILD_REMOTE_CACHE_URL

# A `Resume` block that names `smlname` binds the theorem it proves to that
# name, which the script can save.  A pipelined build defers the proofs of a
# theory, and a deferred proof's stub is an oracle theorem of its goal, with
# the goal's assumptions as hypotheses: here the subgoal's `p`, which the
# real proof `ACCEPT_TAC TRUTH` doesn't use.  So the block's proof stays in
# place, and the theorem saved from `sub` has no hypotheses, as in a build
# without pipelining, while the theory is still pipelined.

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
name = "resume-smlname"

[build]
members = ["src"]
TOML

# a_slow is a proof the build defers, and takes long enough for B to
# attempt its build on A's outline meanwhile.
pause='(fn g => (OS.Process.sleep (Time.fromSeconds 2); ALL_TAC g))'
cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib markerLib;
val _ = new_theory "A";

Theorem parent:
  p ==> T
Proof
  DISCH_TAC >> suspend "finish"
QED

Resume parent[finish,smlname=sub]:
  ACCEPT_TAC TRUTH
QED

val _ = save_thm ("saved_resume", sub);

Finalise parent

Theorem a_slow:
  T
Proof
  $pause >> $pause >> ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib ATheory;
val _ = new_theory "B";

val n = length (Thm.hyp saved_resume);
val _ = if n = 0 then () else raise Fail ("saved_resume has " ^ Int.toString n ^ " hypotheses");

val _ = export_theory();
SML

log=$tmpdir/build.log
(cd "$project" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" -j4 build --skip-checkpoints --skip-proof-steps BTheory) \
  > "$log" 2>&1 || { cat "$log" >&2; exit 1; }
# The build was pipelined: A published an outline and was committed after the
# gate, B too, so the result doesn't come from pipelining being off.
require_grep "pipeline: outline ready: ATheory" "$log"
require_grep "pipeline: gate passed: ATheory" "$log"
require_grep "pipeline: committed: ATheory" "$log"
require_grep "pipeline: committed: BTheory" "$log"
if grep -q -e "attempt failed" -e "gate failed" "$log"; then
  echo "unexpected pipeline failure in $log" >&2
  cat "$log" >&2
  exit 1
fi
