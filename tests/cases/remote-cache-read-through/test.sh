#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# The test cache server given REMOTE_CACHE_READ_THROUGH serves what it lacks
# from that cache and writes only to its own.

tmpdir=$(make_temp_dir)
pids=()
cleanup() {
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

start_remote_cache_server "$tmpdir/upstream" "$tmpdir/upstream-state"
pids+=("$server_pid")
upstream_url=$remote_url
printf 'upstream object' > "$tmpdir/object"
sha=$(sha256sum "$tmpdir/object" | cut -d' ' -f1)
curl -fsS -X PUT --data-binary "@$tmpdir/object" "$upstream_url/cas/$sha"
: > "$tmpdir/upstream-state/requests.log"

REMOTE_CACHE_READ_THROUGH=http://127.0.0.1:1,$upstream_url start_remote_cache_server "$tmpdir/local" "$tmpdir/local-state"
pids+=("$server_pid")

curl -fsS -I "$remote_url/cas/$sha" > /dev/null
[[ "$(curl -fsS "$remote_url/cas/$sha")" == "upstream object" ]] || { echo "read-through GET failed" >&2; exit 1; }
[[ "$(curl -s -o /dev/null -w '%{http_code}' "$remote_url/cas/$(printf x | sha256sum | cut -d' ' -f1)")" == 404 ]] || {
  echo "a missing object was served" >&2; exit 1; }
curl -fsS -X PUT --data-binary 'local only' "$remote_url/ac/key"
[[ "$(curl -fsS "$remote_url/ac/key")" == "local only" ]] || { echo "local PUT lost" >&2; exit 1; }
if grep -q '^PUT' "$tmpdir/upstream-state/requests.log"; then
  echo "the read-through server wrote upstream" >&2; exit 1
fi
[[ "$(grep -c "^GET /cas/$sha" "$tmpdir/upstream-state/requests.log")" == 1 ]] || {
  echo "the object was not fetched once" >&2; cat "$tmpdir/upstream-state/requests.log" >&2; exit 1; }
