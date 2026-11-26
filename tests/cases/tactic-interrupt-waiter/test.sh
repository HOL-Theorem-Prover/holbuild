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

# When Poly/ML runs out of heap it broadcasts Interrupt to every thread,
# including the one that waits for the tactic in the timeout.  The step is
# reported as interrupted, not as a timeout or a raw Interrupt, and its thread
# is stopped even though the tactic swallows interrupts.  broadcast_tac
# broadcasts an Interrupt itself, as the runtime would, then spins swallowing
# interrupts.
write_project() {
  local project=$1 proof=$2
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)

[project]
name = "tactic-interrupt-waiter"

[build]
members = ["src"]
TOML
  cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

val broadcast_tac : tactic = fn _ =>
  ((Thread.broadcastInterrupt ()) handle Interrupt => ();
   while true do ((Thread.testInterrupt ()) handle Interrupt => ());
   raise Fail "unreachable");

Theorem t:
  T /\\ T
Proof
$proof
QED

val _ = export_theory();
SML
}

for proof in "  CONJ_TAC >> broadcast_tac >> simp[]"; do
  project=$tmpdir/project
  rm -rf "$project"
  write_project "$project" "$proof"
  if (cd "$project" && "$HOLBUILD_BIN" build --tactic-timeout 30 ATheory) > "$tmpdir/build.log" 2>&1; then
    echo "build succeeded although a step was interrupted: $proof" >&2
    cat "$tmpdir/build.log" >&2
    exit 1
  fi
  require_grep "holbuild tactic interrupted by Poly/ML (stack overflow or out of memory): broadcast_tac" "$tmpdir/build.log"
  # Only kill stops a thread that swallows interrupts.
  require_grep "HolbuildProofRuntime.interruptkill: thread killed" \
    "$project/.holbuild/logs/current/tactic-interrupt-waiter/ATheory/build.log"
  if grep -q "timed out" "$tmpdir/build.log"; then
    echo "interrupted step was reported as a timeout: $proof" >&2
    cat "$tmpdir/build.log" >&2
    exit 1
  fi
done
