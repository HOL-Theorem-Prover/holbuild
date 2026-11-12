#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# build --remote-exec against a stub coordinator whose "workers" run each
# action with exec-action, sharing only the remote cache with the client.

tmpdir=$(make_temp_dir)
cleanup() {
  for pid in ${server_pid:-} ${coordinator_pid:-} ${ring_server_pid:-}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

remote_root=$tmpdir/remote
start_remote_cache_server "$remote_root" "$tmpdir/server" "$tmpdir/cache-control"
use_case_cache "$tmpdir/cache"

# The stand-in for the workers: runs the batch's actions in order (parents
# come before children) in a cache root and directory of their own, until
# one fails, leaving each action's result for the stub to report.
state=$tmpdir/coordinator
mkdir -p "$state"
link_hol_toolchain_cache "$tmpdir/worker-cache"
mkdir -p "$tmpdir/worker-cwd"
cat > "$tmpdir/run-batch" <<SH
#!/usr/bin/env bash
set -eu
[[ ! -e "$state/fail" ]] || exit 1
cd "$tmpdir/worker-cwd"
heap=()
[[ ! -e "\${1%.batch}.heap" ]] || heap=(--max-heap "\$(cat "\${1%.batch}.heap")")
share=
[[ ! -e "$state/share-heaps" ]] || share=--share-heaps
rm -f "$state/failed-batch" "$tmpdir/cache-control/ac-put-status"


# A worker that trusts no HOL repository rejects every spec.
untrusted=()
[[ ! -e "$state/untrusted" ]] || untrusted=(HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES=/unconfigured=master)
awk '\$1 == "action" { print \$2, \$4, \$5 }' "\$1" | while read -r key spec theory; do
  if [[ -e "$state/keep-going" ]]; then
    blocked=
    for parent in \$(awk -v key="\$key" '\$1 == "edge" && \$2 == key { print \$3 }' "\$1"); do
      if grep -Eq '^status=(failed|skipped)$' "$state/result-\$parent"; then
        blocked=\$parent
        break
      fi
    done
    if [[ -n \$blocked ]]; then
      printf 'holbuild-action-result-v1\\nstatus=skipped\\nfailure=skipped because of %s\\n' "\$blocked" > "$state/result-\$key"
      continue
    fi
  fi
  echo "\$theory" >> "$state/ran"
  status=0
  env "\${untrusted[@]}" HOLBUILD_CACHE="$tmpdir/worker-cache" "$HOLBUILD_BIN" --remote-cache "$remote_url" "\${heap[@]}" \
    exec-action "\$spec" --cache-limit-gb 1000 --result "$tmpdir/worker.result" \$share \
    >> "$tmpdir/worker.log" 2>&1 || status=\$?
  echo "\$theory \$(grep '^status=' "$tmpdir/worker.result")" >> "$state/results"
  cp "$tmpdir/worker.result" "$state/result-\$key"
  [[ "\$(cat "$state/memory-failure" 2>/dev/null)" != "\$theory" ]] ||
    sed -i 's/^failure=.*/failure=memory/' "$state/result-\$key"
  if [[ -e "$state/drop-log" ]] || { [[ -e "$state/drop-success-log" ]] && [[ \$status -eq 0 ]]; }; then
    rm -f "$remote_root/cas/\$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$tmpdir/worker.result")"
  fi
  if [[ -e "$state/optional-log-outage" && \$theory == *:ATheory ]]; then
    echo 500 > "$tmpdir/cache-control/cas-get-status-\$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$tmpdir/worker.result")"
  fi
  # A failed action fails the batch, naming the theory or blob it found
  # missing.
  if [[ \$status -ne 0 ]]; then
    if [[ -e "$state/keep-going" ]]; then
      touch "$state/failed-batch"
    else
      sed -n 's/^missing=//p' "$tmpdir/worker.result" > "$state/missing"
      exit 1
    fi
  fi
done
# Until the next batch, the remote cache takes no entries.
[[ ! -e "$state/refuse-ac-put" ]] || echo 503 > "$tmpdir/cache-control/ac-put-status"
[[ ! -e "$state/failed-batch" ]]
SH
chmod +x "$tmpdir/run-batch"
python3 "$SCRIPT_DIR/../../fixtures/remote_exec_coordinator.py" \
  "$state/port" "$state" "$tmpdir/run-batch" &
coordinator_pid=$!
for _ in {1..100}; do
  [[ -s "$state/port" ]] && break
  sleep 0.01
done
coordinator="http://127.0.0.1:$(< "$state/port")"
# Nothing listens here.
unreachable="http://127.0.0.1:9"
# Four quick retries rather than the production schedule's minutes.
export HOLBUILD_TEST_RETRY_DELAYS=0,0,0,0

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rx"

[build]
members = ["src"]
TOML
write_theories() {
  local stamp=$1
  cat > "$project/src/AScript.sml" <<SML
Theory A
Ancestors bool

Theorem a_thm:
  T
Proof
  simp[] (* $stamp *)
QED
SML
  cat > "$project/src/BScript.sml" <<SML
Theory B
Ancestors A

Theorem b_thm:
  T
Proof
  ACCEPT_TAC a_thm (* $stamp *)
QED
SML
}

hb() {
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" "$@")
}

# run NAME EXPECTED-EXIT ARGS...: runs hb with ARGS, logging to $tmpdir/NAME.log.
run() {
  local name=$1 code=$2
  shift 2
  set +e
  hb "$@" > "$tmpdir/$name.log" 2>&1
  local status=$?
  set -e
  if [[ "$status" != "$code" ]]; then
    echo "$name exited $status, wanted $code" >&2
    cat "$tmpdir/$name.log" >&2
    exit 1
  fi
}

refute_grep() {
  if grep -q -- "$1" "$2"; then
    echo "unexpected '$1' in $2:" >&2
    cat "$2" >&2
    exit 1
  fi
}

# Submit and follow: the workers build both theories, and the client restores
# them from the remote cache without building anything itself.
write_theories one
run follow 0 build --remote-exec "$coordinator" BTheory
require_grep "holbuild: remote batch b1" "$tmpdir/follow.log"
require_grep "holbuild: remote rx:BTheory: done" "$tmpdir/follow.log"
[[ $(grep -c "remote rx:BTheory: running" "$tmpdir/follow.log") -eq 1 ]] || { cat "$tmpdir/follow.log" >&2; exit 1; }
require_grep "holbuild: remote execution: remote workers finished 2 of 2 theories" "$tmpdir/follow.log"
require_grep "ATheory restored from cache" "$tmpdir/follow.log"
require_grep "BTheory restored from cache" "$tmpdir/follow.log"
refute_grep "Theory built" "$tmpdir/follow.log"
[[ $(grep -c . "$state/ran") -eq 2 ]] || { cat "$state/ran" >&2; exit 1; }
require_grep "^action .* rx:ATheory$" "$state/b1.batch"
require_grep "^edge " "$state/b1.batch"

# With everything cached there is nothing to submit.
run cached 0 build --remote-exec "$coordinator" BTheory
refute_grep "remote batch" "$tmpdir/cached.log"
require_grep "remote execution: nothing to build remotely" "$tmpdir/cached.log"

# Detach and reattach.
write_theories two
run detach 0 build --remote-exec "$coordinator" --detach BTheory
require_grep "holbuild: remote batch b2" "$tmpdir/detach.log"
refute_grep "Theory built\|restored from cache" "$tmpdir/detach.log"
run attach 0 build --remote-exec "$coordinator" --attach b2 BTheory
require_grep "BTheory restored from cache" "$tmpdir/attach.log"
refute_grep "Theory built" "$tmpdir/attach.log"
[[ $(grep -c '^POST' "$state/requests.log") -eq 2 ]] || { cat "$state/requests.log" >&2; exit 1; }

# A coordinator that can't be reached, refuses the batch, or loses the
# event stream: the build goes on locally, or fails with --remote-only (exit
# status 75, so a caller can build locally) or --detach (1).  With
# --remote-only an unreachable coordinator is retried first, as one moving
# to a new instance is; without it the build falls back at once.
write_theories three
run unreachable-only 75 build --remote-exec "$unreachable" --remote-only BTheory
require_grep "remote execution: could not reach the coordinator at $unreachable" "$tmpdir/unreachable-only.log"
[[ $(grep -c "could not reach the coordinator at $unreachable.*; retrying" "$tmpdir/unreachable-only.log") -eq 4 ]] ||
  { cat "$tmpdir/unreachable-only.log" >&2; exit 1; }
refute_grep "Theory built" "$tmpdir/unreachable-only.log"
run unreachable 0 build --remote-exec "$unreachable" BTheory
refute_grep "retrying" "$tmpdir/unreachable.log"
require_grep "building locally" "$tmpdir/unreachable.log"
require_grep "BTheory built" "$tmpdir/unreachable.log"

write_theories four
touch "$state/refuse"
run refused-only 75 build --remote-exec "$coordinator" --remote-only BTheory
require_grep "coordinator refused the batch (HTTP 400): .*batch refused by the stub" "$tmpdir/refused-only.log"
run refused-detach 1 build --remote-exec "$coordinator" --detach BTheory
refute_grep "Theory built" "$tmpdir/refused-detach.log"
run refused-only-detach 1 build --remote-exec "$coordinator" --remote-only --detach BTheory
refute_grep "Theory built" "$tmpdir/refused-only-detach.log"
run refused 0 build --remote-exec "$coordinator" BTheory
require_grep "BTheory built" "$tmpdir/refused.log"
rm "$state/refuse"

# A dropped stream is reattached; one that stays down is given up on, and
# the batch cancelled if the coordinator answers.
write_theories five
touch "$state/drop"
run dropped 0 build --remote-exec "$coordinator" BTheory
require_grep "lost the event stream for batch b3; reattaching" "$tmpdir/dropped.log"
require_grep "remote execution: remote workers finished 2 of 2 theories" "$tmpdir/dropped.log"
require_grep "BTheory restored from cache" "$tmpdir/dropped.log"
refute_grep "Theory built\|building locally" "$tmpdir/dropped.log"
write_theories five-down
touch "$state/down"
run down 0 build --remote-exec "$coordinator" BTheory
[[ $(grep -c "answered HTTP 503 to the event stream for batch b4.*; reattaching" "$tmpdir/down.log") -eq 4 ]] ||
  { cat "$tmpdir/down.log" >&2; exit 1; }
require_grep "could not cancel remote batch b4 (HTTP 503)" "$tmpdir/down.log"
require_grep "the coordinator reported no theories; building locally" "$tmpdir/down.log"
require_grep "BTheory built" "$tmpdir/down.log"
write_theories five-down-only
run down-only 75 build --remote-exec "$coordinator" --remote-only --priority 17 --speculative-loading=5 BTheory
require_grep "the coordinator reported no theories; reattach with --attach b5 --priority 17 --speculative-loading=5$" \
  "$tmpdir/down-only.log"
refute_grep "^POST /v1/batches/b5/cancel " "$state/requests.log"
rm "$state/down"
run unknown-only 75 build --remote-exec "$coordinator" --remote-only --attach nope BTheory
require_grep "batch nope can't be followed (HTTP 404): .*no such batch.*, cancelled the batch" "$tmpdir/unknown-only.log"
require_grep "^POST /v1/batches/nope/cancel " "$state/requests.log"
refute_grep "reattach" "$tmpdir/unknown-only.log"
run unknown 0 build --remote-exec "$coordinator" --attach nope BTheory
require_grep "batch nope can't be followed (HTTP 404): .*, cancelled the batch; building locally" "$tmpdir/unknown.log"
[[ $(grep -c "^POST /v1/batches/nope/cancel " "$state/requests.log") -eq 2 ]] || { echo "wanted a cancel of batch nope from each of unknown-only and unknown" >&2; exit 1; }

# A batch reported done whose results aren't in the remote cache: with
# --remote-only nothing is built locally, and the exit status says a local
# build would go on.
write_theories five-skip
touch "$state/skip"
run skipped-only 75 build --remote-exec "$coordinator" --remote-only BTheory
require_grep "ATheory is not in the remote cache, and --remote-only builds nothing locally" "$tmpdir/skipped-only.log"
refute_grep "Theory built" "$tmpdir/skipped-only.log"
rm "$state/skip"

# A proof failure with no log stays a failure even if its local diagnostic
# retry succeeds. --remote-only requests diagnostics without running HOL.
write_theories six
touch "$state/fail"
run failed-only 75 build --remote-exec "$coordinator" --remote-only BTheory
require_grep "remote rx:ATheory: failed (proof)" "$tmpdir/failed-only.log"
require_grep "remote execution: batch b7 failed: an action failed; remote workers finished 0 of 2 theories" "$tmpdir/failed-only.log"
run failed 1 build --remote-exec "$coordinator" BTheory
require_grep "could not fetch the failed theory's build log; building ATheory locally" "$tmpdir/failed.log"
require_grep "ATheory failed remotely: proof" "$tmpdir/failed.log"
require_grep "BTheory built" "$tmpdir/failed.log"
refute_grep "^POST /v1/batches/b8/cancel " "$state/requests.log"
rm "$state/fail"

# A batch that ended while its stream was down isn't reported cancelled.
write_theories ended
touch "$state/ended"
run ended 0 build --remote-exec "$coordinator" BTheory
require_grep "^POST /v1/batches/b9/cancel " "$state/requests.log"
require_grep "the coordinator reported no theories; building locally" "$tmpdir/ended.log"
refute_grep "cancel" "$tmpdir/ended.log"
rm "$state/ended"

# An interrupted build cancels the batch it follows, --remote-only too.
# interrupt NAME ARGS...: starts hb with ARGS, logging to $tmpdir/NAME.log,
# and sends holbuild SIGTERM once it follows its batch.  HOLBUILD_BIN may be
# a wrapper that runs holbuild as its child, as tests/run.sh's does, so the
# signal goes to that child if there is one, else to $! itself.
interrupt() {
  local name=$1
  shift
  (cd "$project" && exec "$HOLBUILD_BIN" --remote-cache "$remote_url" "$@") > "$tmpdir/$name.log" 2>&1 &
  local pid=$!
  for _ in {1..600}; do
    grep -q "remote rx:ATheory: running" "$tmpdir/$name.log" && break
    sleep 0.1
  done
  require_grep "remote rx:ATheory: running" "$tmpdir/$name.log"
  local targets
  targets=$(pgrep -x holbuild -P "$pid" || echo "$pid")
  # shellcheck disable=SC2086
  kill -TERM $targets
  set +e
  wait "$pid"
  local status=$?
  set -e
  [[ $status -eq 1 ]] || { echo "$name exited $status after SIGTERM, wanted 1" >&2; cat "$tmpdir/$name.log" >&2; exit 1; }
}
write_theories interrupted
printf '%s\n' '{"theory":"rx:ATheory","output":"HOL interrupted marker\n"}' > "$state/interrupted-output"
touch "$state/hang"
interrupt interrupted build --remote-exec "$coordinator" BTheory
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/interrupted.log")
require_grep "^POST /v1/batches/$batch/cancel " "$state/requests.log"
require_grep "holbuild: cancelled remote batch $batch" "$tmpdir/interrupted.log"
require_grep "holbuild: interrupted" "$tmpdir/interrupted.log"
require_grep "HOL interrupted marker" "$tmpdir/interrupted.log"
refute_grep "Theory built" "$tmpdir/interrupted.log"
interrupt interrupted-only build --remote-exec "$coordinator" --remote-only BTheory
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/interrupted-only.log")
require_grep "^POST /v1/batches/$batch/cancel " "$state/requests.log"
require_grep "holbuild: cancelled remote batch $batch" "$tmpdir/interrupted-only.log"
require_grep "HOL interrupted marker" "$tmpdir/interrupted-only.log"
rm "$state/hang"
rm "$state/interrupted-output"

