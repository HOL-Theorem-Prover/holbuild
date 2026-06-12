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
metadata="$project/.holbuild/dep/checkpointrecovery/src/AScript.sml.key"
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "checkpointrecovery"

[build]
members = ["src"]

[actions.ATheory]
cache = false
TOML

write_good_source() {
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem second:
  T
Proof
  ACCEPT_TAC first
QED

val _ = export_theory();
SML
}

write_bad_suffix_source() {
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem second:
  T
Proof
  FAIL_TAC "expected dirty residue"
QED

val _ = export_theory();
SML
}

write_changed_prefix_source() {
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

(* prefix edit changes the theorem context key *)
Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem second:
  T
Proof
  ACCEPT_TAC first
QED

val _ = export_theory();
SML
}

write_non_goal_failure_source() {
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED

val _ = print "HOL message: expected non-goal failure\n";
val _ = raise Fail "expected non-goal failure";
SML
}

write_non_goal_failure_after_first_source() {
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED

val _ = print "HOL message: expected non-goal failure after first\n";
val _ = raise Fail "expected non-goal failure after first";
SML
}

write_bad_after_three_source() {
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem second:
  T
Proof
  ACCEPT_TAC first
QED

Theorem third:
  T
Proof
  ACCEPT_TAC second
QED

val _ = raise Fail "expected failure after three contexts";
SML
}

write_good_three_source() {
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem second:
  T
Proof
  ACCEPT_TAC first
QED

Theorem third:
  T
Proof
  ACCEPT_TAC second
QED

val _ = export_theory();
SML
}

assert_no_checkpoints() {
  # checkpoints now persist after successful builds for incremental rebuilds.
  # This function is kept as a no-op for compatibility with existing test structure;
  # the real correctness checks are the require_grep/not-grep assertions in each scenario.
  :
}

checkpoint_count() {
  find "$project/.holbuild/checkpoints" \( -name '*.save' -o -name '*.save.ok' \) -print 2>/dev/null | wc -l
}

force_rebuild() {
  rm -f "$metadata"
}

first_context_path() {
  find "$project/.holbuild/checkpoints/checkpointrecovery/src/AScript.sml.theorems" \
    -path '*/first_context.save' -print -quit
}

second_context_path() {
  find "$project/.holbuild/checkpoints/checkpointrecovery/src/AScript.sml.theorems" \
    -path '*/second_context.save' -print -quit
}

third_context_path() {
  find "$project/.holbuild/checkpoints/checkpointrecovery/src/AScript.sml.theorems" \
    -path '*/third_context.save' -print -quit
}

first_deps_path() {
  find "$project/.holbuild/checkpoints/checkpointrecovery/src/AScript.sml.deps" \
    -path '*/deps_loaded.save' -print -quit
}

second_failed_prefix_path() {
  find "$project/.holbuild/checkpoints/checkpointrecovery/src/AScript.sml.theorems" \
    -path '*second_failed_prefix.save' -print -quit
}

run_expect_suffix_failure() {
  local log=$1
  # Isolate each recovery scenario. Successful builds intentionally retain
  # checkpoints now, so path helpers like first_context_path can otherwise find
  # an older prefix's checkpoint instead of the one this scenario corrupts.
  rm -rf "$project/.holbuild/checkpoints"
  write_bad_suffix_source
  if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$log" 2>&1; then
    echo "expected second theorem failure" >&2
    exit 1
  fi
  require_grep "expected dirty residue" "$log"
  deps_loaded_path=$(first_deps_path)
  context_path=$(first_context_path)
  if [[ -z "$deps_loaded_path" || ! -e "$deps_loaded_path.ok" ]]; then
    echo "failed action did not retain deps_loaded checkpoint breadcrumb" >&2
    exit 1
  fi
  if [[ -z "$context_path" || ! -e "$context_path.ok" ]]; then
    echo "failed action did not retain reusable first theorem context" >&2
    exit 1
  fi
  require_grep '^holbuild-checkpoint-ok-v2$' "$deps_loaded_path.ok"
  require_grep '^kind=deps_loaded$' "$deps_loaded_path.ok"
  require_grep '^holbuild-checkpoint-ok-v2$' "$context_path.ok"
  require_grep '^kind=theorem_context$' "$context_path.ok"
}

