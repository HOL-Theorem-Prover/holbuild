#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# Toolchain GC against real holbuild consumers, builders and restorers, using
# the fake HOL toolchain from lib.sh so no real HOL or Poly/ML build is needed.

tmpdir=$(make_temp_dir)
background=()
cleanup() {
  # ${background[@]+...} keeps bash 3.2 (macOS) happy with an empty array under set -u.
  for pid in ${background[@]+"${background[@]}"}; do
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

hol=$tmpdir/hol
fakebin=$tmpdir/fakebin
project=$tmpdir/project
cache=$tmpdir/cache
build_count=$tmpdir/build-count
: > "$build_count"
write_fake_hol "$hol"
hol_rev=$(init_git_repo "$hol")
write_fake_poly "$fakebin"
mkdir -p "$project"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "toolchain-gc-test"

[dependencies.hol]
git = "$hol"
rev = "$hol_rev"
TOML

unset HOLDIR HOLBUILD_HOLDIR
export HOLBUILD_CANONICAL_HOL_GIT=$hol
export HOLBUILD_POLY=$fakebin/poly
export HOLBUILD_POLYC=$fakebin/polyc
export HOLBUILD_TEST_BUILD_COUNT=$build_count
export HOLBUILD_CACHE=$cache

builds() { wc -l < "$build_count" | tr -d ' '; }

# age DAYS PATH...: set modification times without GNU touch -d.
age() {
  python3 - "$@" <<'PY'
import os, sys, time
when = time.time() - float(sys.argv[1]) * 86400
for path in sys.argv[2:]:
    os.utime(path, (when, when))
PY
}

buildhol() {
  (cd "$project" && "$HOLBUILD_BIN" "$@" buildhol) > "$tmpdir/buildhol.log" 2>&1 ||
    { cat "$tmpdir/buildhol.log" >&2; exit 1; }
}

# expect_gc REMOVED BUSY [GC OPTION...]
expect_gc() {
  local removed=$1 busy=$2
  shift 2
  (cd "$project" && "$HOLBUILD_BIN" gc --cache-only "$@") > "$tmpdir/gc.log" 2>&1 ||
    { cat "$tmpdir/gc.log" >&2; exit 1; }
  grep -q "toolchains=$removed toolchains-busy=$busy" "$tmpdir/gc.log" || { echo "unexpected toolchain GC result (wanted removed=$removed busy=$busy):" >&2; cat "$tmpdir/gc.log" >&2; exit 1; }
}

require_entry() { [[ -f "$entry/build.ok" ]] || { echo "toolchain GC removed $1" >&2; exit 1; }; }
require_entry_dir() { [[ -d "$entry" ]] || { echo "toolchain GC removed $1" >&2; exit 1; }; }
require_no_entry() { [[ ! -e "$entry" ]] || { echo "toolchain GC kept $1" >&2; exit 1; }; }

# start_paused NAME EVENT_VAR GATE_VAR HOLBUILD_ARG...: run holbuild in the
# background until it reports EVENT, leaving it blocked on a gate FIFO.
start_paused() {
  local name=$1 event_var=$2 gate_var=$3
  shift 3
  paused_event=$tmpdir/$name.event
  paused_gate=$tmpdir/$name.gate
  paused_log=$tmpdir/$name.log
  mkfifo "$paused_gate"
  (cd "$project" && exec env "$event_var=$paused_event" "$gate_var=$paused_gate" "$HOLBUILD_BIN" "$@") \
    > "$paused_log" 2>&1 &
  paused_pid=$!
  background+=("$paused_pid")
  for _ in $(seq 1 1000); do
    [[ -s "$paused_event" ]] && return 0
    kill -0 "$paused_pid" 2>/dev/null ||
      { echo "$name exited before reaching its gate" >&2; cat "$paused_log" >&2; exit 1; }
    sleep 0.01
  done
  echo "timed out waiting for $name to reach its gate" >&2
  exit 1
}

release_paused() { printf 'continue\n' > "$paused_gate"; }

finish_paused() {
  release_paused
  wait "$paused_pid" || { echo "$1 failed after GC" >&2; cat "$paused_log" >&2; exit 1; }
}

buildhol
entry=$(dirname "$(tail -n 1 "$tmpdir/buildhol.log")")
require_entry "a freshly built toolchain"
[[ -f "$entry/last-used" ]] || { echo "buildhol did not record last-used" >&2; exit 1; }

# Retention: every acquisition refreshes last-used, so a toolchain in use is
# kept; one unused for longer than the retention period is removed and is
# rebuilt on next use.
age 10 "$entry/last-used"
buildhol
expect_gc 0 0
require_entry "a toolchain used within the retention period"
age 10 "$entry/last-used"
expect_gc 1 0
require_no_entry "a toolchain unused for the retention period"
buildhol
[[ $(builds) -eq 2 ]] || { echo "removed toolchain was not rebuilt" >&2; exit 1; }

# An active consumer keeps its toolchain even with zero-day retention.
start_paused consumer HOLBUILD_TEST_FAKE_HOL_EVENT HOLBUILD_TEST_FAKE_HOL_GATE run
expect_gc 0 1 --retention-days 0
require_entry "a toolchain in use by holbuild run"
finish_paused "holbuild run"
expect_gc 1 0 --retention-days 0
require_no_entry "an idle toolchain with zero-day retention"

# An active builder keeps its incomplete entry.
start_paused builder HOLBUILD_TEST_BUILD_EVENT HOLBUILD_TEST_BUILD_GATE buildhol
expect_gc 0 1 --retention-days 0
require_entry_dir "a toolchain being built"
finish_paused "toolchain build"
require_entry "a toolchain whose build overlapped GC"

# A build child that outlives its killed holbuild still holds the mutation
# lease, so GC must not remove the entry from under it.
expect_gc 1 0 --retention-days 0
start_paused orphan HOLBUILD_TEST_BUILD_EVENT HOLBUILD_TEST_BUILD_GATE buildhol
{ kill -KILL "$paused_pid"; wait "$paused_pid"; } 2>/dev/null || true
expect_gc 0 1 --retention-days 0
require_entry_dir "a toolchain with a live orphaned build child"
release_paused
for _ in $(seq 1 1000); do [[ -e "$entry/hol/built" ]] && break; sleep 0.01; done
[[ -e "$entry/hol/built" ]] || { echo "orphaned build child did not finish" >&2; exit 1; }
for _ in $(seq 1 1000); do
  (cd "$project" && "$HOLBUILD_BIN" gc --cache-only --retention-days 0) > "$tmpdir/gc.log" 2>&1
  grep -q "toolchains=1 toolchains-busy=0" "$tmpdir/gc.log" && break
  sleep 0.01
done
require_no_entry "an abandoned toolchain once its orphaned build child exited"

# An active restorer keeps the entry it is installing from a remote cache.
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
buildhol --remote-cache "$remote_url"
expect_gc 1 0 --retention-days 0
builds_before_restore=$(builds)
start_paused restorer HOLBUILD_TEST_TOOLCHAIN_RENAMED HOLBUILD_TEST_TOOLCHAIN_RENAMED_GATE \
  --remote-cache "$remote_url" buildhol
expect_gc 0 1 --retention-days 0
require_entry_dir "a toolchain being restored"
finish_paused "toolchain restore"
require_entry "a toolchain whose restore overlapped GC"
[[ $(builds) -eq $builds_before_restore ]] || { echo "toolchain was rebuilt instead of restored" >&2; exit 1; }
