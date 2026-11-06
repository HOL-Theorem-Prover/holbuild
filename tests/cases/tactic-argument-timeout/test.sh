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
mkdir -p "$project/src"
write_schema2_prelude > "$project/holproject.toml"
cat >> "$project/holproject.toml" <<'TOML'
[project]
name = "tactic-argument-timeout"

[build]
members = ["src"]
TOML

# A finite delay keeps a broken implementation from hanging the test runner.
# Construction prints a marker so we can distinguish the outer expression
# from the fragment and ensure it is not evaluated once per goal.
write_script() {
  local proof=$1
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
fun slow_rule th = (OS.Process.sleep (Time.fromReal 4.0); th);
fun counted_rule th = (print "TACTIC_ARGUMENT_CONSTRUCTED\n"; th);
SML
  printf '%s\n' "$proof" >> "$project/src/AScript.sml"
  printf 'val _ = export_theory();\n' >> "$project/src/AScript.sml"
}

expect_timeout() {
  local label=$1
  local log=$2
  shift 2
  if (cd "$project" && "$HOLBUILD_BIN" build --no-cache "$@" ATheory) > "$log" 2>&1; then
    echo "slow tactic argument was not timed out: $label" >&2
    exit 1
  fi
  require_grep "tactic timed out after 2.5s while building ATheory: $label" "$log"
  require_grep 'TacticTimeout' "$log"
}

write_script 'Theorem argument_timeout: T
Proof
  ALL_TAC >> ACCEPT_TAC (slow_rule TRUTH)
QED'
expect_timeout '.*ACCEPT_TAC (slow_rule TRUTH)' "$tmpdir/tactic.log"
# Check the non-checkpoint path too: it must still instrument proof steps.
expect_timeout '.*ACCEPT_TAC (slow_rule TRUTH)' "$tmpdir/no-checkpoints.log" --skip-checkpoints

write_script 'Theorem list_argument_timeout: T
Proof
  ALL_TAC >>> TACS_TO_LT [ACCEPT_TAC (slow_rule TRUTH)]
QED'
expect_timeout '.*TACS_TO_LT' "$tmpdir/list.log"

write_script 'Definition recursive_def:
  recursive n = if n = 0 then 0 else recursive (n - 1)
Termination
  ACCEPT_TAC (slow_rule TRUTH)
End'
expect_timeout '.*ACCEPT_TAC (slow_rule TRUTH)' "$tmpdir/termination.log"

write_script 'Theorem construct_once: T /\ T
Proof
  CONJ_TAC >> ACCEPT_TAC (counted_rule TRUTH)
QED'
(cd "$project" && "$HOLBUILD_BIN" build --no-cache ATheory) > "$tmpdir/once.log" 2>&1
log=$project/.holbuild/logs/current/tactic-argument-timeout/ATheory/build.log
require_file "$log"
if [[ $(grep -c '^TACTIC_ARGUMENT_CONSTRUCTED$' "$log") != 1 ]]; then
  echo "tactic argument was not constructed exactly once for the step" >&2
  exit 1
fi

write_script 'Theorem type_error: T
Proof
  ACCEPT_TAC 42
QED'
if (cd "$project" && "$HOLBUILD_BIN" build --no-cache ATheory) > "$tmpdir/type-error.log" 2>&1; then
  echo "ill-typed tactic argument was accepted" >&2
  exit 1
fi
require_grep 'Type error' "$tmpdir/type-error.log"
if grep -q 'TacticTimeout' "$tmpdir/type-error.log"; then
  echo "type error was reported as a timeout" >&2
  exit 1
fi