write_good_source
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/initial.log" 2>&1
require_file "$project/.holbuild/obj/src/ATheory.dat"
# checkpoints persist after successful builds for incremental rebuilds
if ! find "$project/.holbuild/checkpoints" \( -name '*.save' -o -name '*.save.ok' \) -print -quit 2>/dev/null | grep -q .; then
  echo "successful build should retain checkpoint files" >&2
  exit 1
fi

run_expect_suffix_failure "$tmpdir/failed.log"
write_good_source
force_rebuild
fixed_log=$tmpdir/fixed.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$fixed_log" 2>&1
require_grep "from: failed-prefix checkpoint in second" "$fixed_log"
if grep -q "parent for this saved state\|goalfrag/checkpoint run failed" "$fixed_log"; then
  echo "suffix recovery hit checkpoint parent mismatch/instrumentation failure" >&2
  exit 1
fi
require_file "$project/.holbuild/obj/src/ATheory.dat"
# checkpoints persist after successful fixed build for incremental rebuilds

run_expect_suffix_failure "$tmpdir/missing-ok-seed.log"
missing_context=$(first_context_path)
missing_failed_prefix=$(second_failed_prefix_path)
rm -f "$missing_context.ok" "$missing_failed_prefix" "$missing_failed_prefix.ok" "$missing_failed_prefix.meta" "$missing_failed_prefix.prefix"
write_good_source
force_rebuild
missing_ok_log=$tmpdir/missing-ok.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$missing_ok_log" 2>&1
require_grep "from: deps-loaded checkpoint" "$missing_ok_log"
if grep -q "from: theorem-context checkpoint after first" "$missing_ok_log"; then
  echo "missing checkpoint .ok was treated as replayable" >&2
  exit 1
fi
# checkpoints persist after successful missing-ok rebuild for incremental rebuilds

run_expect_suffix_failure "$tmpdir/missing-save-seed.log"
missing_save_context=$(first_context_path)
missing_save_failed_prefix=$(second_failed_prefix_path)
rm -f "$missing_save_context" "$missing_save_failed_prefix" "$missing_save_failed_prefix.ok" "$missing_save_failed_prefix.meta" "$missing_save_failed_prefix.prefix"
write_good_source
force_rebuild
missing_save_log=$tmpdir/missing-save.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$missing_save_log" 2>&1
require_grep "checkpoint metadata exists without checkpoint file; discarding metadata:" "$missing_save_log"
require_grep "from: deps-loaded checkpoint" "$missing_save_log"
if grep -q "from: theorem-context checkpoint after first\|selected HOL base-state checkpoint is missing\|Couldn't load HOL base-state\|instrumented log:" "$missing_save_log"; then
  echo "orphan checkpoint .ok/.save mismatch was treated as replayable" >&2
  exit 1
fi
# checkpoints persist after successful orphan-metadata rebuild for incremental rebuilds

run_expect_suffix_failure "$tmpdir/missing-failed-prefix-seed.log"
missing_failed_prefix_save=$(second_failed_prefix_path)
rm -f "$missing_failed_prefix_save"
write_good_source
force_rebuild
missing_failed_prefix_log=$tmpdir/missing-failed-prefix.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$missing_failed_prefix_log" 2>&1
require_grep "from: theorem-context checkpoint after first" "$missing_failed_prefix_log"
if grep -q "from: failed-prefix checkpoint\|selected HOL base-state checkpoint is missing\|Couldn't load HOL base-state\|instrumented log:" "$missing_failed_prefix_log"; then
  echo "missing failed-prefix .save was treated as replayable" >&2
  exit 1
