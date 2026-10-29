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

# Record curl policy without relying on network routing or wall-clock timing.
# The builds below make their requests with the curl command, since they can't
# load libcurl; remote-cache-libcurl covers libcurl.
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

for failure in 404 401 403 503 transport; do
  use_case_cache "$tmpdir/cache-$failure"
  rm -rf "$project/.holbuild"
  log=$tmpdir/$failure.log
  curl_log=$tmpdir/$failure.curl
  http_code=$failure
  curl_status=0
  if [[ "$failure" == transport ]]; then
    http_code=000
    curl_status=7
  fi
  (cd "$project" && PATH="$tmpdir/shims:$PATH" TMPDIR="$tmpdir/tmp" \
    HOLBUILD_TEST_CURL_LOG="$curl_log" HOLBUILD_TEST_HTTP_CODE="$http_code" \
    HOLBUILD_TEST_CURL_STATUS="$curl_status" HOLBUILD_TEST_LIBCURL=libholbuild-test-no-such-curl.so \
    "$HOLBUILD_BIN" -j2 --remote-cache http://cache.invalid build ATheory BTheory CTheory) > "$log" 2>&1
  require_grep 'ATheory built' "$log"
  require_grep 'BTheory built' "$log"
  require_grep 'CTheory built' "$log"
  require_grep 'connect-timeout 10 --max-time 30' "$curl_log"
  if grep -q 'missing curl timeout policy' "$log"; then
    cat "$log" >&2
    exit 1
  fi
  warning_count=$(grep -c 'warning: remote cache restore failed:' "$log" || true)
  expected=1
  [[ "$failure" != 404 ]] || expected=0
  if [[ "$warning_count" != "$expected" ]]; then
    echo "expected $expected restore warnings for $failure, found $warning_count" >&2
    cat "$log" >&2
    exit 1
  fi
done

# Exercise archive staging as well as parallel build/cache/stat temporary names.
archive=$tmpdir/cache.hbx
(cd "$project" && TMPDIR="$tmpdir/tmp" "$HOLBUILD_BIN" export -o "$archive" ATheory) > "$tmpdir/export.log" 2>&1
TMPDIR="$tmpdir/tmp" HOLBUILD_CACHE="$tmpdir/import-cache" "$HOLBUILD_BIN" import "$archive" > "$tmpdir/import.log" 2>&1
