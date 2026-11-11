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
# user; a blob no entry names goes when it was last used, as an old one is
# and a recent one isn't.
blob1=$(printf 1 | sha256sum | cut -d' ' -f1)
blob2=$(printf 2 | sha256sum | cut -d' ' -f1)
orphan=$(printf 3 | sha256sum | cut -d' ' -f1)
sparse "$cache/blobs/$blob1" 1
sparse "$cache/blobs/$blob2" 1
recent_orphan=$(printf 4 | sha256sum | cut -d' ' -f1)
echo orphan > "$cache/blobs/$orphan"
echo recent > "$cache/blobs/$recent_orphan"
at 2000 "$cache/blobs/$orphan"
at 2006 "$cache/blobs/$recent_orphan"
mkdir -p "$cache/actions/entry1" "$cache/actions/entry2"
printf 'blob sig %s\n' "$blob1" > "$cache/actions/entry1/manifest"
printf 'blob sig %s\nblob dat %s\n' "$blob1" "$blob2" > "$cache/actions/entry2/manifest"
at 2001 "$cache/actions/entry1/manifest"
at 2003 "$cache/actions/entry2/manifest"
mkdir -p "$cache/theory-modules"
printf 'old module\n' > "$cache/theory-modules/old.pmo"
at 1999 "$cache/theory-modules/old.pmo"

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
# stamped_within STATE GB WHAT: an eviction re-measured the shared roots,
# rather than leaving no stamp or publishing pre-eviction totals.
stamped_within() {
  python3 - "$1" "$2" "$3" <<'PY'
import pathlib, sys
path, gb, what = sys.argv[1:]
assert pathlib.Path(path).exists(), f"no stamp after {what}"
total = sum(map(int, pathlib.Path(path).read_text().split()[3::2]))
assert total <= int(gb) * 1024 ** 3, f"stamp after {what} holds {total} bytes, over {gb} GiB"
PY
}
kept "$entry_pinned/weight" "a toolchain in use"
evicted "$checkpoints/NewScript.deps" "private checkpoints after the action"
evicted "$entry_idle" "the idle toolchain"
evicted "$checkpoints/OldScript.deps" "an old checkpoint family"
evicted "$cache/actions/entry1" "an old cache entry"
evicted "$cache/actions/entry2" "a cache entry needed to get under the cap"
evicted "$cache/blobs/$blob1" "a blob whose entries were evicted"
evicted "$cache/blobs/$blob2" "a blob whose entry was evicted"
evicted "$cache/blobs/$orphan" "an old unreferenced blob"
kept "$cache/blobs/$recent_orphan" "a recently used unreferenced blob"
evicted "$cache/theory-modules/old.pmo" "an old compiled theory module"

# Under the cap, the toolchain remains. Private checkpoints are still cleared
# after the action, independently of the cap.
sparse "$checkpoints/OldScript.deps/key/deps_loaded.save" 1
at 2001 "$checkpoints/OldScript.deps/key/deps_loaded.save"
set +e
"$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" --result "$tmpdir/result" \
  --cache-limit-gb 7 --cache-reserve-gb 1 > "$tmpdir/exec2.log" 2>&1
set -e
evicted "$checkpoints/OldScript.deps" "private checkpoints under the cap"
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

# Young unpublished blobs are last even when a newer manifest can free space.
cache3=$tmpdir/cache3
young=$(printf young | sha256sum | cut -d' ' -f1)
referenced=$(printf referenced | sha256sum | cut -d' ' -f1)
sparse "$cache3/blobs/$young" 1
sparse "$cache3/blobs/$referenced" 2
mkdir -p "$cache3/actions/newer"
printf 'blob dat %s\n' "$referenced" > "$cache3/actions/newer/manifest"
python3 - "$cache3/blobs/$young" <<'YOUNG'
import os, sys, time
when = time.time() - 10
os.utime(sys.argv[1], (when, when))
YOUNG
set +e
HOLBUILD_CACHE=$cache3 "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" \
  --result "$tmpdir/result" --cache-limit-gb 2 --cache-reserve-gb 0 > "$tmpdir/young.log" 2>&1