# Forced builds execute on the workers, including under --remote-only.
run forced-only 0 build --remote-exec "$coordinator" --remote-only --force BTheory
require_grep "remote execution: remote workers finished 2 of 2 theories" "$tmpdir/forced-only.log"
run forced 0 build --remote-exec "$coordinator" --force BTheory
refute_grep "BTheory built\|building locally" "$tmpdir/forced.log"

# A stream cut midway through an event: the partial line is no theory.
write_theories cut
touch "$state/cut"
run cut 0 build --remote-exec "$coordinator" BTheory
require_grep 'lost the event stream for batch b[0-9]*: {"type": "action", "input_key"curl: (18) .*; reattaching' "$tmpdir/cut.log"
require_grep "remote execution: remote workers finished 2 of 2 theories" "$tmpdir/cut.log"
refute_grep "remote ?" "$tmpdir/cut.log"

# A stream that only repeats states it sent before breaking is no progress:
# after the first stream, the retries run out and the build goes local,
# rather than reattaching for as long as the streams keep breaking.
write_theories replay
echo 10 > "$state/replay"
run replay 0 build --remote-exec "$coordinator" BTheory
[[ $(grep -c "lost the event stream for batch b[0-9]*: curl: (18) .*; reattaching" "$tmpdir/replay.log") -eq 5 ]] ||
  { cat "$tmpdir/replay.log" >&2; exit 1; }
require_grep "remote workers finished 0 of 1 theories, cancelled the batch; building locally" "$tmpdir/replay.log"
require_grep "BTheory built" "$tmpdir/replay.log"
rm "$state/replay"

# The coordinator's credentials come from a curl config file.
printf 'header = "Authorization: Bearer stub-token"\n' > "$tmpdir/coordinator.curl"
write_theories seven
HOLBUILD_REMOTE_EXEC_CURL_CONFIG=$tmpdir/coordinator.curl run auth 0 build --remote-exec "$coordinator" BTheory
require_grep "^POST /v1/batches Bearer stub-token$" "$state/requests.log"

