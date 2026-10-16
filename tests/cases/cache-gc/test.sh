#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

cache=$tmpdir/cache
mkdir -p "$cache/tmp/oldtmp" "$cache/blobs" "$cache/actions/live" "$cache/actions/old" "$cache/actions/nomani" "$cache/locks/action-stale.lock"
: > "$cache/blobs/live"
: > "$cache/blobs/dead"
printf 'holbuild-cache-action-v2\nblob sig live\n' > "$cache/actions/live/manifest"
printf 'holbuild-cache-action-v2\nblob=old\n' > "$cache/actions/old/manifest"
touch -d '10 days ago' \
  "$cache/tmp/oldtmp" \
  "$cache/blobs/live" \
  "$cache/blobs/dead" \
  "$cache/actions/old/manifest" \
  "$cache/actions/nomani" \
  "$cache/locks/action-stale.lock"

env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$cache" "$HOLBUILD_BIN" gc --cache-only > "$tmpdir/cache-gc.log"

require_file "$cache/blobs/live"
[[ ! -e "$cache/blobs/dead" ]] || { echo "unreferenced blob survived" >&2; exit 1; }
[[ ! -e "$cache/actions/old" ]] || { echo "old action survived" >&2; exit 1; }
[[ ! -e "$cache/actions/nomani" ]] || { echo "stale incomplete action survived" >&2; exit 1; }
[[ ! -e "$cache/tmp/oldtmp" ]] || { echo "stale tmp survived" >&2; exit 1; }
[[ ! -e "$cache/locks/action-stale.lock" ]] || { echo "stale action lock survived" >&2; exit 1; }
[[ -f "$cache/locks/gc.lock" ]] || { echo "cache gc lock file missing" >&2; exit 1; }
[[ ! -e "$cache/locks/gc.lock.owner" ]] || { echo "cache gc lock owner survived" >&2; exit 1; }

obsolete_cache=$tmpdir/obsolete-cache
mkdir -p "$obsolete_cache/locks/gc.lock" "$obsolete_cache/actions" "$obsolete_cache/blobs" "$obsolete_cache/tmp"
env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$obsolete_cache" "$HOLBUILD_BIN" gc --cache-only > "$tmpdir/obsolete-gc.log" 2>&1
require_grep "removing obsolete directory cache gc lock" "$tmpdir/obsolete-gc.log"
[[ -f "$obsolete_cache/locks/gc.lock" ]] || { echo "obsolete gc lock directory was not replaced" >&2; exit 1; }
[[ ! -e "$obsolete_cache/locks/gc.lock.owner" ]] || { echo "obsolete gc lock owner survived" >&2; exit 1; }

live_cache=$tmpdir/live-cache
mkdir -p "$live_cache/locks" "$live_cache/actions" "$live_cache/blobs" "$live_cache/tmp"
python3 - "$live_cache/locks/gc.lock" "$live_cache/held" <<'PY' &
import fcntl
import os
import sys
import time

lock, held = sys.argv[1:]
fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o666)
fcntl.lockf(fd, fcntl.LOCK_EX)
with open(held, "w") as out:
    out.write("held\n")
time.sleep(60)
PY
holder=$!
for _ in $(seq 1 100); do
  [[ -f "$live_cache/held" ]] && break
  sleep 0.05
done
[[ -f "$live_cache/held" ]] || { echo "test lock holder did not start" >&2; kill "$holder" 2>/dev/null || true; exit 1; }
if env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$live_cache" "$HOLBUILD_BIN" gc --cache-only > "$tmpdir/live-gc.log" 2>&1; then
  echo "cache gc unexpectedly acquired a live lock" >&2
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  exit 1
fi
require_grep "cache gc already running" "$tmpdir/live-gc.log"
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$live_cache" "$HOLBUILD_BIN" gc --cache-only > "$tmpdir/live-gc-after-kill.log"
[[ ! -e "$live_cache/locks/gc.lock.owner" ]] || { echo "cache gc lock owner survived after retry" >&2; exit 1; }

# age DAYS PATH...: set modification times, without following symlinks.
age() {
  python3 - "$@" <<'PY'
import os, sys, time
when = time.time() - float(sys.argv[1]) * 86400
for path in sys.argv[2:]:
    os.utime(path, (when, when), follow_symlinks=False)
PY
}

# Entry removal never follows symlinks out of the cache.
outside=$tmpdir/outside
safe_cache=$tmpdir/safe-cache
mkdir -p "$outside/keep" "$safe_cache/tmp/olddir" "$safe_cache/actions" "$safe_cache/blobs"
printf 'keep\n' > "$outside/keep/file"
ln -s "$outside/keep" "$safe_cache/tmp/olddir/link"
ln -s "$outside/keep" "$safe_cache/tmp/oldlink"
age 10 "$safe_cache/tmp/olddir/link" "$safe_cache/tmp/olddir" "$safe_cache/tmp/oldlink" "$outside/keep"
env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$safe_cache" "$HOLBUILD_BIN" gc --cache-only > "$tmpdir/safe-gc.log"
require_grep "removed tmp=2 " "$tmpdir/safe-gc.log"
[[ ! -e "$safe_cache/tmp/olddir" && ! -L "$safe_cache/tmp/oldlink" ]] || { echo "stale tmp entries survived" >&2; exit 1; }
require_file "$outside/keep/file"

# Long stages report progress on stderr before the summary; stdout keeps only
# the summary line. The test interval forces a report for every entry.
make_progress_cache() {
  local dir=$1
  rm -rf "$dir"
  mkdir -p "$dir/actions" "$dir/blobs" "$dir/tmp"
  for i in $(seq 1 20); do : > "$dir/blobs/blob$i"; done
  age 10 "$dir"/blobs/*
}
progress_cache=$tmpdir/progress-cache
make_progress_cache "$progress_cache"
env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$progress_cache" HOLBUILD_TEST_GC_PROGRESS_INTERVAL=0 \
  "$HOLBUILD_BIN" gc --cache-only > "$tmpdir/progress.log" 2>&1
require_grep "cache gc: blobs: 1/20 scanned, 1 removed" "$tmpdir/progress.log"
require_grep "cache gc: blobs: 20/20 scanned, 20 removed" "$tmpdir/progress.log"
first_progress=$(grep -n "cache gc: blobs:" "$tmpdir/progress.log" | head -n 1 | cut -d: -f1)
summary=$(grep -n "cache gc: removed" "$tmpdir/progress.log" | cut -d: -f1)
[[ $first_progress -lt $summary ]] || { echo "GC progress was not reported before completion" >&2; exit 1; }
make_progress_cache "$progress_cache"
env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$progress_cache" HOLBUILD_TEST_GC_PROGRESS_INTERVAL=0 \
  "$HOLBUILD_BIN" gc --cache-only > "$tmpdir/progress.out" 2> /dev/null
[[ $(wc -l < "$tmpdir/progress.out") -eq 1 ]] || { echo "GC progress leaked onto stdout" >&2; exit 1; }
require_grep "blobs=20 " "$tmpdir/progress.out"

# A GC that finishes within the default interval prints no progress.
make_progress_cache "$progress_cache"
env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$progress_cache" \
  "$HOLBUILD_BIN" gc --cache-only > /dev/null 2> "$tmpdir/quiet.err"
[[ ! -s "$tmpdir/quiet.err" ]] || { echo "fast GC printed progress:" >&2; cat "$tmpdir/quiet.err" >&2; exit 1; }
