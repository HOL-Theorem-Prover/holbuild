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
  for pid in ${server_pid:-} ${coordinator_pid:-}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

remote_root=$tmpdir/remote
start_remote_cache_server "$remote_root" "$tmpdir/server"
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
share=
[[ ! -e "$state/share-heaps" ]] || share=--share-heaps
awk '\$1 == "action" { print \$2, \$4, \$5 }' "\$1" | while read -r key spec theory; do
  echo "\$theory" >> "$state/ran"
  status=0
  HOLBUILD_CACHE="$tmpdir/worker-cache" "$HOLBUILD_BIN" --remote-cache "$remote_url" \
    exec-action "\$spec" --cache-limit-gb 1000 --result "$tmpdir/worker.result" \$share \
    >> "$tmpdir/worker.log" 2>&1 || status=\$?
  echo "\$theory \$(grep '^status=' "$tmpdir/worker.result")" >> "$state/results"
  cp "$tmpdir/worker.result" "$state/result-\$key"
  if [[ -e "$state/drop-log" ]]; then
    rm -f "$remote_root/cas/\$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$tmpdir/worker.result")"
  fi
  # A failed action fails the batch, naming the theory it found missing.
  [[ \$status -eq 0 ]] ||
    { sed -n 's/^missing=theory //p' "$tmpdir/worker.result" > "$state/missing"; exit 1; }
done
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
# status 75, so a caller can build locally) or --detach (1).
write_theories three
run unreachable-only 75 build --remote-exec "$unreachable" --remote-only BTheory
require_grep "remote execution: could not reach the coordinator at $unreachable" "$tmpdir/unreachable-only.log"
refute_grep "Theory built" "$tmpdir/unreachable-only.log"
run unreachable 0 build --remote-exec "$unreachable" BTheory
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
run down-only 75 build --remote-exec "$coordinator" --remote-only BTheory
require_grep "the coordinator reported no theories; reattach with --attach b5" "$tmpdir/down-only.log"
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

# A failed batch falls back too.
write_theories six
touch "$state/fail"
run failed-only 75 build --remote-exec "$coordinator" --remote-only BTheory
require_grep "remote rx:ATheory: failed (proof)" "$tmpdir/failed-only.log"
require_grep "remote execution: batch b7 failed: an action failed; remote workers finished 0 of 2 theories" "$tmpdir/failed-only.log"
run failed 0 build --remote-exec "$coordinator" BTheory
require_grep "batch b8 failed: an action failed; remote workers finished 0 of 2 theories; building locally" "$tmpdir/failed.log"
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
touch "$state/hang"
interrupt interrupted build --remote-exec "$coordinator" BTheory
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/interrupted.log")
require_grep "^POST /v1/batches/$batch/cancel " "$state/requests.log"
require_grep "holbuild: cancelled remote batch $batch" "$tmpdir/interrupted.log"
require_grep "holbuild: interrupted" "$tmpdir/interrupted.log"
refute_grep "Theory built" "$tmpdir/interrupted.log"
interrupt interrupted-only build --remote-exec "$coordinator" --remote-only BTheory
batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/interrupted-only.log")
require_grep "^POST /v1/batches/$batch/cancel " "$state/requests.log"
require_grep "holbuild: cancelled remote batch $batch" "$tmpdir/interrupted-only.log"
rm "$state/hang"

# A closure that can't run remotely (a forced action) is built locally.
run forced-only 75 build --remote-exec "$coordinator" --remote-only --force BTheory
require_grep "can't run remotely: it is forced" "$tmpdir/forced-only.log"
run forced 0 build --remote-exec "$coordinator" --force BTheory
require_grep "BTheory built" "$tmpdir/forced.log"

# A stream cut midway through an event: the partial line is no theory.
write_theories cut
touch "$state/cut"
run cut 0 build --remote-exec "$coordinator" BTheory
require_grep 'lost the event stream for batch b[0-9]*: {"type": "action", "input_key"curl: (18) .*; reattaching' "$tmpdir/cut.log"
require_grep "remote execution: remote workers finished 2 of 2 theories" "$tmpdir/cut.log"
refute_grep "remote ?" "$tmpdir/cut.log"

