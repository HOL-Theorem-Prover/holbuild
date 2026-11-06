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
name = "failed-prefix-parse-error"

[build]
members = ["src"]
TOML

# The Resume block is missing its QED, so HOL's source reader reports a parse
# error before the block's proof runs.  HOL remembers that error in the heap,
# and a checkpoint saved after it would keep it: a HOL run from it exits with
# failure after its first declaration, printing nothing.
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem partial:
  T /\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >- suspend "right"
QED

Resume partial[right]:
  ALL_TAC >> FAIL_TAC "first failure"

Finalise partial

val _ = export_theory();
SML

checkpoints=$project/.holbuild/checkpoints
first_log=$tmpdir/first.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$first_log" 2>&1; then
  echo "expected the first build to fail" >&2
  exit 1
fi
require_grep "expected 'QED'" "$first_log"
require_grep 'first failure' "$first_log"
if [[ -z "$(find "$checkpoints" -name 'partial_context.save' -print -quit)" ]]; then
  echo "expected the checkpoint saved before the parse error to stay" >&2
  find "$checkpoints" >&2
  exit 1
fi
if [[ -n "$(find "$checkpoints" -name '*failed_prefix*' -print -quit)" ]]; then
  echo "saved a failed-prefix checkpoint after a parse error" >&2
  find "$checkpoints" >&2
  exit 1
fi

# With the parse error fixed, the build resumes from the theorem's checkpoint
# and reports the proof's own failure.
write_source() {
  cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem partial:
  T /\\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >- suspend "right"
QED

Resume partial[right]:
  ALL_TAC >> FAIL_TAC "$1"
QED

Finalise partial

val _ = export_theory();
SML
}
write_source "second failure"
second_log=$tmpdir/second.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$second_log" 2>&1; then
  echo "expected the second build to fail" >&2
  exit 1
fi
require_grep 'from: theorem-context checkpoint after partial' "$second_log"
require_grep 'failed tactic top input goal:' "$second_log"
require_grep 'second failure' "$second_log"
fp=$(find "$checkpoints" -path '*/.failed/partial_right__failed_prefix.save' -print -quit)
if [[ -z "$fp" ]]; then
  echo "expected a failed-prefix checkpoint from the second build" >&2
  find "$checkpoints" >&2
  exit 1
fi

# Holbuild before 0.13.7 saved failed-prefix checkpoints after a parse error.
# Make one: reload this one, report a parse error, and save it again in place.
cat > "$tmpdir/bad.sml" <<'SML'
Theorem bad: T
Proof
  ALL_TAC
SML
cat > "$tmpdir/poison.sml" <<SML
val _ =
  (QUse.failOnError := false;
   QUse.use "$tmpdir/bad.sml" handle _ => ();
   if QUse.hadError () then () else raise Fail "no parse error";
   PolyML.SaveState.saveChild ("$tmpdir/poisoned.save",
                               length (PolyML.SaveState.showHierarchy ()) - 1));
SML
# hol run exits with failure after the parse error, once the heap is saved.
"$HOLDIR/bin/hol" run --noconfig --holstate "$fp" "$tmpdir/poison.sml" > "$tmpdir/poison.log" 2>&1 || true
if [[ ! -f "$tmpdir/poisoned.save" ]]; then
  echo "could not make a poisoned failed-prefix checkpoint" >&2
  cat "$tmpdir/poison.log" >&2
  exit 1
fi
mv "$tmpdir/poisoned.save" "$fp"

# The build discards it and resumes from the theorem's checkpoint instead.
write_source "third failure"
third_log=$tmpdir/third.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$third_log" 2>&1; then
  echo "expected the third build to fail" >&2
  exit 1
fi
require_grep 'from: failed-prefix checkpoint' "$third_log"
require_grep 'discarding failed-prefix checkpoint after failed resume: .*/partial_right__failed_prefix.save' "$third_log"
require_grep 'failed tactic top input goal:' "$third_log"
require_grep 'third failure' "$third_log"
