#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# build --check-only gives a target the verdict a plain build would, and
# writes no outputs: none installed, none cached, here or by a remote
# worker.  What the target loads is built and cached as usual, and a
# failed proof still saves its prefix, which the next check resumes from.

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
name = "checkonly"

[build]
members = ["src"]
TOML

cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Theorem a:
  T
Proof
  ACCEPT_TAC TRUTH
QED
SML

# write_t STEP: theory T, on A, whose second theorem's last step is STEP.
write_t() {
  cat > "$project/src/TScript.sml" <<SML
Theory T
Ancestors A

Theorem t1:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem t2:
  T /\\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >> $1
QED
SML
}

obj=$project/.holbuild/obj/src
t_outputs=("$obj/TTheory.dat" "$obj/TTheory.sig" "$obj/TTheory.sml")
checkpoints=$project/.holbuild/checkpoints
saves() { find "$checkpoints" -path "*/$1Script.sml*" -name '*.save' 2>/dev/null | sort; }
# entries: the local cache's action entries, one file per line.
entries() { find "$HOLBUILD_CACHE/actions" -type f 2>/dev/null | sort; }
build() {
  local name=$1
  shift
  set +e
  (cd "$project" && "$HOLBUILD_BIN" build "$@") > "$tmpdir/$name.log" 2>&1
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
no_t_outputs() {
  for output in "${t_outputs[@]}"; do
    if [[ -e "$output" ]]; then echo "$1: check-only wrote $output" >&2; exit 1; fi
  done
}

# A first check builds A in full and checks T alone.
write_t "ACCEPT_TAC TRUTH"
build first --check-only TTheory
expect_build first 0
[[ -f "$obj/ATheory.dat" ]] || { echo "the dependency A was not built" >&2; exit 1; }
no_t_outputs first
a_entries=$(entries)
[[ -n "$a_entries" ]] || { echo "the dependency A was not cached" >&2; exit 1; }

# The same check again builds T again: it left nothing to find.
build again --check-only TTheory
expect_build again 0
no_t_outputs again
[[ "$(entries)" == "$a_entries" ]] || { echo "check-only cached T" >&2; entries >&2; exit 1; }

# A failing proof fails the check as it fails a build, and saves its prefix.
write_t 'FAIL_TAC "seeded failure"'
build fail --check-only TTheory
expect_build fail 1
require_grep "seeded failure" "$tmpdir/fail.log"
grep -q '_failed_prefix\.save$' <<< "$(saves T)" || { echo "the failed check saved no prefix" >&2; saves T >&2; exit 1; }
no_t_outputs fail
build fail-plain TTheory
expect_build fail-plain 1
require_grep "seeded failure" "$tmpdir/fail-plain.log"

# The fixed proof resumes from the prefix and passes; T still has no outputs.
write_t "ALL_TAC >> ACCEPT_TAC TRUTH"
build fixed --check-only TTheory
expect_build fixed 0
require_grep "from: failed-prefix checkpoint in t2" "$tmpdir/fixed.log"
no_t_outputs fixed
[[ "$(entries)" == "$a_entries" ]] || { echo "check-only cached T" >&2; entries >&2; exit 1; }

# A plain build then builds T, and check-only leaves its outputs as they are,
# up to date or not.
build plain TTheory
expect_build plain 0
t_dat=$(sha256sum "$obj/TTheory.dat")
t_metadata=$(find "$project/.holbuild" -name 'TScript.sml.key' -exec sha256sum {} + | sort)
build up-to-date --check-only TTheory
expect_build up-to-date 0
write_t 'FAIL_TAC "after a build"'
build fail-built --check-only TTheory
expect_build fail-built 1
require_grep "after a build" "$tmpdir/fail-built.log"
write_t "ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH"
build pass-built --check-only TTheory
expect_build pass-built 0
[[ "$(sha256sum "$obj/TTheory.dat")" == "$t_dat" ]] || { echo "check-only replaced T's outputs" >&2; exit 1; }
[[ "$(find "$project/.holbuild" -name 'TScript.sml.key' -exec sha256sum {} + | sort)" == "$t_metadata" ]] ||
  { echo "check-only changed T's metadata" >&2; exit 1; }

# A target another target depends on is built in full.
build both --check-only ATheory TTheory
expect_build both 0
build both-check --check-only TTheory ATheory
expect_build both-check 0

for flag in --emit-output-hashes; do
  build "reject$flag" --check-only "$flag" TTheory
  expect_build "reject$flag" 1
  require_grep "remove $flag" "$tmpdir/reject$flag.log"
done

# exec-action: the worker gives the verdict, and publishes nothing of T: no
# action entry, no early-cutoff pair, no deps heap.  A failure still shares
# its prefix.
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
url=$remote_url
worker_cache=$tmpdir/worker
field() { awk -v want="$2" -v col="$3" '$1 == "action" && $5 == want { print $col }' "$1"; }
worker() {
  local name=$1 spec
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$url" action-spec --upload --check-only TTheory) \
    > "$tmpdir/$name.batch"
  spec=$(field "$tmpdir/$name.batch" checkonly:TTheory 4)
  remote_key=$(field "$tmpdir/$name.batch" checkonly:TTheory 3)
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
published() { grep -lx "$1" "$tmpdir"/remote/ac/* 2>/dev/null || true; }
nothing_published() {
  if [[ -e "$tmpdir/remote/ac/$remote_key" ]]; then
    echo "worker $1 published T's entry" >&2; exit 1
  fi
  if [[ -n "$(published holbuild-early-cutoff-v1)$(published holbuild-shared-heap-v1)" ]]; then
    echo "worker $1 published an early-cutoff pair or a deps heap" >&2; exit 1
  fi
}

# A, which T loads, is in the remote cache, as a batch's client leaves it.
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$url" build --force-theory ATheory) > "$tmpdir/publish-a.log" 2>&1 ||
  { cat "$tmpdir/publish-a.log" >&2; exit 1; }

write_t "ALL_TAC >> ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH"
worker share-pass
grep -rqx "option check-only=true" "$tmpdir/remote" || { echo "no spec says check-only" >&2; exit 1; }
expect_worker share-pass 0 "status=built"
nothing_published share-pass

write_t 'FAIL_TAC "remote failure"'
worker share-fail
expect_worker share-fail 1 "status=failed" "failure=proof"
require_grep "remote failure" "$tmpdir/share-fail.log"
nothing_published share-fail
[[ -n "$(published holbuild-shared-failed-prefix-v1)" ]] || {
  echo "the failing check shared no failed prefix" >&2; cat "$tmpdir/share-fail.log" >&2; exit 1; }
