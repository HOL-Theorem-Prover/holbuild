#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT

project=$tmpdir/project
cache=$tmpdir/cache
mkdir -p \
  "$project/.holbuild/stage/old-stage" \
  "$project/.holbuild/logs" \
  "$project/.holbuild/checkpoints/pkg/src/theory.deps/key" \
  "$cache/tmp/old" \
  "$cache/actions/old" \
  "$cache/blobs"

cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "gc"

[build]
members = []
TOML

printf 'stage residue\n' > "$project/.holbuild/stage/old-stage/file"
printf 'old log\n' > "$project/.holbuild/logs/old.log"
printf 'checkpoint\n' > "$project/.holbuild/checkpoints/pkg/src/theory.deps/key/deps_loaded.save"
printf 'ok\n' > "$project/.holbuild/checkpoints/pkg/src/theory.deps/key/deps_loaded.save.ok"
printf 'meta\n' > "$project/.holbuild/checkpoints/pkg/src/theory.deps/key/deps_loaded.save.meta"
printf 'prefix\n' > "$project/.holbuild/checkpoints/pkg/src/theory.deps/key/deps_loaded.save.prefix"
printf 'tmp\n' > "$cache/tmp/old/file"
printf 'holbuild-cache-action-v2\nblob dat deadbeef\n' > "$cache/actions/old/manifest"
printf 'blob\n' > "$cache/blobs/deadbeef"

