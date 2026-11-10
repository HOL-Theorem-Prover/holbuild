#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
use_case_cache "$tmpdir/cache"
unset HOLBUILD_REMOTE_CACHE_URL

# Pipelined builds (here of theories without checkpoints or proof steps):
# a theory's build defers its proofs and publishes its outline before
# proving them, a child proves against that outline meanwhile, and is
# committed only once every outline it loaded passed the gate.  Each
# project is also built with pipelining off, and both builds must produce
# the same theory data.

new_project() {
  local project=$tmpdir/$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "$1"

[build]
members = ["src"]
TOML
}

# A proof the outline stubs, which takes long enough for the children to
# prove against the outline first, in steps short enough for the tactic
# timeout.
pause='(fn g => (OS.Process.sleep (Time.fromSeconds 2); ALL_TAC g))'
slow_truth="$pause >> $pause >> $pause >> ACCEPT_TAC TRUTH"

write_b_and_c() {
  local project=$tmpdir/$1
  cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib ATheory;
val _ = new_theory "B";
Theorem b_thm:
  T /\ T
Proof
  CONJ_TAC >> ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
  cat > "$project/src/CScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib BTheory;
val _ = new_theory "C";
Theorem c_thm:
  T /\ T
Proof
  ACCEPT_TAC BTheory.b_thm
QED
val _ = export_theory();
SML
}

