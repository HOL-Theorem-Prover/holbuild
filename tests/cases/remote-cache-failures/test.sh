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
max_time=
put=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --connect-timeout) connect_timeout=$2; shift 2 ;;
    --max-time) max_time=$2; shift 2 ;;
    -T) put=1; shift 2 ;;
    *) shift ;;
  esac
done
[[ "$connect_timeout" == 10 && "$max_time" == 30 ]] || {
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

# A publish that never reached the cache is a failed write, not a conflict
# with a different value already there.
require_publish_failure() {
  local log=$1
  local detail=$2
  require_grep 'warning: could not publish remote cache entry .*destination cache blob publish failed' "$log"
  require_grep "$detail" "$log"
  if grep -q 'conflict' "$log"; then
    echo "remote cache publish failure reported as a conflict" >&2
    cat "$log" >&2
    exit 1
  fi
}

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
    require_grep 'connect-timeout 10 --max-time 30' "$curl_log"
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
    [[ "$failure" != transport ]] || require_publish_failure "$log" 'Failed to connect to 127.0.0.1 port 1'
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
}

for failure in 404 401 403 503 transport; do
  build_with_failure curl-command "$failure"
  build_with_failure libcurl "$failure"
done

# Exercise archive staging as well as parallel build/cache/stat temporary names.
archive=$tmpdir/cache.hbx
(cd "$project" && TMPDIR="$tmpdir/tmp" "$HOLBUILD_BIN" export -o "$archive" ATheory) > "$tmpdir/export.log" 2>&1
TMPDIR="$tmpdir/tmp" HOLBUILD_CACHE="$tmpdir/import-cache" "$HOLBUILD_BIN" import "$archive" > "$tmpdir/import.log" 2>&1

# The cache answers reads but rejects every upload with 502.  DTheory is
# not in the remote cache yet, so the build has to publish it.
cat > "$project/src/DScript.sml" <<SML
Theory D
Ancestors bool
Theorem truth:
  T
Proof
  simp[]
QED
SML
use_case_cache "$tmpdir/cache-put-502"
rm -rf "$project/.holbuild"
rm -f "$tmpdir/control/get-status"
printf '502\n' > "$tmpdir/control/put-status"
put_log=$tmpdir/put-502.log
(cd "$project" && env -u HOLBUILD_REMOTE_CACHE_CURL_CONFIG TMPDIR="$tmpdir/tmp" \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build DTheory) > "$put_log" 2>&1
rm -f "$tmpdir/control/put-status"
require_grep 'DTheory built' "$put_log"
require_publish_failure "$put_log" 'HTTP 502 from'