fi
# checkpoints persist after successful missing-failed-prefix rebuild for incremental rebuilds

run_expect_suffix_failure "$tmpdir/fresh-deps-seed.log"
fresh_deps=$(first_deps_path)
fresh_context=$(first_context_path)
fresh_failed_prefix=$(second_failed_prefix_path)
stale_descendant="$(dirname "$(dirname "$fresh_context")")/stale_prefix/stale_context.save"
mkdir -p "$(dirname "$stale_descendant")"
printf 'stale child checkpoint\n' > "$stale_descendant"
printf 'holbuild-checkpoint-ok-v2\nkind=theorem_context\n' > "$stale_descendant.ok"
rm -f "$fresh_deps" "$fresh_deps.ok" "$fresh_deps.meta" "$fresh_deps.prefix" "$fresh_failed_prefix" "$fresh_failed_prefix.ok" "$fresh_failed_prefix.meta" "$fresh_failed_prefix.prefix"
force_rebuild
fresh_deps_log=$tmpdir/fresh-deps-rebuild-failure.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$fresh_deps_log" 2>&1; then
  echo "expected fresh deps rebuild to preserve suffix failure" >&2
  exit 1
fi
require_grep "expected dirty residue" "$fresh_deps_log"
if [[ -e "$stale_descendant" || -e "$stale_descendant.ok" ]]; then
  echo "fresh deps checkpoint rewrite left stale theorem descendants" >&2
  exit 1
fi
rm -rf "$project/.holbuild/checkpoints"

run_expect_suffix_failure "$tmpdir/interrupted-save-seed.log"
interrupted_context=$(first_context_path)
interrupted_failed_prefix=$(second_failed_prefix_path)
rm -f "$interrupted_failed_prefix" "$interrupted_failed_prefix.ok" "$interrupted_failed_prefix.meta" "$interrupted_failed_prefix.prefix"
rm -f "$interrupted_context.ok"
printf 'partial interrupted checkpoint\n' > "$interrupted_context"
write_good_source
force_rebuild
interrupted_log=$tmpdir/interrupted-save-rebuild.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$interrupted_log" 2>&1
require_grep "from: deps-loaded checkpoint" "$interrupted_log"
if grep -q "from: theorem-context checkpoint after first\|restoring previous checkpoint" "$interrupted_log"; then
  echo "interrupted checkpoint save was restored instead of ignored" >&2
  exit 1
fi
# checkpoints persist after successful interrupted-save rebuild for incremental rebuilds

run_expect_suffix_failure "$tmpdir/orphan-ok-seed.log"
orphan_ok_context=$(first_context_path)
orphan_ok_failed_prefix=$(second_failed_prefix_path)
rm -f "$orphan_ok_failed_prefix" "$orphan_ok_failed_prefix.ok" "$orphan_ok_failed_prefix.meta" "$orphan_ok_failed_prefix.prefix"
rm -f "$orphan_ok_context"
write_good_source
force_rebuild
orphan_ok_log=$tmpdir/orphan-ok-rebuild.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$orphan_ok_log" 2>&1
require_grep "checkpoint metadata exists without checkpoint file; discarding metadata:" "$orphan_ok_log"
require_grep "from: deps-loaded checkpoint" "$orphan_ok_log"
if grep -q "from: theorem-context checkpoint after first\|restoring previous checkpoint" "$orphan_ok_log"; then
  echo "orphan checkpoint metadata was restored instead of ignored" >&2
  exit 1
fi
# checkpoints persist after successful orphan-ok rebuild for incremental rebuilds

