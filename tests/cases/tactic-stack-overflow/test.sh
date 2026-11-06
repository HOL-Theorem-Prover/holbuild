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

# Poly/ML raises Interrupt in a thread whose stack can't grow.  A step
# interrupted before its tactic timeout is reported as a stack overflow, not as
# a timeout, and TRY doesn't take its failure branch for it.  overflow_tac
# raises Interrupt itself, as the runtime would, without exhausting memory.
write_project() {
  local project=$1 proof=$2
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "tactic-stack-overflow"

[build]
members = ["src"]
TOML
  cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

val overflow_tac : tactic = fn _ => raise Interrupt;

Theorem t:
  T /\\ T
Proof
$proof
QED

val _ = export_theory();
SML
}

for proof in "  CONJ_TAC >> overflow_tac >> simp[]" "  CONJ_TAC >> TRY overflow_tac >> simp[]"; do
  project=$tmpdir/project
  rm -rf "$project"
  write_project "$project" "$proof"
  if (cd "$project" && "$HOLBUILD_BIN" build --tactic-timeout 30 ATheory) > "$tmpdir/build.log" 2>&1; then
    echo "build succeeded although a step was interrupted: $proof" >&2
    cat "$tmpdir/build.log" >&2
    exit 1
  fi
  require_grep "holbuild tactic stack overflow (interrupted by Poly/ML): overflow_tac" "$tmpdir/build.log"
  if grep -q "timed out" "$tmpdir/build.log"; then
    echo "interrupted step was reported as a timeout: $proof" >&2
    cat "$tmpdir/build.log" >&2
    exit 1
  fi
done
