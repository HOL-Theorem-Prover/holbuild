#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# run-action --remote-exec against a stub coordinator whose "workers" run
# each run with exec-action, sharing only the remote cache with the client,
# which then fetches every run's outputs.

tmpdir=$(make_temp_dir)
cleanup() {
  for pid in ${run_pid:-} ${server_pid:-} ${coordinator_pid:-}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
unset HOLBUILD_REMOTE_CACHE_URL

remote_root=$tmpdir/remote
start_remote_cache_server "$remote_root" "$tmpdir/server" "$tmpdir/control"
use_case_cache "$tmpdir/cache"

# The stand-in for the workers: runs every action of the batch in a cache
# root and directory of their own, leaving each one's result for the stub
# to report; in a run batch a failed action doesn't stop the others.
state=$tmpdir/coordinator
mkdir -p "$state"
link_hol_toolchain_cache "$tmpdir/worker-cache"
mkdir -p "$tmpdir/worker-cwd"
cat > "$tmpdir/run-batch" <<SH
#!/usr/bin/env bash
set -eu
cd "$tmpdir/worker-cwd"
# A worker that trusts no HOL repository rejects every spec.
untrusted=()
[[ ! -e "$state/untrusted" ]] || untrusted=(HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES=/unconfigured=master)
awk '\$1 == "action" { print \$2, \$4, \$5 }' "\$1" | while read -r key spec theory; do
  echo "\$theory" >> "$state/ran"
  env "\${untrusted[@]}" HOLBUILD_CACHE="$tmpdir/worker-cache" "$HOLBUILD_BIN" --remote-cache "$remote_url" \
    exec-action "\$spec" --cache-limit-gb 1000 --result "$state/result-\$key" \
    >> "$tmpdir/worker.log" 2>&1 || true
  if [[ -e "$state/drop-log" ]]; then
    rm -f "$remote_root/cas/\$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$state/result-\$key")"
  fi
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
export HOLBUILD_TEST_RETRY_DELAYS=0,0,0,0

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rr"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Theorem a_thm:
  T
Proof
  simp[]
QED
SML
cat > "$project/src/CScript.sml" <<'SML'
Theory C
Ancestors A

Theorem c_thm:
  T
Proof
  ACCEPT_TAC a_thm
QED
SML

runner=$tmpdir/runner
mkdir -p "$runner"
# script NAME STAMP: a script that writes its context to its two outputs,
# and raises in A's context; each stamp is a new run key.
script() {
  cat > "$runner/$1" <<SML
(* $2 *)
fun env name = valOf (OS.Process.getEnv name);
fun write name text =
  let val out = TextIO.openOut (OS.Path.concat (env "HOLBUILD_RUN_OUTPUT_DIR", name))
  in TextIO.output (out, text); TextIO.closeOut out end;
val _ = if env "HOLBUILD_RUN_CONTEXT" = "rr:ATheory" then raise Fail "no A" else ();
val _ = write "first" (env "HOLBUILD_RUN_CONTEXT" ^ "\n");
val _ = write "second" (env "HOLBUILD_RUN_CONTEXT_KEY" ^ "\n");
SML
}
script run.sml 1

out=$tmpdir/out
hb() {
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" "$@")
}
# run NAME EXPECTED-EXIT ARGS...: run-action with ARGS; stdout to
# $tmpdir/NAME.out, stderr to $tmpdir/NAME.err.
run() {
  local name=$1 code=$2
  shift 2
  set +e
  hb run-action --outputs-dir "$out" --output first --output second "$@" \
    > "$tmpdir/$name.out" 2> "$tmpdir/$name.err"
  local status=$?
  set -e
  if [[ "$status" != "$code" ]]; then
    echo "$name exited $status, wanted $code" >&2
    cat "$tmpdir/$name.out" "$tmpdir/$name.err" >&2
    cat "$tmpdir/worker.log" >&2 2>/dev/null || true
    exit 1
  fi
}
# line NAME CONTEXT STATUS: the run's line, and its run key printed.
line() {
  local key
  key=$(awk -v c="$2" '$1 == c { print $2 }' "$tmpdir/$1.out")
  grep -qx -- "$2 $key $3" "$tmpdir/$1.out" || {
    echo "$1 has no line '$2 <key> $3':" >&2
    cat "$tmpdir/$1.out" "$tmpdir/$1.err" >&2
    exit 1
  }
  echo "$key"
}
posts() { grep -c '^POST /v1/batches?' "$state/requests.log" || true; }
ac_file() {
  printf '%s/ac/%s' "$remote_root" \
    "$(printf 'holbuild-remote-ac-v1\n%s\n' "$1" | sha256sum | awk '{ print $1 }')"
}

