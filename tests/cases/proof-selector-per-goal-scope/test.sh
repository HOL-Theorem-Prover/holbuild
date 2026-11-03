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
mkdir -p "$project"
write_schema2_prelude > "$project/holproject.toml"
cat >> "$project/holproject.toml" <<'TOML'
[project]
name = "proof-selector-per-goal-scope"
[build]
roots = ["SelectorScript.sml"]
TOML
cat > "$project/SelectorScript.sml" <<'SML'
Theory Selector
Ancestors arithmetic

Theorem nested_selection:
  ((0:num = 0) /\ T) /\ ((0:num = 0) /\ T)
Proof
  CONJ_TAC >>~- ([`_ /\ _`],
    CONJ_TAC >~ [`0:num = 0`] >- REFL_TAC >> ACCEPT_TAC TRUTH)
QED
SML

# Both matching conjunctions must get their own inner first-goal selection.
# Keep the default step budget and kernel checking on this regression.
(cd "$project" && "$HOLBUILD_BIN" build --skip-checkpoints --force=theory --trace-steps SelectorTheory) > "$tmpdir/steps.log" 2>&1
require_grep 'SelectorTheory built' "$tmpdir/steps.log"
require_file "$project/.holbuild/obj/SelectorTheory.dat"
(cd "$project" && "$HOLBUILD_BIN" execution-plan SelectorTheory:nested_selection) > "$tmpdir/plan.log" 2>&1
require_grep 'select matching-all .* solve' "$tmpdir/plan.log"
require_grep '  each' "$tmpdir/plan.log"
require_grep 'step REFL_TAC' "$tmpdir/plan.log"

(cd "$project" && "$HOLBUILD_BIN" build --skip-checkpoints --force=theory --skip-proof-steps SelectorTheory) > "$tmpdir/native.log" 2>&1
require_grep 'SelectorTheory built' "$tmpdir/native.log"
