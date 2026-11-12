#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() {
  touch "$tmpdir/control/action-get-release" 2>/dev/null || true
  touch "$tmpdir/control/cas-put-release" 2>/dev/null || true
  if [[ -n "${export_pid:-}" ]]; then
    kill "$export_pid" 2>/dev/null || true
    wait "$export_pid" 2>/dev/null || true
  fi
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

remote_root=$tmpdir/remote
start_remote_cache_server "$remote_root" "$tmpdir/server" "$tmpdir/control"
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "spec"

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
cat > "$project/src/helperLib.sml" <<'SML'
structure helperLib = struct val helper_value = 1 end
SML
echo data > "$project/src/data.txt"
cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors A
Libs helperLib

fun holbuild_extra_deps (_ : string list) = ()
val _ = holbuild_extra_deps ["data.txt"]

Theorem b_thm:
  T
Proof
  simp[]
QED
SML
cat > "$project/src/CScript.sml" <<'SML'
Theory C
Ancestors B

Theorem c_thm:
  T
Proof
  simp[]
QED
SML

hb() {
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" "$@")
}

# Input keys as the build plan computes them.
hb build --dry-run CTheory > "$tmpdir/plan.txt"
plan_key() {
  awk -v want="$1" '/^[^ ]/ { name = $1 } $1 == "input_key:" && name == want { print $2 }' "$tmpdir/plan.txt"
}
key_a=$(plan_key ATheory)
key_b=$(plan_key BTheory)
key_c=$(plan_key CTheory)
[[ -n "$key_a" && -n "$key_b" && -n "$key_c" ]] || { cat "$tmpdir/plan.txt" >&2; exit 1; }

# Checks one spec against its batch line: its name is its hash, its action
# text hashes to its input key, and its source line matches that text.
check_specs() {
  python3 - "$project/.holbuild/action-specs" "$1" <<'PY'
import hashlib, pathlib, re, sys
spec_dir, batch = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).read_text().splitlines()
assert batch[0] == "holbuild-action-batch-v1", batch
for line in batch[1:]:
    fields = line.split()
    if fields[0] != "action":
        continue
    _, key, ac_key, spec_sha, target = fields
    expected_ac = hashlib.sha256(f"holbuild-remote-ac-v1\n{key}\n".encode()).hexdigest()
    assert ac_key == expected_ac, (line, expected_ac)
    data = (spec_dir / spec_sha).read_bytes()
    assert hashlib.sha256(data).hexdigest() == spec_sha, spec_sha
    head, action_text = data.split(b"\naction-text\n", 1)
    lines = head.decode().splitlines()
    assert lines[0] == "holbuild-action-spec-v1", lines[0]
    assert f"input-key={key}" in lines, (target, key)
    assert hashlib.sha256(action_text).hexdigest() == key, target
    assert f"action-text-sha256={key}" in lines, target
    assert any(re.fullmatch("deps-key=[0-9a-f]{64}", l) for l in lines), target
    assert f"target {target}" in lines, target
    source = [l.split() for l in lines if l.startswith("source ")]
    assert len(source) == 1, source
    text_lines = action_text.split(b"\n")
    assert f"package={source[0][1]}".encode() in text_lines, target
    assert f"source={source[0][2]}".encode() in text_lines, target
    assert f"source-sha256={source[0][3]}".encode() in text_lines, target
PY
}

# Nothing is cached: every theory is exported, each waiting for its parent.
hb action-spec CTheory > "$tmpdir/batch1.txt"
check_specs "$tmpdir/batch1.txt"
hb action-spec --remote-only CTheory > "$tmpdir/batch-remote-only.txt"
diff -u "$tmpdir/batch1.txt" "$tmpdir/batch-remote-only.txt"
grep '^edge' "$tmpdir/batch1.txt" | sort > "$tmpdir/edges1.txt"
printf 'edge %s %s\nedge %s %s\n' "$key_b" "$key_a" "$key_c" "$key_b" | sort > "$tmpdir/edges1.expected"
diff -u "$tmpdir/edges1.expected" "$tmpdir/edges1.txt"
[[ $(grep -c '^action' "$tmpdir/batch1.txt") -eq 3 ]] || { cat "$tmpdir/batch1.txt" >&2; exit 1; }