build_pipelined() {
  local name=$1 target=$2
  (cd "$tmpdir/$name" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" -j4 build --skip-checkpoints --skip-proof-steps "$target") > "$tmpdir/$name.log" 2>&1
}

# Builds project NAME with default flags (checkpoints and proof steps on).
build_pipelined_steps() {
  local name=$1
  shift
  (cd "$tmpdir/$name" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" -j4 build --no-cache "$@") > "$tmpdir/$name.log" 2>&1 ||
    { tail -n 60 "$tmpdir/$name.log" >&2; return 1; }
}

# Builds a copy of project NAME with pipelining off and compares the theory
# data of each theory in THEORIES: the patched data of a deferred build is
# byte for byte what the plain build exports.  The plain build takes the
# flags in UNPIPELINED_FLAGS, by default those of build_pipelined.
require_same_as_unpipelined() {
  local name=$1 target=$2
  shift 2
  local flags
  read -r -a flags <<< "${UNPIPELINED_FLAGS---skip-checkpoints --skip-proof-steps}"
  rm -rf "$tmpdir/$name-off"
  cp -r "$tmpdir/$name" "$tmpdir/$name-off"
  rm -rf "$tmpdir/$name-off/.holbuild"
  (cd "$tmpdir/$name-off" && HOLBUILD_PIPELINE=off "$HOLBUILD_BIN" -j4 build --no-cache ${flags[@]+"${flags[@]}"} "$target") \
    > "$tmpdir/$name-off.log" 2>&1
  local theory
  for theory in "$@"; do
    local ext
    for ext in dat sml sig; do
      cmp "$tmpdir/$name/.holbuild/obj/src/${theory}Theory.$ext" \
          "$tmpdir/$name-off/.holbuild/obj/src/${theory}Theory.$ext"
    done
  done
}

# Requires the first line matching FIRST to come before the first matching
# SECOND.
require_before() {
  local first=$1 second=$2 file=$3 a b
  a=$(grep -n -m1 -- "$first" "$file" | cut -d: -f1)
  b=$(grep -n -m1 -- "$second" "$file" | cut -d: -f1)
  if [[ -z "$a" || -z "$b" || "$a" -ge "$b" ]]; then
    echo "expected '$first' before '$second' in $file" >&2
    cat "$file" >&2
    exit 1
  fi
}

require_no_grep() {
  local pattern=$1 file=$2
  if grep -q -- "$pattern" "$file"; then
    echo "unexpected '$pattern' in $file" >&2
    cat "$file" >&2
    exit 1
  fi
}

# The gate passes: B and C are committed from their speculative attempts.
# A's suspended theorem, and its Resume block that suspends again, keep
# their proofs in the outline, so its Finalise still saves it in place, with
# its attributes.  So does a_hidden, whose proof suspends through a helper
# tactic, and its Finalise keeps it local.
new_project pass
cat > "$tmpdir/pass/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_thm:
  T
Proof
  $slow_truth
QED
Theorem a_split:
  T /\\ T
Proof
  CONJ_TAC >- suspend "left" >> suspend "right"
QED
Resume a_split[left]:
  ACCEPT_TAC TRUTH
QED
Resume a_split[right]:
  suspend "inner"
QED
Resume a_split[inner]:
  ACCEPT_TAC TRUTH
QED
Finalise a_split[simp]
fun split_tac () = CONJ_TAC >- suspend "left" >> suspend "right";
Theorem a_hidden:
  T /\\ T
Proof
  split_tac ()
QED
Resume a_hidden[left]:
  ACCEPT_TAC TRUTH
QED
Resume a_hidden[right]:
  ACCEPT_TAC TRUTH
QED
Finalise a_hidden[local]
val _ = export_theory();
SML
write_b_and_c pass
# B's local lemma depends on a theory no other string of B names, and its
# users, one a simp theorem, inherit that dependency once it is proved.
cat > "$tmpdir/pass/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib ATheory;
val _ = new_theory "B";
Triviality b_local:
  T
Proof
  ACCEPT_TAC (EQ_MP (EQT_INTRO (SPEC_ALL combinTheory.I_THM)) (SPEC_ALL combinTheory.I_THM))
QED
Theorem b_simp[simp]:
  T
Proof
  ACCEPT_TAC b_local
QED
Theorem b_thm:
  T /\ T
Proof
  CONJ_TAC >> ACCEPT_TAC b_local
QED
val _ = export_theory();
SML
# A pipelined build publishes its committed theories to the remote cache as
# a plain build does.
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
HOLBUILD_REMOTE_CACHE_URL=$remote_url build_pipelined pass CTheory
log=$tmpdir/pass.log
require_grep "pipeline: outline ready: ATheory" "$log"
require_grep "pipeline: outline ready: BTheory" "$log"
require_grep "pipeline: gate passed: ATheory" "$log"
require_grep "pipeline: committed: BTheory" "$log"
require_grep "pipeline: committed: CTheory" "$log"
require_no_grep "gate failed" "$log"
if [[ -n "$(ls -A "$tmpdir/pass/.holbuild/outline")" ]]; then
  echo "outlines left behind in $tmpdir/pass/.holbuild/outline" >&2
  exit 1
fi
published=$(grep -c "remote cache published: " "$log" || true)
if [[ "$published" -ne 3 ]]; then
  echo "expected A, B and C published to the remote cache, saw $published:" >&2
  cat "$log" >&2
  exit 1
fi
require_same_as_unpipelined pass CTheory A B C
# A copy of the project with an empty local cache restores all three from the
# remote cache, the pipelined build's outputs byte for byte.
cp -r "$tmpdir/pass" "$tmpdir/pass-remote"
rm -rf "$tmpdir/pass-remote/.holbuild"
link_hol_toolchain_cache "$tmpdir/cache-remote"
(cd "$tmpdir/pass-remote" && HOLBUILD_CACHE="$tmpdir/cache-remote" HOLBUILD_REMOTE_CACHE_URL=$remote_url \
  "$HOLBUILD_BIN" -j4 build --skip-checkpoints --skip-proof-steps CTheory) > "$tmpdir/pass-remote.log" 2>&1 ||
  { cat "$tmpdir/pass-remote.log" >&2; exit 1; }
for theory in A B C; do
  require_grep "${theory}Theory restored from cache" "$tmpdir/pass-remote.log"
  for ext in dat sml sig; do
    cmp "$tmpdir/pass/.holbuild/obj/src/${theory}Theory.$ext" \
        "$tmpdir/pass-remote/.holbuild/obj/src/${theory}Theory.$ext"
  done
done
require_no_grep "Theory built" "$tmpdir/pass-remote.log"
(cd "$tmpdir/pass" && "$HOLBUILD_BIN" --verbose build --skip-checkpoints --skip-proof-steps CTheory) > "$tmpdir/pass-again.log"
require_grep "CTheory is up to date" "$tmpdir/pass-again.log"

# With default flags, proof steps on, the proof runtime runs the deferred
# proofs.  A bare build's targets are the project's roots, here C, which
# saves theorem checkpoints, which a speculative proof doesn't, so C builds
# only on the committed B.
cp -r "$tmpdir/pass" "$tmpdir/steps"
rm -rf "$tmpdir/steps/.holbuild"
sed -i 's|^members = \["src"\]$|&\nroots = ["src/CScript.sml"]|' "$tmpdir/steps/holproject.toml"
require_grep '^roots = \["src/CScript.sml"\]$' "$tmpdir/steps/holproject.toml"
build_pipelined_steps steps
log=$tmpdir/steps.log
require_grep "pipeline: outline ready: ATheory" "$log"
require_grep "pipeline: gate passed: ATheory" "$log"
require_grep "pipeline: attempt done: BTheory" "$log"
require_no_grep "attempt done: CTheory" "$log"
require_no_grep "attempt failed" "$log"
require_before "pipeline: committed: BTheory" "CTheory built" "$log"
UNPIPELINED_FLAGS="" require_same_as_unpipelined steps CTheory A B C

# With --all-checkpoints every theory saves checkpoints, so none is
# pipelined.
cp -r "$tmpdir/pass" "$tmpdir/checkpointed"
rm -rf "$tmpdir/checkpointed/.holbuild"
build_pipelined_steps checkpointed --all-checkpoints
log=$tmpdir/checkpointed.log
require_grep "CTheory built" "$log"
require_no_grep "pipeline: dispatch pipelined" "$log"
require_no_grep "pipeline: outline ready" "$log"
require_no_grep "pipeline: attempt" "$log"
require_grep "pipeline: summary: outlines=0 " "$log"

# Each deferred proof runs in its goal's context, though the script changed
# it later: a_use needs a_const_simp, which the script then removes from the
# simp set.  Its tactic reads the simp set from the live context, not the
# one HOL passes it, as a tactic defined outside a theorem can.  (Every
# proof here uses a theorem of an ancestor, so carries DISK_THM, as the
# outline has it.)
new_project restore
cat > "$tmpdir/restore/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Definition a_const_def:
  a_const = T
End
Theorem a_const_simp[simp]:
  a_const = T
Proof
  ACCEPT_TAC (CONJUNCT1 (CONJ a_const_def TRUTH))
QED
fun live_simp g = SIMP_TAC (BasicProvers.srw_ss ()) [] g;
Theorem a_use:
  a_const
Proof
  $pause >> live_simp
QED
val _ = temp_delsimps ["a_const_simp"];
val _ = export_theory();
SML
write_b_and_c restore
build_pipelined_steps restore CTheory
log=$tmpdir/restore.log
require_grep "pipeline: gate passed: ATheory" "$log"
require_grep "pipeline: committed: BTheory" "$log"
require_no_grep "attempt failed" "$log"
UNPIPELINED_FLAGS="" require_same_as_unpipelined restore CTheory A B C

# A deferred proof's step that runs out of time fails A's deferred build,
# and A's build with its proofs in place fails the same way.
new_project timeout
cat > "$tmpdir/timeout/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_slow:
  T
Proof
  $pause >> ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
write_b_and_c timeout
if (cd "$tmpdir/timeout" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" -j4 build --no-cache --tactic-timeout 1 BTheory) > "$tmpdir/timeout.log" 2>&1; then
  echo "expected the tactic timeout to fail the build" >&2
  cat "$tmpdir/timeout.log" >&2
  exit 1
fi
log=$tmpdir/timeout.log
require_grep "pipeline: attempt failed: ATheory" "$log"
require_grep "holbuild tactic timeout after" "$log"

# A cheat in scope: B's proof uses A's cheated theorem, so it carries the
# cheat once proved, which an outline can't predict.  B publishes no outline,
# and C builds on the committed B.
new_project withheld
cat > "$tmpdir/withheld/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_lemma:
  T
Proof
  cheat
QED
val _ = export_theory();
SML
write_b_and_c withheld
cat > "$tmpdir/withheld/src/BScript.sml" <<SML
open HolKernel Parse boolLib bossLib ATheory;
val _ = new_theory "B";
Theorem b_thm:
  T
Proof
  $pause >> $pause >> $pause >> ACCEPT_TAC ATheory.a_lemma
QED
val _ = export_theory();
SML
sed -i 's/T \/\\ T/T/' "$tmpdir/withheld/src/CScript.sml"
build_pipelined withheld CTheory
log=$tmpdir/withheld.log
require_grep "pipeline: gate passed: ATheory" "$log"
require_grep "pipeline: outline withheld: BTheory (oracle cheat in theory A)" "$log"
require_no_grep "outline ready: BTheory" "$log"
require_no_grep "gate failed" "$log"
require_before "committed: BTheory" "attempt done: CTheory" "$log"
require_same_as_unpipelined withheld CTheory A B C

# The same from a cheat in A itself, in a [local] lemma whose proof does more
# than cheat (so it stays in place) and that a deferred proof uses.
new_project withheld-local
cat > "$tmpdir/withheld-local/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Triviality a_lemma:
  T
Proof
  ALL_TAC >> cheat
QED
Theorem a_thm:
  T
Proof
  $pause >> $pause >> ACCEPT_TAC a_lemma
QED
val _ = export_theory();
SML
write_b_and_c withheld-local
build_pipelined withheld-local CTheory
log=$tmpdir/withheld-local.log
require_grep "pipeline: outline withheld: ATheory (oracle cheat in theory A)" "$log"
require_no_grep "gate failed" "$log"
require_same_as_unpipelined withheld-local CTheory A B C

# The digest differs: B's proof makes an oracle itself, which nothing in
# scope shows, so B's outline is published without it; C's attempt on it is
# dropped and C builds on the real B.
new_project digest
cat > "$tmpdir/digest/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_lemma:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
write_b_and_c digest
cat > "$tmpdir/digest/src/BScript.sml" <<SML
open HolKernel Parse boolLib bossLib ATheory;
val _ = new_theory "B";
Theorem b_thm:
  T
Proof
  $pause >> $pause >> $pause >> (fn (asl, w) => ACCEPT_TAC (mk_oracle_thm "made_here" (asl, w)) (asl, w))
QED
val _ = export_theory();
SML
sed -i 's/T \/\\ T/T/' "$tmpdir/digest/src/CScript.sml"
build_pipelined digest CTheory
log=$tmpdir/digest.log
require_grep "pipeline: gate passed: ATheory" "$log"
require_grep "pipeline: gate failed: BTheory (digest differs)" "$log"
require_grep "pipeline: attempt done: CTheory" "$log"
require_grep "pipeline: dropped attempt: CTheory" "$log"
# C then builds again, on the committed B.
require_before "dropped attempt: CTheory" "committed: CTheory" "$log"
require_file "$tmpdir/digest/.holbuild/plan/outline-skip"
require_same_as_unpipelined digest CTheory B C

# Only the numbering differs: A's proof saves a temporary theorem through an
# alias, which shifts the save index of each later theorem but exports
# nothing.  Deferred, the proof would save it after the export, so A's
# deferred build fails and A builds again with its proofs in place.
new_project numbering
cat > "$tmpdir/numbering/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val hidden = Theory.save_thm;
Theorem a_thm:
  T
Proof
  (fn g => (ignore (hidden ("@tempx", TRUTH)); ACCEPT_TAC TRUTH g))
QED
Theorem a_slow:
  T
Proof
  $slow_truth
QED
val _ = export_theory();
SML
write_b_and_c numbering
build_pipelined numbering CTheory
log=$tmpdir/numbering.log
require_grep "pipeline: attempt failed: ATheory" "$log"
require_grep "a deferred proof changed the theory: saved @tempx" "$log"
require_grep "pipeline: gate failed: ATheory (theorem numbering differs)" "$log"
require_before "dropped attempt: BTheory" "committed: BTheory" "$log"
# C's attempt loaded A's outline only through B's, so the fallback reaches it
# transitively.
require_grep "pipeline: dropped attempt: CTheory" "$log"
require_same_as_unpipelined numbering CTheory A B C

# A deferred proof that writes theory data (here a simp set entry) would
# write it to its own context only, so A's deferred build fails and A
# builds again with its proofs in place; its outline lacked the entry.
new_project thydata
cat > "$tmpdir/thydata/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
Theorem a_slow:
  T
Proof
  (fn g => (BasicProvers.export_rewrites ["a_thm"]; ALL_TAC g)) >> $slow_truth
QED
val _ = export_theory();
SML
write_b_and_c thydata
build_pipelined thydata CTheory
log=$tmpdir/thydata.log
require_grep "pipeline: attempt failed: ATheory" "$log"
require_grep "wrote theory data of type simp.deltas" "$log"
require_grep "pipeline: gate failed: ATheory (digest differs)" "$log"
require_same_as_unpipelined thydata CTheory A B C

# A deferred proof that suspends a subgoal through a helper tactic, with no
# Resume in the script to show it, proves its goal only under the suspended
# subgoal, so A's deferred build fails and A builds again with its proofs
# in place, where the theorem is stashed rather than saved.
new_project hidden
cat > "$tmpdir/hidden/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
fun later_tac () = suspend "later";
Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
Theorem a_hidden:
  T
Proof
  later_tac ()
QED
Theorem a_slow:
  T
Proof
  $slow_truth
QED
val _ = export_theory();
SML
write_b_and_c hidden
build_pipelined hidden CTheory
log=$tmpdir/hidden.log
require_grep "pipeline: attempt failed: ATheory" "$log"
require_grep "the proof left a hypothesis its goal lacks: suspendlabel" "$log"
require_grep "pipeline: gate failed: ATheory (digest differs)" "$log"
require_same_as_unpipelined hidden CTheory A B C

# A deferred proof that fails, as one racing another thread on a library's
# cache can, runs again alone before it fails the build.  This one fails
# only the first time it runs; a_other gives the proofs a second thread.
new_project retry
cat > "$tmpdir/retry/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val tries = ref 0;
Theorem a_other:
  T
Proof
  ACCEPT_TAC TRUTH
QED
Theorem a_flaky:
  T
Proof
  (fn g => (tries := !tries + 1; if !tries = 1 then NO_TAC g else ALL_TAC g)) >> $slow_truth
QED
val _ = export_theory();
SML
write_b_and_c retry
build_pipelined retry CTheory
log=$tmpdir/retry.log
require_no_grep "attempt failed" "$log"
require_grep "pipeline: gate passed: ATheory" "$log"
require_grep "pipeline: committed: CTheory" "$log"

# Pipelining only fills slots that would otherwise sit idle.  At -j2, A is
# the only ready theory, so a worker is left over and A is pipelined; B and
# C then run as speculative attempts on the outlines.
new_project idle
cat > "$tmpdir/idle/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_thm:
  T
Proof
  $slow_truth
QED
val _ = export_theory();
SML
write_b_and_c idle
(cd "$tmpdir/idle" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" -j2 build --no-cache --skip-checkpoints --skip-proof-steps CTheory) \
  > "$tmpdir/idle.log" 2>&1
log=$tmpdir/idle.log
require_grep "pipeline: dispatch pipelined: ATheory (pending 1, free 2)" "$log"
require_grep "pipeline: attempt done: BTheory" "$log"
require_grep "pipeline: attempt done: CTheory" "$log"
require_grep "pipeline: committed: CTheory" "$log"
require_no_grep "dispatch plain" "$log"
require_no_grep "dispatch pipelined: [BC]Theory" "$log"
require_same_as_unpipelined idle CTheory A B C

# Under a backlog nothing is pipelined: six independent theories at -j2.
# Each worker that takes one leaves at least as many ready as free, so each
# builds plain, but for the last if both workers are free then.
new_project backlog
for t in R1 R2 R3 R4 R5 R6; do
  cat > "$tmpdir/backlog/src/${t}Script.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "$t";
Theorem ${t}_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
done
(cd "$tmpdir/backlog" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" -j2 build --no-cache --skip-checkpoints --skip-proof-steps) \
  > "$tmpdir/backlog.log" 2>&1
log=$tmpdir/backlog.log
plain=$(grep -c "pipeline: dispatch plain: R" "$log" || true)
pipelined=$(grep -c "pipeline: dispatch pipelined: R" "$log" || true)
if (( plain < 5 || plain + pipelined != 6 )); then
  echo "expected at least 5 of the 6 theories dispatched plain, got $plain plain and $pipelined pipelined" >&2
  cat "$log" >&2
  exit 1
fi
require_no_grep "dispatch pipelined: .*free 1)" "$log"
for t in $(sed -n 's/.*pipeline: dispatch plain: \([A-Za-z0-9]*\)Theory .*/\1/p' "$log"); do
  require_no_grep "attempt done: ${t}Theory" "$log"
done
