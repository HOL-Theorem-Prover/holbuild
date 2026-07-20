#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
background_pids=()

stop_remote_cache_server() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=
  fi
}

cleanup() {
  local pid
  for pid in "${background_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  stop_remote_cache_server
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

start_publisher() {
  local project=$1
  local cache=$2
  local timeout=$3
  local log=$4
  (
    cd "$project"
    HOLBUILD_CACHE="$cache" HOLBUILD_CACHE_TRACE=1 \
      "$HOLBUILD_BIN" --remote-cache "$remote_url" build --tactic-timeout "$timeout" ATheory
  ) > "$log" 2>&1 &
  publisher_pid=$!
  background_pids+=("$publisher_pid")
}

wait_for_file() {
  local path=$1
  local attempt
  for ((attempt = 0; attempt < 6000; attempt++)); do
    [[ -f "$path" ]] && return
    sleep 0.01
  done
  echo "timed out waiting for fixture event: $path" >&2
  return 1
}

wait_for_publisher() {
  local pid=$1
  local log=$2
  if ! wait "$pid"; then
    cat "$log" >&2
    return 1
  fi
}

action_put_count() {
  python3 - "$request_log" <<'PY'
import pathlib
import sys

requests = pathlib.Path(sys.argv[1]).read_text().splitlines()
print(sum(request.startswith("PUT /ac/") for request in requests))
PY
}

remote_theory_action_path() {
  python3 - "$remote_root" <<'PY'
import pathlib
import sys

actions = []
for action in (pathlib.Path(sys.argv[1]) / "ac").glob("*"):
    if b"manifest-text-v1\nholbuild-cache-action-v3\n" in action.read_bytes():
        actions.append(action)
if len(actions) != 1:
    raise SystemExit(f"expected one remote theory action, found {len(actions)}")
print(actions[0])
PY
}

mutate_remote_manifest() {
  local action=$1
  local mutation=$2
  local value=${3:-}
  python3 - "$action" "$mutation" "$value" <<'PY'
import hashlib
import pathlib
import re
import sys

action = pathlib.Path(sys.argv[1])
mutation = sys.argv[2]
value = sys.argv[3].encode()
marker = b"manifest-text-v1\n"
header, manifest = action.read_bytes().split(marker, 1)

if mutation == "timeout":
    manifest, count = re.subn(
        rb"(?m)^proof-timeout=[^\n]*$",
        b"proof-timeout=" + value,
        manifest,
        count=1,
    )
elif mutation == "blank":
    manifest, count = manifest.replace(
        b"load-metadata-v1\n", b"load-metadata-v1\n\n", 1
    ), 1
elif mutation == "trailing":
    manifest, count = manifest + b"\n", 1
else:
    raise SystemExit(f"unknown manifest mutation: {mutation}")
if count != 1:
    raise SystemExit(f"manifest mutation {mutation} did not apply exactly once")

header = re.sub(
    rb"(?m)^manifest-sha256 [^\n]*$",
    b"manifest-sha256 " + hashlib.sha256(manifest).hexdigest().encode(),
    header,
)
header = re.sub(
    rb"(?m)^manifest-size [^\n]*$",
    b"manifest-size " + str(len(manifest)).encode(),
    header,
)
action.write_bytes(header + marker + manifest)
PY
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

equal_action=$(remote_theory_action_path)
equal_action_before=$tmpdir/equal-action.before
cp "$equal_action" "$equal_action_before"
equal_puts_before=$(action_put_count)
equal_log=$tmpdir/equal.log
(cd "$second" && HOLBUILD_CACHE="$second_cache" HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build --force --tactic-timeout 180 ATheory) > "$equal_log" 2>&1
require_grep "ATheory built" "$equal_log"
require_grep "remote cache published:" "$equal_log"
equal_puts_after=$(action_put_count)
if [[ "$equal_puts_after" != "$equal_puts_before" ]]; then
  echo "equal timeout publication issued an action PUT" >&2
  exit 1
fi
cmp "$equal_action_before" "$equal_action" || {
  echo "equal timeout publication changed resident action bytes" >&2
  exit 1
}

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

remote_action=$(remote_theory_action_path)
clean_remote_action=$tmpdir/remote-action-60.clean
cp "$remote_action" "$clean_remote_action"

for invalid_timeout in 60.0junk inf; do
  cp "$clean_remote_action" "$remote_action"
  mutate_remote_manifest "$remote_action" timeout "$invalid_timeout"
  invalid_before=$tmpdir/invalid-$invalid_timeout.before
  cp "$remote_action" "$invalid_before"
  invalid_log=$tmpdir/invalid-$invalid_timeout.log
  (cd "$fourth" && HOLBUILD_CACHE="$fourth_cache" HOLBUILD_CACHE_TRACE=1 \
    "$HOLBUILD_BIN" --remote-cache "$remote_url" build --force --tactic-timeout 30 ATheory) > "$invalid_log" 2>&1
  require_grep "cache manifest invalid proof-timeout" "$invalid_log"
  cmp "$invalid_before" "$remote_action" || {
    echo "malformed remote timeout $invalid_timeout was replaced" >&2
    exit 1
  }
done

for byte_mutation in blank trailing; do
  cp "$clean_remote_action" "$remote_action"
  mutate_remote_manifest "$remote_action" "$byte_mutation"
  byte_before=$tmpdir/$byte_mutation-action.before
  cp "$remote_action" "$byte_before"
  byte_log=$tmpdir/$byte_mutation-action.log
  (cd "$fourth" && HOLBUILD_CACHE="$fourth_cache" HOLBUILD_CACHE_TRACE=1 \
    "$HOLBUILD_BIN" --remote-cache "$remote_url" build --force --tactic-timeout 30 ATheory) > "$byte_log" 2>&1
  require_grep "resident manifest differs outside proof-timeout" "$byte_log"
  cmp "$byte_before" "$remote_action" || {
    echo "$byte_mutation non-timeout bytes were replaced" >&2
    exit 1
  }
done
cp "$clean_remote_action" "$remote_action"

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
clean_weaker_manifest=$tmpdir/weaker-manifest.clean
cp "$weaker_manifest" "$clean_weaker_manifest"

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

cp "$clean_weaker_manifest" "$weaker_manifest"
different_output=$tmpdir/different-output.dat
printf 'different valid cached output\n' > "$different_output"
different_output_hash=$(sha1sum "$different_output" | cut -d' ' -f1)
cp "$different_output" "$weaker_cache/blobs/$different_output_hash"
python3 - "$weaker_manifest" "$different_output_hash" <<'PY'
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1])
different_hash = sys.argv[2]
lines = manifest.read_text().splitlines()
lines[lines.index("proof-timeout=none")] = "proof-timeout=30.0"
dat_lines = [index for index, line in enumerate(lines) if line.startswith("blob dat ")]
if len(dat_lines) != 1:
    raise SystemExit(f"expected one dat output, found {len(dat_lines)}")
