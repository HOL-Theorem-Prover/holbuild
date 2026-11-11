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
export HOLBUILD_ROOT=${HOLBUILD_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}

# A cache holding one unreferenced blob older than the retention, and a growth
# journal with the given lines.
make_cache() {
  local cache=$1 journal=$2
  mkdir -p "$cache/actions" "$cache/blobs" "$cache/tmp" "$cache/locks"
  : > "$cache/blobs/dead"
  touch -d '10 days ago' "$cache/blobs/dead"
  printf '%s\n' "$journal" > "$cache/locks/gc-growth.journal"
}

auto_gc() {
  local cache=$1 threshold=$2 log=$3
  HOLBUILD_CACHE="$cache" AUTO_GC_THRESHOLD="$threshold" \
    poly --script "$SCRIPT_DIR/auto-gc.sml" > "$log" 2>&1 || { cat "$log" >&2; exit 1; }
  require_grep "auto-gc-returned" "$log"
}

require_no_grep() {
  ! grep -q "$1" "$2" || { echo "unexpected '$1' in $2:" >&2; cat "$2" >&2; exit 1; }
}

require_journal() {
  local cache=$1 expected=$2 actual
  actual=$(tr '\n' ' ' < "$cache/locks/gc-growth.journal")
  [[ $actual == "$expected " ]] || { echo "journal: expected '$expected', got '$actual'" >&2; exit 1; }
}

# Writes count: a published blob its size once, a new manifest 1 MiB.
counted=$tmpdir/counted
printf 'twelve bytes' > "$tmpdir/blob"
HOLBUILD_CACHE="$counted" BLOB_SRC="$tmpdir/blob" BLOB_HASH=$(sha256sum "$tmpdir/blob" | cut -d' ' -f1) \
  poly --script "$SCRIPT_DIR/growth.sml" > "$tmpdir/growth.log" 2>&1 || { cat "$tmpdir/growth.log" >&2; exit 1; }
require_grep "pending=1048588" "$tmpdir/growth.log"
require_grep "flushed=1048588" "$tmpdir/growth.log"
require_journal "$counted" 1048588

# Past the threshold (the journal's lines sum to 12): collects and resets.
trigger=$tmpdir/trigger
make_cache "$trigger" $'6\n6'
auto_gc "$trigger" 10 "$tmpdir/trigger.log"
[[ ! -e "$trigger/blobs/dead" ]] || { echo "automatic gc kept a stale blob" >&2; exit 1; }
require_grep "holbuild: automatic cache gc: removed .* blobs=1 " "$tmpdir/trigger.log"
require_journal "$trigger" 0

# Past the threshold with nothing to remove: resets silently.
clean=$tmpdir/clean
make_cache "$clean" 20
rm "$clean/blobs/dead"
auto_gc "$clean" 10 "$tmpdir/clean.log"
require_no_grep "automatic" "$tmpdir/clean.log"
require_journal "$clean" 0

# Below the threshold: nothing runs.
below=$tmpdir/below
make_cache "$below" 6
auto_gc "$below" 10 "$tmpdir/below.log"
require_file "$below/blobs/dead"
require_no_grep "automatic" "$tmpdir/below.log"
require_journal "$below" 6

# Another process holds the GC lock: skipped, the count kept for next time.
busy=$tmpdir/busy
make_cache "$busy" 20
python3 - "$busy/locks/gc.lock" "$SCRIPT_DIR/auto-gc.sml" "$tmpdir/busy.log" <<'PY'
import fcntl, os, subprocess, sys
lock, script, log = sys.argv[1:]
with open(lock, "a") as held:
    fcntl.lockf(held, fcntl.LOCK_EX)
    result = subprocess.run(["poly", "--script", script], capture_output=True, timeout=60,
        env={**os.environ, "HOLBUILD_CACHE": os.path.dirname(os.path.dirname(lock)),
             "AUTO_GC_THRESHOLD": "10"})
    open(log, "wb").write(result.stdout + result.stderr)
PY
require_grep "auto-gc-returned" "$tmpdir/busy.log"
require_file "$busy/blobs/dead"
require_no_grep "automatic" "$tmpdir/busy.log"
require_journal "$busy" 20

# A failing collection warns and returns.
failing=$tmpdir/failing
make_cache "$failing" 20
chmod a-w "$failing/blobs"
auto_gc "$failing" 10 "$tmpdir/failing.log"
require_grep "holbuild: warning: automatic gc failed: failed to remove cache path" "$tmpdir/failing.log"

# Manual gc resets the journal too.
manual=$tmpdir/manual
make_cache "$manual" 5
env -u HOLDIR -u HOLBUILD_HOLDIR HOLBUILD_CACHE="$manual" "$HOLBUILD_BIN" gc --cache-only > "$tmpdir/manual.log"
require_journal "$manual" 0