gc_log=$tmpdir/gc.log
(cd "$project" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$tmpdir/ignored-cache" \
  "$HOLBUILD_BIN" --cache-dir "$cache" gc --retention-days 0) > "$gc_log" 2>&1

require_grep "project clean: removed" "$gc_log"
require_grep "checkpoint_gb_initial=" "$gc_log"
require_grep "checkpoint_gb_before=" "$gc_log"
require_grep "checkpoint_gb_after=" "$gc_log"
require_grep "checkpoint_max_gb=" "$gc_log"
require_grep "cache gc: removed" "$gc_log"
[[ ! -e "$project/.holbuild/stage/old-stage" ]] || { echo "gc left stale stage dir" >&2; exit 1; }
[[ ! -e "$project/.holbuild/logs/old.log" ]] || { echo "gc left stale log" >&2; exit 1; }
if find "$project/.holbuild/checkpoints" -type f -print -quit 2>/dev/null | grep -q .; then
  if find "$project/.holbuild/checkpoints" -type f \
      ! -name .index-v2 ! -name .index-v2.tmp -print -quit 2>/dev/null | grep -q .; then
    echo "gc left stale checkpoint artifacts" >&2
    exit 1
  fi
fi
require_file "$project/.holbuild/checkpoints/.index-v2"
require_grep "holbuild-checkpoint-index-v2" "$project/.holbuild/checkpoints/.index-v2"
printf 'not an index\n' > "$project/.holbuild/checkpoints/.index-v2"
(cd "$project" && "$HOLBUILD_BIN" gc --clean-only --retention-days 0) > "$tmpdir/corrupt-index-gc.log" 2>&1
require_grep "holbuild-checkpoint-index-v2" "$project/.holbuild/checkpoints/.index-v2"

index_budget_project=$tmpdir/index-budget-project
index_budget_family="$index_budget_project/.holbuild/checkpoints/index-budget/src/OldScript.sml"
mkdir -p "$index_budget_project/.holbuild/checkpoints/index-budget/src/OldScript.sml.deps/old"
cat > "$index_budget_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "index-budget"

[build]
members = []
TOML
cat > "$index_budget_project/.holconfig.toml" <<'TOML'
[build]
checkpoint_limit_gb = 1
TOML
truncate -s 2G "$index_budget_family.deps/old/deps_loaded.save"
printf 'ok\n' > "$index_budget_family.deps/old/deps_loaded.save.ok"
cat > "$index_budget_project/.holbuild/checkpoints/.index-v2" <<EOF_INDEX
holbuild-checkpoint-index-v2
root=$index_budget_project/.holbuild/checkpoints
created_by=holbuild
family	$index_budget_family	1	2147483651
EOF_INDEX
(cd "$index_budget_project" && "$HOLBUILD_BIN" build) > "$tmpdir/index-budget.log" 2>&1
require_grep "checkpoint budget: .*evicted=" "$tmpdir/index-budget.log"
if [[ -e "$index_budget_family.deps/old" ]]; then
  echo "index-based checkpoint budget did not evict stale indexed family" >&2
  exit 1
fi

# Recover from a syntactically valid index that still names real families but
# omits families written by an older, unmanaged holbuild.  The large sidecar
# also verifies that every artifact removed by remove_checkpoint is included in
# budget accounting.
drift_project=$tmpdir/index-drift-project
drift_actual_family="$drift_project/.holbuild/checkpoints/index-drift/src/ActualScript.sml"
drift_indexed_family="$drift_project/.holbuild/checkpoints/index-drift/src/IndexedScript.sml"
drift_prefix="$drift_actual_family.theorems/key/proof/prefix/actual_failed_prefix.save.prefix"
drift_indexed_save="$drift_indexed_family.deps/key/deps_loaded.save"
mkdir -p "$(dirname "$drift_prefix")" "$(dirname "$drift_indexed_save")"
cat > "$drift_project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "index-drift"

[build]
members = []
TOML
cat > "$drift_project/.holconfig.toml" <<'TOML'
[build]
checkpoint_limit_gb = 1
TOML
truncate -s 2G "$drift_prefix"
touch -t 200001010000 "$drift_prefix"
printf 'indexed\n' > "$drift_indexed_save"
printf 'ok\n' > "$drift_indexed_save.ok"
cat > "$drift_project/.holbuild/checkpoints/.index-v2" <<EOF_INDEX
holbuild-checkpoint-index-v2
root=$drift_project/.holbuild/checkpoints
created_by=holbuild
family	$drift_indexed_family	1	11
EOF_INDEX
(cd "$drift_project" && "$HOLBUILD_BIN" build) > "$tmpdir/index-drift.log" 2>&1
require_grep "checkpoint budget: .*evicted=1" "$tmpdir/index-drift.log"
if [[ -e "$drift_prefix" ]]; then
  echo "checkpoint budget trusted an incomplete index or ignored a large prefix sidecar" >&2
  exit 1
fi
require_file "$drift_indexed_save"
if ! grep -q "IndexedScript.sml" "$drift_project/.holbuild/checkpoints/.index-v2"; then
  echo "recovered checkpoint index lost its valid indexed family" >&2
  exit 1
fi
if grep -q "ActualScript.sml" "$drift_project/.holbuild/checkpoints/.index-v2"; then
  echo "recovered checkpoint index retained its evicted unindexed family" >&2
  exit 1
fi

# A failed rm must not be credited as reclaimed bytes or dropped from the
# persisted index.  Use a narrow PATH shim so the fixture is independent of the
# account running the test and does not rely on directory permission semantics.
delete_failure_project=$tmpdir/delete-failure-project
delete_failure_family="$delete_failure_project/.holbuild/checkpoints/delete-failure/src/UndeletableScript.sml"
delete_failure_bin=$tmpdir/delete-failure-bin
mkdir -p "$delete_failure_family.deps/old" "$delete_failure_bin"
cat > "$delete_failure_project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "delete-failure"

[build]
members = []
TOML
cat > "$delete_failure_project/.holconfig.toml" <<'TOML'
[build]
checkpoint_limit_gb = 1
TOML
truncate -s 2G "$delete_failure_family.deps/old/deps_loaded.save"
printf 'ok\n' > "$delete_failure_family.deps/old/deps_loaded.save.ok"
cat > "$delete_failure_bin/rm" <<'SH'
#!/bin/sh
case "$*" in
  *UndeletableScript.sml*) exit 1 ;;
  *) exec /bin/rm "$@" ;;
