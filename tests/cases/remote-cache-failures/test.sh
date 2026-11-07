#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
project=$tmpdir/project
mkdir -p "$project/src" "$tmpdir/tmp" "$tmpdir/shims"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "remote-cache-failures"

[build]
members = ["src"]
TOML
for theory in A B C; do
  cat > "$project/src/${theory}Script.sml" <<SML
Theory $theory
Ancestors bool
Theorem truth:
  T
Proof
  simp[]
QED
SML
done

# Empty env settings have the same meaning as an unset setting.
use_case_cache "$tmpdir/empty-cache"
(cd "$project" && HOLBUILD_REMOTE_CACHE_URL= "$HOLBUILD_BIN" build ATheory) > "$tmpdir/empty.log" 2>&1
require_grep 'ATheory built' "$tmpdir/empty.log"

# Each failure gives one restore warning, and a miss none, with either client.
# The curl command is a shim that records curl policy without relying on
# network routing or wall-clock timing; libcurl talks to the fixture server,
# told which status to answer GETs with, or to a closed port.
cat > "$tmpdir/shims/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HOLBUILD_TEST_CURL_LOG"
connect_timeout=
speed_limit=
speed_time=
max_time=
put=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --connect-timeout) connect_timeout=$2; shift 2 ;;
    --speed-limit) speed_limit=$2; shift 2 ;;
    --speed-time) speed_time=$2; shift 2 ;;
    --max-time) max_time=$2; shift 2 ;;
    -T) put=1; shift 2 ;;
    *) shift ;;
  esac
done
[[ "$connect_timeout" == 5 && "$speed_limit" == 1 && "$speed_time" == 30 && "$max_time" == 1800 ]] || {
  echo "missing curl timeout policy" >&2
  exit 99
}
if [[ "$put" == 1 ]]; then
  printf '204'
else
  printf '%s' "$HOLBUILD_TEST_HTTP_CODE"
  exit "$HOLBUILD_TEST_CURL_STATUS"
fi
SH
chmod +x "$tmpdir/shims/curl"
# On PATH when the requests must go through libcurl.
mkdir -p "$tmpdir/no-curl"
cat > "$tmpdir/no-curl/curl" <<'SH'
#!/usr/bin/env bash
echo "unexpected curl command" >&2
exit 99
SH
chmod +x "$tmpdir/no-curl/curl"

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server" "$tmpdir/control"
trap 'kill "$server_pid" 2>/dev/null || true; cleanup_temp_dir "$tmpdir"' EXIT

