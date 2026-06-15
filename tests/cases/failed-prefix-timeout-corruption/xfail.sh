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

fun corrupt_history_then_sleep_tac g =
  (HolbuildProofRuntime.append_history (goalStack.expandf (ACCEPT_TAC TRUTH));
   OS.Process.sleep (Time.fromReal 0.4);
   ALL_TAC g);

Theorem timeout_poison:
  T /\ T
Proof
  CONJ_TAC >> corrupt_history_then_sleep_tac >> ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML

low_log=$tmpdir/low.log
if (cd "$project" && "$HOLBUILD_BIN" build --tactic-timeout 0.1 ATheory) > "$low_log" 2>&1; then
  echo "expected initial tactic timeout" >&2
  exit 1
fi
require_grep "tactic timed out" "$low_log"
fp=$(find "$project/.holbuild/checkpoints" -path '*/.failed/timeout_poison_failed_prefix.save' -print -quit)
if [[ -n "$fp" && -e "$fp.ok" ]]; then
  echo "timeout failure saved a failed-prefix checkpoint; this can serialize an asynchronously interrupted proof state" >&2
  echo "$fp" >&2
  exit 1
fi
