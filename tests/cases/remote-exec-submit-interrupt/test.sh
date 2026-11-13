#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

if [[ $(uname -s) != Linux ]]; then
  echo 'SKIP remote-exec-submit-interrupt (requires LD_PRELOAD)'
  exit 0
fi

tmpdir=$(make_temp_dir)
cleanup() {
  for pid in ${server_pid:-} ${coordinator_pid:-}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

cc -shared -fPIC -Wall -Wextra -Werror \
  "$SCRIPT_DIR/../../fixtures/interrupt_remote_batch.c" -ldl -o "$tmpdir/interrupt.so"
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
use_case_cache "$tmpdir/cache"
state=$tmpdir/coordinator
mkdir -p "$state"
touch "$state/hang"
python3 "$SCRIPT_DIR/../../fixtures/remote_exec_coordinator.py" \
  "$state/port" "$state" /bin/false &
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
name = "interrupt"
[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool
Theorem a: T
Proof simp[] QED
SML
echo 'val _ = ();' > "$tmpdir/run.sml"

check_interrupt() {
  local name=$1 cancel=$2
  shift 2
  local code=0 batch
  (cd "$project" && LD_PRELOAD="$tmpdir/interrupt.so" \
    timeout 30 "$HOLBUILD_BIN" --remote-cache "$remote_url" "$@") > "$tmpdir/$name.log" 2>&1 || code=$?
  [[ $code == 1 ]] || { cat "$tmpdir/$name.log" >&2; echo "$name exited $code, wanted 1" >&2; exit 1; }
  require_grep '^holbuild: interrupted$' "$tmpdir/$name.log"
  batch=$(sed -n 's/^holbuild: remote batch //p' "$tmpdir/$name.log")
  [[ -n $batch ]] || { cat "$tmpdir/$name.log" >&2; exit 1; }
  if [[ $cancel == yes ]]; then
    require_grep "^POST /v1/batches/$batch/cancel " "$state/requests.log"
    require_grep "^holbuild: cancelled remote batch $batch$" "$tmpdir/$name.log"
  else
    ! grep -q "^POST /v1/batches/$batch/cancel " "$state/requests.log" || exit 1
  fi
  echo "PASS $name at batch announcement"
}

# Check both submit paths even when one fails, so old-client validation
# demonstrates that each regression detects the unregistered batch.
failed=0
(check_interrupt build yes build --remote-exec "$coordinator" ATheory) || failed=1
(check_interrupt remote-only yes build --remote-exec "$coordinator" --remote-only ATheory) || failed=1
(check_interrupt run yes run-action --remote-exec "$coordinator" \
  --script "$tmpdir/run.sml" --output result --outputs-dir "$tmpdir/out" hol:bool) || failed=1
(check_interrupt detached no build --remote-exec "$coordinator" --detach ATheory) || failed=1
exit "$failed"
