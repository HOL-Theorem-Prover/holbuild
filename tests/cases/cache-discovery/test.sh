#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
tmpdir=$(make_temp_dir)
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
python3 "$SCRIPT_DIR/server.py" "$tmpdir" &
server_pid=$!
for ((i=0; i<500; i++)); do
  [[ -f "$tmpdir/port" ]] && break
  sleep 0.01
done
[[ -f "$tmpdir/port" ]]
printf '%s\n' 'header = "Authorization: Bearer fixture-token"' > "$tmpdir/discovery.curl"
DISCOVERY_DIR="$tmpdir" \
HOLBUILD_REMOTE_CACHE_DISCOVERY_URL="http://127.0.0.1:$(cat "$tmpdir/port")/members" \
HOLBUILD_REMOTE_CACHE_DISCOVERY_CURL_CONFIG="$tmpdir/discovery.curl" \
HOLBUILD_REMOTE_CACHE_ALLOWED_URLS='http://c.example,http://d.example,http://e.example,http://f.example' \
poly --script "$SCRIPT_DIR/check.sml"
