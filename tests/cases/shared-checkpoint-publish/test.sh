#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
tmpdir=$(make_temp_dir)
server_pid=
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
for failing in 0 1; do
  dir=$tmpdir/$failing
  start_remote_cache_server "$dir/remote" "$dir/server" "$dir/control"
  PUBLISH_DIR="$dir" PUBLISH_URL="$remote_url" PUBLISH_FAIL="$failing" \
    python3 "$SCRIPT_DIR/check.py"
  kill "$server_pid"
  wait "$server_pid" 2>/dev/null || true
  server_pid=
done