# The coordinator's credentials come from a curl config file.
printf 'header = "Authorization: Bearer stub-token"\n' > "$tmpdir/coordinator.curl"
write_theories seven
HOLBUILD_REMOTE_EXEC_CURL_CONFIG=$tmpdir/coordinator.curl run auth 0 build --remote-exec "$coordinator" BTheory
require_grep "^POST /v1/batches Bearer stub-token$" "$state/requests.log"

# Flags that need --remote-exec, and ones it excludes.
run no-url 1 build --remote-only BTheory
require_grep "need --remote-exec URL" "$tmpdir/no-url.log"
run both 1 build --remote-exec "$coordinator" --detach --attach b1 BTheory
require_grep "exclude each other" "$tmpdir/both.log"
run url-missing 1 build --remote-exec --remote-only BTheory
require_grep "remote-exec requires URL" "$tmpdir/url-missing.log"
run id-missing 1 build --remote-exec "$coordinator" --attach --remote-only BTheory
require_grep "attach requires BATCH-ID" "$tmpdir/id-missing.log"
run trace 1 build --remote-exec "$coordinator" --trace-steps BTheory
require_grep "does not support .*--trace-steps" "$tmpdir/trace.log"

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
(cd "$generated" && "$HOLBUILD_BIN" --remote-cache "$remote_url" build --remote-exec "$coordinator" UseLib) \
  > "$tmpdir/generated.log" 2>&1 || { cat "$tmpdir/generated.log" >&2; exit 1; }
require_grep "theories that write SML sources build before the rest is planned; building locally" "$tmpdir/generated.log"
require_grep "GenTheory built" "$tmpdir/generated.log"
require_grep "UseLib built" "$tmpdir/generated.log"
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
touch "$state/cancelled"
run cancelled-only 1 build --remote-exec "$coordinator" --remote-only BTheory
require_grep "remote execution: batch b[0-9]* cancelled; remote workers finished 0 of 2 theories" "$tmpdir/cancelled-only.log"
run cancelled 0 build --remote-exec "$coordinator" BTheory
require_grep "batch b[0-9]* cancelled; remote workers finished 0 of 2 theories; building locally" "$tmpdir/cancelled.log"
require_grep "BTheory built" "$tmpdir/cancelled.log"
rm "$state/cancelled"

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
# Without a local cache entry to publish, it goes to the workers.
rm "$remote_root/ac/$ac_a"
rm -r "$HOLBUILD_CACHE/actions/$key_a"
sed -i 's/(\* built-here-batch \*)/(* built-here-unpublished *)/' "$project/src/BScript.sml"
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

# Early cutoff on the workers.  A <- B <- C, built with shared heaps: a
# proof-only edit of A rebuilds A and reuses the earlier builds of B and C,
# whose dependencies' outputs are unchanged; an edit that changes A's
# outputs rebuilds them; and an edited B, on unchanged dependency outputs,
# resumes from the deps heap its last build shared.
project=$tmpdir/cutoff
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rxc"