esac
SH
chmod +x "$delete_failure_bin/rm"
(cd "$delete_failure_project" && PATH="$delete_failure_bin:$PATH" "$HOLBUILD_BIN" build) > "$tmpdir/delete-failure.log" 2>&1
require_grep "could not completely evict checkpoint family: .*UndeletableScript.sml" "$tmpdir/delete-failure.log"
require_grep "checkpoint budget still exceeds limit after eviction" "$tmpdir/delete-failure.log"
require_file "$delete_failure_family.deps/old/deps_loaded.save"
require_grep "UndeletableScript.sml" "$delete_failure_project/.holbuild/checkpoints/.index-v2"
/bin/rm -rf "$delete_failure_family.deps"
[[ ! -e "$cache/tmp/old" ]] || { echo "gc left stale cache tmp" >&2; exit 1; }
[[ ! -e "$cache/actions/old" ]] || { echo "gc left stale cache action" >&2; exit 1; }
[[ ! -e "$cache/blobs/deadbeef" ]] || { echo "gc left stale cache blob" >&2; exit 1; }


clean_only_project=$tmpdir/clean-only-project
clean_only_cache=$tmpdir/clean-only-cache
mkdir -p "$clean_only_project/.holbuild/stage/old" "$clean_only_cache/tmp/old"
cat > "$clean_only_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "gc-clean-only"

