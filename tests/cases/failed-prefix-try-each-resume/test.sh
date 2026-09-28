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

project=$tmpdir/project
marker=$tmpdir/suffix-ready
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "failed-prefix-try-each-resume"

[build]
members = ["src"]
TOML

cat > "$project/src/AScript.sml" <<SML
Theory A

fun suffix_tac (asl, goal) =
  if OS.FileSys.access ("$marker", []) then
    DECIDE_TAC (asl, goal)
  else
    let
      val out = TextIO.openOut "$marker"
      val _ = TextIO.closeOut out
    in
      raise Fail "seed suffix failure"
    end;

Theorem try_each_resume:
  (1 = 1) /\\ T
Proof
  rpt CONJ_TAC >>
  TRY (ACCEPT_TAC TRUTH >> NO_TAC) >>
  TRY (ALL_TAC >> NO_TAC) >>
  suffix_tac
QED
SML

# The first TRY closes only the T goal, making its final NO_TAC the latest
# committed successful leaf.  In the sibling TRY, ALL_TAC records a transient
# successful leaf before NO_TAC fails and TRY rolls the goal state back.  The
# runtime snapshot currently omits successful_leaf_snapshots_ref, so that
# transient leaf leaks into failed-prefix metadata.  Salvage then mistakes it
# for the resume endpoint and resumes immediately before the sibling NO_TAC.
seed_log=$tmpdir/seed.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$seed_log" 2>&1; then
  echo "expected failed-prefix TRY/Each seed build to fail" >&2
  exit 1
fi
require_grep "seed suffix failure" "$seed_log"
require_file "$marker"

checkpoint=$(find "$project/.holbuild/checkpoints" -name 'try_each_resume_failed_prefix.save' -print -quit)
require_file "$checkpoint"
require_file "$checkpoint.meta"
require_grep '^path=.*each:.*try/' "$checkpoint.meta"
require_grep $'leaf_signature=step\t(NO_TAC)' "$checkpoint.meta"

# The marker makes the unchanged suffix succeed on the second run.  Resuming
# from the nested TRY/Each endpoint must preserve ordinary TRY rollback for the
# following sibling TRY.  The current bug lets that sibling's expected NO_TAC
# escape, making this assertion red until failed-prefix restoration is fixed.
resume_log=$tmpdir/resume.log
if ! (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$resume_log" 2>&1; then
  cat "$resume_log" >&2
  echo "failed-prefix resume leaked an expected failure from a sibling TRY under Each" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in try_each_resume" "$resume_log"
if grep -q "discarding failed-prefix checkpoint after failed resume" "$resume_log"; then
  cat "$resume_log" >&2
  echo "failed-prefix metadata retained a transient successful leaf from a rolled-back TRY" >&2
  exit 1
fi
require_file "$project/.holbuild/obj/src/ATheory.dat"
