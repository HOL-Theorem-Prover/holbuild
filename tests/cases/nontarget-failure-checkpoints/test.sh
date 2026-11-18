#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A theory that isn't a build target saves no checkpoint while it passes: no
# deps heap, no theorem context.  When one of its proofs fails or times out
# it saves the failed prefix alone, on the toolchain's base state; a rebuild
# resumes from it, and exec-action --share-heaps shares it with other
# workers, which resume from it with no deps heap published.

tmpdir=$(make_temp_dir)
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "nontarget"

[build]
members = ["src"]
tactic_timeout = 0.2
TOML

# write_a STEP [STEP3]: theory A, whose second theorem's last step is STEP
# and whose third theorem's is STEP3 (by default one that proves it).
write_a() {
  cat > "$project/src/AScript.sml" <<SML
Theory A
Ancestors bool

fun slow_tac g = (OS.Process.sleep (Time.fromReal 1.0); ACCEPT_TAC TRUTH g);

Theorem a1:
  T
Proof
  simp[]
QED

Theorem a2:
  T /\\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >> $1
QED

Theorem a3:
  T /\\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >> ${2:-ACCEPT_TAC TRUTH}
QED
SML
}
cat > "$project/src/TScript.sml" <<'SML'
Theory T
Ancestors A

Theorem t:
  T
Proof
  ACCEPT_TAC TRUTH
QED
SML

