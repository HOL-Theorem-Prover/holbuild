#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# gc --toolchains-only against a --cache-dir cache, using the fake HOL
# toolchain from lib.sh so no real HOL or Poly/ML build is needed.

tmpdir=$(make_temp_dir)
background=()
cleanup() {
  # ${background[@]+...} keeps bash 3.2 (macOS) happy with an empty array under set -u.
  for pid in ${background[@]+"${background[@]}"}; do
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

hol=$tmpdir/hol
fakebin=$tmpdir/fakebin
project=$tmpdir/project
outside=$tmpdir/outside
cache=$tmpdir/cache
env_cache=$tmpdir/env-cache
build_count=$tmpdir/build-count
: > "$build_count"
write_fake_hol "$hol"
old_rev=$(init_git_repo "$hol")
git -C "$hol" commit -q --no-gpg-sign --allow-empty -m second
new_rev=$(git -C "$hol" rev-parse HEAD)
write_fake_poly "$fakebin"
mkdir -p "$project" "$outside"

write_manifest() {
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "gc-toolchains-only-test"

[dependencies.hol]
git = "$hol"
rev = "$1"
TOML
}

unset HOLDIR HOLBUILD_HOLDIR
export HOLBUILD_CANONICAL_HOL_GIT=$hol
export HOLBUILD_POLY=$fakebin/poly
export HOLBUILD_POLYC=$fakebin/polyc
export HOLBUILD_TEST_BUILD_COUNT=$build_count
# --cache-dir must win over the environment.
export HOLBUILD_CACHE=$env_cache

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
  (cd "$project" && "$HOLBUILD_BIN" --cache-dir "$cache" buildhol) > "$tmpdir/buildhol.log" 2>&1 ||
    { cat "$tmpdir/buildhol.log" >&2; exit 1; }
  dirname "$(tail -n 1 "$tmpdir/buildhol.log")"
}

# expect_gc DIR REMOVED BUSY [GC OPTION...]: run gc --toolchains-only from DIR.
# A zero progress interval makes the toolchains stage report on stderr; stdout
# must hold only the summary.
expect_gc() {
  local dir=$1 removed=$2 busy=$3
  shift 3
  (cd "$dir" && HOLBUILD_TEST_GC_PROGRESS_INTERVAL=0 \
    "$HOLBUILD_BIN" --cache-dir "$cache" gc --toolchains-only "$@") > "$tmpdir/gc.out" 2> "$tmpdir/gc.err" ||
    { cat "$tmpdir/gc.out" "$tmpdir/gc.err" >&2; exit 1; }
  [[ $(cat "$tmpdir/gc.out") == "cache gc: removed toolchains=$removed toolchains-busy=$busy" ]] ||
    { echo "unexpected toolchain GC result (wanted removed=$removed busy=$busy):" >&2; cat "$tmpdir/gc.out" >&2; exit 1; }
  grep '^cache gc: toolchains: ' "$tmpdir/gc.err" | tail -n 1 |
    grep -Eq "^cache gc: toolchains: ([0-9]+)/\1 scanned, $removed removed, " ||
    { echo "missing toolchain GC progress on stderr:" >&2; cat "$tmpdir/gc.err" >&2; exit 1; }
}

require_entry() { [[ -f "$1/build.ok" ]] || { echo "toolchain GC removed $2" >&2; exit 1; }; }
require_no_entry() { [[ ! -e "$1" ]] || { echo "toolchain GC kept $2" >&2; exit 1; }; }

write_manifest "$old_rev"
stale_entry=$(buildhol)
write_manifest "$new_rev"
recent_entry=$(buildhol)
[[ "$stale_entry" != "$recent_entry" ]] || { echo "expected two toolchain entries" >&2; exit 1; }
# holbuild prints canonical paths, so compare entries by name rather than
# against $cache, which may contain // from a trailing-slash TMPDIR.
[[ -d "$cache/hol-toolchains/$(basename "$stale_entry")" ]] || { echo "toolchain not under --cache-dir: $stale_entry" >&2; exit 1; }
[[ $(builds) -eq 2 ]] || { echo "expected two toolchain builds" >&2; exit 1; }

# Stale entries that a full or --cache-only GC would remove.
mkdir -p "$cache/tmp/old" "$cache/actions/old" "$cache/blobs" "$cache/locks/action-stale.lock" \
  "$project/.holbuild/stage/old-stage" "$project/.holbuild/logs"
