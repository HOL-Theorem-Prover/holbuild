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
require_grep "ATheory restored from cache" "$tmpdir/follow.log"
require_grep "BTheory restored from cache" "$tmpdir/follow.log"
refute_grep "Theory built" "$tmpdir/follow.log"
[[ $(grep -c . "$state/ran") -eq 2 ]] || { cat "$state/ran" >&2; exit 1; }
require_grep "^action .* rx:ATheory$" "$state/b1.batch"
require_grep "^edge " "$state/b1.batch"

# With everything cached there is nothing to submit.
run cached 0 build --remote-exec "$coordinator" BTheory
refute_grep "remote batch" "$tmpdir/cached.log"

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
# event stream: the build goes on locally, or fails with --remote-only or
# --detach.
write_theories three
run unreachable-only 1 build --remote-exec "$unreachable" --remote-only BTheory
require_grep "remote execution: could not reach the coordinator at $unreachable" "$tmpdir/unreachable-only.log"
refute_grep "Theory built" "$tmpdir/unreachable-only.log"
run unreachable 0 build --remote-exec "$unreachable" BTheory
require_grep "building locally" "$tmpdir/unreachable.log"
require_grep "BTheory built" "$tmpdir/unreachable.log"

write_theories four
touch "$state/refuse"
run refused-only 1 build --remote-exec "$coordinator" --remote-only BTheory
require_grep "coordinator refused the batch (HTTP 400): .*batch refused by the stub" "$tmpdir/refused-only.log"
run refused-detach 1 build --remote-exec "$coordinator" --detach BTheory
refute_grep "Theory built" "$tmpdir/refused-detach.log"
run refused 0 build --remote-exec "$coordinator" BTheory
require_grep "BTheory built" "$tmpdir/refused.log"
rm "$state/refuse"

write_theories five
touch "$state/drop"
run dropped 0 build --remote-exec "$coordinator" BTheory
require_grep "lost the coordinator's event stream for batch b3; reattach with --attach b3" "$tmpdir/dropped.log"
require_grep "BTheory restored from cache" "$tmpdir/dropped.log"
rm "$state/drop"
run unknown-only 1 build --remote-exec "$coordinator" --remote-only --attach nope BTheory
require_grep "batch nope can't be followed (HTTP 404): .*no such batch" "$tmpdir/unknown-only.log"
refute_grep "reattach" "$tmpdir/unknown-only.log"

# A batch reported done whose results aren't in the remote cache: with
# --remote-only nothing is built locally.
write_theories five-skip
touch "$state/skip"
run skipped-only 1 build --remote-exec "$coordinator" --remote-only BTheory
require_grep "ATheory is not in the remote cache, and --remote-only builds nothing locally" "$tmpdir/skipped-only.log"
refute_grep "Theory built" "$tmpdir/skipped-only.log"
rm "$state/skip"

# A failed batch falls back too.
write_theories six
touch "$state/fail"
run failed-only 1 build --remote-exec "$coordinator" --remote-only BTheory
require_grep "remote rx:ATheory: failed (proof)" "$tmpdir/failed-only.log"
require_grep "remote execution: batch b5 failed: an action failed" "$tmpdir/failed-only.log"
run failed 0 build --remote-exec "$coordinator" BTheory
require_grep "BTheory built" "$tmpdir/failed.log"
rm "$state/fail"

# A closure that can't run remotely (a forced action) is built locally.
run forced-only 1 build --remote-exec "$coordinator" --remote-only --force BTheory
require_grep "can't run remotely: it is forced" "$tmpdir/forced-only.log"
run forced 0 build --remote-exec "$coordinator" --force BTheory
require_grep "BTheory built" "$tmpdir/forced.log"

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