lines[dat_lines[0]] = f"blob dat {different_hash}"
manifest.write_text("\n".join(lines) + "\n")
PY
output_action_before=$tmpdir/output-action.before
cp "$remote_action" "$output_action_before"
output_conflict_log=$tmpdir/output-conflict.log
(cd "$weaker" && HOLBUILD_CACHE="$weaker_cache" HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build --force --tactic-timeout 30 ATheory) > "$output_conflict_log" 2>&1
require_grep "resident manifest differs outside proof-timeout" "$output_conflict_log"
cmp "$output_action_before" "$remote_action" || {
  echo "different output reference changed resident action bytes" >&2
  exit 1
}
assert_remote_proof_timeout 60.0

discrepancy=$tmpdir/discrepancy
write_project "$discrepancy"
discrepancy_cache=$tmpdir/cache-discrepancy
link_hol_toolchain_cache "$discrepancy_cache"
discrepancy_metadata=$discrepancy/.holbuild/dep/remote-cache-test/src/AScript.sml.key

discrepancy_restore_log=$tmpdir/discrepancy-restore.log
(cd "$discrepancy" && HOLBUILD_CACHE="$discrepancy_cache" HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build \
  --allow-cache-timeout-discrepancy --tactic-timeout 30 ATheory) > "$discrepancy_restore_log" 2>&1
require_grep "remote cache hydrated:" "$discrepancy_restore_log"
require_grep "ATheory restored from cache" "$discrepancy_restore_log"
require_grep '^proof_timeout=60.0$' "$discrepancy_metadata"