printf 'holbuild-cache-action-v2\nblob dat deadbeef\n' > "$cache/actions/old/manifest"
printf 'blob\n' > "$cache/blobs/deadbeef"
printf 'stage residue\n' > "$project/.holbuild/stage/old-stage/file"
printf 'old log\n' > "$project/.holbuild/logs/old.log"
age 10 "$cache/tmp/old" "$cache/actions/old/manifest" "$cache/actions/old" "$cache/blobs/deadbeef" \
  "$cache/locks/action-stale.lock" "$project/.holbuild/stage/old-stage" "$project/.holbuild/logs/old.log"

# Retention, from outside any project: only the stale toolchain goes, and
# nothing is provisioned.
age 10 "$stale_entry/last-used"
expect_gc "$outside" 1 0
require_no_entry "$stale_entry" "a toolchain unused for the retention period"
require_entry "$recent_entry" "a toolchain used within the retention period"
[[ $(builds) -eq 2 ]] || { echo "gc --toolchains-only built a toolchain" >&2; exit 1; }
[[ ! -e "$env_cache" ]] || { echo "gc --toolchains-only ignored --cache-dir" >&2; exit 1; }

# An active consumer keeps its toolchain even with zero-day retention, and a
# project directory with stale state changes nothing.
event=$tmpdir/consumer.event
gate=$tmpdir/consumer.gate
mkfifo "$gate"
(cd "$project" && exec env HOLBUILD_TEST_FAKE_HOL_EVENT="$event" HOLBUILD_TEST_FAKE_HOL_GATE="$gate" \
  "$HOLBUILD_BIN" --cache-dir "$cache" run) > "$tmpdir/consumer.log" 2>&1 &
consumer=$!
background+=("$consumer")
for _ in $(seq 1 1000); do
  [[ -s "$event" ]] && break
  kill -0 "$consumer" 2>/dev/null || { echo "consumer exited early" >&2; cat "$tmpdir/consumer.log" >&2; exit 1; }
  sleep 0.01
done
[[ -s "$event" ]] || { echo "timed out waiting for consumer" >&2; exit 1; }
expect_gc "$project" 0 1 --retention-days 0
require_entry "$recent_entry" "a toolchain in use by holbuild run"
printf 'continue\n' > "$gate"
wait "$consumer" || { echo "holbuild run failed after GC" >&2; cat "$tmpdir/consumer.log" >&2; exit 1; }
expect_gc "$project" 1 0 --retention-days 0
require_no_entry "$recent_entry" "an idle toolchain with zero-day retention"

for path in "$cache/tmp/old" "$cache/actions/old/manifest" "$cache/blobs/deadbeef" \
    "$cache/locks/action-stale.lock" "$project/.holbuild/stage/old-stage/file" \
    "$project/.holbuild/logs/old.log"; do
  [[ -e "$path" ]] || { echo "gc --toolchains-only removed $path" >&2; exit 1; }
done

for other in --cache-only --clean-only; do
  if (cd "$project" && "$HOLBUILD_BIN" --cache-dir "$cache" gc --toolchains-only "$other") > "$tmpdir/bad-flags.log" 2>&1; then
    echo "gc accepted --toolchains-only with $other" >&2
    exit 1
  fi
  require_grep "mutually exclusive" "$tmpdir/bad-flags.log"
done

# A running cache GC holds locks/gc.lock; toolchain-only GC must not overlap it.
write_manifest "$old_rev"
locked_entry=$(buildhol)
age 10 "$locked_entry/last-used"
python3 - "$cache/locks/gc.lock" "$tmpdir/held" <<'PY' &
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
background+=("$holder")
for _ in $(seq 1 100); do
  [[ -f "$tmpdir/held" ]] && break
  sleep 0.05
done
[[ -f "$tmpdir/held" ]] || { echo "test lock holder did not start" >&2; exit 1; }
if (cd "$outside" && "$HOLBUILD_BIN" --cache-dir "$cache" gc --toolchains-only) > "$tmpdir/locked.log" 2>&1; then
  echo "gc --toolchains-only ran while the cache gc lock was held" >&2
  exit 1
fi
require_grep "cache gc already running" "$tmpdir/locked.log"
require_entry "$locked_entry" "a toolchain while the cache gc lock was held"
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
expect_gc "$outside" 1 0
require_no_entry "$locked_entry" "a stale toolchain once the cache gc lock was free"
[[ ! -e "$cache/locks/gc.lock.owner" ]] || { echo "cache gc lock owner survived" >&2; exit 1; }

(cd "$outside" && "$HOLBUILD_BIN" --cache-dir "$tmpdir/missing" gc --toolchains-only) > "$tmpdir/missing.log" 2>&1
require_grep "cache not found: $tmpdir/missing" "$tmpdir/missing.log"
