#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
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

write_project() {
  local project=$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "remote-cache-test"

[build]
members = ["src"]
TOML
  cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Theorem a_thm:
  T
Proof
  simp[]
QED
SML
}

assert_server_action_paths() {
  python3 - "$request_log" <<'PY'
import pathlib
import re
import sys

requests = pathlib.Path(sys.argv[1]).read_text().splitlines()
paths = [request.split(" ", 1)[1] for request in requests]
action_paths = [path for path in paths if path.startswith("/ac/")]
if not action_paths:
    raise SystemExit("remote cache server observed no action-cache requests")
invalid_paths = [path for path in action_paths
                 if re.fullmatch(r"/ac/[a-f0-9]{64}", path) is None]
if invalid_paths:
    raise SystemExit(
        "remote cache server observed invalid action-cache paths: "
        + ", ".join(invalid_paths)
    )
PY
}

assert_remote_proof_timeout() {
  local expected=$1
  python3 - "$remote_root" "$expected" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = sys.argv[2]
marker = "manifest-text-v1\n"
timeouts = []
for action in (root / "ac").glob("*"):
    text = action.read_text()
    if marker not in text:
        continue
    manifest = text.split(marker, 1)[1]
    if not manifest.startswith("holbuild-cache-action-v3\n"):
        continue
    fields = [line.split("=", 1)[1]
              for line in manifest.splitlines()
              if line.startswith("proof-timeout=")]
    if len(fields) != 1:
        raise SystemExit(f"remote theory action has {len(fields)} proof-timeout fields")
    timeouts.append(fields[0])
if timeouts != [expected]:
    raise SystemExit(f"expected remote proof-timeout {expected}, found {timeouts}")
PY
}

remote_root=$tmpdir/remote
start_remote_cache_server "$remote_root" "$tmpdir/server"

first=$tmpdir/first
second=$tmpdir/second
write_project "$first"
write_project "$second"

first_cache=$tmpdir/cache-first
second_cache=$tmpdir/cache-second
third_cache=$tmpdir/cache-third
fourth_cache=$tmpdir/cache-fourth
fifth_cache=$tmpdir/cache-fifth
sixth_cache=$tmpdir/cache-sixth
weaker_cache=$tmpdir/cache-weaker
for cache in "$first_cache" "$second_cache" "$third_cache" "$fourth_cache" \
             "$fifth_cache" "$sixth_cache" "$weaker_cache"; do
  link_hol_toolchain_cache "$cache"
done

first_log=$tmpdir/first.log
(cd "$first" && HOLBUILD_CACHE="$first_cache" HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build --tactic-timeout 0 ATheory) > "$first_log" 2>&1
require_grep "ATheory built" "$first_log"
require_grep "remote cache published:" "$first_log"
assert_remote_proof_timeout none

second_log=$tmpdir/second.log
(cd "$second" && HOLBUILD_CACHE="$second_cache" HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build --tactic-timeout 180 ATheory) > "$second_log" 2>&1
require_grep "remote cache hydrated:" "$second_log"
require_grep "insufficient tactic-timeout contract" "$second_log"
require_grep "ATheory built" "$second_log"
require_grep "remote cache published:" "$second_log"
assert_remote_proof_timeout 180.0

third=$tmpdir/third
write_project "$third"
cat > "$third/.holconfig.toml" <<TOML
[build]
tactic_timeout = 180

[remote_cache]
url = "$remote_url"
TOML
third_log=$tmpdir/third.log
(cd "$third" && HOLBUILD_CACHE="$third_cache" HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" build ATheory) > "$third_log" 2>&1
require_grep "remote cache hydrated:" "$third_log"
require_grep "cache hit: ATheory" "$third_log"
require_grep "ATheory restored from cache" "$third_log"
if grep -q "ATheory built" "$third_log"; then
  echo "third build ignored .holconfig.toml remote cache default" >&2
  cat "$third_log" >&2
  exit 1
fi

fourth=$tmpdir/fourth
write_project "$fourth"
fourth_log=$tmpdir/fourth.log
(cd "$fourth" && HOLBUILD_CACHE="$fourth_cache" HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build --tactic-timeout 60 ATheory) > "$fourth_log" 2>&1
require_grep "insufficient tactic-timeout contract" "$fourth_log"
require_grep "ATheory built" "$fourth_log"
assert_remote_proof_timeout 60.0

fifth=$tmpdir/fifth
write_project "$fifth"
fifth_log=$tmpdir/fifth.log
(cd "$fifth" && HOLBUILD_CACHE="$fifth_cache" HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build --tactic-timeout 180 ATheory) > "$fifth_log" 2>&1
require_grep "ATheory restored from cache" "$fifth_log"
if grep -q "ATheory built" "$fifth_log"; then
  echo "stronger remote timeout contract was not reused" >&2
  cat "$fifth_log" >&2
  exit 1
fi

sixth=$tmpdir/sixth
write_project "$sixth"
sixth_log=$tmpdir/sixth.log
(cd "$sixth" && HOLBUILD_CACHE="$sixth_cache" HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build --tactic-timeout 0 ATheory) > "$sixth_log" 2>&1
require_grep "ATheory restored from cache" "$sixth_log"
if grep -q "ATheory built" "$sixth_log"; then
  echo "finite remote timeout contract did not satisfy unlimited request" >&2
  cat "$sixth_log" >&2
  exit 1
fi

weaker=$tmpdir/weaker
write_project "$weaker"
weaker_log=$tmpdir/weaker.log
(cd "$weaker" && HOLBUILD_CACHE="$weaker_cache" HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build --force --tactic-timeout 180 ATheory) > "$weaker_log" 2>&1
require_grep "ATheory built" "$weaker_log"
assert_remote_proof_timeout 60.0

weaker_manifest=$(find "$weaker_cache/actions" -type f -name manifest -print -quit)
require_file "$weaker_manifest"
python3 - "$weaker_manifest" <<'PY'
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1])
lines = manifest.read_text().splitlines()
lines[lines.index("proof-timeout=180.0")] = "proof-timeout=none"
manifest.write_text("\n".join(lines) + "\n")
PY
unlimited_publish_log=$tmpdir/unlimited-publish.log
(cd "$weaker" && HOLBUILD_CACHE="$weaker_cache" HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build --force --tactic-timeout 0 ATheory) > "$unlimited_publish_log" 2>&1
require_grep "ATheory built" "$unlimited_publish_log"
assert_remote_proof_timeout 60.0

python3 - "$weaker_manifest" <<'PY'
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1])
lines = manifest.read_text().splitlines()
lines.insert(lines.index("load-metadata-v1") + 1, "mldep DifferentTheory")
manifest.write_text("\n".join(lines) + "\n")
PY
conflict_log=$tmpdir/conflict.log
(cd "$weaker" && HOLBUILD_CACHE="$weaker_cache" HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build --force --tactic-timeout 0 ATheory) > "$conflict_log" 2>&1
require_grep "resident manifest differs outside proof-timeout" "$conflict_log"
assert_remote_proof_timeout 60.0

assert_server_action_paths
