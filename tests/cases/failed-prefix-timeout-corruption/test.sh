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
name = "failed-prefix-timeout-corruption"

[build]
members = ["src"]
TOML

cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

fun sleep_tac g = (OS.Process.sleep (Time.fromReal 0.4); ALL_TAC g);

Theorem timeout_prefix:
  T /\ T
Proof
  CONJ_TAC >> sleep_tac >> ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML

low_log=$tmpdir/low.log
if (cd "$project" && "$HOLBUILD_BIN" build --tactic-timeout 0.1 ATheory) > "$low_log" 2>&1; then
  echo "expected initial tactic timeout" >&2
  exit 1
fi
require_grep "tactic timed out" "$low_log"
fp=$(find "$project/.holbuild/checkpoints" -path '*/.failed/timeout_prefix_failed_prefix.save' -print -quit)
if [[ -z "$fp" || ! -e "$fp.ok" ]]; then
  echo "expected timeout failure to save a failed-prefix checkpoint for the completed prefix" >&2
  find "$project/.holbuild/checkpoints" -print >&2 || true
  exit 1
fi

retry_log=$tmpdir/retry.log
(cd "$project" && "$HOLBUILD_BIN" build --tactic-timeout 2 ATheory) > "$retry_log" 2>&1
require_grep "from: failed-prefix checkpoint in timeout_prefix" "$retry_log"
require_grep "ATheory built" "$retry_log"
require_file "$project/.holbuild/obj/src/ATheory.dat"
