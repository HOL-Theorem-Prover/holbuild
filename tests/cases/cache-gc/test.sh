#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { chmod -R u+w "$tmpdir" 2>/dev/null || true; rm -rf "$tmpdir"; }
trap cleanup EXIT

cache=$tmpdir/cache
mkdir -p "$cache/tmp/oldtmp" "$cache/blobs" "$cache/actions/live" "$cache/actions/old" "$cache/actions/nomani" "$cache/actions/fresh-nomani" "$cache/actions/old/nested/dir" "$cache/locks/action-stale.lock"
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
[[ -d "$cache/actions/live" ]] || { echo "live action was removed" >&2; exit 1; }
[[ -d "$cache/actions/fresh-nomani" ]] || { echo "fresh incomplete action was removed" >&2; exit 1; }
[[ ! -e "$cache/actions/nomani" ]] || { echo "stale incomplete action survived" >&2; exit 1; }
[[ ! -e "$cache/tmp/oldtmp" ]] || { echo "stale tmp survived" >&2; exit 1; }
[[ ! -e "$cache/locks/action-stale.lock" ]] || { echo "stale action lock survived" >&2; exit 1; }
[[ -f "$cache/locks/gc.lock" ]] || { echo "cache gc lock file missing" >&2; exit 1; }
[[ ! -e "$cache/locks/gc.lock.owner" ]] || { echo "cache gc lock owner survived" >&2; exit 1; }

# A fresh manifest GC cannot read stops GC before any blob it names is swept.
unreadable_cache=$tmpdir/unreadable-cache
mkdir -p "$unreadable_cache/actions/live" "$unreadable_cache/blobs" "$unreadable_cache/tmp"
: > "$unreadable_cache/blobs/live"
printf 'holbuild-cache-action-v2\nblob sig live\n' > "$unreadable_cache/actions/live/manifest"
touch -d '10 days ago' "$unreadable_cache/blobs/live"
chmod a-r "$unreadable_cache/actions/live/manifest"
if [[ -r "$unreadable_cache/actions/live/manifest" ]]; then
  :  # running as a user that ignores file permissions
elif env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$unreadable_cache" "$HOLBUILD_BIN" gc --cache-only > /dev/null 2>&1; then
  echo "GC succeeded despite an unreadable manifest" >&2; exit 1
fi
require_file "$unreadable_cache/blobs/live"

# More stale actions than one removal batch holds are all removed.
batch_cache=$tmpdir/batch-cache
mkdir -p "$batch_cache/actions" "$batch_cache/blobs" "$batch_cache/tmp"
for i in $(seq 1 1100); do
  mkdir "$batch_cache/actions/stale$i"
  printf 'holbuild-cache-action-v2\n' > "$batch_cache/actions/stale$i/manifest"
done
mkdir "$batch_cache/actions/fresh"
printf 'holbuild-cache-action-v2\n' > "$batch_cache/actions/fresh/manifest"
touch -d '10 days ago' "$batch_cache"/actions/stale*/manifest
env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$batch_cache" "$HOLBUILD_BIN" gc --cache-only > "$tmpdir/batch-gc.log"
require_grep "actions=1100 " "$tmpdir/batch-gc.log"
[[ -d "$batch_cache/actions/fresh" ]] || { echo "fresh action was removed" >&2; exit 1; }
[[ $(ls "$batch_cache/actions" | wc -l) -eq 1 ]] || { echo "stale actions survived" >&2; exit 1; }

obsolete_cache=$tmpdir/obsolete-cache
mkdir -p "$obsolete_cache/locks/gc.lock" "$obsolete_cache/actions" "$obsolete_cache/blobs" "$obsolete_cache/tmp"
env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$obsolete_cache" "$HOLBUILD_BIN" gc --cache-only > "$tmpdir/obsolete-gc.log" 2>&1
require_grep "removing obsolete directory cache gc lock" "$tmpdir/obsolete-gc.log"
[[ -f "$obsolete_cache/locks/gc.lock" ]] || { echo "obsolete gc lock directory was not replaced" >&2; exit 1; }
[[ ! -e "$obsolete_cache/locks/gc.lock.owner" ]] || { echo "obsolete gc lock owner survived" >&2; exit 1; }

# Pause a real migrator on its warning, then replace the old directory with a
# sibling's held lock. Migration must leave that file and its inode alone.
# The PID probe needs the binary itself, not the suite's timing wrapper.
if [[ $(uname -s) == Linux ]]; then
  python3 "$SCRIPT_DIR/migration-race.py" "${REAL_HOLBUILD_BIN:-$HOLBUILD_BIN}"
fi

