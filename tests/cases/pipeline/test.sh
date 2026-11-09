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
  rm -rf "$tmpdir"
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

# Builds a copy of project NAME with pipelining off and compares the theory
# data of each theory in THEORIES: the patched data of a deferred build is
# byte for byte what the plain build exports.
require_same_as_unpipelined() {
  local name=$1 target=$2
  shift 2
  rm -rf "$tmpdir/$name-off"
  cp -r "$tmpdir/$name" "$tmpdir/$name-off"
  rm -rf "$tmpdir/$name-off/.holbuild"
  (cd "$tmpdir/$name-off" && HOLBUILD_PIPELINE=off "$HOLBUILD_BIN" -j4 build --no-cache --skip-checkpoints --skip-proof-steps "$target") \
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
# its attributes.
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
# A pipelined build isn't published to the remote cache: a deferred proof
# can record other dependencies than the plain build would.
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
HOLBUILD_REMOTE_CACHE_URL=$remote_url build_pipelined pass CTheory
log=$tmpdir/pass.log
require_no_grep "remote cache published" "$log"
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
require_same_as_unpipelined pass CTheory A B C
# The same build with pipelining off, on an empty cache, is published.
cp -r "$tmpdir/pass" "$tmpdir/pass-plain"
rm -rf "$tmpdir/pass-plain/.holbuild"
link_hol_toolchain_cache "$tmpdir/cache-plain"
(cd "$tmpdir/pass-plain" && HOLBUILD_CACHE="$tmpdir/cache-plain" HOLBUILD_PIPELINE=off HOLBUILD_CACHE_TRACE=1 \
  HOLBUILD_REMOTE_CACHE_URL=$remote_url "$HOLBUILD_BIN" -j4 build --skip-checkpoints --skip-proof-steps CTheory) \
  > "$tmpdir/pass-plain.log" 2>&1
require_grep "remote cache published" "$tmpdir/pass-plain.log"
(cd "$tmpdir/pass" && "$HOLBUILD_BIN" --verbose build --skip-checkpoints --skip-proof-steps CTheory) > "$tmpdir/pass-again.log"
require_grep "CTheory is up to date" "$tmpdir/pass-again.log"

# A speculative proof saves no checkpoints, so theories that keep them
# build only on committed parents.
cp -r "$tmpdir/pass" "$tmpdir/checkpointed"
rm -rf "$tmpdir/checkpointed/.holbuild"
(cd "$tmpdir/checkpointed" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" -j4 build --no-cache CTheory) \
  > "$tmpdir/checkpointed.log" 2>&1
require_no_grep "attempt done" "$tmpdir/checkpointed.log"

# The digest differs: B's theorem comes from A's cheat, its stub doesn't, so
# C's attempt on B's outline is dropped and C builds on the real B.  A's
# proof is just `cheat`, which its outline keeps, so A passes.
new_project digest
cat > "$tmpdir/digest/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_lemma:
  T
Proof
  cheat
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
  $pause >> $pause >> $pause >> ACCEPT_TAC ATheory.a_lemma
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
