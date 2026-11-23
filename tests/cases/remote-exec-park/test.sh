#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# build --remote-exec with HOLBUILD_PARKED=1: a one-theory build that fails
# in a proof starts a park server, and the next build whose only change is
# the theory's script is checked by it without planning or a batch.  Any
# other change, a request the server can't check, or a server gone builds
# as usual; a pass builds as usual too, for the theory's outputs.

tmpdir=$(make_temp_dir)
cleanup() {
  for pid in ${server_pid:-} ${coordinator_pid:-} $(cat "$tmpdir"/project/.holbuild/park/*.pid 2>/dev/null); do
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

remote_root=$tmpdir/remote
start_remote_cache_server "$remote_root" "$tmpdir/server"
use_case_cache "$tmpdir/cache"

# The workers: run each action of the batch with exec-action in a cache of
# their own, until one fails.
state=$tmpdir/coordinator
mkdir -p "$state"
link_hol_toolchain_cache "$tmpdir/worker-cache"
cat > "$tmpdir/run-batch" <<SH
#!/usr/bin/env bash
set -eu
awk '\$1 == "action" { print \$2, \$4 }' "\$1" | while read -r key spec; do
  status=0
  HOLBUILD_CACHE="$tmpdir/worker-cache" "$HOLBUILD_BIN" --remote-cache "$remote_url" \
    exec-action "\$spec" --cache-limit-gb 1000 --result "$tmpdir/worker.result" >> "$tmpdir/worker.log" 2>&1 || status=\$?
  cp "$tmpdir/worker.result" "$state/result-\$key"
  [[ \$status -eq 0 ]] || exit 1
done
SH
chmod +x "$tmpdir/run-batch"
python3 "$SCRIPT_DIR/../../fixtures/remote_exec_coordinator.py" "$state/port" "$state" "$tmpdir/run-batch" &
coordinator_pid=$!
for _ in {1..100}; do
  [[ -s "$state/port" ]] && break
  sleep 0.01
done
coordinator="http://127.0.0.1:$(< "$state/port")"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rxpark"

[build]
members = ["src"]
TOML
cat > "$project/src/BScript.sml" <<SML
Theory B
Ancestors bool

Theorem b_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
SML
# write_a STEP: A's theorem splits its goal, proves the first conjunct and
# runs STEP on the second.
write_a() {
  cat > "$project/src/AScript.sml" <<SML
Theory A
Ancestors B

Theorem target:
  T /\\ T
Proof
  CONJ_TAC >- ACCEPT_TAC b_thm >> $1
QED
SML
}

# build NAME EXIT [ARGS...]: a parked-checks build of A, which must exit EXIT.
build() {
  local name=$1 code=$2 status=0
  shift 2
  (cd "$project" && HOLBUILD_PARKED=1 "$HOLBUILD_BIN" --remote-cache "$remote_url" build --remote-exec "$coordinator" "$@" ATheory) \
    > "$tmpdir/$name.log" 2>&1 || status=$?
  [[ "$status" == "$code" ]] || {
    echo "$name exited $status, wanted $code" >&2
    cat "$tmpdir/$name.log" "$project"/.holbuild/park/*.log >&2 2>/dev/null || true
    exit 1
  }
}
batches() { if [[ -e "$state/submitted-ids" ]]; then wc -l < "$state/submitted-ids"; else echo 0; fi; }
# wait_server: a park server listens.
wait_server() {
  for _ in $(seq 120); do
    grep -q "park: listening on" "$project"/.holbuild/park/*.log 2>/dev/null && return 0
    sleep 0.5
  done
  echo "no park server listened" >&2
  cat "$project"/.holbuild/park/*.log "$tmpdir"/old-park-*.txt >&2 2>/dev/null || true
  exit 1
}
# parked NAME EXIT: a build answered by the park server, without a batch.
parked() {
  local before
  before=$(batches)
  build "$@"
  [[ "$(batches)" == "$before" ]] || {
    echo "$1 submitted a batch" >&2; cat "$tmpdir/$1.log" "$project"/.holbuild/park/*.log >&2 || true
    exit 1; }
}
# usual NAME EXIT [ARGS...]: a build that plans and submits a batch.
usual() {
  local before
  before=$(batches)
  build "$@"
  [[ "$(batches)" != "$before" ]] || { echo "$1 submitted no batch" >&2; cat "$tmpdir/$1.log" >&2; exit 1; }
}
restart_server() {
  for f in "$project"/.holbuild/park/*.log; do [[ -e "$f" ]] && mv "$f" "$tmpdir/old-park-$1.txt"; done
  usual "$1" 1
  require_grep "parked check: started a park server for ATheory" "$tmpdir/$1.log"
  wait_server
}

write_a 'FAIL_TAC "first failure"'
restart_server first
require_grep "first failure" "$tmpdir/first.log"

# Only the script changed: the server answers, with the diagnostic naming
# the project's script and the logs a remote failure leaves.
write_a 'FAIL_TAC "second failure"'
parked second 1
require_grep "second failure" "$tmpdir/second.log"
require_grep "$project/src/AScript.sml" "$tmpdir/second.log"
require_grep "second failure" "$project/.holbuild/logs/current/rxpark/ATheory/build.log"

# A new theory mention: the server can't check it.
write_a 'ACCEPT_TAC arithmeticTheory.ADD_0'
usual mention 1
require_grep "parked check: the edit changes what the theory depends on; building as usual" "$tmpdir/mention.log"

# An ancestor edit: the record's stamps no longer hold.
restart_server third
write_a 'FAIL_TAC "fourth failure"'
sed -i 's/ACCEPT_TAC TRUTH/ACCEPT_TAC TRUTH >> ALL_TAC/' "$project/src/BScript.sml"
usual ancestor 1
require_grep "parked check: file changed: .*BScript.sml; building as usual" "$tmpdir/ancestor.log"

# Other build arguments are other plan inputs: no park record for them.
wait_server
write_a 'FAIL_TAC "fifth failure"'
usual argv 1 --fail-fast
if grep -q "building as usual" "$tmpdir/argv.log"; then cat "$tmpdir/argv.log" >&2; exit 1; fi

# The servers gone: the usual build.
wait_server
kill -9 $(cat "$project"/.holbuild/park/*.pid)
rm -f "$project"/.holbuild/park/*.log
write_a 'FAIL_TAC "sixth failure"'
usual gone 1
require_grep "parked check: .*; building as usual" "$tmpdir/gone.log"

# The fix passes the parked check, then builds as usual for A's outputs.
wait_server
write_a 'ACCEPT_TAC TRUTH'
usual fixed 0
require_grep "parked check: the parked check of ATheory passed; building as usual" "$tmpdir/fixed.log"