build_with_failure() {
  local client=$1
  local failure=$2
  local log=$tmpdir/$client-$failure.log
  use_case_cache "$tmpdir/cache-$client-$failure"
  rm -rf "$project/.holbuild"
  if [[ "$client" == curl-command ]]; then
    local curl_log=$tmpdir/$failure.curl
    local http_code=$failure
    local curl_status=0
    if [[ "$failure" == transport ]]; then
      http_code=000
      curl_status=7
    fi
    (cd "$project" && PATH="$tmpdir/shims:$PATH" TMPDIR="$tmpdir/tmp" \
      HOLBUILD_TEST_CURL_LOG="$curl_log" HOLBUILD_TEST_HTTP_CODE="$http_code" \
      HOLBUILD_TEST_CURL_STATUS="$curl_status" HOLBUILD_TEST_LIBCURL=libholbuild-test-no-such-curl.so \
      "$HOLBUILD_BIN" -j2 --remote-cache http://cache.invalid build ATheory BTheory CTheory) > "$log" 2>&1
    require_grep 'connect-timeout 5 --speed-limit 1 --speed-time 30 --max-time 1800' "$curl_log"
    if grep -q 'missing curl timeout policy' "$log"; then
      cat "$log" >&2
      exit 1
    fi
  else
    local url=$remote_url
    rm -f "$tmpdir/control/get-status"
    if [[ "$failure" == transport ]]; then
      url=http://127.0.0.1:1
    else
      printf '%s\n' "$failure" > "$tmpdir/control/get-status"
    fi
    (cd "$project" && env -u HOLBUILD_REMOTE_CACHE_CURL_CONFIG PATH="$tmpdir/no-curl:$PATH" TMPDIR="$tmpdir/tmp" \
      "$HOLBUILD_BIN" -j2 --remote-cache "$url" build ATheory BTheory CTheory) > "$log" 2>&1
    if grep -q 'using the curl command\|unexpected curl command' "$log"; then
      echo "expected libcurl requests for $failure" >&2
      cat "$log" >&2
      exit 1
    fi
    [[ "$failure" != transport ]] || require_grep 'Failed to connect to 127.0.0.1 port 1' "$log"
  fi
  require_grep 'ATheory built' "$log"
  require_grep 'BTheory built' "$log"
  require_grep 'CTheory built' "$log"
  warning_count=$(grep -c 'warning: remote cache restore failed:' "$log" || true)
  expected=1
  [[ "$failure" != 404 ]] || expected=0
  if [[ "$warning_count" != "$expected" ]]; then
    echo "expected $expected restore warnings for $failure with $client, found $warning_count" >&2
    cat "$log" >&2
    exit 1
  fi
  # Only requests that get no response at all turn the remote cache off.
  disabled_count=$(grep -c 'warning: remote cache disabled for 60 seconds' "$log" || true)
  expected=0
  [[ "$failure" != transport ]] || expected=1
  if [[ "$disabled_count" != "$expected" ]]; then
    echo "expected $expected disabled warnings for $failure with $client, found $disabled_count" >&2
    cat "$log" >&2
    exit 1
  fi
}

for failure in 404 401 403 503 transport; do
  build_with_failure curl-command "$failure"
  build_with_failure libcurl "$failure"
done

# Exercise archive staging as well as parallel build/cache/stat temporary names.
archive=$tmpdir/cache.hbx
(cd "$project" && TMPDIR="$tmpdir/tmp" "$HOLBUILD_BIN" export -o "$archive" ATheory) > "$tmpdir/export.log" 2>&1
TMPDIR="$tmpdir/tmp" HOLBUILD_CACHE="$tmpdir/import-cache" "$HOLBUILD_BIN" import "$archive" > "$tmpdir/import.log" 2>&1

# An unreachable cache costs at most the three failed requests that turn it
# off, plus the one other request in flight then: with one build job and one
# prefetch thread, no more than four requests are sent.  192.0.2.1 is a
# documentation address (RFC 5737), so a connection to it waits for the
# connect timeout or fails at once.  The wall-time bound has room for the
# four requests' timeouts and load noise, but not for the dozens of requests
# a build of three theories sends to a cache that stays on.
build_seconds() {
  local log=$1
  shift
  use_case_cache "$tmpdir/cache-timed-$(basename "$log" .log)"
  rm -rf "$project/.holbuild"
  local started=$SECONDS
  (cd "$project" && env -u HOLBUILD_REMOTE_CACHE_CURL_CONFIG TMPDIR="$tmpdir/tmp" HOLBUILD_CACHE_TRACE=1 \
    "$HOLBUILD_BIN" -j1 "$@" build ATheory BTheory CTheory) > "$log" 2>&1 || {
    cat "$log" >&2
    exit 1
  }
  echo $((SECONDS - started))
}
local_seconds=$(build_seconds "$tmpdir/timed-local.log")
unreachable_log=$tmpdir/timed-unreachable.log
unreachable_seconds=$(build_seconds "$unreachable_log" --prefetch-concurrency 1 --remote-cache http://192.0.2.1)
require_grep 'CTheory built' "$unreachable_log"
require_grep 'warning: remote cache disabled for 60 seconds after 3 requests in a row failed' "$unreachable_log"
requests=$(grep -c '^remote cache \(GET\|PUT\) ' "$unreachable_log" || true)
if (( requests > 4 )); then
  echo "expected at most 4 requests to an unreachable cache, found $requests" >&2
  cat "$unreachable_log" >&2
  exit 1
fi
if (( unreachable_seconds > local_seconds + 25 )); then
  echo "unreachable cache added $((unreachable_seconds - local_seconds))s to a ${local_seconds}s build" >&2
  cat "$unreachable_log" >&2
  exit 1
fi

# The summary counts the restores whose entries came from the remote cache
# apart from the restores of entries already in the local cache.
json_summary() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

path, fields = sys.argv[1], sys.argv[2].split(",")
for line in open(path):
    if line.startswith("{"):
        event = json.loads(line)
        if event.get("event") == "build_finished":
            print(" ".join(f"{field}={event.get(field)}" for field in fields))
PY
}
rm -f "$tmpdir/control/get-status"
build_json() {
  local log=$1
  rm -rf "$project/.holbuild"
  (cd "$project" && env -u HOLBUILD_REMOTE_CACHE_CURL_CONFIG TMPDIR="$tmpdir/tmp" \
    "$HOLBUILD_BIN" --json --remote-cache "$remote_url" build ATheory BTheory CTheory) > "$log" 2>&1 || {
    cat "$log" >&2
    exit 1
  }
}
require_summary() {
  local expected=$1
  local log=$2
  local actual
  actual=$(json_summary "$log" built,from_cache,from_remote)
  [[ "$actual" == "$expected" ]] || {
    echo "expected '$expected', got '$actual'" >&2
    cat "$log" >&2
    exit 1
  }
}
# The libcurl builds above published all three theories to the fixture server.
use_case_cache "$tmpdir/cache-consumer"
build_json "$tmpdir/remote-hits.json"
require_summary "built=0 from_cache=3 from_remote=3" "$tmpdir/remote-hits.json"
build_json "$tmpdir/local-hits.json"
require_summary "built=0 from_cache=3 from_remote=0" "$tmpdir/local-hits.json"
