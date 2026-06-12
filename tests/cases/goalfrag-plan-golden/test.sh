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

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "removed-goalfrag-plan"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem simple:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML

log=$tmpdir/goalfrag-plan.log
if (cd "$project" && "$HOLBUILD_BIN" goalfrag-plan ATheory:simple) > "$log" 2>&1; then
  echo "expected removed goalfrag-plan command to fail" >&2
  exit 1
fi
require_grep "goalfrag-plan has been removed; use execution-plan THEORY:THEOREM" "$log"

