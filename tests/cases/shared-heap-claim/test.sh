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
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server" "$tmpdir/control"
CLAIM_DIR="$tmpdir" CLAIM_URL="$remote_url" python3 "$SCRIPT_DIR/check.py"
