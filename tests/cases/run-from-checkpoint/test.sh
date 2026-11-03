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

# A dependency package with a theory, and a .sig/.sml pair sharing one name.
lib=$tmpdir/lib
mkdir -p "$lib/src"
{
  write_schema2_prelude
  cat <<'TOML'
[project]
name = "lib"

[build]
members = ["src"]
TOML
} > "$lib/holproject.toml"
cat > "$lib/src/CScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "C";
val c_thm = store_thm("c_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
cat > "$lib/src/Foo.sig" <<'SML'
signature FOO = sig val value : bool end
SML
cat > "$lib/src/Foo.sml" <<'SML'
structure Foo : FOO = struct val value = true end
SML
lib_rev=$(init_git_repo "$lib")

project=$tmpdir/project
mkdir -p "$project/src"
# [run].heap is a second name for the HOL base state, so a session's loaded
# state hierarchy shows whether it started from [run].heap, without building a
# separate heap.
run_heap=$tmpdir/run.heap
ln -s "$HOLDIR/bin/hol.state" "$run_heap"
write_manifest() {
  {
    write_schema2_prelude
    cat <<TOML
[project]
name = "runfrom"

[build]
members = ["src"]

[dependencies.lib]
git = "$lib"
rev = "$lib_rev"
TOML
    if [[ $1 == with-heap ]]; then
      printf '\n[run]\nheap = "%s"\n' "$run_heap"
    fi
  } > "$project/holproject.toml"
}
write_manifest with-heap
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib ATheory CTheory;
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
val _ = (Theory.parents "B"; print "B_LOADED\n") handle _ => print "B_NOT_LOADED\n";
SML

# The saved states a session loaded, outermost first.
state_script=$tmpdir/state.sml
cat > "$state_script" <<'SML'
val _ = List.app (fn s => print ("LOADED_STATE " ^ s ^ "\n")) (PolyML.SaveState.showHierarchy ());
SML
fallback_script=$tmpdir/fallback.sml
cat > "$fallback_script" <<'SML'
val _ = print "FALLBACK_RUN_OK\n";
SML

# Fallback to [run].heap with REASON, and the session really started from it.
require_heap_fallback() {
  local name=$1
  local reason=$2
  local log=$tmpdir/$name.log
  run_from "$log" --from BTheory "$fallback_script" "$state_script"
  require_grep "holbuild: --from BTheory: $reason; starting from \[run\].heap $run_heap" "$log"
  require_grep "FALLBACK_RUN_OK" "$log"
  require_grep "LOADED_STATE $run_heap" "$log"
  require_no_grep "starting from its" "$log"
}
no_checkpoint_reason="BTheory has no current checkpoint (not built yet, restored from the cache without a local build, built with --skip-checkpoints, or removed by gc)"

# Current final_context: BTheory is bound before any load, and loading it again
# is a no-op rather than a second copy of the theory.
final_script=$tmpdir/final.sml
cat > "$final_script" <<'SML'
val _ = (BTheory.b_thm; print "FINAL_CONTEXT_BOUND_OK\n");
val _ = load "BTheory";
val _ = print "FINAL_CONTEXT_RELOAD_OK\n";
SML
final_log=$tmpdir/final.log
run_from "$final_log" --from BTheory "$final_script" "$state_script"
require_grep "holbuild: --from BTheory: starting from its final_context checkpoint" "$final_log"
require_grep "FINAL_CONTEXT_BOUND_OK" "$final_log"
require_grep "FINAL_CONTEXT_RELOAD_OK" "$final_log"
require_grep "LOADED_STATE .*/BScript.sml.final_context.save" "$final_log"

source_log=$tmpdir/source-path.log
run_from "$source_log" --from src/BScript.sml "$final_script"
require_grep "holbuild: --from src/BScript.sml: starting from its final_context checkpoint" "$source_log"
require_grep "FINAL_CONTEXT_BOUND_OK" "$source_log"

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

require_no_grep "holbuild: --from" "$tmpdir/plain-trace.log"

# Without --from, run and repl given scripts start from the project theory the
# scripts depend on that has the most ancestors.
load_a_script=$tmpdir/load-a.sml
cat > "$load_a_script" <<'SML'
val _ = load "ATheory";
val _ = print "LOAD_A_OK\n";
SML
load_b_script=$tmpdir/load-b.sml
cat > "$load_b_script" <<'SML'
val _ = load "BTheory";
val _ = print "LOAD_B_OK\n";
SML
inferred="(inferred from the scripts' dependencies)"
run_from "$tmpdir/infer-one.log" "$load_a_script" "$state_script"
require_grep "holbuild: --from ATheory $inferred: starting from its final_context checkpoint" "$tmpdir/infer-one.log"
require_grep "LOAD_A_OK" "$tmpdir/infer-one.log"
require_grep "LOADED_STATE .*/AScript.sml.final_context.save" "$tmpdir/infer-one.log"

# BTheory has ATheory as an ancestor, so a script using both starts from BTheory.
both_script=$tmpdir/both.sml
cat > "$both_script" <<'SML'
val _ = (ATheory.a_thm; BTheory.b_thm; print "BOTH_BOUND_OK\n");
SML
run_from "$tmpdir/infer-both.log" "$both_script"
require_grep "holbuild: --from BTheory $inferred: starting from its final_context checkpoint" "$tmpdir/infer-both.log"
require_grep "BOTH_BOUND_OK" "$tmpdir/infer-both.log"

# An explicit --from overrides the inferred theory.
run_from "$tmpdir/infer-override.log" --from ATheory "$load_b_script"
require_grep "holbuild: --from ATheory: starting from its final_context checkpoint" "$tmpdir/infer-override.log"
require_grep "LOAD_B_OK" "$tmpdir/infer-override.log"
require_no_grep "inferred" "$tmpdir/infer-override.log"

infer_repl_log=$tmpdir/infer-repl.log
printf 'val _ = (BTheory.b_thm; print "REPL_INFER_OK\\n");\n' |
  (cd "$project" && timeout 60 "$HOLBUILD_BIN" repl "$load_b_script") > "$infer_repl_log" 2>&1
require_grep "holbuild: --from BTheory $inferred: starting from its final_context checkpoint" "$infer_repl_log"
require_grep "REPL_INFER_OK" "$infer_repl_log"

bare_repl_log=$tmpdir/bare-repl.log
printf 'val _ = print "BARE_REPL_OK\\n";\n' |
  (cd "$project" && timeout 60 "$HOLBUILD_BIN" repl) > "$bare_repl_log" 2>&1
require_grep "BARE_REPL_OK" "$bare_repl_log"
require_no_grep "holbuild: --from" "$bare_repl_log"

# final_context's saved parent is deps_loaded at its old absolute path, so after
# the project directory moves only deps_loaded can load.
moved=$tmpdir/moved
mv "$project" "$moved"
moved_log=$tmpdir/moved.log
if ! (cd "$moved" && "$HOLBUILD_BIN" run --from BTheory "$deps_script") > "$moved_log" 2>&1; then
  cat "$moved_log" >&2
  exit 1
fi
require_grep "holbuild: --from BTheory: its final_context checkpoint cannot load because its parent state $project/.*/deps_loaded.save has moved or been replaced; starting from its deps_loaded checkpoint" "$moved_log"
require_grep "DEPS_LOADED_BOUND_OK" "$moved_log"
require_grep "B_NOT_LOADED" "$moved_log"
mv "$moved" "$project"

# A final_context that is not a saved state, with its ok-file still current,
# falls back to deps_loaded instead of aborting the run.
final_context_file=$(find "$project/.holbuild/checkpoints" -name 'BScript.sml.final_context.save')
cp "$final_context_file" "$tmpdir/final_context.save.good"
echo garbage > "$final_context_file"
unreadable_log=$tmpdir/unreadable.log
run_from "$unreadable_log" --from BTheory "$deps_script"
require_grep "holbuild: --from BTheory: its final_context checkpoint is unreadable: .*; starting from its deps_loaded checkpoint" "$unreadable_log"
require_grep "B_NOT_LOADED" "$unreadable_log"
cp "$tmpdir/final_context.save.good" "$final_context_file"

# Only BTheory is stale: its ancestors come from deps_loaded.
sed -i 's/^val _ = export_theory();$/val b2_thm = store_thm("b2_thm", ``T``, ACCEPT_TAC TRUTH);\nval _ = export_theory();/' \
  "$project/src/BScript.sml"
deps_log=$tmpdir/deps.log
run_from "$deps_log" --from BTheory "$deps_script"
require_grep "holbuild: --from BTheory: no final_context checkpoint for its current source; starting from its deps_loaded checkpoint" "$deps_log"
require_grep "DEPS_LOADED_BOUND_OK" "$deps_log"
require_grep "B_NOT_LOADED" "$deps_log"

# A stale dependency invalidates both checkpoints.
sed -i 's/ACCEPT_TAC TRUTH);/ACCEPT_TAC TRUTH);\nval a2_thm = store_thm("a2_thm", ``T``, ACCEPT_TAC TRUTH);/' \
  "$project/src/AScript.sml"
require_heap_fallback stale "the dependencies or HOL toolchain of BTheory changed since its checkpoints were saved"

# A cache hit leaves no checkpoint at all.
(cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/rebuild.log" 2>&1 ||
  { cat "$tmpdir/rebuild.log" >&2; exit 1; }
rm -rf "$project/.holbuild"
(cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/cache-hit.log" 2>&1 ||
  { cat "$tmpdir/cache-hit.log" >&2; exit 1; }
require_heap_fallback cache "$no_checkpoint_reason"

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

# gc removes the checkpoints of a successful build.  The edit makes the
# build a cache miss, which saves checkpoints.
sed -i 's/^val _ = export_theory();$/val b4_thm = store_thm("b4_thm", ``T``, ACCEPT_TAC TRUTH);\nval _ = export_theory();/' \
  "$project/src/BScript.sml"
(cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/pre-gc.log" 2>&1 ||
  { cat "$tmpdir/pre-gc.log" >&2; exit 1; }
run_from "$tmpdir/pre-gc-run.log" --from BTheory "$final_script"
require_grep "starting from its final_context checkpoint" "$tmpdir/pre-gc-run.log"
(cd "$project" && "$HOLBUILD_BIN" gc --clean-only --retention-days 0) > "$tmpdir/gc.log" 2>&1 ||
  { cat "$tmpdir/gc.log" >&2; exit 1; }
require_heap_fallback gc "$no_checkpoint_reason"

# A build with --skip-checkpoints saves none.
sed -i 's/^val _ = export_theory();$/val b5_thm = store_thm("b5_thm", ``T``, ACCEPT_TAC TRUTH);\nval _ = export_theory();/' \
  "$project/src/BScript.sml"
(cd "$project" && "$HOLBUILD_BIN" build --skip-checkpoints BTheory) > "$tmpdir/skip.log" 2>&1 ||
  { cat "$tmpdir/skip.log" >&2; exit 1; }
require_heap_fallback skip "$no_checkpoint_reason"

# An inferred theory without a checkpoint falls back like an explicit --from.
infer_fallback_log=$tmpdir/infer-fallback.log
run_from "$infer_fallback_log" "$load_b_script"
require_grep "holbuild: --from BTheory $inferred: $no_checkpoint_reason; starting from \[run\].heap $run_heap" "$infer_fallback_log"
require_grep "LOAD_B_OK" "$infer_fallback_log"

# Dependency-package theories have no checkpoints.
dependency_log=$tmpdir/dependency.log
run_from "$dependency_log" --from CTheory "$fallback_script"
require_grep "holbuild: --from CTheory: CTheory is in dependency package lib; holbuild keeps checkpoints only for root-package theories; starting from \[run\].heap $run_heap" "$dependency_log"
require_grep "FALLBACK_RUN_OK" "$dependency_log"

# Without [run].heap the fallback is the HOL base state.
write_manifest without-heap
base_log=$tmpdir/base.log
run_from "$base_log" --from BTheory "$fallback_script" "$state_script"
require_grep "holbuild: --from BTheory: .*; starting from the HOL base state$" "$base_log"
require_grep "FALLBACK_RUN_OK" "$base_log"
require_grep "LOADED_STATE .*/bin/hol.state$" "$base_log"
require_no_grep "LOADED_STATE $run_heap" "$base_log"

expect_run_failure() {
  local name=$1
  local message=$2
  shift 2
  local log=$tmpdir/$name.log
  if (cd "$project" && "$HOLBUILD_BIN" run "$@" "$fallback_script") > "$log" 2>&1; then
    echo "run accepted $*" >&2
    exit 1
  fi
  require_grep "$message" "$log"
  require_no_grep "FALLBACK_RUN_OK" "$log"
}
expect_run_failure unknown "holbuild: --from MissingTheory: unknown build target: MissingTheory" \
  --from MissingTheory
expect_run_failure unknown-path \
  "holbuild: --from src/MissingScript.sml: build target path is not a known source: src/MissingScript.sml" \
  --from src/MissingScript.sml
expect_run_failure library "holbuild: --from requires a theory target, not Util" --from Util
expect_run_failure sig-pair "holbuild: --from requires a theory target, not Foo" --from Foo
expect_run_failure twice "holbuild: --from given more than once" --from BTheory --from=BTheory
expect_run_failure empty "holbuild: --from requires THEORY" --from=
