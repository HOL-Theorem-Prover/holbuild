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

if [[ -z "${HOLBUILD_TRKNL_POLY:-}" ]]; then
  echo "SKIP trknl: HOLBUILD_TRKNL_POLY is not set"
  exit 0
fi

trknl_holbuild() {
  HOLBUILD_POLY="$HOLBUILD_TRKNL_POLY" "$HOLBUILD_BIN" "$@"
}

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "trknl"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem TRIVIAL:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML

traced_holdir=$(cd "$project" && trknl_holbuild buildhol --trknl | tail -n 1)
if [[ ! -d "$traced_holdir" ]]; then
  echo "tracing toolchain directory not found: $traced_holdir" >&2
  exit 1
fi
if [[ "$traced_holdir" == "$HOLDIR" ]]; then
  echo "standard and tracing kernels resolved to the same toolchain: $traced_holdir" >&2
  exit 1
fi

standard_graph=$tmpdir/standard.graph
tracing_graph=$tmpdir/tracing.graph
(cd "$project" && HOLBUILD_TEST_RESOLVED_GRAPH="$standard_graph" \
  "$HOLBUILD_BIN" build --dry-run ATheory) > "$tmpdir/standard-plan.log"
(cd "$project" && HOLBUILD_TEST_RESOLVED_GRAPH="$tracing_graph" \
  trknl_holbuild build --trknl --dry-run ATheory) > "$tmpdir/tracing-plan.log"
[[ $(grep '^selected-graph-id ' "$standard_graph") == $(grep '^selected-graph-id ' "$tracing_graph") ]]
[[ $(grep '^selected-plan-id ' "$standard_graph") == $(grep '^selected-plan-id ' "$tracing_graph") ]]
[[ $(grep '^resolved-plan-id ' "$standard_graph") != $(grep '^resolved-plan-id ' "$tracing_graph") ]]

trace="$project/.holbuild/obj/src/ATheory.tr.gz"
remapped="$project/.holbuild/obj/src/.hol/objs/ATheory.tr.gz"

require_no_checkpoints() {
  if find "$project/.holbuild/checkpoints" \( -name '*.save' -o -name '*.save.ok' \) -print -quit 2>/dev/null | grep -q .; then
    echo "$1 created checkpoint files" >&2
    exit 1
  fi
}

# A tracing build defaults to --skip-checkpoints --skip-proof-steps.
first_log=$tmpdir/first.log
first_timing=$tmpdir/first.tool-timing
(cd "$project" && HOLBUILD_TIMING_LOG="$first_timing" HOLBUILD_TIMING_DETAIL=fine \
  HOLBUILD_CHECKPOINT_TIMING=1 HOLBUILD_ECHO_CHILD_LOGS=1 \
  trknl_holbuild build --trknl ATheory) > "$first_log" 2>&1
require_file "$trace"
require_file "$remapped"
if [[ ! -s "$trace" ]]; then
  echo "trace output is empty: $trace" >&2
  exit 1
fi
if grep -q "holbuild checkpoint kind=" "$first_log"; then
  echo "--trknl build saved checkpoints" >&2
  exit 1
fi
require_no_checkpoints "--trknl build"
if grep -q $'^phase\tname=build\.exec\.node\.proof_ir_plan\t' "$first_timing"; then
  echo "--trknl build ran proof steps" >&2
  exit 1
fi

# An explicit debugging flag turns proof steps back on.
steps_log=$tmpdir/trace-steps.log
steps_timing=$tmpdir/trace-steps.tool-timing
rm -f "$trace" "$remapped"
(cd "$project" && HOLBUILD_TIMING_LOG="$steps_timing" HOLBUILD_TIMING_DETAIL=fine \
  trknl_holbuild build --trknl --force --trace-steps ATheory) > "$steps_log" 2>&1
require_grep "proof step trace log:" "$steps_log"
require_grep $'^phase\tname=build\.exec\.node\.proof_ir_plan\tstatus=ok\tms=' "$steps_timing"
require_file "$trace"
require_file "$remapped"
require_no_checkpoints "--trknl --trace-steps build"

hash_log=$tmpdir/output-hashes.log
(cd "$project" && trknl_holbuild build --force --emit-output-hashes --trknl ATheory) > "$hash_log" 2>&1
metadata="$project/.holbuild/dep/trknl/src/AScript.sml.key"
for output in "$trace" "$remapped"; do
  expected=$(sha1sum "$output" | awk '{print $1}')
  require_grep "^output-sha1=$output $expected$" "$metadata"
done

second_log=$tmpdir/second.log
(cd "$project" && trknl_holbuild --verbose build --trknl ATheory) > "$second_log" 2>&1
require_grep "ATheory is up to date" "$second_log"

rm -f "$trace" "$remapped"
missing_trace_log=$tmpdir/missing-trace.log
(cd "$project" && HOLBUILD_CACHE_TRACE=1 trknl_holbuild build --trknl ATheory) > "$missing_trace_log" 2>&1
require_file "$trace"
require_file "$remapped"
require_grep "ATheory restored from cache" "$missing_trace_log"

rm -f "$trace" "$remapped"
normal_log=$tmpdir/normal.log
(cd "$project" && "$HOLBUILD_BIN" --verbose build ATheory) > "$normal_log" 2>&1
if grep -q "tracing kernel did not produce expected proof trace" "$normal_log"; then
  echo "normal build unexpectedly required trace output" >&2
  exit 1
fi
if [[ -e "$trace" || -e "$remapped" ]]; then
  echo "normal build unexpectedly produced tracing-kernel outputs" >&2
  exit 1
fi