# The client remembers what the remote cache holds and doesn't ask again.  A
# worker that finds something gone fails the batch; the client forgets what
# it remembered, and the resubmitted batch builds.
write_theories ledger
run ledger-seed 0 build --remote-exec "$coordinator" --remote-only BTheory
[[ -n $(ls "$HOLBUILD_CACHE/remote-ledger") ]] || { echo "the export left no remote ledger" >&2; exit 1; }
ledger_file=$(ls "$HOLBUILD_CACHE"/remote-ledger/* | grep -v '\.lock$')
# The specs it uploaded aren't in it: no later export has the same spec.
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/ledger-seed.log")
for spec in $(awk '$1 == "action" { print $4 }' "$state/$batch.batch"); do
  refute_grep "^blob $spec$" "$ledger_file"
done
# A build with nothing to do doesn't read the ledger: a FIFO in its place
# would block the read.
cp "$ledger_file" "$tmpdir/ledger.seed"
rm "$ledger_file"
mkfifo "$ledger_file"
(cd "$project" && timeout 120 "$HOLBUILD_BIN" --remote-cache "$remote_url" build --remote-exec "$coordinator" --remote-only BTheory) \
  > "$tmpdir/ledger-noop.log" 2>&1 || { cat "$tmpdir/ledger-noop.log" >&2; exit 1; }
[[ -p "$ledger_file" ]] || { echo "the no-op build replaced the ledger" >&2; exit 1; }
rm "$ledger_file"
cp "$tmpdir/ledger.seed" "$ledger_file"
# The ledger is the cache root's, so another directory of the project, as a
# fresh worktree is, doesn't ask about the blob of the unchanged BScript.sml
# again; the changed AScript.sml it uploads.
copy=$tmpdir/project-copy
mkdir -p "$copy"
cp -r "$project/holproject.toml" "$project/src" "$copy/"
sed -i 's/(\* ledger \*)/(* ledger-copy *)/' "$copy/src/AScript.sml"
b_source=$(sha256sum "$copy/src/BScript.sml" | cut -d' ' -f1)
a_copy_source=$(sha256sum "$copy/src/AScript.sml" | cut -d' ' -f1)
: > "$tmpdir/server/requests.log"
(cd "$copy" && "$HOLBUILD_BIN" --remote-cache "$remote_url" build --remote-exec "$coordinator" --remote-only BTheory) \
  > "$tmpdir/ledger-copy.log" 2>&1 || { cat "$tmpdir/ledger-copy.log" >&2; exit 1; }
require_grep "remote execution: remote workers finished 2 of 2 theories" "$tmpdir/ledger-copy.log"
refute_grep "^\(HEAD\|PUT\) /cas/$b_source$" "$tmpdir/server/requests.log"
require_grep "^PUT /cas/$a_copy_source$" "$tmpdir/server/requests.log"
[[ ! -e "$copy/.holbuild/remote-ledger" ]] || { echo "the copy kept a ledger of its own" >&2; exit 1; }
# The export looks entries up by binary search over the ledger's lines, matching
# whole lines only: BScript.sml's blob is found as the first line, and as the
# last line without a newline.  Out of order it is missed, so the export checks
# it again, and the build records the ledger sorted again.
b_entry="blob $b_source"
b_line=$(grep -nxF "$b_entry" "$ledger_file" | cut -d: -f1)
[[ -n "$b_line" && $(wc -l < "$ledger_file") -gt 1 ]] || { cat "$ledger_file" >&2; exit 1; }
cp "$ledger_file" "$tmpdir/ledger.sorted"
# Without its metadata, the copy can't cut BTheory off, so both export.
ledger_copy_build() {
  sed -i "s/(\* ledger[^*]*\*)/(* $1 *)/" "$copy/src/AScript.sml"
  rm -r "$copy/.holbuild/dep"
  : > "$tmpdir/server/requests.log"
  (cd "$copy" && "$HOLBUILD_BIN" --remote-cache "$remote_url" build --remote-exec "$coordinator" --remote-only BTheory) \
    > "$tmpdir/$1.log" 2>&1 || { cat "$tmpdir/$1.log" >&2; exit 1; }
  require_grep "remote execution: remote workers finished 2 of 2 theories" "$tmpdir/$1.log"
}
tail -n +"$b_line" "$tmpdir/ledger.sorted" > "$ledger_file"
ledger_copy_build ledger-first
refute_grep "^\(HEAD\|PUT\) /cas/$b_source$" "$tmpdir/server/requests.log"
head -n "$b_line" "$tmpdir/ledger.sorted" | head -c -1 > "$ledger_file"
ledger_copy_build ledger-last
refute_grep "^\(HEAD\|PUT\) /cas/$b_source$" "$tmpdir/server/requests.log"
# A long line sorting after every entry sits between the search and the
# misplaced last line, so no search reaches it.
{ grep -vxF "$b_entry" "$tmpdir/ledger.sorted"; printf '~%.0s' {1..200}; echo; echo "$b_entry"; } > "$ledger_file"
ledger_copy_build ledger-unsorted
require_grep "^\(HEAD\|PUT\) /cas/$b_source$" "$tmpdir/server/requests.log"
LC_ALL=C sort -c "$ledger_file" || { cat "$ledger_file" >&2; exit 1; }
grep -qxF "$b_entry" "$ledger_file" || { cat "$ledger_file" >&2; exit 1; }
sed -i '/^~/d' "$ledger_file"
# A forced BTheory uploads its spec every time.  The first learns that the
# remote cache holds ATheory; the second learns nothing, so doesn't record
# the ledger.
forced_copy_build() {
  : > "$tmpdir/server/requests.log"
  (cd "$copy" && "$HOLBUILD_BIN" --remote-cache "$remote_url" build --remote-exec "$coordinator" --remote-only --force=theory BTheory) \
    > "$tmpdir/$1.log" 2>&1 || { cat "$tmpdir/$1.log" >&2; exit 1; }
  require_grep "remote execution: remote workers finished 1 of 1 theories" "$tmpdir/$1.log"
  local batch spec
  batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/$1.log")
  spec=$(awk '$1 == "action" { print $4 }' "$state/$batch.batch")
  require_grep "^\(HEAD\|PUT\) /cas/$spec$" "$tmpdir/server/requests.log"
}
forced_copy_build ledger-forced
touch -d '2000-01-01' "$ledger_file"
forced_copy_build ledger-forced-again
[[ $(stat -c %Y "$ledger_file") == $(date -d '2000-01-01' +%s) ]] ||
  { echo "a build that learned nothing recorded the ledger" >&2; exit 1; }
cp "$ledger_file" "$tmpdir/ledger.sorted"
# Past 100000 entries, the build recording the ledger keeps only the entries it
# used or learned: BScript.sml's blob, which it used, and the new
# AScript.sml's, which it learned, but none of the filler.
filler() { seq -f "blob f%063g" 1 100000; }
{ cat "$tmpdir/ledger.sorted"; filler; } | LC_ALL=C sort > "$ledger_file"
ledger_copy_build ledger-cap
a_copy_source=$(sha256sum "$copy/src/AScript.sml" | cut -d' ' -f1)
LC_ALL=C sort -c "$ledger_file" || { cat "$ledger_file" >&2; exit 1; }
refute_grep "^blob f" "$ledger_file"
grep -qxF "$b_entry" "$ledger_file" || { cat "$ledger_file" >&2; exit 1; }
grep -qxF "blob $a_copy_source" "$ledger_file" || { cat "$ledger_file" >&2; exit 1; }
# Each entry kept was in the ledger, or one the build asked the remote cache about.
while read -r kind hash; do
  grep -qxF "$kind $hash" "$tmpdir/ledger.sorted" || grep -q "^\(HEAD\|PUT\) /cas/$hash$" "$tmpdir/server/requests.log" ||
    { echo "the ledger kept $kind $hash, which the build didn't use" >&2; exit 1; }
done < "$ledger_file"
# Another build forgets the ledger and fills it past the limit while this one
# runs: BScript.sml's blob, which this build used, doesn't come back.
cp "$tmpdir/ledger.sorted" "$ledger_file"
printf 'rm %q\n{ seq -f "blob f%%063g" 1 100001; } > %q\n' "$ledger_file" "$ledger_file" > "$state/on-submit"
ledger_copy_build ledger-forget-race
rm "$state/on-submit"
refute_grep "^blob f" "$ledger_file"
refute_grep "^$b_entry$" "$ledger_file"
cp "$tmpdir/ledger.sorted" "$ledger_file"
# ATheory changes and BScript.sml doesn't, so its blob is remembered.  Without
# its metadata, the client can't cut BTheory off itself.
sed -i 's/(\* ledger \*)/(* ledger-a *)/' "$project/src/AScript.sml"
rm -r "$project/.holbuild/dep"
b_source=$(sha256sum "$project/src/BScript.sml" | cut -d' ' -f1)
rm "$remote_root/cas/$b_source" "$tmpdir/worker-cache/blobs/$b_source"
run ledger 0 build --remote-exec "$coordinator" --remote-only BTheory
require_grep "still missing blob $b_source after 3 attempts; .*; resubmitting$" "$tmpdir/ledger.log"
require_grep "remote execution: remote workers finished 1 of 1 theories" "$tmpdir/ledger.log"
[[ -f "$remote_root/cas/$b_source" ]] || { echo "the resubmission did not upload BScript.sml again" >&2; exit 1; }

# Flags that need --remote-exec, and ones it excludes.
run no-url 1 build --remote-only BTheory
require_grep "need --remote-exec URL" "$tmpdir/no-url.log"
run both 1 build --remote-exec "$coordinator" --detach --attach b1 BTheory
require_grep "exclude each other" "$tmpdir/both.log"
run url-missing 1 build --remote-exec --remote-only BTheory
require_grep "remote-exec requires URL" "$tmpdir/url-missing.log"
run id-missing 1 build --remote-exec "$coordinator" --attach --remote-only BTheory
require_grep "attach requires BATCH-ID" "$tmpdir/id-missing.log"
run trace 0 build --remote-exec "$coordinator" --remote-only --trace-steps BTheory
require_grep "proof step trace log:" "$tmpdir/trace.log"
require_grep "holbuild proof-ir trace:" "$tmpdir/trace.log"

# With --remote-only, a HOL toolchain that no cache holds is an error (exit
# status 75) rather than a local HOL build.
fake_hol=$tmpdir/fake-hol
write_fake_hol "$fake_hol"
fake_rev=$(init_git_repo "$fake_hol")
mkdir -p "$tmpdir/fake-project"
cat > "$tmpdir/fake-project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "rx-fake"

[dependencies.hol]
git = "$fake_hol"
rev = "$fake_rev"
TOML
: > "$tmpdir/fake-build-count"
set +e
(cd "$tmpdir/fake-project" &&
  HOLBUILD_CACHE=$tmpdir/fake-cache \
  HOLBUILD_TEST_BUILD_COUNT=$tmpdir/fake-build-count \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build --remote-exec "$coordinator" --remote-only) \
  > "$tmpdir/toolchain-only.log" 2>&1
status=$?
# The same without the build command word.
(cd "$tmpdir/fake-project" &&
  HOLBUILD_CACHE=$tmpdir/fake-cache \
  HOLBUILD_TEST_BUILD_COUNT=$tmpdir/fake-build-count \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" --remote-exec "$coordinator" --remote-only ATheory) \
  > "$tmpdir/toolchain-only-implicit.log" 2>&1
implicit_status=$?
set -e
for name in toolchain-only toolchain-only-implicit; do
  [[ $name == toolchain-only ]] && code=$status || code=$implicit_status
  [[ $code -eq 75 ]] || { echo "$name exited $code, wanted 75" >&2; cat "$tmpdir/$name.log" >&2; exit 1; }
  require_grep "HOL toolchain could not be restored from a cache, and --remote-only builds nothing locally" "$tmpdir/$name.log"
done
[[ ! -s "$tmpdir/fake-build-count" ]] || { cat "$tmpdir/fake-build-count" >&2; exit 1; }

# run and repl build their [run].loads on the remote workers, as build
# --remote-exec does, then start HOL locally.
cat >> "$project/holproject.toml" <<TOML

[run]
loads = ["BTheory"]
TOML
printf 'val _ = (BTheory.b_thm; print "RUN_REMOTE_OK\\n");\n' > "$tmpdir/run-script.sml"
printf 'val _ = (BTheory.b_thm; print "REPL_REMOTE_OK\\n");\n' > "$tmpdir/repl-input.sml"
write_theories run
: > "$state/ran"
run run-remote 0 run --remote-exec "$coordinator" "$tmpdir/run-script.sml"
require_grep "holbuild: remote batch b[0-9]*$" "$tmpdir/run-remote.log"
require_grep "remote execution: remote workers finished 2 of 2 theories" "$tmpdir/run-remote.log"
require_grep "BTheory restored from cache" "$tmpdir/run-remote.log"
refute_grep "Theory built" "$tmpdir/run-remote.log"
require_grep "RUN_REMOTE_OK" "$tmpdir/run-remote.log"
[[ $(grep -c . "$state/ran") -eq 2 ]] || { cat "$state/ran" >&2; exit 1; }
write_theories repl
run repl-remote 0 repl --remote-exec "$coordinator" --remote-only < "$tmpdir/repl-input.sml"
require_grep "remote execution: remote workers finished 2 of 2 theories" "$tmpdir/repl-remote.log"
refute_grep "Theory built" "$tmpdir/repl-remote.log"
require_grep "REPL_REMOTE_OK" "$tmpdir/repl-remote.log"

# An unreachable coordinator: run builds locally; with --remote-only, repl
# fails before HOL starts.
write_theories run-unreachable
run run-unreachable 0 run --remote-exec "$unreachable" "$tmpdir/run-script.sml"
require_grep "could not reach the coordinator at $unreachable.*; building locally" "$tmpdir/run-unreachable.log"
require_grep "BTheory built" "$tmpdir/run-unreachable.log"
require_grep "RUN_REMOTE_OK" "$tmpdir/run-unreachable.log"
write_theories repl-unreachable
run repl-unreachable-only 75 repl --remote-exec "$unreachable" --remote-only < "$tmpdir/repl-input.sml"
require_grep "remote execution: could not reach the coordinator at $unreachable" "$tmpdir/repl-unreachable-only.log"
refute_grep "Theory built\|REPL_REMOTE_OK" "$tmpdir/repl-unreachable-only.log"

run run-no-url 1 run --remote-only "$tmpdir/run-script.sml"
require_grep "remote-only needs --remote-exec URL" "$tmpdir/run-no-url.log"
run repl-url-missing 1 repl --remote-exec --remote-only < /dev/null
require_grep "remote-exec requires URL" "$tmpdir/repl-url-missing.log"
run run-from-flag 1 run --from --remote-only --remote-exec "$coordinator" "$tmpdir/run-script.sml"
require_grep "from requires THEORY" "$tmpdir/run-from-flag.log"

# A theory that writes SML sources runs before the rest is planned, which a
# batch can't do, so such a build stays local; --remote-only fails.
generated=$tmpdir/generated
mkdir -p "$generated/src"
cat > "$generated/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rxgen"

[build]
members = ["src"]

[actions.UseLib]
deps = ["GenTheory"]
TOML
cat > "$generated/src/GenScript.sml" <<SML
Theory Gen

fun holbuild_extra_outputs (_ : string list) = ();
val () = holbuild_extra_outputs ["GenML.sml"];
val () = let val out = TextIO.openOut "GenML.sml"
         in TextIO.output (out, "structure GenML = struct val x = 42 end\n"); TextIO.closeOut out end;
SML
cat > "$generated/src/UseLib.sml" <<SML
structure UseLib = struct val y = GenML.x + 1 end
SML
: > "$state/requests.log"
(cd "$generated" && "$HOLBUILD_BIN" --remote-cache "$remote_url" build --remote-exec "$coordinator" --detach UseLib) \
  > "$tmpdir/generated-detach.log" 2>&1 && { cat "$tmpdir/generated-detach.log" >&2; exit 1; }
require_grep "remote execution: theories that write SML sources build before the rest is planned" "$tmpdir/generated-detach.log"
refute_grep "GenTheory built" "$tmpdir/generated-detach.log"
# --remote-only restores, so with nothing cached it fails without building,
# and cancels a batch it was to attach to.
set +e
(cd "$generated" && "$HOLBUILD_BIN" --remote-cache "$remote_url" build --remote-exec "$coordinator" --remote-only --attach genb UseLib) \
  > "$tmpdir/generated-only.log" 2>&1
status=$?
set -e
[[ $status -eq 75 ]] || { echo "generated-only exited $status, wanted 75" >&2; cat "$tmpdir/generated-only.log" >&2; exit 1; }
require_grep "build before the rest is planned; restoring from the cache" "$tmpdir/generated-only.log"
require_grep "^POST /v1/batches/genb/cancel " "$state/requests.log"
: > "$state/requests.log"
refute_grep "GenTheory built" "$tmpdir/generated-only.log"
(cd "$generated" && "$HOLBUILD_BIN" --remote-cache "$remote_url" build --remote-exec "$coordinator" --remote-only UseLib) \
  > "$tmpdir/generated.log" 2>&1 || { cat "$tmpdir/generated.log" >&2; exit 1; }
require_grep "remote execution: remote workers finished 1 of 1 theories" "$tmpdir/generated.log"
require_grep "GenTheory restored from cache" "$tmpdir/generated.log"
require_grep "UseLib built" "$tmpdir/generated.log"
refute_grep "GenTheory built" "$tmpdir/generated.log"
: > "$state/requests.log"
# Once GenTheory is in the remote cache, --remote-only restores it in a
# fresh copy of the project, writing GenML.sml, and builds UseLib on it.
mkdir -p "$tmpdir/generated-copy"
cp -r "$generated/src" "$generated/holproject.toml" "$tmpdir/generated-copy/"
rm -f "$tmpdir/generated-copy/src/GenML.sml"
(cd "$tmpdir/generated-copy" && "$HOLBUILD_BIN" --remote-cache "$remote_url" build --remote-exec "$coordinator" --remote-only UseLib) \
  > "$tmpdir/generated-restore.log" 2>&1 || { cat "$tmpdir/generated-restore.log" >&2; exit 1; }
require_grep "GenTheory restored from cache" "$tmpdir/generated-restore.log"
require_grep "UseLib built" "$tmpdir/generated-restore.log"
require_file "$tmpdir/generated-copy/src/GenML.sml"
refute_grep "^POST /v1/batches\\|^GET /v1/batches" "$state/requests.log"

# A theory the batch finishes is copied into the local cache while the
# batch still runs: the stub holds the stream after ATheory's final event.
write_theories streaming
: > "$state/requests.log"
touch "$state/hold"
(cd "$project" && HOLBUILD_CACHE_TRACE=1 exec "$HOLBUILD_BIN" --remote-cache "$remote_url" build --remote-exec "$coordinator" BTheory) \
  > "$tmpdir/streaming.log" 2>&1 &
streaming_pid=$!
for _ in {1..600}; do
  grep -q "remote rx:ATheory: done" "$tmpdir/streaming.log" && break
  sleep 0.1
done
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/streaming.log")
a_key=$(awk '$1 == "action" && $5 == "rx:ATheory" { print $2 }' "$state/$batch.batch")
for _ in {1..600}; do
  grep -q "remote cache prefetched: $a_key$" "$tmpdir/streaming.log" && break
  sleep 0.1
done
require_grep "remote cache prefetched: $a_key$" "$tmpdir/streaming.log"
refute_grep "remote workers finished\|remote rx:BTheory: done" "$tmpdir/streaming.log"
rm "$state/hold"
wait "$streaming_pid" || { cat "$tmpdir/streaming.log" >&2; exit 1; }
require_grep "BTheory restored from cache" "$tmpdir/streaming.log"

# The theories outside a submitted batch, which the remote cache already
# holds, are copied while it runs too: a fresh copy of the project, with a
# cache of its own, changes only BTheory.
seeded=$tmpdir/seeded
mkdir -p "$seeded"
cp -r "$project/src" "$project/holproject.toml" "$seeded/"
sed -i 's/(\* streaming \*)/(* seeded *)/' "$seeded/src/BScript.sml"
link_hol_toolchain_cache "$tmpdir/seeded-cache"
(cd "$seeded" && HOLBUILD_CACHE=$tmpdir/seeded-cache HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build --remote-exec "$coordinator" BTheory) \
  > "$tmpdir/seeded.log" 2>&1 || { cat "$tmpdir/seeded.log" >&2; exit 1; }
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/seeded.log")
refute_grep "rx:ATheory" "$state/$batch.batch"
finished_line=$(grep -n "remote execution: remote workers finished 1 of 1 theories" "$tmpdir/seeded.log" | cut -d: -f1)
seeded_line=$(grep -n "remote cache prefetched: $a_key$" "$tmpdir/seeded.log" | head -n 1 | cut -d: -f1)
[[ -n $finished_line && -n $seeded_line && $seeded_line -lt $finished_line ]] ||
  { echo "ATheory not prefetched while following" >&2; cat "$tmpdir/seeded.log" >&2; exit 1; }
require_grep "ATheory restored from cache" "$tmpdir/seeded.log"

# A batch someone cancelled: --remote-only fails with status 1, since a local
# build would redo what was stopped; without it the build goes on locally.
write_theories cancelled
printf '%s\n' '{"theory":"rx:ATheory","output":"HOL budget marker\n"}' > "$state/interrupted-output"
touch "$state/cancelled"
run cancelled-only 1 build --remote-exec "$coordinator" --remote-only BTheory
require_grep "remote execution: batch b[0-9]* cancelled; remote workers finished 0 of 2 theories" "$tmpdir/cancelled-only.log"
require_grep "HOL budget marker" "$tmpdir/cancelled-only.log"
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/cancelled-only.log")
run cancelled-reattach 1 build --remote-exec "$coordinator" --remote-only --attach "$batch" BTheory
require_grep "output from interrupted attempt" "$tmpdir/cancelled-reattach.log"
require_grep "HOL budget marker" "$tmpdir/cancelled-reattach.log"
run cancelled 0 build --remote-exec "$coordinator" BTheory
require_grep "batch b[0-9]* cancelled; remote workers finished 0 of 2 theories; building locally" "$tmpdir/cancelled.log"
require_grep "BTheory built" "$tmpdir/cancelled.log"
rm "$state/cancelled"
rm "$state/interrupted-output"

# A theory built here for its current source needs no worker, though the
# remote cache lacks it (its publish failed, say): with ATheory's remote
# entry gone, nothing goes to the workers.
write_theories built-here
run built-here-base 0 build BTheory
key_a=$(awk -F= '/^input_key=/ { print $2; exit }' "$project/.holbuild/dep/rx/src/AScript.sml.key")
ac_a=$(printf 'holbuild-remote-ac-v1\n%s\n' "$key_a" | sha256sum | cut -d' ' -f1)
rm "$remote_root/ac/$ac_a"
: > "$state/requests.log"
run built-here 0 build --remote-exec "$coordinator" BTheory
require_grep "remote execution: nothing to build remotely" "$tmpdir/built-here.log"
refute_grep "^POST /v1/batches" "$state/requests.log"
refute_grep "Theory built" "$tmpdir/built-here.log"
[[ ! -e "$remote_root/ac/$ac_a" ]] || { echo "ATheory published with no batch to need it" >&2; exit 1; }
# A theory in the batch that depends on it gets it from the remote cache,
# where it goes from the local cache rather than to the workers: BTheory and
# CTheory change together, so both go to the workers, and ATheory doesn't.
sed -i 's/(\* built-here \*)/(* built-here-batch *)/' "$project/src/BScript.sml"
printf 'Theory C\nAncestors A\n\nTheorem c_thm:\n  T\nProof\n  simp[]\nQED\n' > "$project/src/CScript.sml"
run built-here-batch 0 build --remote-exec "$coordinator" BTheory CTheory
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/built-here-batch.log")
refute_grep "^action .* rx:ATheory$" "$state/$batch.batch"
require_grep "^action .* rx:BTheory$" "$state/$batch.batch"
require_grep "^action .* rx:CTheory$" "$state/$batch.batch"
require_grep "remote execution: remote workers finished 2 of 2 theories" "$tmpdir/built-here-batch.log"
[[ -e "$remote_root/ac/$ac_a" ]] || { echo "ATheory was not published" >&2; exit 1; }
# A theory edited alone goes to the workers too, though its dependencies are
# built here and its local checkpoints are current.
find "$project/.holbuild/checkpoints" -path '*BScript*' -name deps_loaded.save | grep -q . ||
  { echo "BTheory has no deps_loaded checkpoint" >&2; exit 1; }
sed -i 's/(\* built-here-batch \*)/(* built-here-alone *)/' "$project/src/BScript.sml"
run built-here-alone 0 build --remote-exec "$coordinator" BTheory
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/built-here-alone.log")
require_grep "^action .* rx:BTheory$" "$state/$batch.batch"
refute_grep "^action .* rx:ATheory$" "$state/$batch.batch"
require_grep "remote execution: remote workers finished 1 of 1 theories" "$tmpdir/built-here-alone.log"
# Without a local cache entry to publish, it goes to the workers.  The
# remote ledger, which says the remote has it, goes too.
rm "$remote_root/ac/$ac_a"
rm -r "$HOLBUILD_CACHE/remote-ledger"
rm -r "$HOLBUILD_CACHE/actions/$key_a"
sed -i 's/(\* built-here-alone \*)/(* built-here-unpublished *)/' "$project/src/BScript.sml"
sed -i 's/simp\[\]$/simp[] (* unpublished *)/' "$project/src/CScript.sml"
run built-here-unpublished 0 build --remote-exec "$coordinator" BTheory CTheory
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/built-here-unpublished.log")
require_grep "^action $key_a .* rx:ATheory$" "$state/$batch.batch"
require_grep "^edge [0-9a-f]* $key_a$" "$state/$batch.batch"
require_grep "remote execution: remote workers finished 3 of 3 theories" "$tmpdir/built-here-unpublished.log"
rm "$project/src/CScript.sml"

# A submission answered 502 while the coordinator restarts is retried, and
# given up on when it stays down.
write_theories restarting
echo 2 > "$state/unavailable"
run restarting-only 0 build --remote-exec "$coordinator" --remote-only BTheory
[[ $(grep -c "coordinator refused the batch (HTTP 502): .*restarting.*; retrying" "$tmpdir/restarting-only.log") -eq 2 ]] ||
  { cat "$tmpdir/restarting-only.log" >&2; exit 1; }
require_grep "remote execution: remote workers finished 2 of 2 theories" "$tmpdir/restarting-only.log"
rm "$state/unavailable"
write_theories unavailable
echo 10 > "$state/unavailable"
run unavailable-detach 1 build --remote-exec "$coordinator" --remote-only --detach BTheory
[[ $(grep -c "coordinator refused the batch (HTTP 502): .*restarting.*; retrying" "$tmpdir/unavailable-detach.log") -eq 4 ]] ||
  { cat "$tmpdir/unavailable-detach.log" >&2; exit 1; }
# The four retries, then the refusal that ends it.
[[ $(grep -c "coordinator refused the batch (HTTP 502)" "$tmpdir/unavailable-detach.log") -eq 5 ]] ||
  { cat "$tmpdir/unavailable-detach.log" >&2; exit 1; }
rm "$state/unavailable"
# The coordinator's own 500 under load, and a 429, are retried the same way;
# another 4xx is refused at once.
for status in 500 429; do
  write_theories "overloaded-$status"
  echo 1 > "$state/unavailable"
  echo "$status" > "$state/unavailable-status"
  run "overloaded-$status" 0 build --remote-exec "$coordinator" --remote-only BTheory
  [[ $(grep -c "coordinator refused the batch (HTTP $status): .*restarting.*; retrying" "$tmpdir/overloaded-$status.log") -eq 1 ]] ||
    { cat "$tmpdir/overloaded-$status.log" >&2; exit 1; }
  require_grep "remote execution: remote workers finished 2 of 2 theories" "$tmpdir/overloaded-$status.log"
done
write_theories forbidden
echo 1 > "$state/unavailable"
echo 403 > "$state/unavailable-status"
run forbidden 75 build --remote-exec "$coordinator" --remote-only BTheory
require_grep "coordinator refused the batch (HTTP 403): .*restarting" "$tmpdir/forbidden.log"
refute_grep "retrying" "$tmpdir/forbidden.log"
rm "$state/unavailable" "$state/unavailable-status"

# Early cutoff on the workers.  A <- B <- C, built with shared heaps: a
# proof-only edit of A rebuilds A and reuses the earlier builds of B and C,
# whose dependencies' outputs are unchanged; an edit that changes A's
# outputs rebuilds them; and an edited B, on unchanged dependency outputs,
# resumes from the deps heap its last build shared.  Only targets share
# heaps, so those builds name B as a target.  Each edit runs in a checkout
# without the metadata of its last build, where the client can't cut off
# itself (see below).
project=$tmpdir/cutoff
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rxc"

[build]
members = ["src"]
TOML
# write_cutoff A-STAMP B-STAMP [A-EXTRA] [A-PREFIX] [A-PROOF]: A-PREFIX goes
# before a_thm, whose proof is A-PROOF (simp[] by default).
write_cutoff() {
  cat > "$project/src/AScript.sml" <<SML
Theory A
Ancestors bool
${4:-}
Theorem a_thm:
  T
Proof
  ${5:-simp[]} (* $1 *)
QED
${3:-}
SML
  cat > "$project/src/BScript.sml" <<SML
Theory B
Ancestors A

Theorem b_thm:
  T
Proof
  ACCEPT_TAC a_thm (* $2 *)
QED
SML
  cat > "$project/src/CScript.sml" <<SML
Theory C
Ancestors B

Theorem c_thm:
  T
Proof
  ACCEPT_TAC b_thm
QED
SML
}
# results STATUS...: the workers' statuses for A, B and C in this batch.
results() {
  local want="rxc:ATheory status=$1
rxc:BTheory status=$2
rxc:CTheory status=$3"
  [[ "$(< "$state/results")" == "$want" ]] ||
    { echo "worker results:" >&2; cat "$state/results" "$tmpdir/worker.log" >&2; exit 1; }
  : > "$state/results"
  : > "$tmpdir/worker.log"
}
touch "$state/share-heaps"
: > "$state/results"
: > "$tmpdir/worker.log"

write_cutoff one one
run cutoff-v1 0 build --remote-exec "$coordinator" CTheory
results built built built

write_cutoff two one
rm -r "$project/.holbuild/dep"
run cutoff-proof 0 build --remote-exec "$coordinator" CTheory
require_grep "remote workers finished 3 of 3 theories" "$tmpdir/cutoff-proof.log"
refute_grep "Theory built" "$tmpdir/cutoff-proof.log"
require_grep "early cutoff: rxc:BTheory reuses" "$tmpdir/worker.log"
require_grep "early cutoff: rxc:CTheory reuses" "$tmpdir/worker.log"
results built cached cached

# A proof edit that moves a_thm down the file and proves it from another
# lemma changes ATheory.dat (its source locations and dependency records)
# but not what dependents load from it.
a_dat=$project/.holbuild/obj/src/ATheory.dat
a_dat_hash=$(sha256sum "$a_dat")
write_cutoff two one "" $'(* a comment\n   of three\n   lines *)' "ACCEPT_TAC TRUTH"
rm -r "$project/.holbuild/dep"
run cutoff-proof-moved 0 build --remote-exec "$coordinator" CTheory
[[ "$(sha256sum "$a_dat")" != "$a_dat_hash" ]] || { echo "the proof edit left ATheory.dat unchanged" >&2; exit 1; }
require_grep "early cutoff: rxc:BTheory reuses" "$tmpdir/worker.log"
require_grep "early cutoff: rxc:CTheory reuses" "$tmpdir/worker.log"
results built cached cached

a2=$'Theorem a2_thm:\n  T\nProof\n  simp[]\nQED'
write_cutoff three one "$a2"
rm -r "$project/.holbuild/dep"
run cutoff-output 0 build --remote-exec "$coordinator" BTheory CTheory
refute_grep "early cutoff" "$tmpdir/worker.log"
results built built built

write_cutoff four four "$a2"
rm -r "$project/.holbuild/dep"
run cutoff-dependent 0 build --remote-exec "$coordinator" BTheory CTheory
require_grep "BTheory restored from cache" "$tmpdir/cutoff-dependent.log"
refute_grep "Theory built" "$tmpdir/cutoff-dependent.log"
grep -A1 "^resuming BTheory$" "$tmpdir/worker.log" | grep -q "from: deps-loaded checkpoint" ||
  { echo "B did not resume from the shared deps heap" >&2; cat "$tmpdir/worker.log" >&2; exit 1; }
require_grep "early cutoff: rxc:CTheory reuses" "$tmpdir/worker.log"
results built built cached
rm "$state/share-heaps"

# Early cutoff on the client.  A theory whose own inputs are as at the build
# its outputs come from waits for the batch of what it depends on; the
# client then reuses its outputs where what it loads is unchanged, and sends
# the rest in another batch.  A <- B <- C, restored from entries built
# locally, which leave the workers no early-cutoff record.
project=$tmpdir/client-cutoff
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rxk"

[build]
members = ["src"]
TOML
write_cutoff one one
run client-cutoff-local 0 build CTheory
rm -r "$project/.holbuild"
run client-cutoff-restore 0 build CTheory
require_grep "CTheory restored from cache" "$tmpdir/client-cutoff-restore.log"
: > "$state/ran"
write_cutoff two one
run client-cutoff-proof 0 build --remote-exec "$coordinator" CTheory
require_grep "remote workers finished 1 of 1 theories" "$tmpdir/client-cutoff-proof.log"
require_grep "early cutoff reused 2 of 2 deferred theories" "$tmpdir/client-cutoff-proof.log"
refute_grep "Theory built" "$tmpdir/client-cutoff-proof.log"
[[ "$(< "$state/ran")" == "rxk:ATheory" ]] || { echo "workers ran:" >&2; cat "$state/ran" >&2; exit 1; }
# The reused entries reach the remote cache.
for t in B C; do
  key=$(awk -F= '/^input_key=/ { print $2; exit }' "$project/.holbuild/dep/rxk/src/${t}Script.sml.key")
  [[ -e "$remote_root/ac/$(printf 'holbuild-remote-ac-v1\n%s\n' "$key" | sha256sum | cut -d' ' -f1)" ]] ||
    { echo "${t}Theory's reused entry was not published" >&2; exit 1; }
done

# Admitting A's unchanged statement changes its oracle tags: B and C
# must go to the workers in a second batch rather than be cut off.
: > "$state/ran"
write_cutoff cheat one "" "" "cheat"
run client-cutoff-cheat 0 build --remote-exec "$coordinator" CTheory
require_grep "early cutoff reused 0 of 2 deferred theories" "$tmpdir/client-cutoff-cheat.log"
[[ $(grep -c "^holbuild: remote batch " "$tmpdir/client-cutoff-cheat.log") -eq 2 ]] ||
  { cat "$tmpdir/client-cutoff-cheat.log" >&2; exit 1; }
refute_grep "Theory built" "$tmpdir/client-cutoff-cheat.log"
[[ "$(< "$state/ran")" == $'rxk:ATheory\nrxk:BTheory\nrxk:CTheory' ]] ||
  { echo "workers ran:" >&2; cat "$state/ran" >&2; exit 1; }

# An edit that changes what A produces: B and C go to the workers next.
: > "$state/ran"
write_cutoff three one "$a2"
run client-cutoff-output 0 build --remote-exec "$coordinator" CTheory
require_grep "early cutoff reused 0 of 2 deferred theories" "$tmpdir/client-cutoff-output.log"
[[ $(grep -c "^holbuild: remote batch " "$tmpdir/client-cutoff-output.log") -eq 2 ]] ||
  { cat "$tmpdir/client-cutoff-output.log" >&2; exit 1; }
refute_grep "Theory built" "$tmpdir/client-cutoff-output.log"
[[ "$(< "$state/ran")" == $'rxk:ATheory\nrxk:BTheory\nrxk:CTheory' ]] ||
  { echo "workers ran:" >&2; cat "$state/ran" >&2; exit 1; }

# A theory whose last build's entry the local cache lost has nothing for
# early cutoff to reuse, so it doesn't wait.
: > "$state/ran"
for theory in B C; do
  rm -r "$HOLBUILD_CACHE/actions/$(sed -n 's/^input_key=//p' "$project/.holbuild/dep/rxk/src/${theory}Script.sml.key")"
done
write_cutoff four one "$a2"
run client-cutoff-lost 0 build --remote-exec "$coordinator" CTheory
refute_grep "deferred theories" "$tmpdir/client-cutoff-lost.log"
require_grep "remote workers finished 3 of 3 theories" "$tmpdir/client-cutoff-lost.log"

# Reused theories whose entries don't reach the remote cache go to the
# workers all the same.
: > "$state/ran"
touch "$state/refuse-ac-put"
write_cutoff five one "$a2"
run client-cutoff-unpublished 0 build --remote-exec "$coordinator" CTheory
rm "$state/refuse-ac-put" "$tmpdir/cache-control/ac-put-status"
require_grep "early cutoff reused 2 of 2 deferred theories" "$tmpdir/client-cutoff-unpublished.log"
require_grep "could not publish remote cache entry" "$tmpdir/client-cutoff-unpublished.log"
[[ "$(< "$state/ran")" == $'rxk:ATheory\nrxk:BTheory\nrxk:CTheory' ]] ||
  { echo "workers ran:" >&2; cat "$state/ran" >&2; exit 1; }

# The remote cache is asked afresh about reused theories, whatever the
# remote ledger says: back at an earlier edit whose entries for B and C both
# caches have lost, the ledger still lists them, and they are published again.
write_cutoff six one "$a2"
run client-cutoff-six 0 build --remote-exec "$coordinator" CTheory
require_grep "early cutoff reused 2 of 2 deferred theories" "$tmpdir/client-cutoff-six.log"
declare -A key_six
for t in B C; do
  key_six[$t]=$(sed -n 's/^input_key=//p' "$project/.holbuild/dep/rxk/src/${t}Script.sml.key")
done
write_cutoff seven one "$a2"
run client-cutoff-seven 0 build --remote-exec "$coordinator" CTheory
require_grep "early cutoff reused 2 of 2 deferred theories" "$tmpdir/client-cutoff-seven.log"
for t in B C; do
  rm -r "$HOLBUILD_CACHE/actions/${key_six[$t]}"
  rm "$remote_root/ac/$(printf 'holbuild-remote-ac-v1\n%s\n' "${key_six[$t]}" | sha256sum | cut -d' ' -f1)"
done
: > "$state/ran"
write_cutoff six one "$a2"
run client-cutoff-relisted 0 build --remote-exec "$coordinator" CTheory
require_grep "early cutoff reused 2 of 2 deferred theories" "$tmpdir/client-cutoff-relisted.log"
[[ ! -s "$state/ran" ]] || { echo "workers ran:" >&2; cat "$state/ran" >&2; exit 1; }
for t in B C; do
  [[ -e "$remote_root/ac/$(printf 'holbuild-remote-ac-v1\n%s\n' "${key_six[$t]}" | sha256sum | cut -d' ' -f1)" ]] ||
    { echo "${t}Theory's reused entry was not published again" >&2; exit 1; }
done

# A theory is cut off only once everything it depends on has settled: X <- V
# <- W <- Y, with a proof edit to X and a statement edit to W.  V is reused;
# Y, whose own inputs are unchanged, builds on a worker against the new W.
project=$tmpdir/client-settle
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rxs"

[build]
members = ["src"]
TOML
# write_settle X-STAMP W-STATEMENT
write_settle() {
  printf 'Theory X\nAncestors bool\n\nTheorem x_thm:\n  T\nProof\n  simp[] (* %s *)\nQED\n' "$1" \
    > "$project/src/XScript.sml"
  printf 'Theory V\nAncestors X\n\nTheorem v_thm:\n  T\nProof\n  ACCEPT_TAC x_thm\nQED\n' \
    > "$project/src/VScript.sml"
  printf 'Theory W\nAncestors V\n\nTheorem w_thm:\n  %s\nProof\n  simp[]\nQED\n' "$2" \
    > "$project/src/WScript.sml"
  printf 'Theory Y\nAncestors W\n\nTheorem y_thm:\n  T\nProof\n  simp[]\nQED\n' \
    > "$project/src/YScript.sml"
}
write_settle one T
run client-settle-v1 0 build --remote-exec "$coordinator" YTheory
: > "$state/ran"
: > "$state/results"
write_settle two 'T /\ T'
run client-settle 0 build --remote-exec "$coordinator" YTheory
require_grep "early cutoff reused 1 of 3 deferred theories" "$tmpdir/client-settle.log"
[[ "$(< "$state/results")" == $'rxs:XTheory status=built\nrxs:WTheory status=built\nrxs:YTheory status=built' ]] ||
  { echo "worker results:" >&2; cat "$state/results" >&2; exit 1; }
: > "$state/results"
: > "$tmpdir/worker.log"

# With keep-going, a failure in the first batch holds back only what depends
# on it: P <- Q and X <- Z, with P's outputs changed and X's statement made
# false.  Q goes to the workers after the first batch; Z never does.
project=$tmpdir/client-keep-going
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rxg"

[build]
members = ["src"]
TOML
# write_keep_going P-EXTRA X-STATEMENT
# Q's proof fails once P has p3_thm, which leaves Q's own source unchanged.
write_keep_going() {
  printf 'Theory P\nAncestors bool\n\nTheorem p_thm:\n  T\nProof\n  simp[]\nQED\n%s\n' "$1" \
    > "$project/src/PScript.sml"
  printf 'Theory Q\nAncestors P\n\nTheorem q_thm:\n  T\nProof\n  if can (DB.fetch "P") "p3_thm" then NO_TAC else simp[]\nQED\n' \
    > "$project/src/QScript.sml"
  printf 'Theory X\nAncestors bool\n\nTheorem x_thm:\n  %s\nProof\n  simp[]\nQED\n' "$2" \
    > "$project/src/XScript.sml"
  printf 'Theory Z\nAncestors X\n\nTheorem z_thm:\n  T\nProof\n  simp[]\nQED\n' \
    > "$project/src/ZScript.sml"
}
: > "$state/keep-going"
write_keep_going "" T
run client-keep-going-v1 0 build --remote-exec "$coordinator" QTheory ZTheory
: > "$state/ran"
write_keep_going "$a2" F
run client-keep-going 1 build --remote-exec "$coordinator" QTheory ZTheory
require_grep "early cutoff reused 0 of 2 deferred theories" "$tmpdir/client-keep-going.log"
require_grep "proof failed on a remote worker while building XTheory" "$tmpdir/client-keep-going.log"
require_grep "QTheory restored from cache" "$tmpdir/client-keep-going.log"
refute_grep "QTheory is not in the remote cache" "$tmpdir/client-keep-going.log"
[[ "$(sort "$state/ran")" == $'rxg:PTheory\nrxg:QTheory\nrxg:XTheory' ]] ||
  { echo "workers ran:" >&2; cat "$state/ran" >&2; exit 1; }

# So does a failure other than a proof's, after which --remote-only asks for
# a local build and still reports the deferred theories' failures.
: > "$state/ran"
echo rxg:XTheory > "$state/memory-failure"
write_keep_going "$a2"$'\nTheorem p3_thm: T\nProof\n  simp[]\nQED' F
run client-keep-going-memory 75 build --remote-exec "$coordinator" --remote-only QTheory ZTheory
rm "$state/memory-failure"
require_grep "early cutoff reused 0 of 2 deferred theories" "$tmpdir/client-keep-going-memory.log"
require_grep "proof failed on a remote worker while building QTheory" "$tmpdir/client-keep-going-memory.log"
[[ "$(sort "$state/ran")" == $'rxg:PTheory\nrxg:QTheory\nrxg:XTheory' ]] ||
  { echo "workers ran:" >&2; cat "$state/ran" >&2; exit 1; }
rm "$state/keep-going"
: > "$state/results"
: > "$tmpdir/worker.log"

# A proof that fails on a worker: the build restores what the workers
# finished, reports the failure from the worker's build log, and exits 1
# without running HOL locally.  A <- B, with B's proof broken.
project=$tmpdir/proof
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rxp"

[build]
members = ["src"]
TOML
# write_broken STAMP: A proves, B doesn't.
write_broken() {
  cat > "$project/src/AScript.sml" <<SML
Theory A
Ancestors bool

Theorem a_thm:
  T
Proof
  simp[] (* $1 *)
QED
SML
  cat > "$project/src/BScript.sml" <<SML
Theory B
Ancestors A

Theorem b_thm:
  F
Proof
  simp[] (* $1 *)
QED
SML
}
# The theory builds a run starts: a local build would run HOL here.
local_hol_runs() { grep -c "kind=run_in_dir_to_file" "$1" || true; }
write_broken one
HOLBUILD_TIMING_LOG=$tmpdir/proof.timing run proof 1 build --remote-exec "$coordinator" BTheory
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/proof.log")
log_sha=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$state/result-$(awk '$1 == "action" && $5 == "rxp:BTheory" { print $2 }' "$state/$batch.batch")")
require_grep "remote rxp:BTheory: failed (proof), log /cas/$log_sha" "$tmpdir/proof.log"
require_grep "remote execution: batch $batch failed: an action failed; remote workers finished 1 of 2 theories" "$tmpdir/proof.log"
require_grep "ATheory restored from cache" "$tmpdir/proof.log"
require_grep "proof failed on a remote worker while building BTheory" "$tmpdir/proof.log"
# What only B's log yields: where the proof failed, and its goal.
require_grep "^theorem: b_thm (line 4)$" "$tmpdir/proof.log"
require_grep "^> 7 |   simp\[\] (\* one \*)$" "$tmpdir/proof.log"
require_grep 'Failed to prove theorem "b_thm"' "$tmpdir/proof.log"
require_grep "instrumented log: .*/.holbuild/logs/current/rxp/BTheory/build.log" "$tmpdir/proof.log"
refute_grep "Theory built\|building locally" "$tmpdir/proof.log"
[[ $(sha256sum < "$project/.holbuild/logs/current/rxp/BTheory/build.log" | cut -d' ' -f1) == "$log_sha" ]] ||
  { echo "the local build log is not the worker's" >&2; exit 1; }
[[ $(local_hol_runs "$tmpdir/proof.timing") -eq 0 ]] || { cat "$tmpdir/proof.timing" >&2; exit 1; }

# --remote-only reports it the same way: a local build wouldn't help, so
# the exit status is 1, not 75.
write_broken one-only
run proof-only 1 build --remote-exec "$coordinator" --remote-only BTheory
require_grep "proof failed on a remote worker while building BTheory" "$tmpdir/proof-only.log"
require_grep "^theorem: b_thm (line 4)$" "$tmpdir/proof-only.log"
# The same edit again, its spec gone from the remote cache meanwhile: the
# export uploads the spec again, though the remote ledger knows its hash.
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/proof-only.log")
b_spec=$(awk '$1 == "action" && $5 == "rxp:BTheory" { print $4 }' "$state/$batch.batch")
rm "$remote_root/cas/$b_spec"
run proof-only-again 1 build --remote-exec "$coordinator" --remote-only BTheory
require_grep "proof failed on a remote worker while building BTheory" "$tmpdir/proof-only-again.log"
[[ -f "$remote_root/cas/$b_spec" ]] || { echo "the export did not upload the spec again" >&2; exit 1; }

# A static error and a tactic timeout are reported from the worker's log too.
write_failing_b() {
  cat > "$project/src/BScript.sml" <<SML
Theory B
Ancestors A

Theorem b_thm:
  T
Proof
  $1
QED
SML
}
write_failing_b "simp[] >> no_such_tactic"
run proof-static 1 build --remote-exec "$coordinator" --remote-only BTheory
require_grep "proof failed on a remote worker while building BTheory" "$tmpdir/proof-static.log"
require_grep "no_such_tactic" "$tmpdir/proof-static.log"
write_failing_b "REPEAT ALL_TAC"
run proof-timeout 1 build --remote-exec "$coordinator" --remote-only --tactic-timeout 1 BTheory
require_grep "tactic timed out on a remote worker while building BTheory" "$tmpdir/proof-timeout.log"
require_grep "^theorem: b_thm (line 4)$" "$tmpdir/proof-timeout.log"

# Without the log in the cache (the workers drop it), the build builds only
# the failed theory locally, which fails on the same proof: not C, which
# doesn't need B and which the batch, failed at B, didn't finish.
write_broken two
cat > "$project/src/CScript.sml" <<SML
Theory C
Ancestors bool

Theorem c_thm:
  T
Proof
  simp[]
QED
SML
touch "$state/drop-log"
HOLBUILD_TIMING_LOG=$tmpdir/proof-nolog.timing run proof-nolog 1 build --remote-exec "$coordinator" BTheory CTheory
rm "$state/drop-log"
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/proof-nolog.log")
awk '$1 == "action" { print $5 }' "$state/$batch.batch" | tail -n 1 | grep -qx "rxp:CTheory" ||
  { echo "C is not after B in the batch" >&2; cat "$state/$batch.batch" >&2; exit 1; }
require_grep "could not fetch the failed theory's build log; building BTheory locally" "$tmpdir/proof-nolog.log"
require_grep "^holbuild: theorem: b_thm (line 4)$" "$tmpdir/proof-nolog.log"
refute_grep "on a remote worker\|CTheory built" "$tmpdir/proof-nolog.log"
[[ $(local_hol_runs "$tmpdir/proof-nolog.timing") -gt 0 ]] || { cat "$tmpdir/proof-nolog.timing" >&2; exit 1; }

# A theory the remote cache holds that doesn't fit its cached parent, as
# when a nondeterministic parent was built twice: the workers can't use it,
# so the batch is resubmitted with it and its dependents, whose workers
# rebuild it and replace its entry.
nondet=$tmpdir/nondet
mkdir -p "$nondet/src"
cat > "$nondet/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rxnd"

[build]
members = ["src"]
TOML
cat > "$nondet/src/NScript.sml" <<'SML'
Theory N
Ancestors bool

val _ = save_thm ("n" ^ LargeInt.toString (Time.toMicroseconds (Time.now ())), TRUTH);
SML
for theory in M:N P:M; do
  cat > "$nondet/src/${theory%%:*}Script.sml" <<SML
Theory ${theory%%:*}
Ancestors ${theory##*:}

Theorem ${theory%%:*}_thm:
  T
Proof
  simp[]
QED
SML
done
hn() {
  (cd "$nondet" && "$HOLBUILD_BIN" --remote-cache "$remote_url" "$@")
}
n_ac=$(hn action-spec MTheory | awk '$1 == "action" && $5 == "rxnd:NTheory" { print $3 }')
[[ -n $n_ac ]] || { echo "no action for NTheory" >&2; exit 1; }
hn build MTheory > "$tmpdir/nondet-first.log" 2>&1 || { cat "$tmpdir/nondet-first.log" >&2; exit 1; }
rm "$remote_root/ac/$n_ac"
# A fresh copy of the project, with a cache of its own, builds NTheory again.
mkdir -p "$tmpdir/nondet-again"
cp -r "$nondet/src" "$nondet/holproject.toml" "$tmpdir/nondet-again/"
link_hol_toolchain_cache "$tmpdir/nondet-again-cache"
(cd "$tmpdir/nondet-again" && HOLBUILD_CACHE=$tmpdir/nondet-again-cache \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build NTheory) > "$tmpdir/nondet-again.log" 2>&1 ||
  { cat "$tmpdir/nondet-again.log" >&2; exit 1; }
require_grep "NTheory built" "$tmpdir/nondet-again.log"
mkdir -p "$tmpdir/nondet-client"
cp -r "$nondet/src" "$nondet/holproject.toml" "$tmpdir/nondet-client/"
nondet=$tmpdir/nondet-client
link_hol_toolchain_cache "$tmpdir/nondet-client-cache"
HOLBUILD_CACHE=$tmpdir/nondet-client-cache HOLBUILD_CACHE_TRACE=1 \
  hn build --remote-exec "$coordinator" --remote-only PTheory \
  > "$tmpdir/nondet.log" 2>&1 || { cat "$tmpdir/nondet.log" "$tmpdir/worker.log" >&2; exit 1; }
require_grep "failed: resubmit: .*; resubmitting with 2 theories rebuilt or rechecked" "$tmpdir/nondet.log"
# The first batch copied MTheory's unusable entry into the local cache, which
# the resubmission drops so that the rebuilt one is restored.
m_key=$(sed -n 's/.*still missing theory \([0-9a-f]*\) .*/\1/p' "$tmpdir/nondet.log")
prefetched_line=$(grep -n "remote cache prefetched: $m_key$" "$tmpdir/nondet.log" | head -n 1 | cut -d: -f1)
resubmit_line=$(grep -n "resubmitting with" "$tmpdir/nondet.log" | cut -d: -f1)
[[ -n $m_key && -n $prefetched_line && $prefetched_line -lt $resubmit_line ]] ||
  { echo "MTheory not prefetched before the resubmission" >&2; cat "$tmpdir/nondet.log" >&2; exit 1; }
require_grep "remote execution: remote workers finished 2 of 2 theories" "$tmpdir/nondet.log"
require_grep "MTheory restored from cache" "$tmpdir/nondet.log"
require_grep "PTheory restored from cache" "$tmpdir/nondet.log"
refute_grep "Theory built" "$tmpdir/nondet.log"
require_grep "replacing remote cache entry .*: its recorded parents differ from the cache's" "$tmpdir/worker.log"

# A worker's own copy of a parent that differs from the remote cache's, as
# when it built the nondeterministic parent itself and another build's copy
# won.  copy_nondet NAME PROJECT: the sources above in $tmpdir/NAME, as
# project PROJECT, with a cache of its own; in_copy NAME ARGS... runs
# holbuild there.
copy_nondet() {
  mkdir -p "$tmpdir/$1"
  cp -r "$tmpdir/nondet/src" "$tmpdir/$1/"
  sed "s/^name = \"rxnd\"/name = \"$2\"/" "$tmpdir/nondet/holproject.toml" > "$tmpdir/$1/holproject.toml"
  link_hol_toolchain_cache "$tmpdir/$1-cache"
}
in_copy() {
  local name=$1
  shift
  (cd "$tmpdir/$name" && HOLBUILD_CACHE=$tmpdir/$name-cache "$HOLBUILD_BIN" "$@")
}
# worker_n NAME: builds NTheory of copy NAME into the workers' cache alone.
worker_n() {
  (cd "$tmpdir/$1" && HOLBUILD_CACHE=$tmpdir/worker-cache "$HOLBUILD_BIN" build NTheory) \
    > "$tmpdir/$1-worker.log" 2>&1 || { cat "$tmpdir/$1-worker.log" >&2; exit 1; }
}

# The remote's MTheory doesn't fit the worker's NTheory: the worker replaces
# its copy by the remote's and builds PTheory in the first batch.
copy_nondet stale-dep rxnw
worker_n stale-dep
copy_nondet stale-dep-remote rxnw
in_copy stale-dep-remote --remote-cache "$remote_url" build MTheory > "$tmpdir/stale-dep-remote.log" 2>&1 ||
  { cat "$tmpdir/stale-dep-remote.log" >&2; exit 1; }
copy_nondet stale-dep-client rxnw
in_copy stale-dep-client --remote-cache "$remote_url" build --remote-exec "$coordinator" --remote-only PTheory \
  > "$tmpdir/stale-dep.log" 2>&1 || { cat "$tmpdir/stale-dep.log" "$tmpdir/worker.log" >&2; exit 1; }
refute_grep "resubmitting" "$tmpdir/stale-dep.log"
require_grep "remote execution: remote workers finished 1 of 1 theories" "$tmpdir/stale-dep.log"
require_grep "PTheory restored from cache" "$tmpdir/stale-dep.log"

# The worker's NTheory fits MTheory's other parents but differs from the
# remote's: the worker replaces it by the remote's before building MTheory on
# it, so the build is published and the batch finishes the first time.
copy_nondet stale-build rxnv
worker_n stale-build
copy_nondet stale-build-remote rxnv
in_copy stale-build-remote --remote-cache "$remote_url" build NTheory > "$tmpdir/stale-build-remote.log" 2>&1 ||
  { cat "$tmpdir/stale-build-remote.log" >&2; exit 1; }
m_ac=$(in_copy stale-build-remote --remote-cache "$remote_url" action-spec PTheory |
  awk '$1 == "action" && $5 == "rxnv:MTheory" { print $3 }')
[[ -n $m_ac ]] || { echo "no action for MTheory" >&2; exit 1; }
copy_nondet stale-build-client rxnv
in_copy stale-build-client --remote-cache "$remote_url" build --remote-exec "$coordinator" --remote-only PTheory \
  > "$tmpdir/stale-build-client.log" 2>&1 || { cat "$tmpdir/stale-build-client.log" "$tmpdir/worker.log" >&2; exit 1; }
refute_grep "resubmitting" "$tmpdir/stale-build-client.log"
require_grep "remote execution: remote workers finished 2 of 2 theories" "$tmpdir/stale-build-client.log"
require_grep "PTheory restored from cache" "$tmpdir/stale-build-client.log"
require_file "$remote_root/ac/$m_ac"

# A warm client's forced target must still run on a warm worker, while its
# ancestor stays cached. The log must be from that execution, not a local HOL.
project=$tmpdir/force-project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rxf"
[build]
members = ["src"]
TOML
write_theories forced-traced
cat > "$project/src/helperLib.sml" <<'SML'
structure helperLib = struct val verdict = "remote execution verdict: PASS\n" end
SML
sed -i '/^Ancestors A$/a Libs helperLib' "$project/src/BScript.sml"
sed -i '/^Theorem b_thm:/i val _ = print "probe-before-theorem\\n";' "$project/src/BScript.sml"
cat >> "$project/src/BScript.sml" <<'SML'
val _ = print helperLib.verdict
SML
run force-seed 0 build --remote-exec "$coordinator" --remote-only BTheory
run force-clean 0 clean BTheory
: > "$state/results"
HOLBUILD_TIMING_LOG=$tmpdir/force-target.timing run force-target 0 build --remote-exec "$coordinator" --remote-only --force=theory BTheory
require_grep 'BTheory restored from cache' "$tmpdir/force-target.log"
require_grep "^rxf:BTheory status=built$" "$state/results"
[[ $(wc -l < "$state/results") -eq 1 ]] || { cat "$state/results" >&2; exit 1; }
refute_grep "Theory built\|building locally" "$tmpdir/force-target.log"
[[ $(local_hol_runs "$tmpdir/force-target.timing") -eq 0 ]] || { cat "$tmpdir/force-target.timing" >&2; exit 1; }
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/force-target.log")
key=$(awk '$1 == "action" { print $2 }' "$state/$batch.batch")
spec=$(awk '$1 == "action" { print $4 }' "$state/$batch.batch")
require_grep '^option force=true$' "$remote_root/cas/$spec"
log_sha=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$state/result-$key")
local_log=$project/.holbuild/logs/current/rxf/BTheory/build.log
[[ -n $log_sha && $(sha256sum < "$local_log" | cut -d' ' -f1) == "$log_sha" ]] ||
  { echo "forced log is not the worker's log" >&2; exit 1; }
require_grep 'remote execution verdict: PASS' "$local_log"

for flag in --force=project --force=full --force --force-project --force-full; do
  : > "$state/results"
  run force-scope 0 build --remote-exec "$coordinator" --remote-only "$flag" BTheory
  [[ $(wc -l < "$state/results") -eq 2 ]] || { cat "$state/results" >&2; exit 1; }
  require_grep '^rxf:ATheory status=built$' "$state/results"
  require_grep '^rxf:BTheory status=built$' "$state/results"
done

# Explicitly skipping checkpoints must survive the remote boundary, with
# both persistent worker checkpoint trees and shared heaps.
for shared in no yes; do
  [[ $shared == no ]] || touch "$state/share-heaps"
  run checkpoint-seed 0 build --remote-exec "$coordinator" --remote-only --force=theory BTheory
  run skip-checkpoints 0 build --remote-exec "$coordinator" --remote-only --force=theory --skip-checkpoints BTheory
  require_grep '^probe-before-theorem$' "$local_log"
  batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/skip-checkpoints.log")
  spec=$(awk '$1 == "action" { print $4 }' "$state/$batch.batch")
  require_grep '^option skip-checkpoints=true$' "$remote_root/cas/$spec"
done
rm "$state/share-heaps"

# Trace policy applies to the root package's theories and bypasses both
# worker whole-action reuse and checkpoint replay, also with shared heaps.
touch "$state/share-heaps"
for flag in --trace-steps --goalfrag-trace; do
  : > "$state/results"
  HOLBUILD_TIMING_LOG=$tmpdir/trace-target.timing run trace-target 0 build --remote-exec "$coordinator" --remote-only "$flag" BTheory
  require_grep '^rxf:ATheory status=built$' "$state/results"
  require_grep '^rxf:BTheory status=built$' "$state/results"
  require_grep 'holbuild proof-ir trace:' "$tmpdir/trace-target.log"
  require_grep 'proof step trace log: .*rxf/BTheory/proof-trace.log' "$tmpdir/trace-target.log"
  require_grep 'theorem=b_thm' "$local_log"
  cmp "$local_log" "$project/.holbuild/logs/current/rxf/BTheory/proof-trace.log"
  [[ $(local_hol_runs "$tmpdir/trace-target.timing") -eq 0 ]] || { cat "$tmpdir/trace-target.timing" >&2; exit 1; }
  batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/trace-target.log")
  spec=$(awk '$1 == "action" && $5 == "rxf:BTheory" { print $4 }' "$state/$batch.batch")
  require_grep '^option trace-steps=true$' "$remote_root/cas/$spec"
done
rm "$state/share-heaps"

# A lost required log fails closed instead of silently succeeding or
# repeating a forced build on the client.
touch "$state/drop-log"
run force-log-missing 75 build --remote-exec "$coordinator" --remote-only --force=theory BTheory
require_grep 'could not fetch the remote build log for rxf:BTheory' "$tmpdir/force-log-missing.log"
refute_grep 'Theory built\|building locally' "$tmpdir/force-log-missing.log"
[[ ! -e "$local_log" ]] || { echo 'stale forced log survived' >&2; exit 1; }
run force-log-local 0 build --remote-exec "$coordinator" --force=theory BTheory
require_grep 'could not fetch the remote build log.*building locally' "$tmpdir/force-log-local.log"
require_grep 'BTheory built' "$tmpdir/force-log-local.log"
require_grep 'remote execution verdict: PASS' "$local_log"
run trace-log-missing 75 build --remote-exec "$coordinator" --remote-only --trace-steps BTheory
for theory in ATheory BTheory; do
  for log in build.log proof-trace.log; do
    [[ ! -e "$project/.holbuild/logs/current/rxf/$theory/$log" ]] ||
      { echo "stale trace log survived: $theory/$log" >&2; exit 1; }
  done
done
run trace-log-local 0 build --remote-exec "$coordinator" --trace-steps BTheory
require_grep 'could not fetch the remote build log.*building locally' "$tmpdir/trace-log-local.log"
require_grep 'ATheory built' "$tmpdir/trace-log-local.log"
require_grep 'BTheory built' "$tmpdir/trace-log-local.log"
require_grep 'theorem=b_thm' "$local_log"
cmp "$local_log" "$project/.holbuild/logs/current/rxf/BTheory/proof-trace.log"
rm "$state/drop-log"

# An attached batch must cover the requested forced/traced targets.
run attach-parent 0 build --remote-exec "$coordinator" --detach --force=theory ATheory
parent_batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/attach-parent.log")
for flag in --force=theory --trace-steps; do
  run attach-missing 75 build --remote-exec "$coordinator" --remote-only --attach "$parent_batch" "$flag" BTheory
  require_grep 'remote batch did not execute the required theory rxf:BTheory' "$tmpdir/attach-missing.log"
  refute_grep 'holbuild proof-ir trace:' "$tmpdir/attach-missing.log"
done

# Requeued actions replace the previous execution's now-evicted log.
touch "$state/requeue-log"
for snapshot in no yes; do
  [[ $snapshot == no ]] || touch "$state/requeue-snapshot"
  run trace-requeued 0 build --remote-exec "$coordinator" --remote-only --trace-steps BTheory
  [[ $(grep -c '^proof step trace log:' "$tmpdir/trace-requeued.log") -eq 2 ]] ||
    { cat "$tmpdir/trace-requeued.log" >&2; exit 1; }
  require_grep 'theorem=b_thm' "$local_log"
done
rm "$state/requeue-log" "$state/requeue-snapshot"

# A completed ancestor's missing log cannot hide cancellation or the failed
# child's proof diagnostic, or print traces from a batch that will be retried.
touch "$state/drop-success-log" "$state/cancel-after-actions"
run trace-cancelled 1 build --remote-exec "$coordinator" --remote-only --trace-steps BTheory
require_grep 'remote execution: batch .* cancelled' "$tmpdir/trace-cancelled.log"
refute_grep 'could not fetch the remote build log\|holbuild proof-ir trace:' "$tmpdir/trace-cancelled.log"
rm "$state/cancel-after-actions"
sed -i 's/ACCEPT_TAC a_thm/FAIL_TAC "review regression"/' "$project/src/BScript.sml"
run trace-failed-child 1 build --remote-exec "$coordinator" --remote-only --trace-steps BTheory
require_grep 'review regression' "$tmpdir/trace-failed-child.log"
refute_grep 'could not fetch the remote build log\|before theorem=a_thm' "$tmpdir/trace-failed-child.log"
rm "$state/drop-success-log"


# An outage fetching an ordinary ancestor's optional log must not discard
# the forced target's result or require local HOL execution.
project=$tmpdir/optional-log-project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rxoptional"
[build]
members = ["src"]
TOML
write_theories optional-log-outage
touch "$state/optional-log-outage"
HOLBUILD_TIMING_LOG=$tmpdir/optional-log.timing run optional-log 0 build --remote-exec "$coordinator" --remote-only --force=theory BTheory
require_grep 'could not fetch the remote build log for rxoptional:ATheory' "$tmpdir/optional-log.log"
[[ $(local_hol_runs "$tmpdir/optional-log.timing") -eq 0 ]] || { cat "$tmpdir/optional-log.timing" >&2; exit 1; }
require_grep 'build.execute' "$tmpdir/optional-log.timing"
rm "$state/optional-log-outage"

# The client cap must reach the HOL child, before Poly/ML consumes --maxheap.
copy_nondet heap-cap rxheap
cat > "$tmpdir/heap-cap/src/HeapScript.sml" <<'SML'
Theory Heap
Ancestors bool
val _ =
  let
    val ins = TextIO.openIn "/proc/self/cmdline"
    val text = TextIO.inputAll ins before TextIO.closeIn ins
  in
    print ("heap-child-argv: " ^ String.translate (fn #"\000" => " " | c => str c) text ^ "\n")
  end
SML
in_copy heap-cap --max-heap 4096 --remote-cache "$remote_url" build \
  --remote-exec "$coordinator" --remote-only HeapTheory > "$tmpdir/heap-cap.log" 2>&1 ||
  { cat "$tmpdir/heap-cap.log" "$tmpdir/worker.log" >&2; exit 1; }
heap_key=$(awk '$1 == "action" && $5 == "rxheap:HeapTheory" { print $2 }' "$state/"*.batch)
heap_log=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$state/result-$heap_key")
require_grep '^heap-child-argv: .*/bin/hol .*--maxheap 4096 run ' "$remote_root/cas/$heap_log"

# A worker strengthens a timeout-free entry, while the client still has its
# older local manifest. The restore must pick up the stronger remote contract.
copy_nondet timeout-contract rxtimeout
cat > "$tmpdir/timeout-contract/src/TimeoutScript.sml" <<'SML'
Theory Timeout
Ancestors bool

Theorem timeout_thm:
  T
Proof
  simp[]
QED
SML
in_copy timeout-contract --remote-cache "$remote_url" build --tactic-timeout 0 TimeoutTheory \
  > "$tmpdir/timeout-seed.log" 2>&1 || { cat "$tmpdir/timeout-seed.log" >&2; exit 1; }
timeout_metadata=$tmpdir/timeout-contract/.holbuild/dep/rxtimeout/src/TimeoutScript.sml.key
require_grep '^proof_timeout=none$' "$timeout_metadata"
cp "$timeout_metadata" "$tmpdir/timeout-weak-metadata"
timeout_key=$(sed -n 's/^input_key=//p' "$timeout_metadata")
timeout_manifest=$tmpdir/timeout-contract-cache/actions/$timeout_key/manifest
cp "$timeout_manifest" "$tmpdir/timeout-weak-manifest"
timeout_ac=$(printf 'holbuild-remote-ac-v1\n%s\n' "$timeout_key" | sha256sum | cut -d' ' -f1)
require_grep '^proof-timeout=none$' "$remote_root/ac/$timeout_ac"
in_copy timeout-contract --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --remote-only --tactic-timeout 2.5 TimeoutTheory > "$tmpdir/timeout-strict.log" 2>&1 ||
  { cat "$tmpdir/timeout-strict.log" "$tmpdir/worker.log" >&2; exit 1; }
require_grep 'remote execution: remote workers finished 1 of 1 theories' "$tmpdir/timeout-strict.log"
require_grep 'TimeoutTheory restored from cache' "$tmpdir/timeout-strict.log"
refute_grep 'Theory built' "$tmpdir/timeout-strict.log"
require_grep '^proof-timeout=2.5$' "$remote_root/ac/$timeout_ac"
require_grep '^proof-timeout=2.5$' "$timeout_manifest"
require_grep '^proof_timeout=2.5$' "$timeout_metadata"

# The remote entry can already be strong before planning, so no batch runs.
# Put back the client's older manifest and metadata to exercise that case.
cp "$tmpdir/timeout-weak-manifest" "$timeout_manifest"
cp "$tmpdir/timeout-weak-metadata" "$timeout_metadata"
in_copy timeout-contract --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --remote-only --tactic-timeout 2.5 TimeoutTheory > "$tmpdir/timeout-cached.log" 2>&1 ||
  { cat "$tmpdir/timeout-cached.log" >&2; exit 1; }
require_grep 'remote execution: nothing to build remotely' "$tmpdir/timeout-cached.log"
require_grep 'TimeoutTheory restored from cache' "$tmpdir/timeout-cached.log"
refute_grep 'remote batch\|Theory built' "$tmpdir/timeout-cached.log"
require_grep '^proof-timeout=2.5$' "$timeout_manifest"
require_grep '^proof_timeout=2.5$' "$timeout_metadata"

# Two-phase generated_source_owners remote build: Phase 1 builds Gen2Theory on
# the remote worker and restores Gen2ML.sml; Phase 2 replans and builds
# AfterGenTheory (which depends on Use2Lib -> Gen2ML) on the remote worker.
gen2=$tmpdir/generated-two-phase
mkdir -p "$gen2/src"
link_hol_toolchain_cache "$tmpdir/generated-two-phase-cache"
cat > "$gen2/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rxgen2"

[build]
members = ["src"]

[actions.Use2Lib]
deps = ["Gen2Theory"]
TOML
cat > "$gen2/src/Gen2Script.sml" <<'SML'
Theory Gen2
Ancestors bool

fun holbuild_extra_outputs (_ : string list) = ();
val () = holbuild_extra_outputs ["Gen2ML.sml"];
val () = let val out = TextIO.openOut "Gen2ML.sml"
         in TextIO.output (out, "structure Gen2ML = struct val k = 7 end\n"); TextIO.closeOut out end;
val gen2_thm = save_thm("gen2_thm", TRUTH);
SML
cat > "$gen2/src/Use2Lib.sml" <<'SML'
structure Use2Lib = struct val v = Gen2ML.k + 1 end
SML
cat > "$gen2/src/AfterGenScript.sml" <<'SML'
Theory AfterGen
Ancestors Gen2
Libs Use2Lib

val _ = if Use2Lib.v = 8 then () else raise Fail "bad Use2Lib.v";
val after_gen_thm = save_thm("after_gen_thm", TRUTH);
SML
(cd "$gen2" && HOLBUILD_CACHE=$tmpdir/generated-two-phase-cache "$HOLBUILD_BIN" --remote-cache "$remote_url" \
  build --remote-exec "$coordinator" --remote-only --priority=3 AfterGenTheory) > "$tmpdir/gen2.log" 2>&1 ||
  { cat "$tmpdir/gen2.log" "$tmpdir/worker.log" >&2; exit 1; }
require_grep "Gen2Theory restored from cache" "$tmpdir/gen2.log"
[[ $(grep -c '^POST /v1/batches?priority=3 ' "$state/requests.log") -ge 2 ]] || { cat "$state/requests.log" >&2; exit 1; }
require_grep "Use2Lib built" "$tmpdir/gen2.log"
require_grep "AfterGenTheory restored from cache" "$tmpdir/gen2.log"
refute_grep "Theory built" "$tmpdir/gen2.log"
require_file "$gen2/src/Gen2ML.sml"

# check and check --fingerprint pre-build on the remote coordinator and run the
# check script locally; when a valid deps_loaded checkpoint exists, check
# starts from it via FromTheory.
copy_nondet check-remote rxchk
cat > "$tmpdir/check-remote/src/ChkScript.sml" <<'SML'
Theory Chk
Ancestors bool
val chk_thm = save_thm("chk_thm", TRUTH);
SML
in_copy check-remote --remote-cache "$remote_url" check ChkTheory:chk_thm \
  --remote-exec "$coordinator" --remote-only > "$tmpdir/check-remote.log" 2>&1 ||
  { cat "$tmpdir/check-remote.log" "$tmpdir/worker.log" >&2; exit 1; }
require_grep "remote execution: remote workers finished 1 of 1 theories" "$tmpdir/check-remote.log"
require_grep "ChkTheory restored from cache" "$tmpdir/check-remote.log"
require_grep "^ChkTheory.chk_thm: clean (1 theorem)$" "$tmpdir/check-remote.log"
refute_grep "ChkTheory built" "$tmpdir/check-remote.log"

copy_nondet check-fp-remote rxchkfp
cat > "$tmpdir/check-fp-remote/src/ChkFpScript.sml" <<'SML'
Theory ChkFp
Ancestors bool
val chk_fp_thm = save_thm("chk_fp_thm", TRUTH);
SML
in_copy check-fp-remote --remote-cache "$remote_url" check --fingerprint ChkFpTheory \
  --remote-exec "$coordinator" --remote-only > "$tmpdir/check-fp-remote.log" 2>&1 ||
  { cat "$tmpdir/check-fp-remote.log" "$tmpdir/worker.log" >&2; exit 1; }
require_grep "ChkFpTheory restored from cache" "$tmpdir/check-fp-remote.log"
require_grep "^fingerprint	ChkFpTheory	theorem	chk_fp_thm	" "$tmpdir/check-fp-remote.log"

# run --remote-exec --remote-only builds/restores explicit --from theories and
# script-inferred FromScripts theories (even when [run].loads is empty and when
# --remote-exec / --remote-only trail the script argument).
copy_nondet run-from-remote rxrunfrom
cat > "$tmpdir/run-from-remote/src/RunFromScript.sml" <<'SML'
Theory RunFrom
Ancestors bool
val run_from_thm = save_thm("run_from_thm", TRUTH);
SML
cat > "$tmpdir/run-from-remote/probe-from.sml" <<'SML'
val _ = load "RunFromTheory";
val _ = print ("RUN_FROM_THM=" ^ Int.toString (length (DB.thms "RunFrom")) ^ "\n");
SML
in_copy run-from-remote --remote-cache "$remote_url" run --from RunFromTheory \
  "$tmpdir/run-from-remote/probe-from.sml" --remote-exec "$coordinator" --remote-only \
  > "$tmpdir/run-from-remote.log" 2>&1 ||
  { cat "$tmpdir/run-from-remote.log" "$tmpdir/worker.log" >&2; exit 1; }
require_grep "RunFromTheory restored from cache" "$tmpdir/run-from-remote.log"
require_grep "RUN_FROM_THM=1" "$tmpdir/run-from-remote.log"
refute_grep "RunFromTheory built" "$tmpdir/run-from-remote.log"

copy_nondet run-infer-remote rxruninf
cat > "$tmpdir/run-infer-remote/src/RunInfScript.sml" <<'SML'
Theory RunInf
Ancestors bool
val run_inf_thm = save_thm("run_inf_thm", TRUTH);
SML
cat > "$tmpdir/run-infer-remote/probe-infer.sml" <<'SML'
val _ = load "RunInfTheory";
val _ = print "RUN_INFER_OK\n";
SML
in_copy run-infer-remote --remote-cache "$remote_url" run \
  "$tmpdir/run-infer-remote/probe-infer.sml" --remote-exec "$coordinator" --remote-only \
  > "$tmpdir/run-infer-remote.log" 2>&1 ||
  { cat "$tmpdir/run-infer-remote.log" "$tmpdir/worker.log" >&2; exit 1; }
require_grep "RunInfTheory restored from cache" "$tmpdir/run-infer-remote.log"
require_grep "RUN_INFER_OK" "$tmpdir/run-infer-remote.log"
refute_grep "RunInfTheory built" "$tmpdir/run-infer-remote.log"

# run pre-builds without proof steps, as heap does: an inferred theory the
# workers built for build --skip-proof-steps is reused, with no second batch
# demanding a step timeout its slow tactic exceeds.
copy_nondet run-plain-remote rxrunplain
sed -i 's/^members = \["src"\]$/&\ntactic_timeout = 0.1/' "$tmpdir/run-plain-remote/holproject.toml"
require_grep '^tactic_timeout = 0.1$' "$tmpdir/run-plain-remote/holproject.toml"
cat > "$tmpdir/run-plain-remote/src/RunSlowScript.sml" <<'SML'
Theory RunSlow
Ancestors bool
fun slow_tac g = (OS.Process.sleep (Time.fromReal 0.45); ACCEPT_TAC TRUTH g);
Theorem run_slow_thm:
  T
Proof
  slow_tac
QED
SML
cat > "$tmpdir/run-plain-remote/probe-slow.sml" <<'SML'
val _ = load "RunSlowTheory";
val _ = print "RUN_SLOW_OK\n";
SML
in_copy run-plain-remote --remote-cache "$remote_url" build --skip-proof-steps \
  --remote-exec "$coordinator" --remote-only RunSlowTheory > "$tmpdir/run-plain-build.log" 2>&1 ||
  { cat "$tmpdir/run-plain-build.log" "$tmpdir/worker.log" >&2; exit 1; }
require_grep "remote execution: remote workers finished 1 of 1 theories" "$tmpdir/run-plain-build.log"
in_copy run-plain-remote --remote-cache "$remote_url" run \
  "$tmpdir/run-plain-remote/probe-slow.sml" --remote-exec "$coordinator" --remote-only \
  > "$tmpdir/run-plain-remote.log" 2>&1 ||
  { cat "$tmpdir/run-plain-remote.log" "$tmpdir/worker.log" >&2; exit 1; }
require_grep "RUN_SLOW_OK" "$tmpdir/run-plain-remote.log"
refute_grep "remote batch\|RunSlowTheory built" "$tmpdir/run-plain-remote.log"

# heap, executable, and export --build support --remote-exec --remote-only.
copy_nondet heap-remote rxheapcmd
cat >> "$tmpdir/heap-remote/holproject.toml" <<'TOML'

[[heap]]
name = "myheap"
output = "myheap.heap"
objects = ["HeapCmdTheory"]

[[executable]]
name = "myexe"
output = "myexe.exe"
objects = ["HeapCmdTheory", "ExeMain"]
TOML
cat > "$tmpdir/heap-remote/src/HeapCmdScript.sml" <<'SML'
Theory HeapCmd
Ancestors bool
val heap_cmd_thm = save_thm("heap_cmd_thm", TRUTH);
SML
cat > "$tmpdir/heap-remote/src/ExeMain.sml" <<'SML'
fun main () = print "EXE_REMOTE_OK\n"
SML
in_copy heap-remote --remote-cache "$remote_url" heap myheap \
  --remote-exec "$coordinator" --remote-only > "$tmpdir/heap-remote.log" 2>&1 ||
  { cat "$tmpdir/heap-remote.log" "$tmpdir/worker.log" >&2; exit 1; }
require_grep "HeapCmdTheory restored from cache" "$tmpdir/heap-remote.log"
refute_grep "HeapCmdTheory built" "$tmpdir/heap-remote.log"
require_file "$tmpdir/heap-remote/myheap.heap"

copy_nondet exe-remote rxexecmd
cp "$tmpdir/heap-remote/holproject.toml" "$tmpdir/exe-remote/holproject.toml"
sed -i 's/^name = "rxheapcmd"/name = "rxexecmd"/' "$tmpdir/exe-remote/holproject.toml"
cp "$tmpdir/heap-remote/src/HeapCmdScript.sml" "$tmpdir/heap-remote/src/ExeMain.sml" "$tmpdir/exe-remote/src/"
in_copy exe-remote --remote-cache "$remote_url" executable myexe \
  --remote-exec "$coordinator" --remote-only > "$tmpdir/exe-remote.log" 2>&1 ||
  { cat "$tmpdir/exe-remote.log" "$tmpdir/worker.log" >&2; exit 1; }
require_grep "HeapCmdTheory restored from cache" "$tmpdir/exe-remote.log"
require_grep "ExeMain built" "$tmpdir/exe-remote.log"
refute_grep "HeapCmdTheory built" "$tmpdir/exe-remote.log"
require_file "$tmpdir/exe-remote/myexe.exe"

copy_nondet export-remote rxexpcmd
cat > "$tmpdir/export-remote/src/ExpCmdScript.sml" <<'SML'
Theory ExpCmd
Ancestors bool
val exp_cmd_thm = save_thm("exp_cmd_thm", TRUTH);
SML
in_copy export-remote --remote-cache "$remote_url" export --build \
  --remote-exec "$coordinator" --remote-only -o "$tmpdir/expcmd.hbx" ExpCmdTheory \
  > "$tmpdir/export-remote.log" 2>&1 ||
  { cat "$tmpdir/export-remote.log" "$tmpdir/worker.log" >&2; exit 1; }
require_grep "ExpCmdTheory restored from cache" "$tmpdir/export-remote.log"
require_grep "exported .* cache action.* to $tmpdir/expcmd.hbx" "$tmpdir/export-remote.log"
refute_grep "ExpCmdTheory built" "$tmpdir/export-remote.log"
require_file "$tmpdir/expcmd.hbx"

# A fresh materialization can use local CAS entries without probing HTTP.
# A worker that needs those entries must still receive them remotely.
copy_nondet local-cas rxlocalcas
cat > "$tmpdir/local-cas/src/LocalBaseScript.sml" <<'SML'
Theory LocalBase
Ancestors bool
Theorem local_base: T
Proof
  simp[]
QED
SML
cat > "$tmpdir/local-cas/src/LocalMidScript.sml" <<'SML'
Theory LocalMid
Ancestors LocalBase
Theorem local_mid: T
Proof
  ACCEPT_TAC local_base
QED
SML
in_copy local-cas build LocalMidTheory > "$tmpdir/local-cas-seed.log" 2>&1
in_copy local-cas clean LocalBaseTheory LocalMidTheory > /dev/null
: > "$request_log"
in_copy local-cas --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --remote-only LocalMidTheory > "$tmpdir/local-cas-restore.log" 2>&1 ||
  { cat "$tmpdir/local-cas-restore.log" >&2; exit 1; }
require_grep 'LocalMidTheory restored from cache' "$tmpdir/local-cas-restore.log"
refute_grep 'remote batch' "$tmpdir/local-cas-restore.log"
refute_grep ' /ac/\| /cas/' "$request_log"

cat > "$tmpdir/local-cas/src/LocalTopScript.sml" <<'SML'
Theory LocalTop
Ancestors LocalMid
Theorem local_top: T
Proof
  ACCEPT_TAC local_mid
QED
SML
in_copy local-cas clean LocalBaseTheory LocalMidTheory > /dev/null
in_copy local-cas --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --remote-only LocalTopTheory > "$tmpdir/local-cas-dependency.log" 2>&1 ||
  { cat "$tmpdir/local-cas-dependency.log" "$tmpdir/worker.log" >&2; exit 1; }
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/local-cas-dependency.log")
require_grep '^action .* rxlocalcas:LocalTopTheory$' "$state/$batch.batch"
refute_grep '^action .* rxlocalcas:LocalBaseTheory$\|^action .* rxlocalcas:LocalMidTheory$' "$state/$batch.batch"
require_grep 'remote workers finished 1 of 1 theories' "$tmpdir/local-cas-dependency.log"

in_copy local-cas clean LocalMidTheory > /dev/null
in_copy local-cas --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --remote-only --force=theory LocalMidTheory > "$tmpdir/local-cas-force.log" 2>&1 ||
  { cat "$tmpdir/local-cas-force.log" "$tmpdir/worker.log" >&2; exit 1; }
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/local-cas-force.log")
require_grep '^action .* rxlocalcas:LocalMidTheory$' "$state/$batch.batch"

cat > "$tmpdir/local-cas/src/LocalDetachedScript.sml" <<'SML'
Theory LocalDetached
Ancestors bool
Theorem local_detached: T
Proof
  simp[]
QED
SML
in_copy local-cas build LocalDetachedTheory > "$tmpdir/local-cas-detach-seed.log" 2>&1
in_copy local-cas clean LocalDetachedTheory > /dev/null
in_copy local-cas --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --remote-only --detach LocalDetachedTheory > "$tmpdir/local-cas-detach.log" 2>&1
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/local-cas-detach.log")
require_grep '^action .* rxlocalcas:LocalDetachedTheory$' "$state/$batch.batch"
in_copy local-cas --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --remote-only --attach "$batch" LocalDetachedTheory > "$tmpdir/local-cas-attach.log" 2>&1 ||
  { cat "$tmpdir/local-cas-attach.log" "$tmpdir/worker.log" >&2; exit 1; }

# Two independent proof failures retain both logs and restore the healthy
# branch; descendants are skipped rather than reported as extra failures.
copy_nondet multi-failure rxmultifailure
for name in BadA BadB; do
  cat > "$tmpdir/multi-failure/src/${name}Script.sml" <<SML
Theory $name
Ancestors bool
val _ = raise Fail "independent remote failure $name";
SML
done
cat > "$tmpdir/multi-failure/src/HealthyScript.sml" <<'SML'
Theory Healthy
Ancestors bool
Theorem healthy: T
Proof
  ACCEPT_TAC TRUTH
QED
SML
cat > "$tmpdir/multi-failure/src/BlockedScript.sml" <<'SML'
Theory Blocked
Ancestors BadA
val _ = raise Fail "BLOCKED_REMOTE_MUST_NOT_RUN";
SML
: > "$state/keep-going"
: > "$state/ran"
status=0
in_copy multi-failure --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --remote-only BadATheory BadBTheory HealthyTheory BlockedTheory \
  > "$tmpdir/multi-failure.log" 2>&1 || status=$?
[[ $status -eq 1 ]] || { cat "$tmpdir/multi-failure.log" >&2; exit 1; }
require_grep 'remote failure summary: 2 failed, 1 skipped' "$tmpdir/multi-failure.log"
require_grep 'independent remote failure BadA' "$tmpdir/multi-failure.log"
require_grep 'independent remote failure BadB' "$tmpdir/multi-failure.log"
require_grep 'remote rxmultifailure:BlockedTheory: skipped' "$tmpdir/multi-failure.log"
require_grep 'HealthyTheory restored from cache' "$tmpdir/multi-failure.log"
refute_grep 'BlockedTheory' "$state/ran"
refute_grep 'BLOCKED_REMOTE_MUST_NOT_RUN' "$tmpdir/multi-failure.log"
for name in BadA BadB Healthy; do
  require_file "$tmpdir/multi-failure/.holbuild/logs/current/rxmultifailure/${name}Theory/build.log"
done
require_file "$tmpdir/multi-failure/.holbuild/obj/src/HealthyTheory.dat"
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/multi-failure.log")
while read -r tag key ac spec theory; do
  [[ $tag == action ]] || continue
  if [[ $theory == rxmultifailure:HealthyTheory ]]; then
    require_file "$remote_root/ac/$ac"
  else
    [[ ! -e "$remote_root/ac/$ac" ]] || { echo "$theory published failed or skipped outputs" >&2; exit 1; }
  fi
done < "$state/$batch.batch"

# A coordinator may omit all failure log hashes. Successful independent
# outputs are still restored before requesting a local diagnostic retry.
while read -r tag key ac spec theory; do
  if [[ $tag == action && $theory == rxmultifailure:Bad* ]]; then
    sed -i '/^log=/d' "$state/result-$key"
  fi
done < "$state/$batch.batch"
# Reattach to the recorded failure without rerunning the stand-in workers.
touch "$state/fail"
in_copy multi-failure clean HealthyTheory > /dev/null
[[ ! -e "$tmpdir/multi-failure/.holbuild/obj/src/HealthyTheory.dat" ]]
status=0
in_copy multi-failure --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --remote-only --attach "$batch" BadATheory BadBTheory HealthyTheory BlockedTheory \
  > "$tmpdir/multi-failure-nolog.log" 2>&1 || status=$?
rm "$state/fail"
[[ $status -eq 75 ]] || { cat "$tmpdir/multi-failure-nolog.log" >&2; exit 1; }
require_file "$tmpdir/multi-failure/.holbuild/obj/src/HealthyTheory.dat"
require_grep "could not fetch the failed theory's build log: BadATheory" "$tmpdir/multi-failure-nolog.log"
require_grep "could not fetch the failed theory's build log: BadBTheory" "$tmpdir/multi-failure-nolog.log"
refute_grep 'Theory built\|building locally' "$tmpdir/multi-failure-nolog.log"

# A non-proof final failure must install the healthy branch too, even though
# --remote-only requests a local retry rather than diagnosing the proof.
while read -r tag key ac spec theory; do
  if [[ $tag == action && $theory == rxmultifailure:Bad* ]]; then
    sed -i 's/^failure=.*/failure=memory/' "$state/result-$key"
  fi
done < "$state/$batch.batch"
touch "$state/fail"
in_copy multi-failure clean HealthyTheory > /dev/null
status=0
in_copy multi-failure --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --remote-only --attach "$batch" BadATheory BadBTheory HealthyTheory BlockedTheory \
  > "$tmpdir/multi-failure-memory.log" 2>&1 || status=$?
rm "$state/fail"
[[ $status -eq 75 ]] || { cat "$tmpdir/multi-failure-memory.log" >&2; exit 1; }
require_grep 'remote failure summary: 2 failed, 1 skipped' "$tmpdir/multi-failure-memory.log"
require_grep 'failed (memory)' "$tmpdir/multi-failure-memory.log"
require_file "$tmpdir/multi-failure/.holbuild/obj/src/HealthyTheory.dat"
refute_grep 'Theory built\|building locally' "$tmpdir/multi-failure-memory.log"

# A reported non-proof log can disappear from the cache before the client
# fetches it. Keep the remote failure and report the missing local copy.
while read -r tag key ac spec theory; do
  if [[ $tag == action && $theory == rxmultifailure:Bad* ]]; then
    printf 'log=%064d\n' 0 >> "$state/result-$key"
  fi
done < "$state/$batch.batch"
touch "$state/fail"
in_copy multi-failure clean HealthyTheory > /dev/null
status=0
in_copy multi-failure --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --remote-only --attach "$batch" BadATheory BadBTheory HealthyTheory BlockedTheory \
  > "$tmpdir/multi-failure-memory-missing-log.log" 2>&1 || status=$?
rm "$state/fail"
[[ $status -eq 75 ]] || { cat "$tmpdir/multi-failure-memory-missing-log.log" >&2; exit 1; }
require_grep "could not fetch the failed theory's build log: BadATheory" "$tmpdir/multi-failure-memory-missing-log.log"
require_grep "could not fetch the failed theory's build log: BadBTheory" "$tmpdir/multi-failure-memory-missing-log.log"
require_file "$tmpdir/multi-failure/.holbuild/obj/src/HealthyTheory.dat"
refute_grep 'Theory built\|building locally' "$tmpdir/multi-failure-memory-missing-log.log"

in_copy multi-failure --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --remote-only --detach --fail-fast BadATheory > "$tmpdir/multi-fail-fast.log" 2>&1
require_grep '^POST /v1/batches?fail_fast=true ' "$state/requests.log"


# A spec the worker rejects before any HOL runs has no log; its reason
# reaches the client with the failure.
cat > "$tmpdir/local-cas/src/LocalUntrustedScript.sml" <<'SML'
Theory LocalUntrusted
Ancestors bool
Theorem local_untrusted: T
Proof
  simp[]
QED
SML
touch "$state/untrusted"
set +e
in_copy local-cas --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --remote-only LocalUntrustedTheory > "$tmpdir/local-cas-untrusted.log" 2>&1
untrusted_status=$?
set -e
rm "$state/untrusted"
[[ $untrusted_status == 75 ]] || { cat "$tmpdir/local-cas-untrusted.log" "$tmpdir/worker.log" >&2; exit 1; }
require_grep '^detail=exec-action HOL repository is not trusted by this worker: ' "$tmpdir/worker.result"
refute_grep '^log=' "$tmpdir/worker.result"
require_grep 'holbuild: remote rxlocalcas:LocalUntrustedTheory: failed (spec-rejected: exec-action HOL repository is not trusted by this worker: ' \
  "$tmpdir/local-cas-untrusted.log"


# The missing-input replay below needs the worker's normal resubmit signal.
rm "$state/keep-going"

# Batch priority is scheduling metadata; it reaches submit together with the other batch options.
cat > "$tmpdir/local-cas/src/PriorityScript.sml" <<'SML'
Theory Priority
Ancestors bool
Theorem priority_test: T
Proof
  simp[]
QED
SML
in_copy local-cas --remote-cache "$remote_url" --max-heap 4096 build --remote-exec "$coordinator" \
  --remote-only --priority 7 --fail-fast PriorityTheory > "$tmpdir/priority.log" 2>&1
require_grep '^POST /v1/batches?fail_fast=true&priority=7&max_heap_mb=4096 ' "$state/requests.log"
in_copy local-cas --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --detach --priority=2147483647 LocalUntrustedTheory > "$tmpdir/priority-equals.log" 2>&1
require_grep '^POST /v1/batches?priority=2147483647 ' "$state/requests.log"

for value in -1 1.5 urgent 2147483648; do
  if in_copy local-cas build --remote-exec "$coordinator" --priority "$value" PriorityTheory > "$tmpdir/priority-invalid.log" 2>&1; then
    echo "accepted invalid priority $value" >&2
    exit 1
  fi
  if [[ $value == 2147483648 ]]; then
    require_grep '^holbuild: --priority must be between 0 and 2147483647$' "$tmpdir/priority-invalid.log"
  else
    require_grep "^holbuild: invalid --priority: $value; expected an integer between 0 and 2147483647$" "$tmpdir/priority-invalid.log"
  fi
done
if in_copy local-cas build --priority 1 PriorityTheory > "$tmpdir/priority-no-exec.log" 2>&1; then
  echo 'accepted priority without remote execution' >&2
  exit 1
fi
require_grep 'priority needs --remote-exec URL' "$tmpdir/priority-no-exec.log"

# So is the cap on theories loading ahead of their parents, 4 when given bare.
in_copy local-cas --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --detach --speculative-loading LocalUntrustedTheory > "$tmpdir/speculative-default.log" 2>&1
require_grep '^POST /v1/batches?speculative_loading=4 ' "$state/requests.log"
in_copy local-cas --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --detach --priority 2 --speculative-loading=4 LocalUntrustedTheory > "$tmpdir/speculative.log" 2>&1
require_grep '^POST /v1/batches?priority=2&speculative_loading=4 ' "$state/requests.log"
for value in 0 17 1.5 x '' 999999999999999999999999999999; do
  if in_copy local-cas build --remote-exec "$coordinator" "--speculative-loading=$value" PriorityTheory \
       > "$tmpdir/speculative-invalid.log" 2>&1; then
    echo "accepted invalid --speculative-loading=$value" >&2
    exit 1
  fi
  require_grep "^holbuild: invalid --speculative-loading: $value; expected an integer between 1 and 16$" \
    "$tmpdir/speculative-invalid.log"
done
if in_copy local-cas build --speculative-loading PriorityTheory > "$tmpdir/speculative-no-exec.log" 2>&1; then
  echo 'accepted --speculative-loading without remote execution' >&2
  exit 1
fi
require_grep 'speculative-loading needs --remote-exec URL' "$tmpdir/speculative-no-exec.log"

# Reattaching can need a replacement batch after an input disappears.
cat > "$tmpdir/local-cas/src/PriorityChildScript.sml" <<'SML'
Theory PriorityChild
Ancestors Priority
Theorem priority_child_test: T
Proof
  simp[]
QED
SML
in_copy local-cas --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --remote-only PriorityChildTheory > "$tmpdir/priority-attach-seed.log" 2>&1
printf '\n(* changed parent *)\n' >> "$tmpdir/local-cas/src/PriorityScript.sml"
child_source=$(sha256sum "$tmpdir/local-cas/src/PriorityChildScript.sml" | cut -d' ' -f1)
rm "$remote_root/cas/$child_source" "$tmpdir/worker-cache/blobs/$child_source"
in_copy local-cas --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --detach --priority 9 PriorityChildTheory > "$tmpdir/priority-attach-detach.log" 2>&1
priority_batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/priority-attach-detach.log")
[[ -n $priority_batch ]] || { cat "$tmpdir/priority-attach-detach.log" >&2; exit 1; }
in_copy local-cas --remote-cache "$remote_url" build --remote-exec "$coordinator" \
  --remote-only --attach "$priority_batch" --priority 9 PriorityChildTheory > "$tmpdir/priority-attach.log" 2>&1
require_grep "still missing blob $child_source after 3 attempts; .*; resubmitting$" "$tmpdir/priority-attach.log"
[[ $(grep -c '^POST /v1/batches?priority=9 ' "$state/requests.log") -eq 2 ]] || { cat "$state/requests.log" >&2; exit 1; }
require_grep 'remote rxlocalcas:PriorityChildTheory: done' "$tmpdir/priority-attach.log"

# Timings are execution results, not deterministic cached outputs. A forced
# rebuild must keep the resident entry and return the worker's diagnostic.
project=$tmpdir/publish-project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rxpublish"
[build]
members = ["src"]
TOML
write_theories publish-log
cat >> "$project/src/BScript.sml" <<'SML'
fun holbuild_extra_outputs (_ : string list) = ()
val _ = holbuild_extra_outputs ["timing.txt"]
val _ =
  let val out = TextIO.openOut "timing.txt"
  in TextIO.output (out, Time.toString (Time.now ()) ^ "\n"); TextIO.closeOut out end
SML
run publish-seed 0 build --remote-exec "$coordinator" --remote-only BTheory
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/publish-seed.log")
ac=$(awk '$1 == "action" && $5 == "rxpublish:BTheory" { print $3 }' "$state/$batch.batch")
cp "$remote_root/ac/$ac" "$tmpdir/publish-resident"
run publish-conflict 75 build --remote-exec "$coordinator" --remote-only --force=theory BTheory
require_grep 'the remote cache holds different outputs for the action' "$tmpdir/publish-conflict.log"
require_grep 'existing outputs: .*extra:timing.txt=' "$tmpdir/publish-conflict.log"
require_grep 'new outputs: .*extra:timing.txt=' "$tmpdir/publish-conflict.log"
require_grep 'The same inputs must produce identical outputs' "$tmpdir/publish-conflict.log"
require_grep 'put timings in the build log instead' "$tmpdir/publish-conflict.log"
local_log=$project/.holbuild/logs/current/rxpublish/BTheory/build.log
require_grep "child log: $local_log" "$tmpdir/publish-conflict.log"
require_grep 'the remote cache holds different outputs for the action' "$local_log"
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/publish-conflict.log")
key=$(awk '$1 == "action" && $5 == "rxpublish:BTheory" { print $2 }' "$state/$batch.batch")
log_sha=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$state/result-$key")
[[ -n $log_sha && $(sha256sum < "$local_log" | cut -d' ' -f1) == "$log_sha" ]] ||
  { echo 'publish failure log is not the worker log' >&2; exit 1; }
cmp "$remote_root/ac/$ac" "$tmpdir/publish-resident"
refute_grep 'Theory built\|building locally' "$tmpdir/publish-conflict.log"

# A lost log warns and removes the previous execution's log, without hiding
# the batch failure or changing its exit status.
touch "$state/drop-log"
run publish-missing-log 75 build --remote-exec "$coordinator" --remote-only --force=theory BTheory
rm "$state/drop-log"
require_grep "could not fetch the failed theory's build log: BTheory" "$tmpdir/publish-missing-log.log"
require_grep 'remote execution: batch .* failed' "$tmpdir/publish-missing-log.log"
require_no_file "$local_log"
cmp "$remote_root/ac/$ac" "$tmpdir/publish-resident"


# Cache ring replicas can disagree on an entry's timeout contract.  With the
# weaker copy on the node ranked first, batch export and restore must find the
# stronger one on the next node, also after this build copied the weaker one.
write_ring_timeout() {
  copy_nondet "$1" rxring
  cat > "$tmpdir/$1/src/TimeoutScript.sml" <<'SML'
Theory Timeout
Ancestors bool

Theorem ring_timeout_thm:
  T
Proof
  simp[]
QED
SML
}
write_ring_timeout ring-seed
in_copy ring-seed --remote-cache "$remote_url" build --tactic-timeout 0 TimeoutTheory \
  > "$tmpdir/ring-weak.log" 2>&1 || { cat "$tmpdir/ring-weak.log" >&2; exit 1; }
ring_key=$(sed -n 's/^input_key=//p' "$tmpdir/ring-seed/.holbuild/dep/rxring/src/TimeoutScript.sml.key")
ring_ac=$(printf 'holbuild-remote-ac-v1\n%s\n' "$ring_key" | sha256sum | cut -d' ' -f1)
require_grep '^proof-timeout=none$' "$remote_root/ac/$ring_ac"
cp "$remote_root/ac/$ring_ac" "$tmpdir/ring-weak-ac"
in_copy ring-seed --remote-cache "$remote_url" build --tactic-timeout 2.5 TimeoutTheory \
  > "$tmpdir/ring-strong.log" 2>&1 || { cat "$tmpdir/ring-strong.log" >&2; exit 1; }
require_grep '^proof-timeout=2.5$' "$remote_root/ac/$ring_ac"
cp "$remote_root/ac/$ring_ac" "$tmpdir/ring-strong-ac"

first_server_pid=$server_pid
first_url=$remote_url
first_request_log=$request_log
second_root=$tmpdir/remote-2
start_remote_cache_server "$second_root" "$tmpdir/server-2"
ring_server_pid=$server_pid
second_url=$remote_url
server_pid=$first_server_pid
remote_url=$first_url
request_log=$first_request_log
mkdir -p "$second_root/ac" "$second_root/cas"
for blob in $(awk '$1 == "blob" && length($2) == 64 { print $2 }' "$tmpdir/ring-strong-ac"); do
  cp "$remote_root/cas/$blob" "$second_root/cas/$blob"
done
ring_rank() { printf '%s:%s' "$1" "$ring_ac" | sha256sum | cut -d' ' -f1; }
if [[ $(ring_rank "$first_url") > $(ring_rank "$second_url") ]]; then
  ranked_roots=("$remote_root" "$second_root")
else
  ranked_roots=("$second_root" "$remote_root")
fi
cp "$tmpdir/ring-weak-ac" "${ranked_roots[0]}/ac/$ring_ac"
cp "$tmpdir/ring-strong-ac" "${ranked_roots[1]}/ac/$ring_ac"

write_ring_timeout ring-client
(cd "$tmpdir/ring-client" && HOLBUILD_CACHE=$tmpdir/ring-client-cache HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" --remote-cache "$first_url,$second_url" build --remote-exec "$coordinator" \
  --remote-only --tactic-timeout 2.5 TimeoutTheory) > "$tmpdir/ring-client.log" 2>&1 ||
  { cat "$tmpdir/ring-client.log" >&2; exit 1; }
require_grep 'remote execution: nothing to build remotely' "$tmpdir/ring-client.log"
require_grep 'entry passed over' "$tmpdir/ring-client.log"
require_grep 'TimeoutTheory restored from cache' "$tmpdir/ring-client.log"
refute_grep 'remote batch\|Theory built' "$tmpdir/ring-client.log"
require_grep '^proof-timeout=2.5$' "$tmpdir/ring-client-cache/actions/$ring_key/manifest"
cmp "${ranked_roots[0]}/ac/$ring_ac" "$tmpdir/ring-weak-ac"

# A worker sees both replicas, while a reader sees only the weaker one.
# Export the action before restoring the fixture entries so the worker can
# confirm a cached result without rebuilding it.
rm "${ranked_roots[0]}/ac/$ring_ac" "${ranked_roots[1]}/ac/$ring_ac"
write_ring_timeout ring-spec
in_copy ring-spec --remote-cache "$first_url" action-spec --upload --tactic-timeout 2.5 TimeoutTheory \
  > "$tmpdir/ring-spec.batch" 2> "$tmpdir/ring-spec.log" ||
  { cat "$tmpdir/ring-spec.log" >&2; exit 1; }
ring_spec=$(awk '$1 == "action" && $5 == "rxring:TimeoutTheory" { print $4 }' "$tmpdir/ring-spec.batch")
[[ -n "$ring_spec" ]]
if [[ ${ranked_roots[1]} == "$remote_root" ]]; then
  single_url=$first_url
else
  single_url=$second_url
fi

ring_worker() {
  local name=$1 expected=${2:-cached}
  link_hol_toolchain_cache "$tmpdir/$name-cache"
  mkdir -p "$tmpdir/$name"
  (cd "$tmpdir/$name" && HOLBUILD_CACHE="$tmpdir/$name-cache" \
    "$HOLBUILD_BIN" --remote-cache "$first_url,$second_url" exec-action "$ring_spec" \
      --cache-limit-gb 1000 --result "$tmpdir/$name.result") > "$tmpdir/$name.log" 2>&1 ||
    { cat "$tmpdir/$name.log" "$tmpdir/$name.result" >&2; exit 1; }
  require_grep "^status=$expected\$" "$tmpdir/$name.result"
  if [[ $expected == cached ]]; then
    refute_grep 'phase-ms=.*hol:' "$tmpdir/$name.result"
  else
    require_grep 'phase-ms=.*hol:' "$tmpdir/$name.result"
  fi
}

cp "$tmpdir/ring-strong-ac" "${ranked_roots[0]}/ac/$ring_ac"
cp "$tmpdir/ring-weak-ac" "${ranked_roots[1]}/ac/$ring_ac"
ring_worker ring-cached-worker
require_grep '^proof-timeout=2.5$' "${ranked_roots[1]}/ac/$ring_ac"
write_ring_timeout ring-single-reader
in_copy ring-single-reader --remote-cache "$single_url" build --remote-exec "$unreachable" \
  --remote-only --tactic-timeout 2.5 TimeoutTheory > "$tmpdir/ring-single-reader.log" 2>&1 ||
  { cat "$tmpdir/ring-single-reader.log" >&2; exit 1; }
require_grep 'remote execution: nothing to build remotely' "$tmpdir/ring-single-reader.log"
require_grep 'TimeoutTheory restored from cache' "$tmpdir/ring-single-reader.log"

# The first hydrate must filter a weak primary instead of rebuilding a
# theory already checked on the second replica.
cp "$tmpdir/ring-weak-ac" "${ranked_roots[0]}/ac/$ring_ac"
cp "$tmpdir/ring-strong-ac" "${ranked_roots[1]}/ac/$ring_ac"
ring_worker ring-filtered-worker
require_grep '^proof-timeout=2.5$' "${ranked_roots[0]}/ac/$ring_ac"

# A source build strengthens both existing copies too.
cp "$tmpdir/ring-weak-ac" "${ranked_roots[0]}/ac/$ring_ac"
cp "$tmpdir/ring-weak-ac" "${ranked_roots[1]}/ac/$ring_ac"
ring_worker ring-built-worker built
require_grep '^proof-timeout=2.5$' "${ranked_roots[0]}/ac/$ring_ac"
require_grep '^proof-timeout=2.5$' "${ranked_roots[1]}/ac/$ring_ac"
