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