checkpoints=$project/.holbuild/checkpoints
# saves THEORY: THEORY's saved states, one per line.
saves() { find "$checkpoints" -path "*/$1Script.sml*" -name '*.save' 2>/dev/null | sort; }
# build NAME [TARGET]: build TARGET (default TTheory).
# A failed build echoes no child log; A's are kept under .holbuild/logs.
compacted_failed_prefix() {
  if ! cat "$project"/.holbuild/logs/current/nontarget/ATheory/*.log 2>/dev/null |
       grep -q "checkpoint kind=failed_prefix share=true"; then
    echo "build $1 saved no compacted failed prefix" >&2
    ls -R "$project/.holbuild/logs/current" >&2 || true
    saves A >&2
    for log in "$project"/.holbuild/logs/current/nontarget/ATheory/*.log "$tmpdir/$1.log"; do
      echo "== $log" >&2
      tail -n 40 "$log" >&2 || true
    done
    exit 1
  fi
}
build() {
  local name=$1 target=${2:-TTheory}
  set +e
  (cd "$project" && HOLBUILD_CHECKPOINT_TIMING=1 "$HOLBUILD_BIN" build "$target") > "$tmpdir/$name.log" 2>&1
  build_status=$?
  set -e
}
expect_build() {
  if [[ "$build_status" != "$2" ]]; then
    echo "build $1 exited $build_status, wanted $2" >&2
    cat "$tmpdir/$1.log" >&2
    exit 1
  fi
}
# only_failed_prefix NAME: A's only saved state is a failed prefix.
only_failed_prefix() {
  local states
  states=$(saves A)
  if [[ -z "$states" ]] || grep -qv '_failed_prefix\.save$' <<< "$states"; then
    echo "$1: A saved other states than a failed prefix:" >&2
    printf '%s\n' "$states" >&2
    exit 1
  fi
}

# A passing dependency saves nothing; the target T saves its deps heap.
write_a "ACCEPT_TAC TRUTH"
build pass
expect_build pass 0
if [[ -n "$(saves A)" ]]; then
  echo "the passing dependency A saved checkpoints:" >&2
  saves A >&2
  exit 1
fi
saves T | grep -q '/deps_loaded.save$' || { echo "the target T saved no deps heap" >&2; saves T >&2; exit 1; }

# A failing proof saves its prefix, and the fixed proof resumes from it.
write_a 'FAIL_TAC "seeded failure"'
build fail
expect_build fail 1
require_grep "seeded failure" "$tmpdir/fail.log"
only_failed_prefix fail
# With no deps heap under it, the prefix carries every ancestor: compacted.
compacted_failed_prefix fail
write_a "ALL_TAC >> ACCEPT_TAC TRUTH"
build fixed
expect_build fixed 0
require_grep "from: failed-prefix checkpoint in a2" "$tmpdir/fixed.log"
if [[ -n "$(saves A)" ]]; then
  echo "A kept checkpoints once it passed:" >&2; saves A >&2; exit 1
fi

# Rebuilt as a target, A resumes from the prefix it saved as a dependency, and
# saves no contexts on it: with no deps heap under them none could be reused.
write_a 'FAIL_TAC "seeded failure"'
build fail-again
expect_build fail-again 1
only_failed_prefix fail-again
write_a "ALL_TAC >> ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH"
build as-target ATheory
expect_build as-target 0
require_grep "from: failed-prefix checkpoint in a2" "$tmpdir/as-target.log"
if [[ -n "$(saves A)" ]]; then
  echo "A saved checkpoints on a prefix with no deps heap:" >&2; saves A >&2; exit 1
fi

# A step that times out, and again on its retry at half the budget, saves
# its prefix too, and the next build resumes from it.
write_a "slow_tac"
build timeout
expect_build timeout 1
require_grep "timed out" "$tmpdir/timeout.log"
only_failed_prefix timeout
compacted_failed_prefix timeout
write_a "ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH"
build after-timeout
expect_build after-timeout 0
require_grep "from: failed-prefix checkpoint in a2" "$tmpdir/after-timeout.log"

# exec-action --share-heaps: A's spec names it a dependency of the target T.
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
url=$remote_url
worker_cache=$tmpdir/worker
# worker NAME [TARGET]: exec-action of A's current spec, in a batch for
# TARGET (T, where A is a dependency), on a worker that holds nothing from
# an earlier run.
worker() {
  local name=$1 target=${2:-TTheory} spec
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$url" action-spec --upload "$target") > "$tmpdir/$name.batch"
  spec=$(awk '$1 == "action" && $5 == "nontarget:ATheory" { print $4 }' "$tmpdir/$name.batch")
  [[ -n "$spec" ]] || { cat "$tmpdir/$name.batch" >&2; exit 1; }
  rm -rf "$worker_cache"
  link_hol_toolchain_cache "$worker_cache"
  set +e
  HOLBUILD_CACHE=$worker_cache "$HOLBUILD_BIN" --remote-cache "$url" exec-action "$spec" --share-heaps \
    --cache-limit-gb 1000 --result "$tmpdir/$name.result" > "$tmpdir/$name.log" 2>&1
  worker_status=$?
  set -e
}
expect_worker() {
  local name=$1 code=$2
  shift 2
  if [[ "$worker_status" != "$code" ]]; then
    echo "worker $name exited $worker_status, wanted $code" >&2
    cat "$tmpdir/$name.log" "$tmpdir/$name.result" >&2 || true
    exit 1
  fi
  for line in "$@"; do
    grep -qxF -- "$line" "$tmpdir/$name.result" || {
      echo "worker $name result lacks '$line':" >&2; cat "$tmpdir/$name.result" >&2; exit 1; }
  done
}
# published HEADER: the remote cache's entries of that kind.
published() { grep -lx "$1" "$tmpdir"/remote/ac/* 2>/dev/null || true; }

write_a "ACCEPT_TAC TRUTH"
worker share-pass
expect_worker share-pass 0 "status=built"
if [[ -n "$(published holbuild-shared-heap-v1)$(published holbuild-shared-failed-prefix-v1)" ]]; then
  echo "the passing dependency A shared a heap or checkpoint" >&2; exit 1
fi

write_a 'FAIL_TAC "shared failure"'
worker share-fail
expect_worker share-fail 1 "status=failed" "failure=proof"
[[ -n "$(published holbuild-shared-failed-prefix-v1)" ]] || {
  echo "the failing dependency A shared no failed prefix" >&2; cat "$tmpdir/share-fail.log" >&2; exit 1; }
[[ -z "$(published holbuild-shared-heap-v1)" ]] || { echo "the failing dependency A shared a deps heap" >&2; exit 1; }

# Resumed from that prefix, a later proof fails: the new prefix is published
# with the chain under it, and the next worker resumes at the later proof.
write_a "ALL_TAC >> ACCEPT_TAC TRUTH" 'FAIL_TAC "later failure"'
worker share-chain
expect_worker share-chain 1 "status=failed" "failure=proof"
require_grep "restored shared standalone failed_prefix checkpoint" "$tmpdir/share-chain.log"
require_grep "from: failed-prefix checkpoint in a2" "$tmpdir/share-chain.log"
require_grep "later failure" "$tmpdir/share-chain.log"

write_a "ALL_TAC >> ACCEPT_TAC TRUTH" "ALL_TAC >> ACCEPT_TAC TRUTH"
worker share-fixed
expect_worker share-fixed 0 "status=built"
require_grep "restored shared standalone failed_prefix checkpoint" "$tmpdir/share-fixed.log"
require_grep "from: failed-prefix checkpoint in a3" "$tmpdir/share-fixed.log"

# A passing dependency that restores a deps heap a target build of A shared
# publishes nothing, not even the heap's checkpoint index.
write_a "ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH"
worker share-target ATheory
expect_worker share-target 0 "status=built"
[[ -n "$(published holbuild-shared-heap-v1)" ]] || {
  echo "the target A shared no deps heap" >&2; cat "$tmpdir/share-target.log" >&2; exit 1; }
indexes() { for f in $(grep -lx holbuild-shared-checkpoint-index-v1 "$tmpdir"/remote/ac/* 2>/dev/null); do md5sum "$f"; done; }
before=$(indexes)
# A new proof, so A isn't already in the cache; its deps heap is the same.
write_a "ALL_TAC >> ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH"
worker share-dep-pass
expect_worker share-dep-pass 0 "status=built"
require_grep "restored shared" "$tmpdir/share-dep-pass.log"
if [[ "$(indexes)" != "$before" ]]; then
  echo "the passing dependency A published a checkpoint index:" >&2; indexes >&2; exit 1
fi
