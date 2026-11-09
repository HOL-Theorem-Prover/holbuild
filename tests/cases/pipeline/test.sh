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

# Pipelined builds: a child proves against its parent's outline while the
# parent proves, and is committed only once every outline it loaded passed
# the gate.  Each project is also built with pipelining off, and both builds
# must produce the same theory data.

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
  (cd "$tmpdir/$name" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" -j4 build "$target") > "$tmpdir/$name.log" 2>&1
}

# Builds a copy of project NAME with pipelining off and compares the theory
# data of each theory in THEORIES.
require_same_as_unpipelined() {
  local name=$1 target=$2
  shift 2
  rm -rf "$tmpdir/$name-off"
  cp -r "$tmpdir/$name" "$tmpdir/$name-off"
  rm -rf "$tmpdir/$name-off/.holbuild"
  (cd "$tmpdir/$name-off" && HOLBUILD_PIPELINE=off "$HOLBUILD_BIN" -j4 build --no-cache "$target") \
    > "$tmpdir/$name-off.log" 2>&1
  local theory
  for theory in "$@"; do
    cmp "$tmpdir/$name/.holbuild/obj/src/${theory}Theory.dat" \
        "$tmpdir/$name-off/.holbuild/obj/src/${theory}Theory.dat"
  done
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
new_project pass
cat > "$tmpdir/pass/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_thm:
  T
Proof
  $slow_truth
QED
val _ = export_theory();
SML
write_b_and_c pass
build_pipelined pass CTheory
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
require_same_as_unpipelined pass CTheory A B C
(cd "$tmpdir/pass" && "$HOLBUILD_BIN" --verbose build CTheory) > "$tmpdir/pass-again.log"
require_grep "CTheory is up to date" "$tmpdir/pass-again.log"

# The digest differs: B's theorem comes from A's cheat, its stub doesn't, so
# C's attempt on B's outline is dropped and C builds on the real B.
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
require_no_grep "outline ready: ATheory" "$log"
require_grep "pipeline: gate failed: BTheory (digest differs)" "$log"
require_no_grep "committed: CTheory" "$log"
require_file "$tmpdir/digest/.holbuild/plan/outline-skip"
require_same_as_unpipelined digest CTheory B C

# Only the numbering differs: A's proof saves a temporary theorem through an
# alias the outline can't see, which shifts the save index of each later
# theorem but exports nothing.
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
require_grep "pipeline: gate failed: ATheory (theorem numbering differs)" "$log"
require_no_grep "committed: BTheory" "$log"
require_same_as_unpipelined numbering CTheory A B C