# Untimed root artifacts are valid run contexts. C is built here only:
# the remote cache lacks it until a run needs it.
(cd "$project" && "$HOLBUILD_BIN" build --skip-proof-steps CTheory > /dev/null)
metadata=$project/.holbuild/dep/rr/src/CScript.sml.key
require_grep '^proof_timeout=none$' "$metadata"
(cd "$project" && "$HOLBUILD_BIN" build --dry-run CTheory) > "$tmpdir/plan.txt"
key_c=$(awk '/^[^ ]/ { name = $1 } $1 == "input_key:" && name == "CTheory" { print $2 }' "$tmpdir/plan.txt")
[[ -n "$key_c" ]] || { cat "$tmpdir/plan.txt" >&2; exit 1; }
require_grep "^input_key=$key_c$" "$metadata"
require_no_file "$(ac_file "$key_c")"

# A toolchain context, run and fetched.
run hol 0 --remote-exec "$coordinator" --script "$runner/run.sml" hol:bool
hol_key=$(line hol HOL:boolTheory done)
[[ $(< "$out/HOL/boolTheory/KEY") == "$hol_key" ]]
[[ $(< "$out/HOL/boolTheory/CONTEXT") == HOL:boolTheory ]]
[[ $(< "$out/HOL/boolTheory/first") == HOL:boolTheory ]]
require_no_file "$out/HOL/boolTheory/LOG"
require_grep '^POST /v1/batches?class=run ' "$state/requests.log"
python3 - "$state/result-$hol_key" <<'PY'
import pathlib,sys
fields=dict(line.split('=',1) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if '=' in line)
timings=dict(item.split(':',1) for item in fields['phase-ms'].split(','))
assert 'rebuilt' not in timings, timings
for phase in ('hol','publish','log'):
    assert int(timings[phase+'end']) >= int(timings[phase+'start']), timings
assert int(timings['finished']) >= int(timings['started'])
PY

# Two targets, one cached: only the other is submitted, with the profile;
# C's entry is published from the local cache first.
run two 0 --remote-exec "$coordinator" --profile p1 --script "$runner/run.sml" rr:CTheory hol:bool
[[ $(line two HOL:boolTheory cached) == "$hol_key" ]]
c_run=$(line two rr:CTheory done)
require_grep '^POST /v1/batches?class=run&profile=p1 ' "$state/requests.log"
[[ $(grep -c ' rr:CTheory$' "$state/b2.batch") -eq 1 ]]
if grep -q 'HOL:boolTheory' "$state/b2.batch"; then
  echo "a cached run was submitted" >&2
  exit 1
fi
require_file "$(ac_file "$key_c")"
[[ $(< "$out/rr/CTheory/KEY") == "$c_run" ]]
[[ $(< "$out/rr/CTheory/CONTEXT") == "rr:CTheory@$key_c" ]]
[[ $(< "$out/rr/CTheory/first") == rr:CTheory ]]
[[ $(< "$out/rr/CTheory/second") == "$key_c" ]]
require_grep '^proof_timeout=none$' "$metadata"

# --fetch-only fetches what the cache holds and submits nothing, without a
# coordinator; what it lacks is missing.
rm -rf "$out"
before=$(posts)
run fetch 0 --fetch-only --script "$runner/run.sml" rr:CTheory
[[ $(line fetch rr:CTheory cached) == "$c_run" ]]
[[ $(< "$out/rr/CTheory/first") == rr:CTheory ]]
script other.sml other
run fetch-missing 0 --fetch-only --script "$runner/other.sml" rr:CTheory
line fetch-missing rr:CTheory missing > /dev/null
[[ $(posts) == "$before" ]]
require_grep '^proof_timeout=none$' "$metadata"

# Outputs that can't be written are an error, not a missing run; every
# target still gets its line.
saved_out=$out
out=$tmpdir/unwritable-out
mkdir -p "$out"
touch "$out/rr"
run unwritable 1 --fetch-only --script "$runner/run.sml" hol:bool rr:CTheory
require_grep 'could not create' "$tmpdir/unwritable.err"
line unwritable HOL:boolTheory cached > /dev/null
line unwritable rr:CTheory missing > /dev/null
[[ $(< "$out/HOL/boolTheory/first") == HOL:boolTheory ]]
require_no_file "$out/HOL/boolTheory/LOG"
out=$saved_out

