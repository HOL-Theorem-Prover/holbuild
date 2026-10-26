#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

require_no_grep() {
  local pattern=$1
  local path=$2
  if grep -q "$pattern" "$path"; then
    echo "unexpected pattern '$pattern' in $path" >&2
    exit 1
  fi
}

run_from() {
  local log=$1
  shift
  if ! (cd "$project" && "$HOLBUILD_BIN" run "$@") > "$log" 2>&1; then
    cat "$log" >&2
    exit 1
  fi
}

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
# [run].heap names the toolchain's own base state, so the precedence of --from
# over [run].heap is observable without building a separate heap.
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "runfrom"

[build]
members = ["src"]

[run]
heap = "$HOLDIR/bin/hol.state"
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib ATheory;
val _ = new_theory "B";
val b_thm = store_thm("b_thm", ``T``, ACCEPT_TAC a_thm);
val _ = export_theory();
SML

cat > "$project/src/Util.sml" <<'SML'
structure Util = struct val marker = true end
SML

(cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/build.log" 2>&1 ||
  { cat "$tmpdir/build.log" >&2; exit 1; }

deps_script=$tmpdir/deps.sml
cat > "$deps_script" <<'SML'
val _ = (ATheory.a_thm; print "DEPS_LOADED_BOUND_OK\n");
SML

# Current final_context: BTheory is bound before any load, and loading it again
# is a no-op rather than a second copy of the theory.
final_script=$tmpdir/final.sml
cat > "$final_script" <<'SML'
val _ = (BTheory.b_thm; print "FINAL_CONTEXT_BOUND_OK\n");
val _ = load "BTheory";
val _ = print "FINAL_CONTEXT_RELOAD_OK\n";
SML
final_log=$tmpdir/final.log
run_from "$final_log" --from BTheory "$final_script"
require_grep "holbuild: --from BTheory: starting from its final_context checkpoint" "$final_log"
require_grep "FINAL_CONTEXT_BOUND_OK" "$final_log"
require_grep "FINAL_CONTEXT_RELOAD_OK" "$final_log"

repl_log=$tmpdir/repl.log
printf 'val _ = (BTheory.b_thm; print "REPL_FROM_OK\\n");\n' |
  (cd "$project" && timeout 60 "$HOLBUILD_BIN" repl --from=BTheory) > "$repl_log" 2>&1
require_grep "starting from its final_context checkpoint" "$repl_log"
require_grep "REPL_FROM_OK" "$repl_log"

# A --from session exports theories with the same trace settings as a plain run,
# not the build child policy its checkpoint was saved under.
trace_script=$tmpdir/trace.sml
cat > "$trace_script" <<'SML'
val _ = print ("HTML_DOCS=" ^ Int.toString (Feedback.current_trace "TheoryPP.include_html_docs") ^ "\n");
SML
run_from "$tmpdir/plain-trace.log" "$trace_script"
plain_trace=$(grep -o 'HTML_DOCS=[0-9]*' "$tmpdir/plain-trace.log")
run_from "$tmpdir/from-trace.log" --from BTheory "$trace_script"
require_grep "$plain_trace" "$tmpdir/from-trace.log"

# Only BTheory is stale: its ancestors come from deps_loaded.
sed -i 's/^val _ = export_theory();$/val b2_thm = store_thm("b2_thm", ``T``, ACCEPT_TAC TRUTH);\nval _ = export_theory();/' \
  "$project/src/BScript.sml"
deps_log=$tmpdir/deps.log
run_from "$deps_log" --from BTheory "$deps_script"
require_grep "holbuild: --from BTheory: no final_context checkpoint for its current source; starting from its deps_loaded checkpoint" "$deps_log"
require_grep "DEPS_LOADED_BOUND_OK" "$deps_log"

# A stale dependency invalidates both checkpoints: fall back to [run].heap.
sed -i 's/ACCEPT_TAC TRUTH);/ACCEPT_TAC TRUTH);\nval a2_thm = store_thm("a2_thm", ``T``, ACCEPT_TAC TRUTH);/' \
  "$project/src/AScript.sml"
fallback_script=$tmpdir/fallback.sml
cat > "$fallback_script" <<'SML'
val _ = print "FALLBACK_RUN_OK\n";
SML
stale_log=$tmpdir/stale.log
run_from "$stale_log" --from BTheory "$fallback_script"
require_grep "holbuild: --from BTheory: the dependencies of BTheory changed since its checkpoints were saved; starting from \[run\].heap $HOLDIR/bin/hol.state" "$stale_log"
require_grep "FALLBACK_RUN_OK" "$stale_log"
require_no_grep "starting from its" "$stale_log"

# A cache hit leaves no checkpoint at all.
(cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/rebuild.log" 2>&1 ||
  { cat "$tmpdir/rebuild.log" >&2; exit 1; }
rm -rf "$project/.holbuild"
(cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/cache-hit.log" 2>&1 ||
  { cat "$tmpdir/cache-hit.log" >&2; exit 1; }
cache_log=$tmpdir/cache.log
run_from "$cache_log" --from BTheory "$fallback_script"
require_grep "holbuild: --from BTheory: BTheory has no current checkpoint (not built yet, restored from the cache, built with --skip-checkpoints, or removed by gc); starting from \[run\].heap" "$cache_log"
require_grep "FALLBACK_RUN_OK" "$cache_log"

# A static error discards and rewrites deps_loaded; the final_context saved on
# top of the old deps_loaded must go with it, even once the source is reverted.
sed -i 's/^val _ = export_theory();$/val b3_thm = store_thm("b3_thm", ``T``, ACCEPT_TAC TRUTH);\nval _ = export_theory();/' \
  "$project/src/BScript.sml"
(cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/fresh.log" 2>&1 ||
  { cat "$tmpdir/fresh.log" >&2; exit 1; }
run_from "$tmpdir/fresh-run.log" --from BTheory "$final_script"
require_grep "starting from its final_context checkpoint" "$tmpdir/fresh-run.log"
cp "$project/src/BScript.sml" "$tmpdir/BScript.sml.good"
sed -i 's/^val _ = export_theory();$/val bad : int = "typo";\nval _ = export_theory();/' \
  "$project/src/BScript.sml"
if (cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/static-error.log" 2>&1; then
  echo "build accepted a static error" >&2
  exit 1
fi
cp "$tmpdir/BScript.sml.good" "$project/src/BScript.sml"
reverted_log=$tmpdir/reverted.log
run_from "$reverted_log" --from BTheory "$deps_script"
require_grep "starting from its deps_loaded checkpoint" "$reverted_log"
require_grep "DEPS_LOADED_BOUND_OK" "$reverted_log"

unknown_log=$tmpdir/unknown.log
if (cd "$project" && "$HOLBUILD_BIN" run --from MissingTheory "$fallback_script") > "$unknown_log" 2>&1; then
  echo "run accepted an unknown --from theory" >&2
  exit 1
fi
require_grep "holbuild: --from MissingTheory: unknown build target: MissingTheory" "$unknown_log"
require_no_grep "FALLBACK_RUN_OK" "$unknown_log"

unknown_path_log=$tmpdir/unknown-path.log
if (cd "$project" && "$HOLBUILD_BIN" run --from src/MissingScript.sml "$fallback_script") > "$unknown_path_log" 2>&1; then
  echo "run accepted an unknown --from path" >&2
  exit 1
fi
require_grep "holbuild: --from src/MissingScript.sml: build target path is not a known source: src/MissingScript.sml" "$unknown_path_log"

library_log=$tmpdir/library.log
if (cd "$project" && "$HOLBUILD_BIN" run --from Util "$fallback_script") > "$library_log" 2>&1; then
  echo "run accepted a non-theory --from target" >&2
  exit 1
fi
require_grep "holbuild: --from requires a theory target, not Util" "$library_log"
