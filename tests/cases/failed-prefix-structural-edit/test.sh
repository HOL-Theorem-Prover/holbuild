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
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "failed-prefix-structural-edit"

[build]
members = ["src"]
TOML

write_script() {
  local selected=$1
  cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem selector_edit:
  T ∧ F
Proof
  CONJ_TAC
  >>~- ([\`$selected\`], ALL_TAC >> FAIL_TAC "selector suffix failure")
QED

val _ = export_theory();
SML
}

failed_top_goal() {
  local build_log=$1
  local instrumented_log
  instrumented_log=$(awk -F'instrumented log: ' '/instrumented log: / {print $2}' "$build_log" | tail -n 1)
  require_file "$instrumented_log"
  python3 - "$instrumented_log" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
start = "holbuild failed tactic top input goal:\n"
end = "holbuild end failed tactic top input goal"
if start not in text or end not in text.split(start, 1)[1]:
    raise SystemExit(f"missing failed top-goal markers in {sys.argv[1]}")
print(text.split(start, 1)[1].split(end, 1)[0].strip())
PY
}

# Seed a failed-prefix heap while the structural selector focuses the T goal.
write_script T
seed_log=$tmpdir/seed.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$seed_log" 2>&1; then
  echo "expected selector seed proof to fail" >&2
  exit 1
fi
require_grep "selector suffix failure" "$seed_log"
seed_checkpoint=$(find "$project/.holbuild/checkpoints" -name 'selector_edit_failed_prefix.save' -print -quit)
require_file "$seed_checkpoint"
require_file "$seed_checkpoint.meta"

# This equal-length edit preserves the body leaf, its path, and all following
# source offsets, but changes the semantics of the enclosing selector.
write_script F
incremental_log=$tmpdir/incremental.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$incremental_log" 2>&1; then
  echo "expected edited selector proof to fail" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in selector_edit" "$incremental_log"
require_grep "selector suffix failure" "$incremental_log"
incremental_goal=$(failed_top_goal "$incremental_log")

# Establish the authoritative result by executing exactly the same edited source
# without any source-level checkpoint. Incremental replay must agree with it.
rm -rf "$project/.holbuild/checkpoints"
clean_log=$tmpdir/clean.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$clean_log" 2>&1; then
  echo "expected clean edited selector proof to fail" >&2
  exit 1
fi
require_grep "selector suffix failure" "$clean_log"
clean_goal=$(failed_top_goal "$clean_log")

if [[ "$incremental_goal" != "$clean_goal" ]]; then
  printf '%s\n' \
    "failed-prefix replay after selector edit disagrees with clean execution" \
    "incremental goal:" \
    "$incremental_goal" \
    "clean goal:" \
    "$clean_goal" >&2
  exit 1
fi

if [[ "$clean_goal" != "F" ]]; then
  printf 'expected edited selector to focus F, got:\n%s\n' "$clean_goal" >&2
  exit 1
fi