# One run of a batch fails its script: the other is done all the same, and
# the command ends 0. --closure adds C's ancestry, A.
script mixed.sml 2
run mixed 0 --remote-exec "$coordinator" --closure --script "$runner/mixed.sml" rr:CTheory
mixed_failed=$(line mixed rr:ATheory "failed script")
[[ $(< "$out/rr/ATheory/KEY") == "$mixed_failed" ]]
[[ $(< "$out/rr/ATheory/CONTEXT") == rr:ATheory@* ]]
require_grep 'no A' "$out/rr/ATheory/LOG"
require_grep 'holbuild: exec-action failed:' "$out/rr/ATheory/LOG"
line mixed rr:CTheory done > /dev/null
[[ $(wc -l < "$tmpdir/mixed.out") -eq 2 ]]

# A context neither cache holds is refused; the others still run.
cat > "$project/src/DScript.sml" <<'SML'
Theory D
Ancestors A

Theorem d_thm:
  T
Proof
  ACCEPT_TAC a_thm
QED
SML
script refused.sml 3
run refused 1 --remote-exec "$coordinator" --script "$runner/refused.sml" rr:DTheory hol:bool
require_grep 'rr:DTheory is not in the local or remote cache for its current inputs; build it first' "$tmpdir/refused.err"
line refused rr:DTheory missing > /dev/null
line refused HOL:boolTheory done > /dev/null

# A coordinator that refuses the batch, or whose stream stays down, can't
# take it: 75. A cancelled batch is 1.
script fresh.sml 4
touch "$state/refuse"
run refuse 75 --remote-exec "$coordinator" --script "$runner/fresh.sml" hol:bool
line refuse HOL:boolTheory missing > /dev/null
rm "$state/refuse"
touch "$state/down"
run down 75 --remote-exec "$coordinator" --script "$runner/fresh.sml" hol:bool
require_grep 'is left running' "$tmpdir/down.err"
rm "$state/down"
touch "$state/cancelled"
run cancelled 1 --remote-exec "$coordinator" --script "$runner/fresh.sml" hol:bool
require_grep 'cancelled' "$tmpdir/cancelled.err"
rm "$state/cancelled"

# Runs never execute here: without a coordinator it is a usage error, 75
# under --remote-only.
run no-coordinator 1 --script "$runner/fresh.sml" hol:bool
require_grep 'pass --remote-exec URL' "$tmpdir/no-coordinator.err"
run no-coordinator-remote-only 75 --remote-only --script "$runner/fresh.sml" hol:bool

# Following a remote batch must leave the project available to local builds.
# hold keeps the event stream open after the action's done event.
script concurrent.sml concurrent
touch "$state/hold"
(cd "$project" && exec "$HOLBUILD_BIN" --remote-cache "$remote_url" run-action \
  --outputs-dir "$out" --output first --output second --remote-exec "$coordinator" \
  --script "$runner/concurrent.sml" rr:CTheory) \
  > "$tmpdir/concurrent.out" 2> "$tmpdir/concurrent.err" &
run_pid=$!
for _ in {1..600}; do
  grep -q 'remote rr:CTheory: done' "$tmpdir/concurrent.err" && break
  kill -0 "$run_pid" 2>/dev/null || break
  sleep 0.1
done
require_grep 'remote rr:CTheory: done' "$tmpdir/concurrent.err"
kill -0 "$run_pid"
require_no_file "$project/.holbuild/locks/project.lock.owner"
python3 - "$project/.holbuild/locks/project.lock" <<'PYLOCK'
import fcntl
import sys

with open(sys.argv[1], "r+") as lock:
    fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
PYLOCK
hb build CTheory > "$tmpdir/concurrent-build.log" 2>&1 || {
  cat "$tmpdir/concurrent-build.log" >&2
  exit 1
}
require_grep '^proof_timeout=2.5$' "$metadata"
require_grep "^input_key=$key_c$" "$metadata"
kill -0 "$run_pid"
rm "$state/hold"
wait "$run_pid"
unset run_pid
concurrent_key=$(line concurrent rr:CTheory done)
[[ $(< "$out/rr/CTheory/KEY") == "$concurrent_key" ]]
[[ $(< "$out/rr/CTheory/first") == rr:CTheory ]]

# Strengthening the build's timeout contract leaves existing run keys valid.
run fetch-timed 0 --fetch-only --script "$runner/run.sml" rr:CTheory
[[ $(line fetch-timed rr:CTheory cached) == "$c_run" ]]

