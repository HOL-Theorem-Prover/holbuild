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
val _ = store_thm("TRIVIAL", ``T``, ACCEPT_TAC TRUTH);
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

trace="$project/.holbuild/obj/src/ATheory.tr.gz"
remapped="$project/.holbuild/obj/src/.hol/objs/ATheory.tr.gz"

first_log=$tmpdir/first.log
(cd "$project" && trknl_holbuild build --trknl ATheory) > "$first_log" 2>&1
require_file "$trace"
require_file "$remapped"
if [[ ! -s "$trace" ]]; then
  echo "trace output is empty: $trace" >&2
  exit 1
fi

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