discrepancy_up_to_date_log=$tmpdir/discrepancy-up-to-date.log
(cd "$discrepancy" && HOLBUILD_CACHE="$discrepancy_cache" \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" --verbose build \
  --allow-cache-timeout-discrepancy --tactic-timeout 30 ATheory) > "$discrepancy_up_to_date_log" 2>&1
require_grep "ATheory is up to date" "$discrepancy_up_to_date_log"
require_grep '^proof_timeout=60.0$' "$discrepancy_metadata"

discrepancy_strict_log=$tmpdir/discrepancy-strict.log
(cd "$discrepancy" && HOLBUILD_CACHE="$discrepancy_cache" HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build \
  --tactic-timeout 30 ATheory) > "$discrepancy_strict_log" 2>&1
require_grep "insufficient tactic-timeout contract" "$discrepancy_strict_log"
require_grep "ATheory built" "$discrepancy_strict_log"
require_grep '^proof_timeout=30.0$' "$discrepancy_metadata"
assert_remote_proof_timeout 30.0

assert_server_action_paths

stop_remote_cache_server

remote_root=$tmpdir/race-converges-remote
race_control=$tmpdir/race-converges-control
start_remote_cache_server "$remote_root" "$tmpdir/race-converges-server" "$race_control"

race_weak=$tmpdir/race-weak-none
race_strong=$tmpdir/race-strong-180
race_weak_cache=$tmpdir/race-weak-none-cache
race_strong_cache=$tmpdir/race-strong-180-cache
write_project "$race_weak"
write_project "$race_strong"
link_hol_toolchain_cache "$race_weak_cache"
link_hol_toolchain_cache "$race_strong_cache"

touch "$race_control/action-put-1-before-enable"
touch "$race_control/action-put-2-after-enable"
race_weak_log=$tmpdir/race-weak-none.log
start_publisher "$race_weak" "$race_weak_cache" 0 "$race_weak_log"
race_weak_pid=$publisher_pid
wait_for_file "$race_control/action-put-1-before-event"

race_strong_log=$tmpdir/race-strong-180.log
start_publisher "$race_strong" "$race_strong_cache" 180 "$race_strong_log"
race_strong_pid=$publisher_pid
wait_for_file "$race_control/action-put-2-after-event"
touch "$race_control/action-put-1-before-release"
wait_for_publisher "$race_weak_pid" "$race_weak_log"
touch "$race_control/action-put-2-after-release"
wait_for_publisher "$race_strong_pid" "$race_strong_log"

require_grep "remote cache published:" "$race_strong_log"
assert_remote_proof_timeout 180.0
if [[ $(action_put_count) != 3 ]]; then
  echo "none/180 race did not retry exactly once" >&2
  exit 1
fi
assert_server_action_paths
stop_remote_cache_server

remote_root=$tmpdir/race-exhausts-remote
race_control=$tmpdir/race-exhausts-control
start_remote_cache_server "$remote_root" "$tmpdir/race-exhausts-server" "$race_control"

race_weak_pids=()
race_weak_logs=()
for ordinal in 1 2 3; do
  weak_project=$tmpdir/race-weak-180-$ordinal
  weak_cache=$tmpdir/race-weak-180-cache-$ordinal
  weak_log=$tmpdir/race-weak-180-$ordinal.log
  write_project "$weak_project"
  link_hol_toolchain_cache "$weak_cache"
  touch "$race_control/action-put-$ordinal-before-enable"
  start_publisher "$weak_project" "$weak_cache" 180 "$weak_log"
  race_weak_pids+=("$publisher_pid")
  race_weak_logs+=("$weak_log")
  wait_for_file "$race_control/action-put-$ordinal-before-event"
done

for ordinal in 4 5 6; do
  touch "$race_control/action-put-$ordinal-after-enable"
done
race_strong=$tmpdir/race-strong-60
race_strong_cache=$tmpdir/race-strong-60-cache
race_strong_log=$tmpdir/race-strong-60.log
write_project "$race_strong"
link_hol_toolchain_cache "$race_strong_cache"
start_publisher "$race_strong" "$race_strong_cache" 60 "$race_strong_log"
race_strong_pid=$publisher_pid

for round in 1 2 3; do
  strong_ordinal=$((round + 3))
  wait_for_file "$race_control/action-put-$strong_ordinal-after-event"
  touch "$race_control/action-put-$round-before-release"
  wait_for_publisher "${race_weak_pids[$((round - 1))]}" \
    "${race_weak_logs[$((round - 1))]}"
  touch "$race_control/action-put-$strong_ordinal-after-release"
done
wait_for_publisher "$race_strong_pid" "$race_strong_log"

require_grep "weaker proof-timeout observed after publication" "$race_strong_log"
if grep -q "remote cache published:" "$race_strong_log"; then
  echo "retry-exhausted publication reported success" >&2
  exit 1
fi
assert_remote_proof_timeout 180.0
if [[ $(action_put_count) != 6 ]]; then
  echo "180/60 race did not stop after three strong publication attempts" >&2
  exit 1
fi
assert_server_action_paths