# Serial and concurrent checks emit identical ordered batches. Hold AC GETs
# until two are in flight: a serial exporter cannot reach the release.
hb --prefetch-concurrency 1 action-spec CTheory > "$tmpdir/batch-serial.txt"
diff -u "$tmpdir/batch1.txt" "$tmpdir/batch-serial.txt"
touch "$tmpdir/control/action-get-enable"
(cd "$project" && exec "$HOLBUILD_BIN" --remote-cache "$remote_url" \
  --prefetch-concurrency 2 action-spec CTheory) \
  > "$tmpdir/batch-parallel.txt" 2> "$tmpdir/check-progress.log" &
export_pid=$!
for _ in {1..500}; do
  count=$(cat "$tmpdir/control/action-get-count" 2>/dev/null || echo 0)
  [[ "$count" -ge 2 ]] && break
  kill -0 "$export_pid" 2>/dev/null || break
  sleep 0.01
done
[[ "$count" -eq 2 ]] || {
  echo "expected two concurrent action checks, observed $count" >&2
  exit 1
}
touch "$tmpdir/control/action-get-release"
wait "$export_pid"
unset export_pid
rm "$tmpdir/control/action-get-enable"
diff -u "$tmpdir/batch1.txt" "$tmpdir/batch-parallel.txt"
require_grep '^checking remote cache: 0/3 theories$' "$tmpdir/check-progress.log"
require_grep '^checking remote cache: 3/3 theories$' "$tmpdir/check-progress.log"
hb --quiet action-spec CTheory > "$tmpdir/batch-quiet.txt" 2> "$tmpdir/quiet.log"
diff -u "$tmpdir/batch1.txt" "$tmpdir/batch-quiet.txt"
if grep -q 'checking remote cache:' "$tmpdir/quiet.log"; then
  echo "quiet export printed progress" >&2
  exit 1
fi

spec_b=$(awk -v key="$key_b" '$1 == "action" && $2 == key { print $4 }' "$tmpdir/batch1.txt")
spec_b_path=$project/.holbuild/action-specs/$spec_b
require_grep "^file input src/data.txt " "$spec_b_path"
require_grep "^file library .holbuild/action-src/spec/src/helperLib.sml " "$spec_b_path"
require_grep "^dep theory spec:ATheory .holbuild/obj/src/ATheory $key_a\$" "$spec_b_path"
require_grep "^lib spec:helperLib .holbuild/obj/src/helperLib .uo .holbuild/action-src/spec/src/helperLib.sml\$" "$spec_b_path"
require_grep "^load object .holbuild/obj/src/ATheory\$" "$spec_b_path"
require_grep "^output dat .holbuild/obj/src/BTheory.dat\$" "$spec_b_path"
require_grep "^option tactic-timeout=2.5\$" "$spec_b_path"
if grep -q "$project" "$spec_b_path"; then
  echo "spec names the project's absolute path" >&2
  exit 1
fi

# --upload puts every spec and source in the CAS.
hb action-spec --upload CTheory > "$tmpdir/batch-upload.txt"
diff -u "$tmpdir/batch1.txt" "$tmpdir/batch-upload.txt"
for spec in $(awk '$1 == "action" { print $4 }' "$tmpdir/batch1.txt"); do
  cmp "$project/.holbuild/action-specs/$spec" "$remote_root/cas/$spec"
done
for file in BScript.sml helperLib.sml data.txt; do
  require_file "$remote_root/cas/$(sha256sum "$project/src/$file" | cut -d' ' -f1)"
done