run_expect_suffix_failure "$tmpdir/parent-mismatch-seed.log"
parent_mismatch_deps=$(first_deps_path)
parent_mismatch_failed_prefix=$(second_failed_prefix_path)
rm -f "$parent_mismatch_failed_prefix" "$parent_mismatch_failed_prefix.ok" "$parent_mismatch_failed_prefix.meta" "$parent_mismatch_failed_prefix.prefix"
cp "$HOLDIR/bin/hol.state" "$parent_mismatch_deps"
write_good_source
force_rebuild
parent_mismatch_log=$tmpdir/parent-mismatch.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$parent_mismatch_log" 2>&1
require_grep "discarding invalid checkpoint after HOL state load failure" "$parent_mismatch_log"
if grep -q "Couldn't load HOL base-state\|parent for this saved state" "$parent_mismatch_log"; then
  echo "checkpoint parent mismatch leaked as a build failure" >&2
  exit 1
fi
require_file "$project/.holbuild/obj/src/ATheory.dat"
# checkpoints persist after successful parent-mismatch rebuild for incremental rebuilds

run_expect_suffix_failure "$tmpdir/corrupt-seed.log"
corrupt_context=$(first_context_path)
corrupt_failed_prefix=$(second_failed_prefix_path)
rm -f "$corrupt_failed_prefix" "$corrupt_failed_prefix.ok" "$corrupt_failed_prefix.meta" "$corrupt_failed_prefix.prefix"
printf 'not a valid PolyML checkpoint\n' > "$corrupt_context"
write_good_source
force_rebuild
corrupt_log=$tmpdir/corrupt.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$corrupt_log" 2>&1
require_grep "from: theorem-context checkpoint after first" "$corrupt_log"
require_grep "discarding invalid checkpoint after HOL state load failure" "$corrupt_log"
if grep -q "Couldn't load HOL base-state\|Unable to load header" "$corrupt_log"; then
  echo "corrupt checkpoint load failure leaked as a build failure" >&2
  exit 1
fi
require_file "$project/.holbuild/obj/src/ATheory.dat"
# checkpoints persist after successful corrupt-checkpoint rebuild for incremental rebuilds

rm -rf "$project/.holbuild/checkpoints"
write_bad_after_three_source
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/multi-corrupt-seed.log" 2>&1; then
  echo "expected three-context seed failure" >&2
  exit 1
fi
multi_corrupt_second=$(second_context_path)
multi_corrupt_third=$(third_context_path)
printf 'not a valid second checkpoint\n' > "$multi_corrupt_second"
printf 'not a valid third checkpoint\n' > "$multi_corrupt_third"
write_good_three_source
force_rebuild
multi_corrupt_log=$tmpdir/multi-corrupt.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$multi_corrupt_log" 2>&1
require_grep "from: theorem-context checkpoint after third" "$multi_corrupt_log"
require_grep "from: deps-loaded checkpoint" "$multi_corrupt_log"
if grep -q "from: theorem-context checkpoint after second" "$multi_corrupt_log"; then
  echo "invalid source-context checkpoints cascaded instead of falling back to deps-loaded" >&2
  exit 1
fi
if [[ $(grep -c "discarding invalid checkpoint after HOL state load failure" "$multi_corrupt_log") -ne 1 ]]; then
  echo "invalid source-context checkpoints were not discarded as one group" >&2
  exit 1
fi
if grep -q "RetryInvalidCheckpoint\|Couldn't load HOL base-state\|Unable to load header" "$multi_corrupt_log"; then
  echo "multi-corrupt checkpoint retry leaked internal/load failure" >&2
  exit 1
fi
require_file "$project/.holbuild/obj/src/ATheory.dat"

