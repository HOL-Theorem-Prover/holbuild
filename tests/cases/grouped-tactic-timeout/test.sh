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
name = "grouped-tactic-timeout"

[build]
members = ["src"]
TOML

cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
fun wait_tac g = (OS.Process.sleep (Time.fromReal 0.55); ALL_TAC g);
Theorem grouped_timeout_thm:
  T /\ T
Proof
  CONJ_TAC >- (wait_tac >> wait_tac >> ACCEPT_TAC TRUTH) >- ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML

build_log=$tmpdir/build.log
(cd "$project" && "$HOLBUILD_BIN" build --tactic-timeout 0.8 ATheory) > "$build_log" 2>&1
require_file "$project/.holbuild/obj/src/ATheory.dat"
if grep -q "tactic timed out while building ATheory" "$build_log"; then
  echo "grouped tactic was timed as one coarse step" >&2
  exit 1
fi
