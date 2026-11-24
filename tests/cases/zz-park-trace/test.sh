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
# write_a STEP: A's last theorem splits its goal, proves the first conjunct
# and runs STEP on the second.
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
  HOLBUILD_CACHE=$tmpdir/$1 strace -f -tt -s 200 -o "$TRACE_OUT/strace-$1.txt" "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$spec" \
    --share-heaps --cache-limit-gb 1000 --park "$socket" > "$tmpdir/$1.log" 2>&1 &
  park_pid=$!
  for _ in $(seq 600); do
    grep -q "park: listening on" "$tmpdir/$1.log" && break
    kill -0 "$park_pid" 2>/dev/null || { echo "the park server stopped" >&2; cat "$tmpdir/$1.log" >&2; exit 1; }
    sleep 0.5
  done
  grep -q "park: listening on" "$tmpdir/$1.log" || { echo "the park server never listened" >&2; cat "$tmpdir/$1.log" >&2; exit 1; }
}
TRACE_OUT=/home/claude/tasks/opus-parked-warm-prototype/trace
mkdir -p "$TRACE_OUT"
serve park
check() {
  local status=0
  "$HOLBUILD_BIN" park-check "$socket" "$spec" "$project/src/AScript.sml" > "$TRACE_OUT/$1.out" 2> "$TRACE_OUT/$1.err" || status=$?
  echo "check $1 exit $status" >> "$TRACE_OUT/checks.txt"
}
sleep 3
date +%s.%N >> "$TRACE_OUT/checks.txt"; check one; date +%s.%N >> "$TRACE_OUT/checks.txt"
sleep 3
write_a 'FAIL_TAC "second failure"'
date +%s.%N >> "$TRACE_OUT/checks.txt"; check two; date +%s.%N >> "$TRACE_OUT/checks.txt"
sleep 3
cp "$tmpdir/park.log" "$TRACE_OUT/park.log"
