#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# An interrupted exec-action writes its result, with its log, before it
# publishes its checkpoints: a publish that outlasts the worker's few seconds
# loses only them, not the log.

tmpdir=$(make_temp_dir)
server_pid=""
action_pid=""
cleanup() {
  [[ -z "$action_pid" ]] || { kill -KILL "$action_pid" 2>/dev/null || true; wait "$action_pid" 2>/dev/null || true; }
  if [[ -n "$server_pid" ]]; then
    touch "$tmpdir/control/cas-put-release"
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server" "$tmpdir/control"
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "il"

[build]
members = ["src"]
TOML
# Top-level code has no tactic timeout: A runs until it is stopped, after
# saving its theorems' checkpoints.
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Theorem a1:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem a2:
  T
Proof
  ACCEPT_TAC TRUTH
QED

val _ = (print "holbuild-test: running on\n"; TextIO.flushOut TextIO.stdOut;
         OS.Process.sleep (Time.fromSeconds 600));
SML
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload ATheory) > "$tmpdir/batch.txt"
spec=$(awk '$1 == "action" && $5 == "il:ATheory" { print $4 }' "$tmpdir/batch.txt")
[[ -n "$spec" ]] || { cat "$tmpdir/batch.txt" >&2; exit 1; }

worker=$tmpdir/worker
link_hol_toolchain_cache "$worker"
# The binary itself, not the suite's wrapper: the signal must reach it.
HOLBUILD_CACHE=$worker "${REAL_HOLBUILD_BIN:-$HOLBUILD_BIN}" --remote-cache "$remote_url" exec-action "$spec" \
  --share-heaps --cache-limit-gb 1000 --result "$tmpdir/result" > "$tmpdir/action.log" 2>&1 &
action_pid=$!
for _ in $(seq 1 1200); do
  grep -rqs --include='*.log' 'holbuild-test: running on' "$worker" && break
  kill -0 "$action_pid" 2>/dev/null || break
  sleep 0.1
done
grep -rqs --include='*.log' 'holbuild-test: running on' "$worker" || {
  echo "A did not reach its top-level code" >&2
  find "$worker" -name "*.log" -newer "$tmpdir/batch.txt" >&2
  cat "$tmpdir/action.log" >&2
  exit 1
}

# Checkpoint uploads (heaps, megabytes) stall; the log's (a few KB) doesn't.
echo $((1024 * 1024)) > "$tmpdir/control/min-bytes.tmp"
mv "$tmpdir/control/min-bytes.tmp" "$tmpdir/control/cas-put-enable-min-bytes"
kill -TERM "$action_pid"
for _ in $(seq 1 300); do
  [[ -s "$tmpdir/result" ]] && break
  kill -0 "$action_pid" 2>/dev/null || break
  sleep 0.1
done
[[ -s "$tmpdir/result" ]] || {
  echo "interrupted exec-action wrote no result while its checkpoint upload stalled" >&2
  cat "$tmpdir/action.log" >&2
  exit 1
}
grep -qx 'status=failed' "$tmpdir/result"
grep -qx 'failure=unavailable' "$tmpdir/result"
log=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$tmpdir/result")
[[ -n "$log" ]] || { echo "the interrupted action's result has no log" >&2; cat "$tmpdir/result" >&2; exit 1; }
[[ -f "$tmpdir/remote/cas/$log" ]] || { echo "the result's log $log was not uploaded" >&2; exit 1; }
kill -0 "$action_pid" 2>/dev/null || { echo "exec-action did not wait on its checkpoint upload" >&2; exit 1; }
