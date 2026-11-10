#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"
project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"
[dependencies.hol]
git = "${HOLBUILD_TEST_HOL_GIT:-https://github.com/HOL-Theorem-Prover/HOL.git}"
rev = "$(holbuild_pinned_hol_rev)"
[project]
name = "staticerrors"
[build]
members = ["src"]
[actions.ATheory]
cache = false
TOML

write_source() {
  local first=$1 second=$2 suffix=$3
  cat > "$project/src/AScript.sml" <<SML
Theory A

Theorem first:
  T
Proof
  $first
QED

Theorem second:
  T
Proof
  $second
QED

(* $suffix *)
SML
}

for resume in context failed-prefix deps deps-only; do
  rm -rf "$project/.holbuild/checkpoints"
  if [[ "$resume" == failed-prefix ]]; then
    write_source 'ACCEPT_TAC TRUTH' 'FAIL_TAC "seed failed prefix"' seed
    if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/seed-$resume.log" 2>&1; then
      echo "expected seed tactic failure" >&2
      exit 1
    fi
    require_grep 'seed failed prefix' "$tmpdir/seed-$resume.log"
  else
    write_source 'ACCEPT_TAC TRUTH' 'ACCEPT_TAC first' seed
    (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/seed-$resume.log" 2>&1
  fi
  deps=$(find "$project/.holbuild/checkpoints" -name deps_loaded.save -print -quit)
  context=$(find "$project/.holbuild/checkpoints" -name first_context.save -print -quit)
  require_file "$deps"
  require_file "$context"
  if [[ "$resume" == deps-only ]]; then
    # Only the dependency context is left, as when no proof of the theory
    # has run from this context yet.
    find "$project/.holbuild/checkpoints" -type f ! -name 'deps_loaded.save*' -delete
  fi
  cp "$deps" "$tmpdir/deps.save"
  cp "$deps.ok" "$tmpdir/deps.save.ok"
  if [[ "$resume" != deps-only ]]; then
    cp "$context" "$tmpdir/context.save"
    cp "$context.ok" "$tmpdir/context.save.ok"
  fi
  for typo in missing_lemma_one missing_lemma_two; do
    if [[ "$resume" == deps* ]]; then
      write_source "ACCEPT_TAC $typo" 'ACCEPT_TAC first' broken
    else
      write_source 'ACCEPT_TAC TRUTH' "ACCEPT_TAC $typo" broken
    fi
    log=$tmpdir/$resume-$typo.log
    if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$log" 2>&1; then
      echo "accepted undeclared theorem $typo" >&2
      exit 1
    fi
    require_grep 'static error:' "$log"
    require_grep "$typo" "$log"
    if grep -q 'discarding invalid checkpoint' "$log"; then
      echo "source static error discarded a checkpoint" >&2
      exit 1
    fi
    if [[ $(grep -c '^resuming ATheory' "$log") -gt 1 ]]; then
      echo "source static error was retried from an earlier context" >&2
      exit 1
    fi
    cmp "$tmpdir/deps.save" "$deps"
    cmp "$tmpdir/deps.save.ok" "$deps.ok"
    if [[ "$resume" != deps-only ]]; then
      cmp "$tmpdir/context.save" "$context"
      cmp "$tmpdir/context.save.ok" "$context.ok"
    fi
  done
  write_source 'ACCEPT_TAC TRUTH' 'ACCEPT_TAC first' corrected
  log=$tmpdir/$resume-corrected.log
  (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$log" 2>&1
  require_grep 'from: .*checkpoint' "$log"
  require_file "$project/.holbuild/obj/src/ATheory.dat"
done