# A failed run replaces earlier successful outputs in the same directory.
cat > "$runner/fails.sml" <<'SML'
raise Fail "failed after success";
SML
run failed 0 --remote-exec "$coordinator" --script "$runner/fails.sml" rr:CTheory hol:bool
for context in rr:CTheory HOL:boolTheory; do
  failed_key=$(line failed "$context" "failed script")
  dir=$out/${context/:/\/}
  [[ $(< "$dir/KEY") == "$failed_key" ]]
  [[ $(< "$dir/CONTEXT") == "$context" || $(< "$dir/CONTEXT") == "$context@$key_c" ]]
  require_grep 'failed after success' "$dir/LOG"
  require_no_file "$dir/first"
  require_no_file "$dir/second"
done

# Losing the diagnostic preserves the known failure, clears stale files,
# and warns rather than reporting fleet unavailability.
run before-missing-log 0 --fetch-only --script "$runner/run.sml" rr:CTheory
require_file "$out/rr/CTheory/first"
touch "$state/drop-log"
run missing-log 0 --remote-exec "$coordinator" --script "$runner/fails.sml" rr:CTheory
rm "$state/drop-log"
missing_key=$(line missing-log rr:CTheory "failed script")
[[ $(< "$out/rr/CTheory/KEY") == "$missing_key" ]]
[[ $(< "$out/rr/CTheory/CONTEXT") == "rr:CTheory@$key_c" ]]
require_grep 'could not fetch the log of failed run rr:CTheory' "$tmpdir/missing-log.err"
require_no_file "$out/rr/CTheory/LOG"
require_no_file "$out/rr/CTheory/first"
require_no_file "$out/rr/CTheory/second"

# A run the worker rejects before any HOL runs has no log; its reason
# reaches the client with the failure.
cat > "$runner/untrusted.sml" <<'SML'
val _ = "a run no worker trusts";
SML
touch "$state/untrusted"
run untrusted 0 --remote-exec "$coordinator" --script "$runner/untrusted.sml" rr:CTheory
rm "$state/untrusted"
untrusted_key=$(line untrusted rr:CTheory "failed spec-rejected")
require_grep '^detail=exec-action HOL repository is not trusted by this worker: ' "$state/result-$untrusted_key"
if grep -q '^log=' "$state/result-$untrusted_key"; then
  echo 'a rejected run uploaded a log' >&2
  exit 1
fi
require_grep 'holbuild: remote rr:CTheory: failed (spec-rejected: exec-action HOL repository is not trusted by this worker: ' \
  "$tmpdir/untrusted.err"

# Stop during input hydration, before HOL exists. The driver must not
# launch the script or publish its result after the transfer finishes.
script interrupted.sml interrupted
hb run-action --export-only --script "$runner/interrupted.sml" --output first --output second hol:bool \
  > "$tmpdir/interrupted-spec.txt"
read -r context interrupted_key interrupted_spec < "$tmpdir/interrupted-spec.txt"
python3 - "$HOLBUILD_BIN" "$remote_url" "$interrupted_spec" "$tmpdir" <<'PYTEST'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

binary, url, spec, temp = sys.argv[1:]
binary = os.environ.get("REAL_HOLBUILD_BIN", binary)
root = Path(temp)
control = root / "control"
(control / "action-get-enable").touch()
with (root / "interrupted.log").open("w") as log:
    process = subprocess.Popen(
        [binary, "--remote-cache", url, "exec-action", spec, "--share-heaps",
         "--cache-limit-gb", "1000", "--result", str(root / "interrupted.result")],
        env={**os.environ, "HOLBUILD_CACHE": str(root / "worker-cache")},
        stdout=log, stderr=log,
    )
    try:
        for event in ["action-get-count", "download-event"]:
            deadline = time.monotonic() + 60
            while not (control / event).exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise AssertionError(f"run never reached {event}")
                time.sleep(0.01)
            if event == "action-get-count":
                (control / "download-enable").touch()
                (control / "action-get-release").touch()
        process.send_signal(signal.SIGTERM)
        (control / "download-release").touch()
        assert process.wait(timeout=15) != 0, "cancelled run succeeded"
    finally:
        (control / "download-release").touch()
        (control / "action-get-release").touch()
        if process.poll() is None:
            process.kill()
        process.wait()
PYTEST
require_grep '^status=failed$' "$tmpdir/interrupted.result"
require_grep '^failure=unavailable$' "$tmpdir/interrupted.result"
require_no_file "$(ac_file "$interrupted_key")"