[build]
members = ["src"]
TOML
# write_cutoff A-STAMP B-STAMP [A-EXTRA]
write_cutoff() {
  cat > "$project/src/AScript.sml" <<SML
Theory A
Ancestors bool

Theorem a_thm:
  T
Proof
  simp[] (* $1 *)
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
run cutoff-proof 0 build --remote-exec "$coordinator" CTheory
require_grep "remote workers finished 3 of 3 theories" "$tmpdir/cutoff-proof.log"
refute_grep "Theory built" "$tmpdir/cutoff-proof.log"
require_grep "early cutoff: rxc:BTheory reuses" "$tmpdir/worker.log"
require_grep "early cutoff: rxc:CTheory reuses" "$tmpdir/worker.log"
results built cached cached

a2=$'Theorem a2_thm:\n  T\nProof\n  simp[]\nQED'
write_cutoff three one "$a2"
run cutoff-output 0 build --remote-exec "$coordinator" CTheory
refute_grep "early cutoff" "$tmpdir/worker.log"
results built built built

write_cutoff four four "$a2"
run cutoff-dependent 0 build --remote-exec "$coordinator" CTheory
require_grep "BTheory restored from cache" "$tmpdir/cutoff-dependent.log"
refute_grep "Theory built" "$tmpdir/cutoff-dependent.log"
grep -A1 "^resuming BTheory$" "$tmpdir/worker.log" | grep -q "from: deps-loaded checkpoint" ||
  { echo "B did not resume from the shared deps heap" >&2; cat "$tmpdir/worker.log" >&2; exit 1; }
require_grep "early cutoff: rxc:CTheory reuses" "$tmpdir/worker.log"
results built built cached
rm "$state/share-heaps"

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

# The remote's MTheory doesn't fit the worker's NTheory: the worker drops its
# copy, so that the next attempt (here the resubmission) restores the
# remote's.
copy_nondet stale-dep rxnw
worker_n stale-dep
copy_nondet stale-dep-remote rxnw
in_copy stale-dep-remote --remote-cache "$remote_url" build MTheory > "$tmpdir/stale-dep-remote.log" 2>&1 ||
  { cat "$tmpdir/stale-dep-remote.log" >&2; exit 1; }
copy_nondet stale-dep-client rxnw
in_copy stale-dep-client --remote-cache "$remote_url" build --remote-exec "$coordinator" --remote-only PTheory \
  > "$tmpdir/stale-dep.log" 2>&1 || { cat "$tmpdir/stale-dep.log" "$tmpdir/worker.log" >&2; exit 1; }
require_grep "resubmitting with 2 theories rebuilt or rechecked" "$tmpdir/stale-dep.log"
require_grep "remote execution: remote workers finished 2 of 2 theories" "$tmpdir/stale-dep.log"
require_grep "PTheory restored from cache" "$tmpdir/stale-dep.log"

# The worker builds MTheory against its own NTheory: the build isn't
# published, and the next build's worker restores the remote's NTheory.
copy_nondet stale-build rxnv
worker_n stale-build
copy_nondet stale-build-remote rxnv
in_copy stale-build-remote --remote-cache "$remote_url" build NTheory > "$tmpdir/stale-build-remote.log" 2>&1 ||
  { cat "$tmpdir/stale-build-remote.log" >&2; exit 1; }
m_ac=$(in_copy stale-build-remote --remote-cache "$remote_url" action-spec PTheory |
  awk '$1 == "action" && $5 == "rxnv:MTheory" { print $3 }')
[[ -n $m_ac ]] || { echo "no action for MTheory" >&2; exit 1; }
copy_nondet stale-build-client rxnv
set +e
in_copy stale-build-client --remote-cache "$remote_url" build --remote-exec "$coordinator" --remote-only PTheory \
  > "$tmpdir/stale-build-client.log" 2>&1
status=$?
set -e
[[ $status -eq 75 ]] || { echo "stale-build-client exited $status, wanted 75" >&2; cat "$tmpdir/stale-build-client.log" >&2; exit 1; }
require_grep "built against out-of-date local copies of its parents" "$tmpdir/worker.log"
[[ ! -e $remote_root/ac/$m_ac ]] || { echo "MTheory built on a stale parent reached the remote" >&2; exit 1; }
in_copy stale-build-client --remote-cache "$remote_url" build --remote-exec "$coordinator" --remote-only PTheory \
  > "$tmpdir/stale-build-again.log" 2>&1 || { cat "$tmpdir/stale-build-again.log" "$tmpdir/worker.log" >&2; exit 1; }
require_grep "remote execution: remote workers finished 2 of 2 theories" "$tmpdir/stale-build-again.log"
require_grep "PTheory restored from cache" "$tmpdir/stale-build-again.log"