# The uploads run concurrently too: hold CAS PUTs until two are in flight,
# which a serial uploader cannot reach.
rm -rf "$remote_root/cas"
touch "$tmpdir/control/cas-put-enable"
(cd "$project" && exec "$HOLBUILD_BIN" --remote-cache "$remote_url" \
  --prefetch-concurrency 2 action-spec --upload CTheory) \
  > "$tmpdir/batch-upload-parallel.txt" 2> "$tmpdir/upload-progress.log" &
export_pid=$!
for _ in {1..500}; do
  count=$(cat "$tmpdir/control/cas-put-count" 2>/dev/null || echo 0)
  [[ "$count" -ge 2 ]] && break
  kill -0 "$export_pid" 2>/dev/null || break
  sleep 0.01
done
[[ "$count" -eq 2 ]] || {
  echo "expected two concurrent uploads, observed $count" >&2
  exit 1
}
touch "$tmpdir/control/cas-put-release"
wait "$export_pid"
unset export_pid
rm "$tmpdir/control/cas-put-enable" "$tmpdir/control/cas-put-release"
diff -u "$tmpdir/batch1.txt" "$tmpdir/batch-upload-parallel.txt"
for spec in $(awk '$1 == "action" { print $4 }' "$tmpdir/batch1.txt"); do
  cmp "$project/.holbuild/action-specs/$spec" "$remote_root/cas/$spec"
done
total=$(sed -n 's|^uploading to remote cache: 0/\([0-9][0-9]*\) files$|\1|p' "$tmpdir/upload-progress.log")
[[ -n "$total" ]] || { cat "$tmpdir/upload-progress.log" >&2; exit 1; }
require_grep "^uploading to remote cache: $total/$total files\$" "$tmpdir/upload-progress.log"

# Resident blobs are skipped through both HTTP clients. An unknown HEAD
# response must still attempt the PUT, rather than assume a blob exists.
for client in libcurl cli; do
  if [[ "$client" == cli ]]; then
    export HOLBUILD_TEST_LIBCURL=libholbuild-test-no-such-curl.so
  fi
  : > "$request_log"
  hb action-spec --upload CTheory > "$tmpdir/batch-resident.txt"
  diff -u "$tmpdir/batch1.txt" "$tmpdir/batch-resident.txt"
  [[ $(grep -c '^HEAD /cas/' "$request_log") -eq 8 ]]
  if grep -q '^PUT /cas/' "$request_log"; then
    echo "resident blobs were uploaded again" >&2
    exit 1
  fi
  echo 503 > "$tmpdir/control/head-status"
  : > "$request_log"
  hb action-spec --upload CTheory > "$tmpdir/batch-unknown-head.txt"
  diff -u "$tmpdir/batch1.txt" "$tmpdir/batch-unknown-head.txt"
  [[ $(grep -c '^PUT /cas/' "$request_log") -eq 8 ]]
  rm "$tmpdir/control/head-status"
  # Hold PUT responses until three follow failed HEADs. Counting optional
  # HEAD failures against the breaker would suppress the third PUT.
  rm "$tmpdir/control/cas-put-count"
  touch "$tmpdir/control/head-disconnect" "$tmpdir/control/cas-put-enable"
  (cd "$project" && exec "$HOLBUILD_BIN" --remote-cache "$remote_url" \
    --prefetch-concurrency 3 action-spec --upload CTheory) \
    > "$tmpdir/batch-head-disconnect.txt" 2> "$tmpdir/head-disconnect.log" &
  export_pid=$!
  for _ in {1..500}; do
    count=$(cat "$tmpdir/control/cas-put-count" 2>/dev/null || echo 0)
    [[ "$count" -ge 3 ]] && break
    kill -0 "$export_pid" 2>/dev/null || break
    sleep 0.01
  done
  [[ "$count" -eq 3 ]] || {
    echo "expected three PUTs after failed HEADs, observed $count" >&2
    exit 1
  }
  touch "$tmpdir/control/cas-put-release"
  wait "$export_pid"
  unset export_pid
  rm "$tmpdir/control/head-disconnect" "$tmpdir/control/cas-put-enable" "$tmpdir/control/cas-put-release"
  diff -u "$tmpdir/batch1.txt" "$tmpdir/batch-head-disconnect.txt"
  unset HOLBUILD_TEST_LIBCURL