set -e
kept "$cache3/blobs/$young" "an in-flight orphan while another family could free space"
evicted "$cache3/actions/newer" "a published family before a young orphan"
# Grace never overrides the requested target.
set +e
HOLBUILD_CACHE=$cache3 "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" \
  --result "$tmpdir/result" --cache-limit-gb 1 --cache-reserve-gb 1 > "$tmpdir/grace.log" 2>&1
set -e
evicted "$cache3/blobs/$young" "a young orphan when nothing else could reach the target"

# Reuse a recent shared measurement within the current target.
cache4=$tmpdir/cache4
sparse "$cache4/blobs/first" 1
sweep4() {
  local status=0
  HOLBUILD_CACHE=$cache4 "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" \
    --result "$tmpdir/result" --cache-limit-gb "$1" --cache-reserve-gb "$2" \
    > "$tmpdir/stamp.log" 2>&1 || status=$?
  [[ $status -eq 4 ]] || { cat "$tmpdir/stamp.log" >&2; exit 1; }
}
sweep4 100 1
state=$cache4/locks/worker-cache-cap.state
[[ -s "$state" ]] || { echo "no shared sweep measurement" >&2; exit 1; }
cp "$state" "$tmpdir/first-state"
sparse "$cache4/blobs/second" 1
sweep4 100 1
cmp "$state" "$tmpdir/first-state" || { echo "fresh roomy measurement was not reused" >&2; exit 1; }
# After its result an action refreshes a stamp past half its life, without
# waiting for gc.lock, so that busy hosts keep it fresh.
python3 - "$state" <<'AGE'
import sys, time
lines = open(sys.argv[1]).read().splitlines()
lines[1] = str(time.time_ns() - 40 * 10**9)
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
AGE
cp "$state" "$tmpdir/aged-state"
sweep4 100 1
! cmp -s "$state" "$tmpdir/aged-state" || { echo "a stamp past half its life was not refreshed" >&2; exit 1; }
python3 - "$state" "$tmpdir/aged-state" <<'NEWER'
import sys
new, old = (int(open(p).read().splitlines()[1]) for p in sys.argv[1:])
sys.exit(0 if new > old else "the refreshed stamp is not newer")
NEWER
cp "$state" "$tmpdir/aged-state"
python3 - "$state" <<'AGE'
import sys, time
lines = open(sys.argv[1]).read().splitlines()
lines[1] = str(time.time_ns() - 40 * 10**9)
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
AGE
cp "$state" "$tmpdir/aged-state"
python3 - "$cache4/locks/gc.lock" "$tmpdir/hold.ready" <<'HOLD' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
fcntl.lockf(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(30)
HOLD
holder=$!
for _ in $(seq 100); do [[ -e "$tmpdir/hold.ready" ]] && break; sleep 0.1; done
started=$(date +%s)
sweep4 100 1
(( $(date +%s) - started < 20 )) || { echo "the refresh waited for gc.lock" >&2; exit 1; }
kill "$holder"; wait "$holder" 2>/dev/null || true
cmp "$state" "$tmpdir/aged-state" || { echo "the refresh scanned while gc.lock was held" >&2; exit 1; }
# A small cap scans apparent bytes, including nested sparse growth.
mkdir -p "$cache4/checkpoint-store/family/nested"
sparse "$cache4/checkpoint-store/family/nested/heap" 1
sweep4 7 1
! cmp -s "$state" "$tmpdir/first-state" || { echo "small cap reused a measurement" >&2; exit 1; }
python3 - "$state" <<'BYTES'
import pathlib, sys
assert sum(map(int, pathlib.Path(sys.argv[1]).read_text().split()[3::2])) >= 3 * 1024 ** 3
BYTES
cp "$state" "$tmpdir/small-state"
# Current reserve and fresh private checkpoints participate in the target check.
sweep4 100 50
! cmp -s "$state" "$tmpdir/small-state" || { echo "increased reserve reused a measurement" >&2; exit 1; }
cp "$state" "$tmpdir/reserve-state"
# Private checkpoint bytes count towards the target, so old shared data is
# evicted; the private checkpoint itself is cleared after the action anyway.
at 2000 "$cache4/blobs/first"
sparse "$cache4/checkpoints/pkg/PrivateScript.deps/key/deps_loaded.save" 97
sweep4 100 1
stamped_within "$state" 2 "private checkpoint growth caused eviction"
evicted "$cache4/blobs/first" "old shared data before a new private checkpoint"
evicted "$cache4/checkpoints/pkg/PrivateScript.deps" "private checkpoints after the action"
sparse "$cache4/blobs/first" 1
sweep4 100 1
# Expired, future-dated and malformed state must all fall back to a scan.
for measured in 0 999999999999999999999999 broken; do
  python3 - "$state" "$measured" <<'STAMP'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
lines[1] = sys.argv[2]
path.write_text("\n".join(lines) + "\n")
STAMP
  cp "$state" "$tmpdir/invalid-state"
  sweep4 200 1
  ! cmp -s "$state" "$tmpdir/invalid-state" || { echo "invalid measurement reused" >&2; exit 1; }
done

# Distinct container roots coordinate through host-shared locks/. A waiter
# rechecks the stamp after locking, so a sibling's scan satisfies it.
cache5=$tmpdir/cache5
mkdir -p "$cache5"
for shared_dir in locks checkpoint-store hol-toolchains actions blobs; do
  ln -s "$cache4/$shared_dir" "$cache5/$shared_dir"
done
python3 - "$state" <<'EXPIRE'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
lines[1] = "0"
path.write_text("\n".join(lines) + "\n")
EXPIRE
python3 - "$HOLBUILD_BIN" "$cache5" "$state" "$remote_url" "$absent" "$tmpdir" <<'LOCK'
import fcntl, os, pathlib, subprocess, sys, time
binary, cache, state, remote, absent, tmp = sys.argv[1:]
with open(pathlib.Path(state).parent / "gc.lock", "a") as lock:
    fcntl.lockf(lock, fcntl.LOCK_EX)
    with open(pathlib.Path(tmp) / "waiter.log", "w") as log:
        child = subprocess.Popen(
            [binary, "--remote-cache", remote, "exec-action", absent,
             "--result", str(pathlib.Path(tmp) / "waiter-result"),
             "--cache-limit-gb", "100", "--cache-reserve-gb", "1"],
            env={**os.environ, "HOLBUILD_CACHE": cache}, stdout=log, stderr=log)
        try:
            try:
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
            else:
                raise AssertionError("sweep did not wait on the host-shared lock")
            lines = pathlib.Path(state).read_text().splitlines()
            lines[1] = str(time.time_ns())
            fresh = "\n".join(lines) + "\n"
            pathlib.Path(state).write_text(fresh)
            fcntl.lockf(lock, fcntl.LOCK_UN)
            assert child.wait(timeout=30) == 4
            assert pathlib.Path(state).read_text() == fresh, "waiter repeated sibling's scan"
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
LOCK

# A sibling's shared stamp must not omit this container's private modules.
cp "$state" "$tmpdir/pre-module-state"
at 2000 "$cache4/blobs/first"
sparse "$cache5/theory-modules/large.pmo" 97
set +e
HOLBUILD_CACHE=$cache5 "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" \
  --result "$tmpdir/result" --cache-limit-gb 100 --cache-reserve-gb 1 > "$tmpdir/modules.log" 2>&1
set -e
stamped_within "$state" 2 "private module growth caused eviction"
evicted "$cache4/blobs/first" "old shared data before a new private module"
kept "$cache5/theory-modules/large.pmo" "private modules under the target"
rm "$cache5/theory-modules/large.pmo"
sparse "$cache4/blobs/first" 1
# Refresh through the aliases, preserving coverage of their apparent bytes.
python3 - "$state" <<'EXPIRE'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
lines[1] = "0"
path.write_text("\n".join(lines) + "\n")
EXPIRE
set +e
HOLBUILD_CACHE=$cache5 "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" \
  --result "$tmpdir/result" --cache-limit-gb 100 --cache-reserve-gb 1 > "$tmpdir/modules-refresh.log" 2>&1
set -e
python3 - "$state" <<'ALIASES'
import pathlib, sys
assert sum(map(int, pathlib.Path(sys.argv[1]).read_text().split()[3::2])) >= 3 * 1024 ** 3
ALIASES

# Partial sharing on the same filesystem: differing roots are measured live,
# while matching roots reuse their bytes without rewriting the shared stamp.
cache6=$tmpdir/cache6
mkdir -p "$cache6"
ln -s "$cache4/locks" "$cache6/locks"
sparse "$cache6/blobs/private" 1
cp "$state" "$tmpdir/pre-partial-state"
set +e
HOLBUILD_CACHE=$cache6 "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" \
  --result "$tmpdir/result" --cache-limit-gb 100 --cache-reserve-gb 1 > "$tmpdir/partial.log" 2>&1
set -e
cmp "$state" "$tmpdir/pre-partial-state" || { echo "partial sharing thrashed the stamp" >&2; exit 1; }
# Growing a differing private root over the target must force eviction.
sparse "$cache6/blobs/private" 100
set +e
HOLBUILD_CACHE=$cache6 "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" \
  --result "$tmpdir/result" --cache-limit-gb 100 --cache-reserve-gb 1 > "$tmpdir/partial-large.log" 2>&1
set -e
stamped_within "$state" 99 "a differing private root exceeded the target"
evicted "$cache6/blobs/private" "the differing private root over the target"
# The next action reuses the post-eviction stamp instead of scanning again.
cp "$state" "$tmpdir/post-eviction-state"
set +e
HOLBUILD_CACHE=$cache6 "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" \
  --result "$tmpdir/result" --cache-limit-gb 100 --cache-reserve-gb 1 > "$tmpdir/post-eviction.log" 2>&1
set -e
cmp "$state" "$tmpdir/post-eviction-state" || { echo "the action after an eviction scanned again" >&2; exit 1; }
# Seed a reusable stamp, then perform a separate small-cap eviction.
sparse "$cache6/blobs/private" 2
set +e
HOLBUILD_CACHE=$cache6 "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" \
  --result "$tmpdir/result" --cache-limit-gb 100 --cache-reserve-gb 1 > "$tmpdir/partial-refresh.log" 2>&1
set -e
[[ -s "$state" ]] || { echo "no refreshed shared measurement" >&2; exit 1; }
# A real eviction must re-measure, rather than publish pre-eviction totals.
set +e
HOLBUILD_CACHE=$cache6 "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" \
  --result "$tmpdir/result" --cache-limit-gb 1 --cache-reserve-gb 0 > "$tmpdir/invalidate.log" 2>&1
set -e
stamped_within "$state" 1 "a small-cap eviction"
evicted "$cache6/blobs/private" "a private blob over the cap"

# Existing caches may still have the old directory-shaped GC lock.
cache7=$tmpdir/cache7
mkdir -p "$cache7/locks/gc.lock"
sparse "$cache7/blobs/old" 2
set +e
HOLBUILD_CACHE=$cache7 "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" \
  --result "$tmpdir/result" --cache-limit-gb 1 --cache-reserve-gb 0 > "$tmpdir/legacy-lock.log" 2>&1
set -e
[[ -f "$cache7/locks/gc.lock" ]] || { echo "legacy GC lock directory not migrated" >&2; exit 1; }
evicted "$cache7/blobs/old" "an oversized blob with a legacy GC lock"

# GC may remove private modules while a cap sweep waits for its shared lock.
cache8=$tmpdir/cache8
sparse "$cache8/theory-modules/removed.pmo" 3
sparse "$cache8/blobs/keep" 1
mkdir -p "$cache8/locks"
python3 - "$HOLBUILD_BIN" "$cache8" "$remote_url" "$absent" "$tmpdir" <<'PRIVATE'
import fcntl, os, pathlib, subprocess, sys
binary, cache, remote, absent, tmp = sys.argv[1:]
with open(pathlib.Path(cache) / "locks/gc.lock", "a") as lock:
    fcntl.lockf(lock, fcntl.LOCK_EX)
    with open(pathlib.Path(tmp) / "private-wait.log", "w") as log:
        child = subprocess.Popen(
            [binary, "--remote-cache", remote, "exec-action", absent,
             "--result", str(pathlib.Path(tmp) / "private-result"),
             "--cache-limit-gb", "2", "--cache-reserve-gb", "0"],
            env={**os.environ, "HOLBUILD_CACHE": cache}, stdout=log, stderr=log)
        try:
            try:
                child.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
            else:
                raise AssertionError("sweep did not wait for GC")
            (pathlib.Path(cache) / "theory-modules/removed.pmo").unlink()
            fcntl.lockf(lock, fcntl.LOCK_UN)
            assert child.wait(timeout=30) == 4
            assert (pathlib.Path(cache) / "blobs/keep").exists(), "stale private bytes caused eviction"
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
PRIVATE

# A linked toolchain cache is owned elsewhere. Neither its entries nor its
# trash count towards this worker's cap, and the sweep must leave both alone.
cache9=$tmpdir/cache9
external=$tmpdir/external-toolchains
mkdir -p "$cache9" "$external/.trash/retired"
mv "$entry_pinned" "$external/$(basename "$entry_pinned")"
external_entry=$external/$(basename "$entry_pinned")
sparse "$external/.trash/retired/weight" 3
ln -s "$external" "$cache9/hol-toolchains"
printf owned > "$cache9/own-sentinel"
set +e
HOLBUILD_CACHE=$cache9 "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" \
  --result "$tmpdir/result" --cache-limit-gb 1 --cache-reserve-gb 0 > "$tmpdir/linked.log" 2>&1
status=$?
set -e
[[ $status -eq 4 ]] || { cat "$tmpdir/linked.log" >&2; exit 1; }
kept "$external_entry/weight" "an external toolchain through a symlink"
kept "$external/.trash/retired/weight" "external toolchain trash through a symlink"
if grep -q 'over the .*cap' "$tmpdir/linked.log"; then
  echo 'external toolchains were counted towards the worker cap' >&2
  exit 1
fi

# An error outside the action, here no remote cache, is an infrastructure
# failure (exit 3), never the final exit 1.
set +e
env -u HOLBUILD_REMOTE_CACHE_URL "$HOLBUILD_BIN" exec-action "$absent" --cache-limit-gb 7 \
  > "$tmpdir/exec4.log" 2>&1
status=$?
set -e
[[ $status -eq 3 ]] || { echo "exec-action without a remote exited $status, wanted 3" >&2; cat "$tmpdir/exec4.log" >&2; exit 1; }

# Mature caches between the old extra-cushion ceiling and the eviction target
# must reuse a fresh scan without dropping any retained data.
sweep_mature() {
  local status=0
  HOLBUILD_CACHE=$mature_cache "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$absent" \
    --result "$tmpdir/mature-result" --cache-limit-gb "$1" --cache-reserve-gb "$2" \
    > "$tmpdir/mature.log" 2>&1 || status=$?
  [[ $status -eq 4 ]] || { cat "$tmpdir/mature.log" >&2; exit 1; }
}
for limits in "100 10 89" "400 40 359"; do
  read -r limit reserve bytes <<< "$limits"
  mature_cache=$tmpdir/mature-$limit
  sparse "$mature_cache/checkpoint-store/family/heap" "$bytes"
  sweep_mature "$limit" "$reserve"
  mature_state=$mature_cache/locks/worker-cache-cap.state
  cp "$mature_state" "$tmpdir/mature-state"
  sweep_mature "$limit" "$reserve"
  cmp "$mature_state" "$tmpdir/mature-state" || { echo "mature cache repeated a shared scan" >&2; exit 1; }
  kept "$mature_cache/checkpoint-store/family/heap" "mature cached data under the target"
  # An explicit zero reserve cannot safely reuse even a large cache's estimate.
  sweep_mature "$limit" 0
  ! cmp -s "$mature_state" "$tmpdir/mature-state" || { echo "zero-reserve cache reused a measurement" >&2; exit 1; }
done
