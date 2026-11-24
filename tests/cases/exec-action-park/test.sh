#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# exec-action --park serves the next versions of a script that fails in a
# proof from a process parked before the failing step: a failing version
# answers fail with its diagnostic, the fixed one pass, each from a fresh
# process (nothing the failing step changed is left), and nothing is
# published.

tmpdir=$(make_temp_dir)
server_pid=""
park_pid=""
cleanup() {
  for pid in "$park_pid" "$server_pid"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "park"

[build]
members = ["src"]
TOML
# write_a STEP [LATER]: A's theorem target splits its goal, proves the first
# conjunct and runs STEP on the second; the last theorem runs LATER.
write_a() {
  cat > "$project/src/AScript.sml" <<SML
Theory A
Ancestors bool

val counter = ref 0;

Theorem first_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem target:
  T /\\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >> $1
QED

Theorem later_thm:
  T
Proof
  ${2:-ACCEPT_TAC TRUTH}
QED
SML
}

field() { awk -v want="$2" -v col="$3" '$1 == "action" && $5 == want { print $col }' "$1"; }

write_a 'FAIL_TAC "first failure"'

socket=$tmpdir/park.sock
# serve NAME: a park server on A's current spec, from worker cache NAME.
serve() {
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload ATheory) > "$tmpdir/batch-$1.txt"
  spec=$(field "$tmpdir/batch-$1.txt" park:ATheory 4)
  [[ -n "$spec" ]] || { cat "$tmpdir/batch-$1.txt" >&2; exit 1; }
  link_hol_toolchain_cache "$tmpdir/$1"
  HOLBUILD_CACHE=$tmpdir/$1 "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$spec" \
    --share-heaps --cache-limit-gb 1000 --park "$socket" > "$tmpdir/$1.log" 2>&1 &
  park_pid=$!
  for _ in $(seq 600); do
    grep -q "park: listening on" "$tmpdir/$1.log" && break
    kill -0 "$park_pid" 2>/dev/null || { echo "the park server stopped" >&2; cat "$tmpdir/$1.log" >&2; exit 1; }
    sleep 0.5
  done
  grep -q "park: listening on" "$tmpdir/$1.log" || { echo "the park server never listened" >&2; cat "$tmpdir/$1.log" >&2; exit 1; }
}
serve park
require_grep "park: prepared target at step 2 .* started 2 children" "$tmpdir/park.log"

# check NAME STATUS [SPEC]: park-check of the current A, for SPEC (the
# served one by default), must exit with STATUS.
check() {
  local status=0
  "$HOLBUILD_BIN" park-check "$socket" "${3:-$spec}" "$project/src/AScript.sml" > "$tmpdir/$1.out" 2> "$tmpdir/$1.err" || status=$?
  [[ "$status" == "$2" ]] || {
    echo "park-check $1: wanted exit $2, got $status" >&2
    cat "$tmpdir/$1.out" "$tmpdir/$1.err" "$tmpdir/park.log" >&2
    exit 1
  }
}

# The failing step bumps the counter; the next check must not see it.
write_a '(fn g => (counter := !counter + 1; FAIL_TAC "second failure" g))'
check second 1
require_grep "second failure" "$tmpdir/second.out"

# A proof left unsolved fails after its last step, saving no failed prefix:
# the server parks again where it was.
write_a 'ALL_TAC'
check unsolved 1

# Edits the server cannot check from where it is parked, each answered
# fallback without using a child: a request for another action, a new
# theory mention, an edit above the theorem.
check other-spec 2 0000000000000000000000000000000000000000000000000000000000000000
require_grep "parked on another action" "$tmpdir/other-spec.err"
write_a 'ACCEPT_TAC arithmeticTheory.ADD_0'
check new-mention 2
require_grep "changes what the theory depends on" "$tmpdir/new-mention.err"
write_a 'FAIL_TAC "third failure"'
sed -i 's/^  ACCEPT_TAC TRUTH$/  ACCEPT_TAC TRUTH >> ALL_TAC/' "$project/src/AScript.sml"
check above 2
require_grep "no child is parked" "$tmpdir/above.err"

# An edit before the failing step: the failed prefix does not hold, the
# context's child checks it.
write_a 'FAIL_TAC "fourth failure"'
sed -i 's/CONJ_TAC >- ACCEPT_TAC TRUTH/CONJ_TAC >- (ACCEPT_TAC TRUTH)/' "$project/src/AScript.sml"
check before-step 1
require_grep "fourth failure" "$tmpdir/before-step.out"

write_a '(fn g => (counter := !counter + 1; if !counter = 1 then ACCEPT_TAC TRUTH g else raise Fail "dirty heap"))'
check fixed 0
wait "$park_pid" || { echo "the park server failed" >&2; cat "$tmpdir/park.log" >&2; exit 1; }
park_pid=""
require_grep "park: the script builds, stopping" "$tmpdir/park.log"
[[ ! -e "$socket" ]] || { echo "the park server left its socket" >&2; exit 1; }
# The second and unsolved checks ran from the failed prefix; the one edited
# before the failing step, and the fix, which undoes that edit, from the
# context.
[[ "$(grep -c 'park: served' "$tmpdir/park.log")" == 6 &&
   "$(grep -c 'from: failed-prefix checkpoint in target' "$tmpdir/park.log")" == 2 &&
   "$(grep -c 'failed prefix not resumable' "$tmpdir/park.log")" == 0 ]] || {
  cat "$tmpdir/park.log" >&2; exit 1; }

# A server gone means the caller checks the usual way.
check gone 2

# A proof left unsolved from the start saves no failed prefix: the server
# parks at the theorem's start, on the context before it.
write_a 'ALL_TAC'
serve unsolved-start
require_grep "park: prepared target at step 0 .* started 1 children" "$tmpdir/unsolved-start.log"
write_a 'ACCEPT_TAC TRUTH'
check after-unsolved 0
wait "$park_pid" 2>/dev/null || true
park_pid=""

# A static error in the proof, an undeclared theorem name: no step runs, and
# the server parks at the start of the theorem whose text holds the error.
write_a 'ACCEPT_TAC no_such_theorem'
serve static
require_grep "park: prepared target at step 0 .* started 1 children" "$tmpdir/static.log"
write_a 'ACCEPT_TAC TRUTH'
check after-static 0
wait "$park_pid" 2>/dev/null || true
park_pid=""

# An edit that fixes the failing theorem and leaves a later one unsolved,
# which saves no failed prefix: the server parks again at the start of the
# one that fails now.
write_a 'FAIL_TAC "moved failure"'
serve moved
write_a 'ACCEPT_TAC TRUTH' 'ALL_TAC'
check moved 1
require_grep "later_thm" "$tmpdir/moved.out"
# The server parks again after it answers.
for _ in $(seq 120); do
  [[ "$(grep -c 'park: prepared' "$tmpdir/moved.log")" -ge 2 ]] && break
  sleep 0.5
done
require_grep "park: prepared later_thm at step 0 .* started 1 children" "$tmpdir/moved.log"
write_a 'ACCEPT_TAC TRUTH'
check after-moved 0