done

# After the first upload fails, the rest are skipped and the export fails.
missing_spec=$(awk '$1 == "action" { print $4; exit }' "$tmpdir/batch1.txt")
rm "$remote_root/cas/$missing_spec"
echo 500 > "$tmpdir/control/cas-put-status"
: > "$request_log"
if HOLBUILD_TIMING_LOG="$tmpdir/failed-upload.timing" hb --prefetch-concurrency 1 action-spec --upload CTheory > /dev/null 2> "$tmpdir/upload-failure.log"; then
  echo "an export whose upload failed succeeded" >&2
  exit 1
fi
rm "$tmpdir/control/cas-put-status"
require_grep 'could not upload .*HTTP 500' "$tmpdir/upload-failure.log"
require_grep 'name=action_spec.upload.*status=fail' "$tmpdir/failed-upload.timing"
[[ $(grep -c '^PUT /cas/' "$request_log") -eq 1 ]] || {
  echo "uploads went on after the first failure:" >&2
  grep '^PUT /cas/' "$request_log" >&2
  exit 1
}

# Once A is in the remote cache, only B and C are left, and B waits for nothing.
hb build ATheory > "$tmpdir/build-a.log" 2>&1
hb action-spec CTheory > "$tmpdir/batch2.txt"
check_specs "$tmpdir/batch2.txt"
hb --prefetch-concurrency 1 action-spec CTheory > "$tmpdir/batch2-serial.txt"
diff -u "$tmpdir/batch2.txt" "$tmpdir/batch2-serial.txt"
awk '$1 == "action" { print $2 }' "$tmpdir/batch2.txt" | sort > "$tmpdir/actions2.txt"
printf '%s\n%s\n' "$key_b" "$key_c" | sort > "$tmpdir/actions2.expected"
diff -u "$tmpdir/actions2.expected" "$tmpdir/actions2.txt"
grep '^edge' "$tmpdir/batch2.txt" > "$tmpdir/edges2.txt"
printf 'edge %s %s\n' "$key_c" "$key_b" > "$tmpdir/edges2.expected"
diff -u "$tmpdir/edges2.expected" "$tmpdir/edges2.txt"

# A's entry whose blobs expired from the remote cache counts as uncached,
# through libcurl where the host has it and through the curl CLI.
ac_a=$(printf 'holbuild-remote-ac-v1\n%s\n' "$key_a" | sha256sum | cut -d' ' -f1)
blob_a=$(awk '$1 == "blob" { print $2; exit }' "$remote_root/ac/$ac_a")
[[ -n "$blob_a" ]] || { cat "$remote_root/ac/$ac_a" >&2; exit 1; }
mv "$remote_root/cas/$blob_a" "$tmpdir/blob-a"
hb action-spec CTheory > "$tmpdir/batch-expired.txt" 2> "$tmpdir/batch-expired.err"
[[ $(grep -c '^action' "$tmpdir/batch-expired.txt") -eq 3 ]] || { cat "$tmpdir/batch-expired.txt" >&2; exit 1; }
if grep -q "using the curl command" "$tmpdir/batch-expired.err"; then cat "$tmpdir/batch-expired.err" >&2; exit 1; fi
HOLBUILD_TEST_LIBCURL=libholbuild-test-no-such-curl.so hb action-spec CTheory > "$tmpdir/batch-expired-cli.txt"
[[ $(grep -c '^action' "$tmpdir/batch-expired-cli.txt") -eq 3 ]] || { cat "$tmpdir/batch-expired-cli.txt" >&2; exit 1; }
hb --prefetch-concurrency 1 action-spec CTheory > "$tmpdir/batch-expired-serial.txt"
diff -u "$tmpdir/batch-expired.txt" "$tmpdir/batch-expired-serial.txt"
mv "$tmpdir/blob-a" "$remote_root/cas/$blob_a"