run_expect_suffix_failure "$tmpdir/corrupt-deps-seed.log"
corrupt_deps=$(first_deps_path)
corrupt_context=$(first_context_path)
corrupt_failed_prefix=$(second_failed_prefix_path)
rm -f "$corrupt_context" "$corrupt_context.ok" "$corrupt_failed_prefix" "$corrupt_failed_prefix.ok" "$corrupt_failed_prefix.meta" "$corrupt_failed_prefix.prefix"
printf 'not a valid PolyML deps checkpoint\n' > "$corrupt_deps"
write_good_source
force_rebuild
corrupt_deps_log=$tmpdir/corrupt-deps.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$corrupt_deps_log" 2>&1
require_grep "from: deps-loaded checkpoint" "$corrupt_deps_log"
require_grep "discarding invalid checkpoint after HOL state load failure" "$corrupt_deps_log"
if grep -q "Couldn't load HOL base-state\|Unable to load header" "$corrupt_deps_log"; then
  echo "corrupt deps checkpoint load failure leaked as a build failure" >&2
  exit 1
fi
require_file "$project/.holbuild/obj/src/ATheory.dat"
# checkpoints persist after successful corrupt-deps rebuild for incremental rebuilds

run_expect_suffix_failure "$tmpdir/non-goal-replay-seed.log"
non_goal_replay_deps=$(first_deps_path)
write_non_goal_failure_after_first_source
force_rebuild
non_goal_replay_log=$tmpdir/non-goal-replay.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$non_goal_replay_log" 2>&1; then
  echo "expected non-goal child failure after replay" >&2
  exit 1
fi
require_grep "from: theorem-context checkpoint after first" "$non_goal_replay_log"
require_grep "HOL message: expected non-goal failure after first" "$non_goal_replay_log"
if grep -q "discarding invalid checkpoint after HOL state load failure" "$non_goal_replay_log"; then
  echo "non-load replay failure discarded checkpoints" >&2
  exit 1
fi
if [[ ! -e "$non_goal_replay_deps" || ! -e "$non_goal_replay_deps.ok" ]]; then
  echo "non-load replay failure deleted deps checkpoint" >&2
  exit 1
fi
if ! find "$project/.holbuild/checkpoints/checkpointrecovery/src/AScript.sml.theorems" -type f -print -quit 2>/dev/null | grep -q .; then
  echo "non-load replay failure deleted theorem checkpoints" >&2
  exit 1
fi
rm -rf "$project/.holbuild/checkpoints"

run_expect_suffix_failure "$tmpdir/prefix-seed.log"
write_changed_prefix_source
force_rebuild
prefix_log=$tmpdir/prefix-change.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$prefix_log" 2>&1
if grep -q "from: theorem-context checkpoint after first" "$prefix_log"; then
  echo "prefix-changing edit reused stale theorem checkpoint" >&2
  exit 1
fi
# checkpoints persist after successful prefix-changing rebuild for incremental rebuilds

mkdir -p "$project/.holbuild/checkpoints/checkpointrecovery/src/stale"
printf 'stale residue\n' > "$project/.holbuild/checkpoints/checkpointrecovery/src/stale/manual.save"
printf 'holbuild-checkpoint-ok-v2\nkind=manual\n' > "$project/.holbuild/checkpoints/checkpointrecovery/src/stale/manual.save.ok"
residue_before_up_to_date=$(checkpoint_count)
up_to_date_log=$tmpdir/up-to-date.log
(cd "$project" && "$HOLBUILD_BIN" --verbose build ATheory) > "$up_to_date_log" 2>&1
require_grep "ATheory is up to date" "$up_to_date_log"
residue_after_up_to_date=$(checkpoint_count)
[[ "$residue_before_up_to_date" == "$residue_after_up_to_date" ]] || {
  echo "up-to-date check should not eagerly scan/clean checkpoint residue" >&2
  exit 1
}

rm -rf "$project/.holbuild"
write_non_goal_failure_source
non_goal_failure_log=$tmpdir/non-goal-failure.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$non_goal_failure_log" 2>&1; then
  echo "expected non-goal child failure" >&2
  exit 1
fi
require_grep "child failure:" "$non_goal_failure_log"
require_grep "HOL message: expected non-goal failure" "$non_goal_failure_log"
if grep -q -- "--- child log tail ---" "$non_goal_failure_log"; then
  echo "non-goal failure duplicated full child log tail" >&2
  exit 1
fi