[build]
members = []
TOML
printf 'stage residue\n' > "$clean_only_project/.holbuild/stage/old/file"
printf 'cache residue\n' > "$clean_only_cache/tmp/old/file"
(cd "$clean_only_project" && env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$tmpdir/ignored-clean-only-cache" \
  "$HOLBUILD_BIN" --cache-dir "$clean_only_cache" gc --clean-only --retention-days 0) > "$tmpdir/clean-only.log" 2>&1
require_grep "project clean: removed" "$tmpdir/clean-only.log"
require_grep "checkpoint_gb_before=" "$tmpdir/clean-only.log"
if grep -q "cache gc:" "$tmpdir/clean-only.log"; then
  echo "--clean-only ran cache gc" >&2
  exit 1
fi
[[ ! -e "$clean_only_project/.holbuild/stage/old" ]] || { echo "--clean-only left project stage" >&2; exit 1; }
[[ -e "$clean_only_cache/tmp/old" ]] || { echo "--clean-only removed cache state" >&2; exit 1; }

budget_project=$tmpdir/budget-project
budget_family="$budget_project/.holbuild/checkpoints/checkpoint-budget/src/BadScript.sml"
mkdir -p \
  "$budget_project/src" \
  "$budget_family.deps/old-deps-key" \
  "$budget_family.theorems/old-deps-key/proof_ir_v3/old-prefix"
cat > "$budget_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "checkpoint-budget"

[build]
members = ["src"]
TOML
cat > "$budget_project/.holconfig.toml" <<'TOML'
[build]
checkpoint_limit_gb = 1
TOML
cat > "$budget_project/src/BadScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Bad";
val _ = raise Fail "forced failure after stale checkpoint budget fixture";
SML
truncate -s 2G "$budget_family.deps/old-deps-key/deps_loaded.save"
printf 'ok\n' > "$budget_family.deps/old-deps-key/deps_loaded.save.ok"
printf 'child\n' > "$budget_family.theorems/old-deps-key/proof_ir_v3/old-prefix/first_context.save"
printf 'child ok\n' > "$budget_family.theorems/old-deps-key/proof_ir_v3/old-prefix/first_context.save.ok"
touch -d '2 days ago' \
  "$budget_family.deps/old-deps-key/deps_loaded.save" \
  "$budget_family.deps/old-deps-key/deps_loaded.save.ok" \
  "$budget_family.theorems/old-deps-key/proof_ir_v3/old-prefix/first_context.save" \
  "$budget_family.theorems/old-deps-key/proof_ir_v3/old-prefix/first_context.save.ok"
if (cd "$budget_project" && "$HOLBUILD_BIN" build BadTheory) > "$tmpdir/budget.log" 2>&1; then
  echo "checkpoint budget failure fixture unexpectedly succeeded" >&2
  exit 1
fi
require_grep "checkpoint budget: .*evicted=" "$tmpdir/budget.log"
require_grep "checkpoint_gb_before=" "$tmpdir/budget.log"
require_grep "checkpoint_gb_after=" "$tmpdir/budget.log"
require_grep "checkpoint_limit_gb=1" "$tmpdir/budget.log"
if [[ -e "$budget_family.deps/old-deps-key" || -e "$budget_family.theorems/old-deps-key" ]]; then
  echo "checkpoint budget evicted stale parent/child heap family only partially" >&2
  exit 1
fi

failure_index_project=$tmpdir/failure-index-project
mkdir -p "$failure_index_project/src"
cat > "$failure_index_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "checkpoint-failure-index"

[build]
members = ["src"]
TOML
cat > "$failure_index_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val first = Q.store_thm ("first", `T`, rw []);
val bad = Q.store_thm ("bad", `T`, ALL_TAC THEN FAIL_TAC "forced checkpoint index failure");
val _ = export_theory ();
SML
if (cd "$failure_index_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/failure-index.log" 2>&1; then
  echo "checkpoint failure index fixture unexpectedly succeeded" >&2
  exit 1
fi
require_file "$failure_index_project/.holbuild/checkpoints/.index-v2"
require_grep "checkpoint-failure-index/src/AScript.sml" "$failure_index_project/.holbuild/checkpoints/.index-v2"

deep_watch_project=$tmpdir/deep-watch-budget-project
deep_watch_family="$deep_watch_project/.holbuild/checkpoints/deep-watch/deep/nested/GeneratedScript.sml"
deep_watch_marker="$deep_watch_family.deps/key/deps_loaded.save.ok"
mkdir -p "$deep_watch_project/deep/nested" "$(dirname "$deep_watch_family")"
cat > "$deep_watch_project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "deep-watch"

[build]
members = ["deep"]
TOML
cat > "$deep_watch_project/.holconfig.toml" <<'TOML'
[build]
checkpoint_limit_gb = 1
jobs = 1
TOML
cat > "$deep_watch_project/deep/nested/TriggerScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Trigger";
val _ = export_theory();
val _ = OS.Process.system "mkdir -p $deep_watch_family.deps/key && truncate -s 2G $deep_watch_family.deps/key/deps_loaded.save && printf ok > $deep_watch_marker";
SML
cat > "$deep_watch_project/deep/nested/CheckScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Check";
val _ = load "TriggerTheory";
val _ =
  if OS.FileSys.access("$deep_watch_marker", []) then
    raise Fail "deep generated checkpoint budget was not enforced"
  else raise Fail "forced failure after deep generated checkpoint budget check";
SML
if (cd "$deep_watch_project" && "$HOLBUILD_BIN" build CheckTheory) > "$tmpdir/deep-watch-budget.log" 2>&1; then
  echo "deep watch checkpoint budget fixture unexpectedly succeeded" >&2
  exit 1
fi
require_grep "checkpoint budget: .*evicted=" "$tmpdir/deep-watch-budget.log"
require_grep "forced failure after deep generated checkpoint budget check" "$tmpdir/deep-watch-budget.log"
if grep -q "deep generated checkpoint budget was not enforced" "$tmpdir/deep-watch-budget.log"; then
  echo "checkpoint budget missed a generated family in a pre-existing deep directory" >&2
  exit 1
fi

mid_project=$tmpdir/mid-budget-project
mid_family="$mid_project/.holbuild/checkpoints/mid-budget-generated/src/generated"
mkdir -p "$mid_project/src"
cat > "$mid_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "mid-budget"

[build]
members = ["src"]
TOML
cat > "$mid_project/.holconfig.toml" <<'TOML'
[build]
checkpoint_limit_gb = 1
jobs = 1
TOML
cat > "$mid_project/src/FirstScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "First";
val _ = export_theory();
val _ = OS.Process.system "mkdir -p $mid_family.deps/key && truncate -s 2G $mid_family.deps/key/deps_loaded.save";
val out = TextIO.openOut "$mid_family.deps/key/deps_loaded.save.ok";
val _ = (TextIO.output(out, "ok\\n"); TextIO.closeOut out);
SML
cat > "$mid_project/src/SecondScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Second";
val _ = load "FirstTheory";
val _ =
  if OS.FileSys.access("$mid_family.deps/key/deps_loaded.save.ok", []) then
    raise Fail "mid-build checkpoint budget was not enforced"
  else raise Fail "forced failure after mid-build budget check";
SML
if (cd "$mid_project" && "$HOLBUILD_BIN" build SecondTheory) > "$tmpdir/mid-budget.log" 2>&1; then
  echo "mid-build checkpoint budget fixture unexpectedly succeeded" >&2
  exit 1
fi
require_grep "checkpoint budget: .*evicted=" "$tmpdir/mid-budget.log"
require_grep "forced failure after mid-build budget check" "$tmpdir/mid-budget.log"
if grep -q "mid-build checkpoint budget was not enforced" "$tmpdir/mid-budget.log"; then
  echo "checkpoint budget was not enforced between serial nodes" >&2
  exit 1
fi

protected_project=$tmpdir/protected-active-project
protected_slow_family="$protected_project/.holbuild/checkpoints/protected-active/src/SlowScript.sml"
protected_live="$protected_slow_family.deps/live/deps_loaded.save"
mkdir -p "$protected_project/src" "$protected_slow_family.deps/seed"
cat > "$protected_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "protected-active"

[build]
members = ["src"]
TOML
cat > "$protected_project/.holconfig.toml" <<'TOML'
[build]
checkpoint_limit_gb = 1
jobs = 3
TOML
printf 'seed\n' > "$protected_slow_family.deps/seed/deps_loaded.save"
printf 'ok\n' > "$protected_slow_family.deps/seed/deps_loaded.save.ok"
cat > "$protected_project/src/SlowScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Slow";
val _ = export_theory();
val _ = OS.Process.system "mkdir -p $protected_slow_family.deps/live && truncate -s 2G $protected_live && printf ok > $protected_live.ok";
val _ = OS.Process.sleep (Time.fromSeconds 6);
SML
cat > "$protected_project/src/FastScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Fast";
val _ = OS.Process.sleep (Time.fromSeconds 2);
val _ = export_theory();
SML
cat > "$protected_project/src/ThirdScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Third";
val _ = load "FastTheory";
val _ =
  if OS.FileSys.access("$protected_live.ok", []) then
    raise Fail "protected active family survived"
  else
    raise Fail "protected active family was evicted";
SML
if (cd "$protected_project" && "$HOLBUILD_BIN" build --force=project --no-cache) > "$tmpdir/protected-active.log" 2>&1; then
  echo "protected active family fixture unexpectedly succeeded" >&2
  exit 1
fi
require_grep "checkpoint budget: .*checkpoint_limit_gb=1" "$tmpdir/protected-active.log"
require_grep "protected active family survived" "$tmpdir/protected-active.log"
if grep -q "protected active family was evicted" "$tmpdir/protected-active.log"; then
  echo "checkpoint budget evicted an active protected family" >&2
  exit 1
fi

dependency_project=$tmpdir/evict-completed-dependency-project
dependency_family="$dependency_project/.holbuild/checkpoints/evict-completed-dependency/src/DependencyScript.sml"
dependency_live="$dependency_family.deps/live/deps_loaded.save"
dependency_slow_started=$tmpdir/evict-completed-dependency-slow-started
mkdir -p "$dependency_project/src" "$dependency_family.deps/seed"
cat > "$dependency_project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "evict-completed-dependency"

[build]
members = ["src"]
TOML
cat > "$dependency_project/.holconfig.toml" <<'TOML'
[build]
checkpoint_limit_gb = 1
jobs = 2
TOML
printf 'seed\n' > "$dependency_family.deps/seed/deps_loaded.save"
printf 'ok\n' > "$dependency_family.deps/seed/deps_loaded.save.ok"
cat > "$dependency_project/src/DependencyScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Dependency";
val _ = export_theory();
val _ = OS.Process.system "mkdir -p $dependency_family.deps/live && truncate -s 2G $dependency_live && printf ok > $dependency_live.ok";
SML
cat > "$dependency_project/src/SlowDependentScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "SlowDependent";
val _ = load "DependencyTheory";
val started = TextIO.openOut "$dependency_slow_started";
val _ = (TextIO.output(started, "started\n"); TextIO.closeOut started);
val _ = OS.Process.sleep (Time.fromSeconds 4);
val _ =
  if OS.FileSys.access("$dependency_live.ok", []) then
    raise Fail "completed dependency family remained protected"
  else ();
val _ = export_theory();
SML
cat > "$dependency_project/src/TriggerScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Trigger";
val _ =
  let
    fun wait 0 = raise Fail "dependent did not start"
      | wait remaining =
          if OS.FileSys.access("$dependency_slow_started", []) then ()
          else (OS.Process.sleep (Time.fromMilliseconds 20); wait (remaining - 1))
  in
    wait 300
  end;
val _ = export_theory();
SML
if ! (cd "$dependency_project" && "$HOLBUILD_BIN" build --force=project --no-cache) > "$tmpdir/evict-completed-dependency.log" 2>&1; then
  echo "completed dependency checkpoint family was retained while its dependent was active" >&2
  cat "$tmpdir/evict-completed-dependency.log" >&2
  exit 1
fi
require_grep "checkpoint budget: .*checkpoint_limit_gb=1" "$tmpdir/evict-completed-dependency.log"
if [[ -e "$dependency_live.ok" ]]; then
  echo "checkpoint budget retained a completed dependency family" >&2
  exit 1
fi

gate_project=$tmpdir/checkpoint-maintenance-gate-project
gate_family="$gate_project/.holbuild/checkpoints/checkpoint-maintenance-gate/src/DependentScript.sml"
gate_trash="$gate_project/.holbuild/checkpoints/checkpoint-maintenance-gate/src/TrashScript.sml"
gate_sync=$tmpdir/checkpoint-maintenance
gate_started=$tmpdir/checkpoint-maintenance-dependent-started
gate_live="$gate_family.deps/live/deps_loaded.save"
mkdir -p "$gate_project/src" "$gate_family.deps/seed"
cat > "$gate_project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "checkpoint-maintenance-gate"

[build]
members = ["src"]
TOML
cat > "$gate_project/.holconfig.toml" <<'TOML'
[build]
checkpoint_limit_gb = 1
jobs = 2
TOML
printf 'seed\n' > "$gate_family.deps/seed/deps_loaded.save"
printf 'ok\n' > "$gate_family.deps/seed/deps_loaded.save.ok"
cat > "$gate_project/src/TriggerScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Trigger";
val _ = export_theory();
val _ = OS.Process.system "mkdir -p $gate_trash.deps/old && truncate -s 2G $gate_trash.deps/old/deps_loaded.save && printf ok > $gate_trash.deps/old/deps_loaded.save.ok && touch -d '2 days ago' $gate_trash.deps/old/deps_loaded.save $gate_trash.deps/old/deps_loaded.save.ok";
SML
cat > "$gate_project/src/DependentScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Dependent";
val _ = load "TriggerTheory";
val started = TextIO.openOut "$gate_started";
val _ = (TextIO.output(started, "started\n"); TextIO.closeOut started);
val _ = OS.Process.system "mkdir -p $gate_family.deps/live && truncate -s 2G $gate_live && printf ok > $gate_live.ok";
val _ = OS.Process.sleep (Time.fromSeconds 1);
val _ =
  if OS.FileSys.access("$gate_live.ok", []) then ()
  else raise Fail "dependent checkpoint family was evicted while active";
val _ = export_theory();
SML
(
  cd "$gate_project"
  HOLBUILD_TEST_CHECKPOINT_BUDGET_GATE="$gate_sync" \
    "$HOLBUILD_BIN" build --force=project --no-cache
) > "$tmpdir/checkpoint-maintenance-gate.log" 2>&1 &
gate_pid=$!
gate_seen=0
for _ in $(seq 1 300); do
  if [[ -e "$gate_sync.active" ]]; then
    gate_seen=1
    break
  fi
  if ! kill -0 "$gate_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if [[ "$gate_seen" -ne 1 ]]; then
  touch "$gate_sync.release"
  wait "$gate_pid" || true
  echo "checkpoint maintenance fixture did not enter the budget pass" >&2
  exit 1
fi
sleep 1
if [[ -e "$gate_started" ]]; then
  touch "$gate_sync.release"
  wait "$gate_pid" || true
  echo "dependent started while checkpoint maintenance was active" >&2
  exit 1
fi
touch "$gate_sync.release"
if ! wait "$gate_pid"; then
  echo "checkpoint maintenance fixture failed" >&2
  cat "$tmpdir/checkpoint-maintenance-gate.log" >&2
  exit 1
fi
require_file "$gate_started"
require_grep "checkpoint budget: .*checkpoint_limit_gb=1" "$tmpdir/checkpoint-maintenance-gate.log"
if [[ -e "$gate_family.deps" ]]; then
  echo "final checkpoint budget enforcement retained the completed dependent family" >&2
  exit 1
fi

protected_empty_project=$tmpdir/protected-empty-active-project
protected_empty_slow_family="$protected_empty_project/.holbuild/checkpoints/protected-empty-active/src/SlowScript.sml"
protected_empty_old_family="$protected_empty_project/.holbuild/checkpoints/protected-empty-active/src/OldScript.sml"
protected_empty_live_dir="$protected_empty_slow_family.deps/live"
mkdir -p "$protected_empty_project/src" "$protected_empty_old_family.deps/old"
cat > "$protected_empty_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "protected-empty-active"

[build]
members = ["src"]
TOML
cat > "$protected_empty_project/.holconfig.toml" <<'TOML'
[build]
checkpoint_limit_gb = 1
jobs = 3
TOML
truncate -s 2G "$protected_empty_old_family.deps/old/deps_loaded.save"
printf 'ok\n' > "$protected_empty_old_family.deps/old/deps_loaded.save.ok"
cat > "$protected_empty_project/src/SlowScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Slow";
val _ = export_theory();
val _ = OS.Process.system "mkdir -p $protected_empty_live_dir";
val _ = OS.Process.sleep (Time.fromSeconds 6);
SML
cat > "$protected_empty_project/src/FastScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Fast";
val _ = OS.Process.sleep (Time.fromSeconds 2);
val _ = export_theory();
SML
cat > "$protected_empty_project/src/ThirdScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Third";
val _ = load "FastTheory";
val _ =
  if OS.FileSys.isDir "$protected_empty_live_dir" then
    raise Fail "protected active empty family survived"
  else
    raise Fail "protected active empty family was pruned";
SML
if (cd "$protected_empty_project" && "$HOLBUILD_BIN" build --force=project --no-cache) > "$tmpdir/protected-empty-active.log" 2>&1; then
  echo "protected empty active family fixture unexpectedly succeeded" >&2
  exit 1
fi
require_grep "checkpoint budget: .*checkpoint_limit_gb=1" "$tmpdir/protected-empty-active.log"
require_grep "protected active empty family survived" "$tmpdir/protected-empty-active.log"
if grep -q "protected active empty family was pruned" "$tmpdir/protected-empty-active.log"; then
  echo "checkpoint budget pruned an active protected empty family" >&2
  exit 1
fi

scan_project=$tmpdir/scan-project
mkdir -p "$scan_project/src"
cat > "$scan_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "scan-project"

[build]
members = ["src"]
TOML
cat > "$scan_project/src/ScanScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Scan";
val _ = export_theory();
SML
(cd "$scan_project" && "$HOLBUILD_BIN" build ScanTheory) > "$tmpdir/scan-first.log" 2>&1
require_file "$scan_project/.holbuild/checkpoints/.index-v2"
scan_counter=$tmpdir/checkpoint-scan-counter.log
rm -f "$scan_counter"
(cd "$scan_project" && HOLBUILD_CHECKPOINT_SCAN_COUNTER="$scan_counter" "$HOLBUILD_BIN" build ScanTheory) > "$tmpdir/scan-second.log" 2>&1
if [[ -s "$scan_counter" ]]; then
  echo "up-to-date build performed recursive checkpoint scan despite valid index" >&2
  exit 1
fi

# A failed atomic index write must leave the dirty marker behind.  Otherwise a
# later build trusts the last valid-but-stale index and can let checkpoint data
# grow past the configured budget after ENOSPC or another persistence failure.
mkdir "$scan_project/.holbuild/checkpoints/.index-v2.tmp"
(cd "$scan_project" && "$HOLBUILD_BIN" build --force=project --no-cache ScanTheory) > "$tmpdir/scan-index-write-failure.log" 2>&1
require_grep "could not finalize checkpoint index" "$tmpdir/scan-index-write-failure.log"
require_file "$scan_project/.holbuild/checkpoints/.index-dirty"
rmdir "$scan_project/.holbuild/checkpoints/.index-v2.tmp"
rm -f "$scan_counter"
(cd "$scan_project" && HOLBUILD_CHECKPOINT_SCAN_COUNTER="$scan_counter" "$HOLBUILD_BIN" build ScanTheory) > "$tmpdir/scan-dirty-recovery.log" 2>&1
if [[ ! -s "$scan_counter" ]]; then
  echo "dirty checkpoint index was trusted instead of rebuilt" >&2
  exit 1
fi
if [[ -e "$scan_project/.holbuild/checkpoints/.index-dirty" ]]; then
  echo "checkpoint dirty marker remained after a successful index rebuild" >&2
  exit 1
fi

perf_scan_project=$tmpdir/perf-scan-project
mkdir -p "$perf_scan_project/src1" "$perf_scan_project/src2"
cat > "$perf_scan_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "perf-scan-project"

[build]
members = ["src1", "src2"]
TOML
for theory in PerfA PerfB; do
  cat > "$perf_scan_project/src1/${theory}Script.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "$theory";
val _ = export_theory();
SML
done
for theory in PerfC PerfD; do
  cat > "$perf_scan_project/src2/${theory}Script.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "$theory";
val _ = export_theory();
SML
done
perf_scan_counter=$tmpdir/perf-checkpoint-scan-counter.log
rm -f "$perf_scan_counter"
(cd "$perf_scan_project" && HOLBUILD_CHECKPOINT_SCAN_COUNTER="$perf_scan_counter" \
  "$HOLBUILD_BIN" build --force=project --no-cache) > "$tmpdir/perf-scan.log" 2>&1
perf_scan_count=0
if [[ -f "$perf_scan_counter" ]]; then
  perf_scan_count=$(wc -l < "$perf_scan_counter")
fi
if (( perf_scan_count > 3 )); then
  echo "checkpoint budget performed too many recursive scans on a forced build: $perf_scan_count" >&2
  exit 1
fi

if (cd "$project" && "$HOLBUILD_BIN" gc --clean-only --cache-only) > "$tmpdir/bad-flags.log" 2>&1; then
  echo "gc accepted mutually exclusive flags" >&2
  exit 1
fi
require_grep "mutually exclusive" "$tmpdir/bad-flags.log"