# A stricter timeout than A's entry was built with makes A uncached again.
hb action-spec --tactic-timeout 1 ATheory > "$tmpdir/batch-strict.txt"
[[ $(grep -c '^action' "$tmpdir/batch-strict.txt") -eq 1 ]] || { cat "$tmpdir/batch-strict.txt" >&2; exit 1; }

# Excluded actions are refused with their name and reason.
expect_refusal() {
  local pattern=$1
  shift
  if hb action-spec "$@" > "$tmpdir/refused.log" 2>&1; then
    echo "action-spec unexpectedly succeeded: $*" >&2
    exit 1
  fi
  grep -q -- "$pattern" "$tmpdir/refused.log" || { cat "$tmpdir/refused.log" >&2; require_grep "$pattern" "$tmpdir/refused.log"; }
}
hb action-spec --force=theory CTheory > "$tmpdir/batch-forced.txt"
require_grep '^action .* spec:CTheory$' "$tmpdir/batch-forced.txt"
forced_spec=$(awk '$1 == "action" && $5 == "spec:CTheory" { print $4 }' "$tmpdir/batch-forced.txt")
require_grep '^option force=true$' "$project/.holbuild/action-specs/$forced_spec"

echo outside > "$tmpdir/outside.txt"
cat > "$project/src/DScript.sml" <<'SML'
Theory D
Ancestors bool

fun holbuild_extra_deps (_ : string list) = ()
val _ = holbuild_extra_deps ["../../outside.txt"]
SML
expect_refusal "spec:DTheory can't run remotely: its extra input ../outside.txt lies outside its package root" DTheory
rm "$project/src/DScript.sml"

cp "$project/holproject.toml" "$tmpdir/holproject.toml.orig"
cat >> "$project/holproject.toml" <<'TOML'

[actions.ATheory]
always_reexecute = true
TOML
expect_refusal "spec:ATheory can't run remotely: it sets always_reexecute" CTheory

cp "$tmpdir/holproject.toml.orig" "$project/holproject.toml"
cat >> "$project/holproject.toml" <<'TOML'

[actions.ATheory]
cache = false
TOML
expect_refusal "spec:ATheory can't run remotely: it sets cache = false" CTheory

if (cd "$project" && env -u HOLBUILD_REMOTE_CACHE_URL "$HOLBUILD_BIN" action-spec CTheory) > "$tmpdir/no-remote.log" 2>&1; then
  echo "action-spec without a remote cache unexpectedly succeeded" >&2
  exit 1
fi
require_grep "action-spec needs a remote cache" "$tmpdir/no-remote.log"

# An uncached toolchain must fail without building HOL locally.
fake_hol=$tmpdir/fake-hol
write_fake_hol "$fake_hol"
fake_rev=$(init_git_repo "$fake_hol")
mkdir -p "$tmpdir/fake-project"
cat > "$tmpdir/fake-project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "spec-fake"

[dependencies.hol]
git = "$fake_hol"
rev = "$fake_rev"
TOML
: > "$tmpdir/fake-build-count"
status=0
(cd "$tmpdir/fake-project" &&
  HOLBUILD_CACHE=$tmpdir/fake-cache \
  HOLBUILD_TEST_BUILD_COUNT=$tmpdir/fake-build-count \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --remote-only) \
  > "$tmpdir/toolchain-only.log" 2>&1 || status=$?
[[ $status -eq 75 ]] || { cat "$tmpdir/toolchain-only.log" >&2; echo "wanted 75, got $status" >&2; exit 1; }
require_grep 'HOL toolchain could not be restored from a cache, and --remote-only builds nothing locally' "$tmpdir/toolchain-only.log"
[[ ! -s "$tmpdir/fake-build-count" ]] || { cat "$tmpdir/fake-build-count" >&2; exit 1; }
