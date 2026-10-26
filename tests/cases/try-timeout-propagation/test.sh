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

# A tactic timeout is not a tactic failure.  TRY, ORELSE and rpt must not take
# their failure branch when a body times out: the build fails at the step that
# timed out, and no checkpoint lets a later run skip that body.  The failed
# prefix is saved at the combinator's entry, after the steps before it.
write_project() {
  local project=$1 name=$2 proof=$3
  mkdir -p "$project/src"
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
  cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

fun slow_tac g = (OS.Process.sleep (Time.fromReal 3.0); ALL_TAC g);
fun count_tac g = (OS.Process.sleep (Time.fromReal 3.0); NO_TAC g);

Theorem t:
  T /\\ T
Proof
$proof
QED

val _ = export_theory();
SML
}

has_checkpoint() {
  local project=$1 name=$2
  find "$project/.holbuild/checkpoints" -name "$name" -print -quit 2>/dev/null | grep -q .
}

require_timeout_failure() {
  local case_name=$1 step=$2
  local project=$tmpdir/$case_name
  local log=$tmpdir/$case_name.log
  if (cd "$project" && "$HOLBUILD_BIN" --json build --tactic-timeout 1 ATheory) > "$log" 2>&1; then
    echo "$case_name: build succeeded although a step exceeded the tactic timeout" >&2
    cat "$log" >&2
    exit 1
  fi
  require_grep "tactic timed out after 1.0s while building ATheory: $step" "$log"
  require_grep "holbuild tactic timeout after 1.0s: $step" "$log"
  require_grep '"kind":"tactic_timeout"' "$log"
  if has_checkpoint "$project" 't_end_of_proof.save'; then
    echo "$case_name: timed-out proof saved an end-of-proof checkpoint" >&2
    exit 1
  fi
}

# A failed-prefix checkpoint inside a TRY or ORELSE body would let a resumed
# run commit to that body without rerunning the combinator that chose it, so
# the checkpoint ends at CONJ_TAC, the last step before the combinator.
require_failed_prefix_at_entry() {
  local case_name=$1
  local meta
  meta=$(find "$tmpdir/$case_name/.holbuild/checkpoints" -name 't_failed_prefix.save.meta' -print -quit)
  if [[ -z "$meta" ]]; then
    echo "$case_name: no failed-prefix checkpoint before the timed-out combinator" >&2
    exit 1
  fi
  require_grep '^step_count=1$' "$meta"
}

write_project "$tmpdir/try" try "  CONJ_TAC >> TRY slow_tac >> simp[]"
require_timeout_failure try slow_tac
require_grep "plan position: 03 step slow_tac" "$tmpdir/try.log"
require_failed_prefix_at_entry try

# With a longer timeout the build resumes from that checkpoint and reruns TRY.
(cd "$tmpdir/try" && "$HOLBUILD_BIN" build --tactic-timeout 10 ATheory) > "$tmpdir/try-resume.log" 2>&1
require_grep "from: failed-prefix checkpoint in t" "$tmpdir/try-resume.log"
require_grep "restoring proof-ir prefix with 1 successful leaf steps" "$tmpdir/try-resume.log"
require_grep "ATheory built" "$tmpdir/try-resume.log"

write_project "$tmpdir/orelse" orelse "  CONJ_TAC >> (slow_tac ORELSE ALL_TAC) >> simp[]"
require_timeout_failure orelse slow_tac
require_grep "plan position: 04 step slow_tac" "$tmpdir/orelse.log"
require_failed_prefix_at_entry orelse

# The proof plan runs rpt as one step, timed as a whole.
write_project "$tmpdir/rpt" rpt "  CONJ_TAC >> rpt count_tac >> simp[]"
require_timeout_failure rpt "rpt count_tac"

# A TRY body that fails before the timeout still takes TRY's failure branch.
fast=$tmpdir/fast
write_project "$fast" fast "  CONJ_TAC >> TRY NO_TAC >> simp[]"
(cd "$fast" && "$HOLBUILD_BIN" build --tactic-timeout 1 ATheory) > "$tmpdir/fast.log" 2>&1
require_grep "ATheory built" "$tmpdir/fast.log"
require_file "$fast/.holbuild/obj/src/ATheory.dat"
has_checkpoint "$fast" 't_end_of_proof.save' || {
  echo "fast: no end-of-proof checkpoint, so the absence check above proves nothing" >&2
  exit 1
}
