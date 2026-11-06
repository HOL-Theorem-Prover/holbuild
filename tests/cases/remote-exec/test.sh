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
# come before children) in a cache root and directory of their own.
state=$tmpdir/coordinator
mkdir -p "$state"
link_hol_toolchain_cache "$tmpdir/worker-cache"
mkdir -p "$tmpdir/worker-cwd"
cat > "$tmpdir/run-batch" <<SH
#!/usr/bin/env bash
set -eu
[[ ! -e "$state/fail" ]] || exit 1
cd "$tmpdir/worker-cwd"
awk '\$1 == "action" { print \$4, \$5 }' "\$1" | while read -r spec theory; do
  echo "\$theory" >> "$state/ran"
  HOLBUILD_CACHE="$tmpdir/worker-cache" "$HOLBUILD_BIN" --remote-cache "$remote_url" \
    exec-action "\$spec" --cache-limit-gb 1000 --result "$tmpdir/worker.result" \
    >> "$tmpdir/worker.log" 2>&1
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
require_grep "remote execution: the remote cache has every theory" "$tmpdir/cached.log"

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
require_grep "batch nope can't be followed (HTTP 404): .*no such batch" "$tmpdir/unknown-only.log"
refute_grep "reattach" "$tmpdir/unknown-only.log"
run unknown 0 build --remote-exec "$coordinator" --attach nope BTheory
require_grep "batch nope can't be followed (HTTP 404): .*, cancelled the batch; building locally" "$tmpdir/unknown.log"
require_grep "^POST /v1/batches/nope/cancel " "$state/requests.log"

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

# An interrupted build cancels the batch it follows, unless --remote-only
# (which can reattach to it).
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
refute_grep "^POST /v1/batches/$batch/cancel " "$state/requests.log"
refute_grep "cancelled" "$tmpdir/interrupted-only.log"
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
# --remote-only restores, so with nothing cached it fails without building.
set +e
(cd "$generated" && "$HOLBUILD_BIN" --remote-cache "$remote_url" build --remote-exec "$coordinator" --remote-only UseLib) \
  > "$tmpdir/generated-only.log" 2>&1
status=$?
set -e
[[ $status -eq 75 ]] || { echo "generated-only exited $status, wanted 75" >&2; cat "$tmpdir/generated-only.log" >&2; exit 1; }
require_grep "build before the rest is planned; restoring from the cache" "$tmpdir/generated-only.log"
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
