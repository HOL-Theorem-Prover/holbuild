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
name = "diamond"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open ATheory;
val _ = new_theory "B";
val b_thm = store_thm("b_thm", ``T``, ACCEPT_TAC ATheory.a_thm);
val _ = export_theory();
SML
cat > "$project/src/CScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open ATheory;
val _ = new_theory "C";
val c_thm = store_thm("c_thm", ``T``, ACCEPT_TAC ATheory.a_thm);
val _ = export_theory();
SML
cat > "$project/src/DScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open BTheory CTheory;
val _ = new_theory "D";
val d_thm = store_thm("d_thm", ``T /\ T``, CONJ_TAC THENL [ACCEPT_TAC BTheory.b_thm, ACCEPT_TAC CTheory.c_thm]);
val _ = export_theory();
SML

dry_log=$tmpdir/dry.log
(cd "$project" && "$HOLBUILD_BIN" build --dry-run DTheory) > "$dry_log"
require_grep "ATheory" "$dry_log"
require_grep "BTheory" "$dry_log"
require_grep "CTheory" "$dry_log"
require_grep "DTheory" "$dry_log"

(cd "$project" && "$HOLBUILD_BIN" -j2 build DTheory)
# checkpoints persist after successful builds for incremental rebuilds

second_log=$tmpdir/second.log
(cd "$project" && "$HOLBUILD_BIN" --verbose build DTheory) > "$second_log"
require_grep "DTheory is up to date" "$second_log"
