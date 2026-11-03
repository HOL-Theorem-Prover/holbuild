#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# exec-action's worker cache cap, over a cache root of its own (never the
# suite's shared toolchains): fake HOL toolchains, checkpoint families and
# local cache entries, made large with sparse files.

tmpdir=$(make_temp_dir)
background=()
cleanup() {
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
cache=$tmpdir/cache
build_count=$tmpdir/build-count
: > "$build_count"
write_fake_hol "$hol"
rev_idle=$(init_git_repo "$hol")
echo second > "$hol/second.txt"
git -C "$hol" add second.txt
git -C "$hol" commit -q --no-gpg-sign -m second
rev_pinned=$(git -C "$hol" rev-parse HEAD)
write_fake_poly "$fakebin"

unset HOLDIR HOLBUILD_HOLDIR
export HOLBUILD_CANONICAL_HOL_GIT=$hol
export HOLBUILD_POLY=$fakebin/poly
export HOLBUILD_POLYC=$fakebin/polyc
export HOLBUILD_TEST_BUILD_COUNT=$build_count
export HOLBUILD_CACHE=$cache

# toolchain_project NAME REV: a project pinned to that fake HOL revision.
toolchain_project() {
  mkdir -p "$tmpdir/$1"
  cat > "$tmpdir/$1/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "$1"

[dependencies.hol]
git = "$hol"
rev = "$2"
TOML
}

# toolchain_entry NAME: build the project's toolchain and print its entry.
toolchain_entry() {
  (cd "$tmpdir/$1" && "$HOLBUILD_BIN" buildhol) > "$tmpdir/$1.buildhol" 2>&1 ||
    { cat "$tmpdir/$1.buildhol" >&2; exit 1; }
  dirname "$(tail -n 1 "$tmpdir/$1.buildhol")"
}

# at YEAR PATH...: set modification times, oldest years evicted first.
at() {
  python3 - "$@" <<'PY'
import calendar, os, sys
when = calendar.timegm((int(sys.argv[1]), 1, 1, 0, 0, 0))
for path in sys.argv[2:]:
    os.utime(path, (when, when))
PY
}

# sparse PATH GB: a file of that apparent size taking no disk space.
sparse() {
  mkdir -p "$(dirname "$1")"
  python3 - "$1" "$2" <<'PY'
import sys
with open(sys.argv[1], "wb") as f:
    f.truncate(int(sys.argv[2]) * 1024 ** 3)
PY
}

toolchain_project idle "$rev_idle"
toolchain_project pinned "$rev_pinned"
entry_idle=$(toolchain_entry idle)
entry_pinned=$(toolchain_entry pinned)
sparse "$entry_idle/weight" 3
sparse "$entry_pinned/weight" 3

# The pinned toolchain is the least recently used, but a holbuild run holds it.
gate=$tmpdir/pinned.gate
event=$tmpdir/pinned.event
mkfifo "$gate"
(cd "$tmpdir/pinned" &&
   exec env HOLBUILD_TEST_FAKE_HOL_EVENT="$event" HOLBUILD_TEST_FAKE_HOL_GATE="$gate" "$HOLBUILD_BIN" run) \
  > "$tmpdir/pinned.log" 2>&1 &
pinned_pid=$!
background+=("$pinned_pid")
for _ in $(seq 1 1000); do [[ -s "$event" ]] && break; sleep 0.01; done
[[ -s "$event" ]] || { echo "holbuild run did not start" >&2; cat "$tmpdir/pinned.log" >&2; exit 1; }
at 2000 "$entry_pinned/last-used"
at 2002 "$entry_idle/last-used"

# Checkpoint families: an old one, and a recent one that stays.
checkpoints=$cache/checkpoints/pkg/src
sparse "$checkpoints/OldScript.deps/key/deps_loaded.save" 1
sparse "$checkpoints/NewScript.deps/key/deps_loaded.save" 1
at 2001 "$checkpoints/OldScript.deps/key/deps_loaded.save"
at 2005 "$checkpoints/NewScript.deps/key/deps_loaded.save"

# Local cache entries: blob1 is shared, so it goes with entry2, its newest
# user; an unreferenced blob goes first.
blob1=$(printf 1 | sha256sum | cut -d' ' -f1)
blob2=$(printf 2 | sha256sum | cut -d' ' -f1)
orphan=$(printf 3 | sha256sum | cut -d' ' -f1)
sparse "$cache/blobs/$blob1" 1
sparse "$cache/blobs/$blob2" 1
echo orphan > "$cache/blobs/$orphan"
mkdir -p "$cache/actions/entry1" "$cache/actions/entry2"
printf 'blob sig %s\n' "$blob1" > "$cache/actions/entry1/manifest"
printf 'blob sig %s\nblob dat %s\n' "$blob1" "$blob2" > "$cache/actions/entry2/manifest"
at 2001 "$cache/actions/entry1/manifest"
at 2003 "$cache/actions/entry2/manifest"

# 10 GB in all; a 6 GB cap with a 1 GB reserve leaves room for 5 GB, which
# evicting everything but the pinned toolchain and the newest checkpoints
# reaches (4 GB).
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
absent=$(printf absent | sha256sum | cut -d' ' -f1)
set +e
"$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" --result "$tmpdir/result" \
  --cache-limit-gb 6 --cache-reserve-gb 1 > "$tmpdir/exec.log" 2>&1
status=$?
set -e
[[ $status -eq 4 ]] || { echo "exec-action exited $status, wanted 4" >&2; cat "$tmpdir/exec.log" >&2; exit 1; }

printf 'release\n' > "$gate"
wait "$pinned_pid" || { echo "holbuild run failed" >&2; cat "$tmpdir/pinned.log" >&2; exit 1; }
background=()

kept() { [[ -e "$1" ]] || { echo "the cache cap evicted $2" >&2; exit 1; }; }
evicted() { [[ ! -e "$1" ]] || { echo "the cache cap kept $2" >&2; exit 1; }; }
kept "$entry_pinned/weight" "a toolchain in use"
kept "$checkpoints/NewScript.deps" "the most recent checkpoint family"
evicted "$entry_idle" "the idle toolchain"
evicted "$checkpoints/OldScript.deps" "an old checkpoint family"
evicted "$cache/actions/entry1" "an old cache entry"
evicted "$cache/actions/entry2" "a cache entry needed to get under the cap"
evicted "$cache/blobs/$blob1" "a blob whose entries were evicted"
evicted "$cache/blobs/$blob2" "a blob whose entry was evicted"
evicted "$cache/blobs/$orphan" "an unreferenced blob"

# Under the cap (5 GB and a little, with 6 GB of room), nothing is evicted.
sparse "$checkpoints/OldScript.deps/key/deps_loaded.save" 1
at 2001 "$checkpoints/OldScript.deps/key/deps_loaded.save"
set +e
"$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" --result "$tmpdir/result" \
  --cache-limit-gb 7 --cache-reserve-gb 1 > "$tmpdir/exec2.log" 2>&1
set -e
kept "$checkpoints/OldScript.deps" "a checkpoint family under the cap"
kept "$entry_pinned/weight" "an idle toolchain under the cap"

# An evicted entry leaves the blobs a surviving entry still names.
cache2=$tmpdir/cache2
shared=$(printf shared | sha256sum | cut -d' ' -f1)
own=$(printf own | sha256sum | cut -d' ' -f1)
sparse "$cache2/blobs/$shared" 1
sparse "$cache2/blobs/$own" 1
mkdir -p "$cache2/actions/older" "$cache2/actions/newer"
printf 'blob sig %s\nblob dat %s\n' "$shared" "$own" > "$cache2/actions/older/manifest"
printf 'blob sig %s\n' "$shared" > "$cache2/actions/newer/manifest"
at 2001 "$cache2/actions/older/manifest"
at 2002 "$cache2/actions/newer/manifest"
set +e
HOLBUILD_CACHE=$cache2 "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" \
  --result "$tmpdir/result" --cache-limit-gb 2 --cache-reserve-gb 0 > "$tmpdir/exec3.log" 2>&1
set -e
evicted "$cache2/actions/older" "the least recently used entry over the cap"
evicted "$cache2/blobs/$own" "a blob only an evicted entry named"
kept "$cache2/actions/newer" "an entry once the cache fits"
kept "$cache2/blobs/$shared" "a blob a surviving entry names"

# An error outside the action, here no remote cache, is an infrastructure
# failure (exit 3), never the final exit 1.
set +e
env -u HOLBUILD_REMOTE_CACHE_URL "$HOLBUILD_BIN" exec-action "$absent" --cache-limit-gb 7 \
  > "$tmpdir/exec4.log" 2>&1
status=$?
set -e
[[ $status -eq 3 ]] || { echo "exec-action without a remote exited $status, wanted 3" >&2; cat "$tmpdir/exec4.log" >&2; exit 1; }
