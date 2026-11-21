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

# A pipelined build defers a theorem that suspends goals together with the
# `Resume` blocks that prove them, as one group, when its HOL's markerLib
# drops finalised suspensions at export: the outline suspends a dummy goal
# per label, and the group is proved and assembled after the outline is
# published.  With an older HOL the group stays in place.  Either way the
# theory data is what a plain build exports, and a group whose proof is
# wrong builds plain, with the plain build's verdict.
if grep -q susp_uptodate "$HOLDIR/src/marker/markerLib.sml"; then
  groups=1
else
  groups=0
fi

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

require_no_grep() {
  local pattern=$1 file=$2
  if grep -q -- "$pattern" "$file"; then
    echo "unexpected '$pattern' in $file" >&2
    cat "$file" >&2
    exit 1
  fi
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

# Builds project NAME's TARGET pipelined, with FLAGS, into NAME.log;
# returns the build's status.
build_pipelined() {
  local name=$1 target=$2 flags=$3
  local -a args
  read -r -a args <<< "$flags"
  (cd "$tmpdir/$name" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" -j4 build --no-cache ${args[@]+"${args[@]}"} "$target") \
    > "$tmpdir/$name.log" 2>&1
}

# Builds a copy of project NAME's TARGET with pipelining off, with FLAGS,
# into NAME-off.log; returns the build's status.
build_unpipelined() {
  local name=$1 target=$2 flags=$3
  local -a args
  read -r -a args <<< "$flags"
  rm -rf "$tmpdir/$name-off"
  cp -r "$tmpdir/$name" "$tmpdir/$name-off"
  rm -rf "$tmpdir/$name-off/.holbuild"
  (cd "$tmpdir/$name-off" && HOLBUILD_PIPELINE=off "$HOLBUILD_BIN" -j4 build --no-cache ${args[@]+"${args[@]}"} "$target") \
    > "$tmpdir/$name-off.log" 2>&1
}

# Requires the theory data of each of THEORIES to be the same in project
# NAME and its unpipelined copy.
require_same_data() {
  local name=$1 theory ext
  shift
  for theory in "$@"; do
    for ext in dat sml sig; do
      cmp "$tmpdir/$name/.holbuild/obj/src/${theory}Theory.$ext" \
          "$tmpdir/$name-off/.holbuild/obj/src/${theory}Theory.$ext"
    done
  done
}

pause='(fn g => (OS.Process.sleep (Time.fromSeconds 2); ALL_TAC g))'
slow_truth="$pause >> $pause >> $pause >> $pause >> ACCEPT_TAC TRUTH"
fast='--skip-checkpoints --skip-proof-steps'

# Groups that pass: a closed group whose last Resume is slow; nested
# Resumes; two groups that overlap and share a label (with other goals,
# which HOL needs); a group finalised
# [local], which the script still uses; a group the build keeps in place,
# since its span looks the suspension up, whose `Resume` block suspends
# through a helper (with its body at the start of a line), so it stays in
# place too; and one kept in place since the script reads its theorem's
# hypotheses before its `Finalise`, where the stub would have a
# placeholder.
new_project pass
cat > "$tmpdir/pass/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib markerLib;
val _ = new_theory "A";

Theorem closed:
  T /\\ T
Proof
  CONJ_TAC >- suspend "left" >> suspend "right"
QED
Resume closed[left]:
  ACCEPT_TAC TRUTH
QED
Resume closed[right]:
  $slow_truth
QED
Finalise closed

Theorem nested:
  p ==> p
Proof
  DISCH_TAC >> suspend "outer"
QED
Resume nested[outer]:
  suspend "inner"
QED
Resume nested[inner]:
  FIRST_ASSUM ACCEPT_TAC
QED
Finalise nested[simp]

Theorem first:
  F ==> F
Proof
  suspend "shared"
QED
Triviality second:
  T /\\ T
Proof
  CONJ_TAC >> suspend "shared"
QED
Resume first[shared]:
  DISCH_TAC >> FIRST_ASSUM ACCEPT_TAC
QED
Resume second[shared]:
  ACCEPT_TAC TRUTH
QED
Finalise second
Finalise first

Theorem hidden:
  T
Proof
  suspend "h"
QED
Resume hidden[h]:
  ACCEPT_TAC TRUTH
QED
Finalise hidden[local]

Theorem uses_hidden:
  T /\\ T
Proof
  CONJ_TAC >> ACCEPT_TAC hidden
QED

fun more_tac () =
rpt strip_tac >> suspend "more";
Theorem looked_up:
  T
Proof
  suspend "first"
QED
val _ = assert Option.isSome (markerLib.lookup_suspension "A.looked_up");
Resume looked_up[first]:
  more_tac ()
QED
Resume looked_up[more]:
  ACCEPT_TAC TRUTH
QED
Finalise looked_up

Theorem counted:
  F ==> F
Proof
  suspend "one"
QED
val _ = save_thm ("counted_hyp", if aconv (rand (hd (hyp counted))) \`\`F ==> F\`\` then TRUTH else EQT_INTRO TRUTH);
Resume counted[one]:
  simp[]
QED
Finalise counted

val _ = export_theory();
SML
cat > "$tmpdir/pass/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib ATheory;
val _ = new_theory "B";
Theorem b_thm:
  T /\ T
Proof
  CONJ_TAC >> ACCEPT_TAC (CONJUNCT1 closed)
QED
val _ = export_theory();
SML
build_pipelined pass BTheory "$fast" || { cat "$tmpdir/pass.log" >&2; exit 1; }
log=$tmpdir/pass.log
require_grep "pipeline: outline ready: ATheory" "$log"
require_grep "pipeline: gate passed: ATheory" "$log"
require_grep "pipeline: committed: BTheory" "$log"
require_no_grep "attempt failed" "$log"
require_no_grep "gate failed" "$log"
if [[ $groups = 1 ]]; then
  # The slow Resume block runs after A's outline is out, so B proves
  # against that outline before A's proofs pass.
  require_before "pipeline: attempt done: BTheory" "pipeline: gate passed: ATheory" "$log"
fi
build_unpipelined pass BTheory "$fast" || { cat "$tmpdir/pass-off.log" >&2; exit 1; }
require_same_data pass A B

# With default flags, proof steps on, the instrumented script defers the
# groups the same way.  The target C saves checkpoints, so it builds on the
# committed B, which builds on A's outline.
cp -r "$tmpdir/pass" "$tmpdir/steps"
rm -rf "$tmpdir/steps/.holbuild"
cat > "$tmpdir/steps/src/CScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib BTheory;
val _ = new_theory "C";
val _ = export_theory();
SML
build_pipelined steps CTheory "" || { cat "$tmpdir/steps.log" >&2; exit 1; }
log=$tmpdir/steps.log
require_grep "pipeline: outline ready: ATheory" "$log"
require_grep "pipeline: gate passed: ATheory" "$log"
require_no_grep "attempt failed" "$log"
if [[ $groups = 1 ]]; then
  require_before "pipeline: attempt done: BTheory" "pipeline: gate passed: ATheory" "$log"
fi
build_unpipelined steps CTheory "" || { cat "$tmpdir/steps-off.log" >&2; exit 1; }
require_same_data steps A B

# Groups whose proofs are wrong, each in a theory of its own.  The
# pipelined attempt fails, or its gate does, and the theory builds plain,
# with the plain build's verdict: OK says whether that build passes.
check_fallback() {
  local name=$1 ok=$2 status=0 off_status=0
  cat > "$tmpdir/$name/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib ATheory;
val _ = new_theory "B";
val _ = export_theory();
SML
  build_pipelined "$name" BTheory "$fast" || status=$?
  build_unpipelined "$name" BTheory "$fast" || off_status=$?
  log=$tmpdir/$name.log
  if [[ $ok = 1 ]]; then
    [[ $status = 0 && $off_status = 0 ]] || { cat "$log" "$tmpdir/$name-off.log" >&2; exit 1; }
    require_same_data "$name" A
  else
    [[ $status != 0 && $off_status != 0 ]] || { cat "$log" "$tmpdir/$name-off.log" >&2; exit 1; }
  fi
  if [[ $groups = 1 ]] && ! grep -q -e "pipeline: attempt failed: ATheory" -e "pipeline: gate failed: ATheory" "$log"; then
    echo "expected A's pipelined attempt to fail in $log" >&2
    cat "$log" >&2
    exit 1
  fi
}

# A label that no `Resume` block proves: the outline suspends only the
# resumed one, and the group's proof leaves the other.
new_project unresolved
cat > "$tmpdir/unresolved/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib markerLib;
val _ = new_theory "A";
Theorem t:
  T /\ T
Proof
  CONJ_TAC >- suspend "a" >> suspend "b"
QED
Resume t[a]:
  ACCEPT_TAC TRUTH
QED
Finalise t
val _ = export_theory();
SML
check_fallback unresolved 0

# A Resume block that cites another theorem while it is still suspended.
new_project cites
cat > "$tmpdir/cites/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib markerLib;
val _ = new_theory "A";
Theorem other:
  T
Proof
  suspend "o"
QED
Theorem t:
  T
Proof
  suspend "a"
QED
Resume t[a]:
  ACCEPT_TAC other
QED
Resume other[o]:
  ACCEPT_TAC TRUTH
QED
Finalise other
Finalise t
val _ = export_theory();
SML
check_fallback cites 0

# A cheat behind a helper: the group is deferred, and its cheat appears
# only once it is proved, which the outline didn't predict.
new_project helper_cheat
cat > "$tmpdir/helper_cheat/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib markerLib;
val _ = new_theory "A";
fun skip g = cheat g;
Theorem t:
  T
Proof
  suspend "a"
QED
Resume t[a]:
  skip
QED
Finalise t
val _ = export_theory();
SML
check_fallback helper_cheat 1

# Two groups open at once that suspend the same goal under the same label,
# which a plain build rejects when it stashes the second.  (Not `T`, the
# first group's placeholder.)
new_project same_goal
cat > "$tmpdir/same_goal/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib markerLib;
val _ = new_theory "A";
Theorem t:
  F ==> F
Proof
  suspend "a"
QED
Theorem u:
  F ==> F
Proof
  suspend "a"
QED
Resume t[a]:
  simp[]
QED
Resume u[a]:
  simp[]
QED
Finalise t
Finalise u
val _ = export_theory();
SML
check_fallback same_goal 0
if [[ $groups = 1 ]]; then
  require_grep "suspend the same goal under the same label" "$tmpdir/same_goal.log"
fi

# The same with the second theorem in place (it isn't resumed here): the
# group stays in place too.
new_project same_goal_in_place
cat > "$tmpdir/same_goal_in_place/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib markerLib;
val _ = new_theory "A";
Theorem t:
  F ==> F
Proof
  suspend "a"
QED
Theorem u:
  F ==> F
Proof
  suspend "a"
QED
Resume t[a]:
  simp[]
QED
Finalise t
val _ = export_theory();
SML
check_fallback same_goal_in_place 0

# A group finalised [local] whose Resume block proves its goal from the
# theorem's own deferred stub, where a plain build has the suspended
# theorem itself, which proves nothing.
new_project own_stub
cat > "$tmpdir/own_stub/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib markerLib;
val _ = new_theory "A";
Theorem t:
  F
Proof
  suspend "a"
QED
Resume t[a]:
  mp_tac (REWRITE_RULE [markerTheory.suspendlabel_def] (DISCH_ALL t)) >> simp[]
QED
Finalise t[local]
val _ = export_theory();
SML
check_fallback own_stub 0

# A deferred local theorem proved from its own stub, through a reference
# the script sets after it: no theorem of the export depends on it, and the
# cycle is still found, so A builds plain, where the reference holds TRUTH.
new_project local_cycle
cat > "$tmpdir/local_cycle/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val r = ref TRUTH;
Triviality a_local:
  T
Proof
  (fn g => ACCEPT_TAC (!r) g)
QED
val _ = r := a_local;
val _ = export_theory();
SML
groups=1 check_fallback local_cycle 1
require_grep "deferred proofs depend on each other" "$tmpdir/local_cycle.log"
