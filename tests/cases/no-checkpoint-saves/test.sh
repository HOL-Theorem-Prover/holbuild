#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# build --no-checkpoint-saves resumes from the checkpoints and failed prefixes
# a build saved, but saves, removes and replaces none, here or in the host's
# deps heap store: whatever it builds, both stay as they were.

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
# A pipelined theory saves no deps_loaded checkpoint.
export HOLBUILD_PIPELINE=off
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)

[project]
name = "no-saves"

[build]
members = ["src"]
TOML

# write_a FIRST SECOND: theory A, with FIRST the first theorem's proof and
# SECOND the end of the second's.
write_a() {
  cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem first:
  T
Proof
  $1
QED
Theorem second:
  T /\\ (1 = 1)
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >> $2
QED
val _ = export_theory();
SML
}

checkpoints=$project/.holbuild/checkpoints
store=$tmpdir/cache/checkpoint-store
# Every file and directory of the checkpoint tree and the store, with its
# inode, modification time and contents.
snapshot() {
  local dir
  for dir in "$checkpoints" "$store"; do
    (cd "$dir" && find . -printf '%y %p %i %T@\n' | sort && find . -type f -exec sha256sum {} + | sort)
  done
}

build() {
  local name=$1
  shift
  set +e
  (cd "$project" && "$HOLBUILD_BIN" build "$@" ATheory) > "$tmpdir/$name.log" 2>&1
  build_status=$?
  set -e
}

expect_failure() {
  local name=$1 message=$2
  [[ "$build_status" != 0 ]] || { cat "$tmpdir/$name.log" >&2; echo "$name: expected the build to fail" >&2; exit 1; }
  require_grep "$message" "$tmpdir/$name.log"
}

expect_unchanged() {
  [[ "$(snapshot)" = "$1" ]] || {
    echo "$2: --no-checkpoint-saves changed the checkpoints:" >&2
    diff <(printf '%s\n' "$1") <(snapshot) >&2 || true
    exit 1
  }
}

# A failing build saves the deps heap, the first theorem's context and the
# second's failed prefix.
write_a "ACCEPT_TAC TRUTH" 'FAIL_TAC "seed failure"'
build seed
expect_failure seed "seed failure"
failed_prefix=$(find "$checkpoints" -name 'second_failed_prefix.save' -print -quit)
require_file "$failed_prefix"
require_file "$failed_prefix.ok"
[[ -n "$(find "$checkpoints" -name 'first_context.save' -print -quit)" ]] || { echo "seed saved no context" >&2; exit 1; }
[[ -n "$(find "$store" -name 'deps_loaded.save' -print -quit)" ]] || { echo "seed stored no deps heap" >&2; exit 1; }
steps=$(sed -n 's/^step_count=//p' "$failed_prefix.meta")
saved=$(snapshot)

# An edit after the failed step resumes from the failed prefix, and gets
# past it, which would otherwise save a later one.
write_a "ACCEPT_TAC TRUTH" 'ALL_TAC >> FAIL_TAC "hit failure"'
build hit --no-checkpoint-saves
expect_failure hit "hit failure"
require_grep "from: failed-prefix checkpoint in second" "$tmpdir/hit.log"
require_grep "restoring proof-ir prefix with $steps successful leaf steps" "$tmpdir/hit.log"
expect_unchanged "$saved" hit

# An edit of the first theorem misses every checkpoint above the deps heap:
# the run would save its own context and failed prefix.
write_a "simp[]" 'FAIL_TAC "miss failure"'
build miss --no-checkpoint-saves
expect_failure miss "miss failure"
require_grep "from: deps-loaded checkpoint" "$tmpdir/miss.log"
expect_unchanged "$saved" miss

# A passing resume keeps the failed prefix it resumed from, and saves no
# context after it. Nor does it run the automatic project and cache GC, which
# evict checkpoints: a threshold that collects after every build, and an
# abandoned staging directory a project GC would remove, show none ran.
printf '[gc]\nproject_builds = 1\n' > "$project/.holconfig.toml"
mkdir -p "$project/.holbuild/stage/abandoned"
: > "$project/.holbuild/stage/abandoned/leftover"
touch -d '10 days ago' "$project/.holbuild/stage/abandoned"
write_a "ACCEPT_TAC TRUTH" 'ALL_TAC >> REFL_TAC'
build pass --no-checkpoint-saves
[[ "$build_status" = 0 ]] || { cat "$tmpdir/pass.log" >&2; echo "the passing build failed" >&2; exit 1; }
require_grep "from: failed-prefix checkpoint in second" "$tmpdir/pass.log"
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_file "$project/.holbuild/stage/abandoned/leftover"
! grep -q "automatic" "$tmpdir/pass.log" || { cat "$tmpdir/pass.log" >&2; echo "automatic gc ran" >&2; exit 1; }
rm -r "$project/.holconfig.toml" "$project/.holbuild/stage/abandoned"
expect_unchanged "$saved" pass

# With the tree's deps heap gone, a run from a fresh preload neither takes the
# store's heap nor removes the checkpoints that were on the tree's.
deps_loaded=$(find "$checkpoints" -name 'deps_loaded.save' -print -quit)
rm "$deps_loaded" "$deps_loaded.ok"
saved=$(snapshot)
write_a "simp[] >> ALL_TAC" 'FAIL_TAC "fresh failure"'
build fresh --no-checkpoint-saves
expect_failure fresh "fresh failure"
if grep -q "^resuming ATheory" "$tmpdir/fresh.log"; then
  cat "$tmpdir/fresh.log" >&2
  echo "the fresh preload resumed from a checkpoint" >&2
  exit 1
fi
expect_unchanged "$saved" fresh

# The failed prefix, whose deps heap is gone, can't be loaded: it stays, and
# the theory runs again restoring nothing.
write_a "ACCEPT_TAC TRUTH" 'ALL_TAC >> FAIL_TAC "invalid failure"'
build invalid --no-checkpoint-saves
expect_failure invalid "invalid failure"
require_grep "not resuming from invalid checkpoint after HOL state load failure: $failed_prefix" "$tmpdir/invalid.log"
expect_unchanged "$saved" invalid

# A REPL starts from the checkpoints a failure saves.
build repl --no-checkpoint-saves --repl-on-failure
expect_failure repl "starts from the checkpoints a failure saves; remove --no-checkpoint-saves"