# Checkpoint-store GC must also respect a worker's shared sweep lock.
HOLBUILD_ROOT=${HOLBUILD_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)} \
python3 - "$SCRIPT_DIR/store-lock.sml" "$tmpdir/store-lock-cache" <<'STORELOCK'
import fcntl, os, pathlib, subprocess, sys
script, cache = sys.argv[1:]
root = pathlib.Path(cache)
family = root / "checkpoint-store/old"
family.mkdir(parents=True)
os.utime(family, (1, 1))
(root / "locks").mkdir()
with (root / "locks/gc.lock").open("a") as lock:
    fcntl.lockf(lock, fcntl.LOCK_EX)
    result = subprocess.run(["poly", "--script", script],
        env={**os.environ, "HOLBUILD_CACHE": cache}, capture_output=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    assert b"store-lock-refused" in result.stdout, "checkpoint-store lock check did not run"
    assert family.exists(), "checkpoint-store GC removed a family under a held lock"
STORELOCK

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

# An entry that cannot be removed fails GC with the path that failed inside it,
# and releases the GC lock.
fail_cache=$tmpdir/fail-cache
mkdir -p "$fail_cache/tmp/stuck/ro" "$fail_cache/actions" "$fail_cache/blobs"
: > "$fail_cache/tmp/stuck/ro/file"
age 10 "$fail_cache/tmp/stuck"
chmod a-w "$fail_cache/tmp/stuck/ro"
if env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$fail_cache" \
     "$HOLBUILD_BIN" gc --cache-only > /dev/null 2> "$tmpdir/fail.err"; then
  echo "GC succeeded despite an undeletable entry" >&2; exit 1
fi
chmod u+w "$fail_cache/tmp/stuck/ro"
require_grep "failed to remove cache path: .*$fail_cache/tmp/stuck/ro/file" "$tmpdir/fail.err"
[[ ! -e "$fail_cache/locks/gc.lock.owner" ]] || { echo "failed cache gc kept its lock owner" >&2; exit 1; }
env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$fail_cache" "$HOLBUILD_BIN" gc --cache-only > "$tmpdir/fail-retry.log"
require_grep "removed tmp=1 " "$tmpdir/fail-retry.log"

# --quiet turns progress off.
make_progress_cache "$progress_cache"
env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$progress_cache" HOLBUILD_TEST_GC_PROGRESS_INTERVAL=0 \
  "$HOLBUILD_BIN" --quiet gc --cache-only > "$tmpdir/quiet-progress.out" 2> "$tmpdir/quiet-progress.err"
[[ ! -s "$tmpdir/quiet-progress.err" ]] || { echo "--quiet GC printed progress:" >&2; cat "$tmpdir/quiet-progress.err" >&2; exit 1; }
require_grep "blobs=20 " "$tmpdir/quiet-progress.out"

# On a terminal, progress is redrawn in place only when TERM is ANSI. Needs
# util-linux script(1) for the pseudo-terminal.
if script -qec true /dev/null > /dev/null 2>&1; then
  # gc_on_terminal TERM CACHE: run cache GC on a pseudo-terminal, printing its output.
  gc_on_terminal() {
    local command
    command=$(printf '%q ' env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$2" \
      HOLBUILD_TEST_GC_PROGRESS_INTERVAL=0 "$HOLBUILD_BIN" gc --cache-only)
    TERM=$1 script -qec "$command" /dev/null < /dev/null
  }
  make_progress_cache "$progress_cache"
  gc_on_terminal xterm "$progress_cache" > "$tmpdir/ansi.log"
  require_grep "blobs: 1/20 scanned.*blobs: 2/20 scanned" "$tmpdir/ansi.log"
  make_progress_cache "$progress_cache"
  gc_on_terminal dumb "$progress_cache" > "$tmpdir/dumb.log"
  require_grep "^cache gc: blobs: 20/20 scanned" "$tmpdir/dumb.log"
  ! grep -q $'\033' "$tmpdir/dumb.log" || { echo "GC progress sent escape codes to a dumb terminal" >&2; exit 1; }

  # A stage that fails ends its progress line before the error is printed.
  mkdir -p "$fail_cache/tmp/stuck/ro"
  : > "$fail_cache/tmp/stuck/ro/file"
  for i in $(seq 1 20); do mkdir "$fail_cache/tmp/old$i"; done
  age 10 "$fail_cache/tmp/stuck" "$fail_cache"/tmp/old*
  chmod a-w "$fail_cache/tmp/stuck/ro"
  if gc_on_terminal xterm "$fail_cache" > "$tmpdir/fail-ansi.log"; then
    echo "GC succeeded despite an undeletable entry" >&2; exit 1
  fi
  chmod u+w "$fail_cache/tmp/stuck/ro"
  require_grep "^holbuild: failed to remove cache path: " "$tmpdir/fail-ansi.log"

  # Toolchain removal can warn on stderr mid-stage, here about legacy
  # directory locks, so its reports are not redrawn in place.
  make_progress_cache "$progress_cache"
  for key in 0123456789abcdef0123456789abcdef01234567 0123456789abcdef0123456789abcdef01234568; do
    mkdir -p "$progress_cache/hol-toolchains/$key/hol" \
      "$progress_cache/hol-toolchains/.locks/hol-toolchain-$key.lock"
    : > "$progress_cache/hol-toolchains/$key/last-used"
    age 10 "$progress_cache/hol-toolchains/$key/last-used"
  done
  gc_on_terminal xterm "$progress_cache" > "$tmpdir/toolchain-warning.log"
  require_grep "toolchains=2 " "$tmpdir/toolchain-warning.log"
  [[ $(grep -c "^holbuild: warning: removing obsolete directory HOL toolchain lock" "$tmpdir/toolchain-warning.log") -eq 2 ]] ||
    { echo "toolchain GC warning was appended to a progress line:" >&2; cat -A "$tmpdir/toolchain-warning.log" >&2; exit 1; }
fi

# Leftovers of an interrupted toolchain GC are removed as a reported stage.
make_progress_cache "$progress_cache"
mkdir -p "$progress_cache/hol-toolchains/.trash/interrupted/hol"
: > "$progress_cache/hol-toolchains/.trash/interrupted/hol/file"
env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$progress_cache" HOLBUILD_TEST_GC_PROGRESS_INTERVAL=0 \
  "$HOLBUILD_BIN" gc --cache-only > "$tmpdir/trash.out" 2> "$tmpdir/trash.err"
require_grep "cache gc: toolchain-trash: 1/1 scanned, 1 removed" "$tmpdir/trash.err"
[[ ! -e "$progress_cache/hol-toolchains/.trash/interrupted" ]] || { echo "toolchain trash survived GC" >&2; exit 1; }
