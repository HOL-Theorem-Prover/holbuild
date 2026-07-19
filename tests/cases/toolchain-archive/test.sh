#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
regression_failures=()

record_regression_failure() {
  local message=$1
  printf '%s\n' "$message" >&2
  regression_failures+=("$message")
}

archive_temp_snapshot() (
  local path
  shopt -s nullglob
  for path in "${TMPDIR:-/tmp}"/holbuild-toolchain-download-*; do
    [[ -f "$path" ]] && printf '%s\n' "$path"
  done | sort
)

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

write_fake_hol() {
  local hol=$1
  mkdir -p "$hol"
  mkdir -p "$hol/bin" "$hol/tools/build" "$hol/tools/sequences" "$hol/src/runtime"
  cat > "$hol/.gitignore" <<'EOF'
/bin/hol
/bin/Holmake
/bin/hol.state
/sigobj
/configured
/built
**/.hol/locks/
EOF
  cat > "$hol/tools/smart-configure.sml" <<'EOF'
(* The fake Poly/ML executable records configuration. *)
EOF
  printf '#include sequences/upto-hol\nsrc/runtime\n' > "$hol/tools/build/build-sequence"
  printf 'fake upto-hol sequence\n' > "$hol/tools/sequences/upto-hol"
  cat > "$hol/src/runtime/Runtime.sml" <<'EOF'
val restored_runtime = true
EOF
  cat > "$hol/bin/build" <<'SH'
#!/usr/bin/env sh
set -eu
printf 'build\n' >> "${HOLBUILD_TEST_BUILD_COUNT:?}"
if [ "${HOLBUILD_TEST_FAIL_LOCAL_BUILD:-}" = 1 ]; then
  exit 71
fi
if [ -n "${HOLBUILD_TEST_BUILD_EVENT:-}" ]; then
  printf 'observed\n' > "$HOLBUILD_TEST_BUILD_EVENT"
fi
if [ -n "${HOLBUILD_TEST_BUILD_GATE:-}" ]; then
  cat "$HOLBUILD_TEST_BUILD_GATE" >/dev/null
fi
touch built
mkdir -p bin sigobj src/runtime/.hol/locks
printf 'fake-state\n' > bin/hol.state
printf 'volatile\n' > src/runtime/.hol/locks/owner
cat > bin/hol <<'HOL'
#!/usr/bin/env sh
set -eu
state=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --holstate) state=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$state" ] && ! grep -qx 'fake-state' "$state"; then
  exit 72
fi
exit 0
HOL
chmod +x bin/hol
cat > bin/Holmake <<'HOLMAKE'
#!/usr/bin/env sh
set -eu
for source in "$@"; do
  case "$source" in
    *Script.sml) : > "${source%Script.sml}Theory.uo" ;;
  esac
done
HOLMAKE
chmod +x bin/Holmake
ln -s "$(pwd)/src/runtime/Runtime.sml" sigobj/Runtime.uo
SH
  chmod +x "$hol/bin/build"
}

write_fake_poly() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/poly" <<'SH'
#!/usr/bin/env sh
set -eu
if [ "${1:-}" = -v ]; then
  printf 'Fake Poly/ML Arm64 1.0\n'
  exit 0
fi
touch configured
SH
  chmod +x "$fakebin/poly"
  cat > "$fakebin/polyc" <<'SH'
#!/usr/bin/env sh
set -eu
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ]
cat > "$out" <<'ANALYSER'
#!/usr/bin/env sh
set -eu
if [ "${1:-}" = --version ]; then
  printf 'holbuild-hol-analyser holbuild-hol-analyser-v1\n'
  exit 0
fi
response=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --response) response=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$response" ]
printf 'version 1\nok\nend\n' > "$response"
ANALYSER
chmod +x "$out"
SH
  chmod +x "$fakebin/polyc"
}

write_project() {
  local project=$1
  local hol=$2
  local revision=$3
  mkdir -p "$project"
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "toolchain-archive-test"

[dependencies.hol]
git = "$hol"
rev = "$revision"
TOML
}

hol=$tmpdir/hol
fakebin=$tmpdir/fakebin
project=$tmpdir/project
cache=$tmpdir/cache
build_count=$tmpdir/build-count
: > "$build_count"
write_fake_hol "$hol"
hol_rev=$(init_git_repo "$hol")
write_fake_poly "$fakebin"
write_project "$project" "$hol" "$hol_rev"
remote_root=$tmpdir/remote
server_control=$tmpdir/server-control
start_remote_cache_server "$remote_root" "$tmpdir/server" "$server_control"

export HOLBUILD_CANONICAL_HOL_GIT=$hol
export HOLBUILD_POLY=$fakebin/poly
export HOLBUILD_POLYC=$fakebin/polyc
export HOLBUILD_TEST_BUILD_COUNT=$build_count
export HOLBUILD_CACHE=$cache

publish_log=$tmpdir/publish.log
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol --publish-toolchain) > "$publish_log" 2>&1
published_holdir=$(tail -n 1 "$publish_log")
[[ $(wc -l < "$build_count") -eq 1 ]]
require_file "$published_holdir/bin/hol"
require_file "$(dirname "$published_holdir")/build.ok"
[[ -L "$published_holdir/sigobj/Runtime.uo" ]]
[[ $(find "$remote_root/ac" -type f | wc -l) -eq 1 ]]
[[ $(find "$remote_root/cas" -type f | wc -l) -eq 1 ]]
require_grep '^PUT /cas/' "$request_log"
require_grep '^PUT /ac/' "$request_log"
action_files=("$remote_root"/ac/*)
cas_files=("$remote_root"/cas/*)
original_action=$tmpdir/original-action
original_archive=$tmpdir/original-archive
cp "${action_files[0]}" "$original_action"
cp "${cas_files[0]}" "$original_archive"

rm -rf "$cache/hol-toolchains"
restore_log=$tmpdir/restore.log
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol) > "$restore_log" 2>&1
restored_holdir=$(tail -n 1 "$restore_log")
[[ "$restored_holdir" = "$published_holdir" ]]
[[ $(wc -l < "$build_count") -eq 1 ]]
require_file "$restored_holdir/bin/hol"
require_file "$(dirname "$restored_holdir")/build.ok"
[[ -x "$restored_holdir/bin/hol" ]]
[[ -x "$restored_holdir/bin/Holmake" ]]
[[ -L "$restored_holdir/sigobj/Runtime.uo" ]]
[[ $(readlink "$restored_holdir/sigobj/Runtime.uo") = "$restored_holdir/src/runtime/Runtime.sml" ]]
[[ ! -e "$restored_holdir/src/runtime/.hol/locks" ]]
"$restored_holdir/bin/hol" --noconfig --holstate "$restored_holdir/bin/hol.state" </dev/null
printf 'val x = true\n' > "$tmpdir/TinyScript.sml"
"$restored_holdir/bin/Holmake" "$tmpdir/TinyScript.sml"
require_file "$tmpdir/TinyTheory.uo"
analyser_dirs=("$(dirname "$restored_holdir")"/analysers/*)
"${analyser_dirs[0]}/bin/holbuild-hol-analyser" --version > "$tmpdir/analyser-version"
require_grep '^holbuild-hol-analyser holbuild-hol-analyser-v1$' "$tmpdir/analyser-version"
require_grep '^GET /cas/' "$request_log"

initial_put_count=$(grep -c '^PUT ' "$request_log")
initial_cas_get_count=$(grep -c '^GET /cas/' "$request_log")

# A different absolute installation path must select a different AC record.
# The miss builds locally, and ordinary buildhol must not publish.
other_cache=$tmpdir/other-cache
wrong_path_log=$tmpdir/wrong-path.log
(cd "$project" && HOLBUILD_CACHE="$other_cache" "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol) > "$wrong_path_log" 2>&1
[[ $(wc -l < "$build_count") -eq 2 ]]
[[ $(grep -c '^PUT ' "$request_log") -eq "$initial_put_count" ]]
[[ $(grep -c '^GET /cas/' "$request_log") -eq "$initial_cas_get_count" ]]

# The Poly executable digest is part of remote identity even when its version
# string and the local toolchain key are unchanged.
cp "$fakebin/poly" "$tmpdir/original-poly"
printf '\n# changed executable identity\n' >> "$fakebin/poly"
rm -rf "$cache/hol-toolchains"
wrong_poly_log=$tmpdir/wrong-poly.log
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol) > "$wrong_poly_log" 2>&1
[[ $(wc -l < "$build_count") -eq 3 ]]
[[ $(grep -c '^PUT ' "$request_log") -eq "$initial_put_count" ]]
[[ $(grep -c '^GET /cas/' "$request_log") -eq "$initial_cas_get_count" ]]
cp "$tmpdir/original-poly" "$fakebin/poly"
chmod +x "$fakebin/poly"

# Platform identity is likewise domain-separated.
platformbin=$tmpdir/platformbin
mkdir -p "$platformbin"
cat > "$platformbin/uname" <<'SH'
#!/usr/bin/env sh
case "${1:-}" in
  -s) printf 'Linux\n' ;;
  -m) printf 'incompatible-test-architecture\n' ;;
  *) exec /usr/bin/uname "$@" ;;
esac
SH
chmod +x "$platformbin/uname"
rm -rf "$cache/hol-toolchains"
wrong_platform_log=$tmpdir/wrong-platform.log
(cd "$project" && PATH="$platformbin:$PATH" "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol) > "$wrong_platform_log" 2>&1
[[ $(wc -l < "$build_count") -eq 4 ]]
[[ $(grep -c '^PUT ' "$request_log") -eq "$initial_put_count" ]]
[[ $(grep -c '^GET /cas/' "$request_log") -eq "$initial_cas_get_count" ]]

# The exact path identity must use the same spelling embedded by the HOL build.
# A cache reached through a symlink is still a valid same-path installation.
symlink_cache=$tmpdir/symlink-cache
symlink_cache_real=$tmpdir/symlink-cache-real
symlink_build_count=$tmpdir/symlink-build-count
mkdir -p "$symlink_cache_real"
ln -s "$symlink_cache_real" "$symlink_cache"
: > "$symlink_build_count"
symlink_publish_log=$tmpdir/symlink-publish.log
if (cd "$project" && \
    HOLBUILD_CACHE="$symlink_cache" \
    HOLBUILD_TEST_BUILD_COUNT="$symlink_build_count" \
    "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol --publish-toolchain) \
    > "$symlink_publish_log" 2>&1; then
  symlink_holdir=$(tail -n 1 "$symlink_publish_log")
  require_file "$symlink_holdir/bin/Holmake"
  require_file "$(dirname "$symlink_holdir")/build.ok"
  case "$symlink_holdir" in
    "$symlink_cache"/hol-toolchains/*/hol) ;;
    *) record_regression_failure "symlinked cache returned a different path spelling" ;;
  esac
  rm -rf "$symlink_cache_real/hol-toolchains"
  symlink_restore_log=$tmpdir/symlink-restore.log
  if (cd "$project" && \
      HOLBUILD_CACHE="$symlink_cache" \
      HOLBUILD_TEST_BUILD_COUNT="$symlink_build_count" \
      "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol) \
      > "$symlink_restore_log" 2>&1; then
    symlink_restored_holdir=$(tail -n 1 "$symlink_restore_log")
    if [[ "$symlink_restored_holdir" != "$symlink_holdir" ]] ||
       [[ $(wc -l < "$symlink_build_count") -ne 1 ]] ||
       [[ $(readlink "$symlink_restored_holdir/sigobj/Runtime.uo") != \
          "$symlink_restored_holdir/src/runtime/Runtime.sml" ]]; then
      record_regression_failure "symlink-alias toolchain identity was not restored consistently"
    fi
  else
    record_regression_failure "symlink-alias toolchain archive was not restorable"
  fi
else
  record_regression_failure "toolchain publication rejected a symlinked cache path"
fi

write_archive_mutator() {
  cat > "$tmpdir/mutate_archive.py" <<'PY'
import copy
import hashlib
import io
import pathlib
import sys
import tarfile

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
action_path = pathlib.Path(sys.argv[3])
remote_cas = pathlib.Path(sys.argv[4])
mutation = sys.argv[5]
manifest_name = ".holbuild-toolchain-archive-manifest"

def normalized(name):
    while name.startswith("./"):
        name = name[2:]
    return name.rstrip("/")

def data_for(archive, member):
    if not member.isreg():
        return b""
    extracted = archive.extractfile(member)
    return b"" if extracted is None else extracted.read()

with tarfile.open(source, "r:") as archive:
    members = [(copy.copy(member), data_for(archive, member)) for member in archive.getmembers()]

manifest_bytes = next(data for member, data in members if normalized(member.name) == manifest_name)
marker = b"identity-text-v1\n"
identity = manifest_bytes.split(marker, 1)[1]

if mutation == "wrong-identity":
    manifest_bytes = (
        b"holbuild-toolchain-archive-v1\n" + marker + identity + b"\nwrong"
    )

with tarfile.open(destination, "w", format=tarfile.PAX_FORMAT, pax_headers={}) as output:
    for member, data in members:
        name = normalized(member.name)
        if mutation == "missing-executable" and name == "hol/bin/hol":
            continue
        if mutation == "missing-holmake" and name == "hol/bin/Holmake":
            continue
        if mutation == "wrong-identity" and name == manifest_name:
            data = manifest_bytes
            member.size = len(data)
        if mutation == "corrupt-heap" and name == "hol/bin/hol.state":
            data = b"corrupt-state\n"
            member.size = len(data)
        member.pax_headers = {}
        member.uid = 0
        member.gid = 0
        member.uname = ""
        member.gname = ""
        member.mtime = 0
        output.addfile(member, io.BytesIO(data) if member.isreg() else None)

    if mutation == "traversal":
        extra = tarfile.TarInfo("../parent-escape")
        payload = b"escape"
        extra.size = len(payload)
        extra.mode = 0o755
        extra.uid = 0
        extra.gid = 0
        extra.mtime = 0
        output.addfile(extra, io.BytesIO(payload))

archive_bytes = destination.read_bytes()
sha1 = hashlib.sha1(archive_bytes).hexdigest()
sha256 = hashlib.sha256(archive_bytes).hexdigest()
size = str(len(archive_bytes))
remote_cas.mkdir(parents=True, exist_ok=True)
recorded_sha256 = "0" * 64 if mutation == "digest" else sha256
(remote_cas / recorded_sha256).write_bytes(archive_bytes)

action = f"blob={sha1}\n".encode()
metadata = (
    "holbuild-remote-cache-action-v1\n"
    f"manifest-sha256 {hashlib.sha256(action).hexdigest()}\n"
    f"manifest-size {len(action)}\n"
    f"blob {sha1} {recorded_sha256} {size}\n"
    "manifest-text-v1\n"
).encode() + action
action_path.write_bytes(metadata)
PY
}

write_archive_mutator

invalid_restore() {
  local mutation=$1
  local expected=$2
  local mutated=$tmpdir/mutated-"$mutation".tar
  python3 "$tmpdir/mutate_archive.py" \
    "$original_archive" "$mutated" "${action_files[0]}" "$remote_root/cas" "$mutation"
  rm -rf "$cache/hol-toolchains"
  local log=$tmpdir/invalid-"$mutation".log
  if (cd "$project" && HOLBUILD_TEST_FAIL_LOCAL_BUILD=1 \
      "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol) > "$log" 2>&1; then
    record_regression_failure "invalid $mutation archive unexpectedly restored"
    return
  fi
  require_grep "$expected" "$log"
  [[ ! -e "$(dirname "$published_holdir")" ]]
}

invalid_restore wrong-identity 'identity does not match'
invalid_restore digest 'SHA256 mismatch'
invalid_restore traversal 'could not extract tar archive'
invalid_restore missing-executable 'failed final validation'
invalid_restore missing-holmake 'failed final validation'
invalid_restore corrupt-heap 'failed final validation'

cp "$original_action" "${action_files[0]}"

# A marker-bearing local entry without Holmake must never be accepted as built.
rm -rf "$cache/hol-toolchains"
local_holmake_setup_log=$tmpdir/local-holmake-setup.log
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol) \
  > "$local_holmake_setup_log" 2>&1
local_holmake_holdir=$(tail -n 1 "$local_holmake_setup_log")
rm "$local_holmake_holdir/bin/Holmake"
local_holmake_check_log=$tmpdir/local-holmake-check.log
if (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol) \
    > "$local_holmake_check_log" 2>&1; then
  if [[ ! -x "$local_holmake_holdir/bin/Holmake" ]]; then
    record_regression_failure "local toolchain without bin/Holmake was accepted as built"
  fi
fi


wait_for_file() {
  local path=$1
  local label=$2
  for _ in {1..500}; do
    [[ -e "$path" ]] && return 0
    sleep 0.01
  done
  echo "timed out waiting for $label: $path" >&2
  return 1
}

restore_after_interruption() {
  local label=$1
  local before_builds=$2
  local log=$tmpdir/repair-"$label".log
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol) > "$log" 2>&1
  require_file "$(dirname "$published_holdir")/build.ok"
  [[ $(wc -l < "$build_count") -eq "$before_builds" ]]
}

kill_toolchain_owner() {
  local final_dir owner_file owner_pid
  final_dir=$(dirname "$published_holdir")
  owner_file="$(dirname "$final_dir")/.locks/hol-toolchain-$(basename "$final_dir").lock.owner"
  wait_for_file "$owner_file" "toolchain lock owner"
  owner_pid=$(awk -F= '$1 == "pid" { print $2; exit }' "$owner_file")
  [[ "$owner_pid" =~ ^[0-9]+$ ]]
  kill -KILL "$owner_pid"
}

restore_scratch_paths() {
  local final_dir parent prefix path
  final_dir=$(dirname "$published_holdir")
  parent=$(dirname "$final_dir")
  prefix=".$(basename "$final_dir").restore-"
  for path in "$parent"/"$prefix"*; do
    [[ -e "$path" ]] && printf '%s\n' "$path"
  done
}

# A killed download leaves only task-local scratch. The next caller acquires
# the released per-key lock and performs a complete restore.
archive_temp_baseline=$tmpdir/archive-temp-baseline
archive_temp_snapshot > "$archive_temp_baseline"
rm -rf "$cache/hol-toolchains"
rm -f "$server_control"/download-*
mkfifo "$server_control/download-event"
touch "$server_control/download-enable"
download_log=$tmpdir/interrupted-download.log
(
  cd "$project"
  exec "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol
) > "$download_log" 2>&1 &
download_pid=$!
IFS= read -r _ < "$server_control/download-event"
kill_toolchain_owner
wait "$download_pid" 2>/dev/null || true
mapfile -t download_scratch < <(restore_scratch_paths)
if (( ${#download_scratch[@]} != 1 )); then
  record_regression_failure "interrupted download did not leave recoverable per-entry scratch"
fi
rm -f "$server_control/download-enable"
touch "$server_control/download-release"
rm -f "$server_control/download-event"
restore_after_interruption download "$(wc -l < "$build_count")"
mapfile -t remaining_download_scratch < <(restore_scratch_paths)
if (( ${#remaining_download_scratch[@]} > 0 )); then
  record_regression_failure "next lock owner did not sweep interrupted download scratch"
fi

real_tar=$(command -v tar)
tarbin=$tmpdir/tarbin
mkdir -p "$tarbin"
cat > "$tarbin/tar" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
extract=0
archive=
stage=
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -xf) extract=1; archive=${args[$((i + 1))]} ;;
    -C) stage=${args[$((i + 1))]} ;;
  esac
done
if [[ $extract -eq 0 || -z "${HOLBUILD_TEST_TAR_EVENT:-}" ]]; then
  exec "$HOLBUILD_TEST_REAL_TAR" "$@"
fi
"$HOLBUILD_TEST_REAL_TAR" -xf "$archive" -C "$stage" .holbuild-toolchain-archive-manifest
printf 'observed\n' > "$HOLBUILD_TEST_TAR_EVENT"
while [[ ! -e "$HOLBUILD_TEST_TAR_RELEASE" ]]; do
  sleep 0.01
done
"$HOLBUILD_TEST_REAL_TAR" "$@"
touch "$HOLBUILD_TEST_TAR_DONE"
SH
chmod +x "$tarbin/tar"

interrupt_extraction() {
  rm -rf "$cache/hol-toolchains"
  local event=$tmpdir/extract-event
  local release=$tmpdir/extract-release
  local done=$tmpdir/extract-done
  rm -f "$event" "$release" "$done"
  mkfifo "$event"
  local log=$tmpdir/interrupted-extraction.log
  (
    cd "$project"
    exec env PATH="$tarbin:$PATH" \
      HOLBUILD_TEST_REAL_TAR="$real_tar" \
      HOLBUILD_TEST_TAR_EVENT="$event" \
      HOLBUILD_TEST_TAR_RELEASE="$release" \
      HOLBUILD_TEST_TAR_DONE="$done" \
      "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol
  ) > "$log" 2>&1 &
  local pid=$!
  IFS= read -r _ < "$event"
  local path staging_dir=
  while IFS= read -r path; do
    if [[ -e "$path/.holbuild-toolchain-archive-manifest" ]]; then
      staging_dir=$path
      break
    fi
  done < <(restore_scratch_paths)
  [[ -n "$staging_dir" ]]
  kill_toolchain_owner
  wait "$pid" 2>/dev/null || true
  touch "$release"
  wait_for_file "$done" "orphaned extraction completion"
  rm -f "$event"
  restore_after_interruption extraction "$(wc -l < "$build_count")"
}

interrupt_extraction

# The final rename is not the commit point. Killing at the observable gate
# leaves a markerless directory that the next invocation removes and restores.
rm -rf "$cache/hol-toolchains"
renamed_event=$tmpdir/renamed-event
renamed_gate=$tmpdir/renamed-gate
mkfifo "$renamed_event" "$renamed_gate"
rename_log=$tmpdir/interrupted-rename.log
(
  cd "$project"
  exec env \
    HOLBUILD_TEST_TOOLCHAIN_RENAMED="$renamed_event" \
    HOLBUILD_TEST_TOOLCHAIN_RENAMED_GATE="$renamed_gate" \
    "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol
) > "$rename_log" 2>&1 &
rename_pid=$!
IFS= read -r _ < "$renamed_event"
kill_toolchain_owner
wait "$rename_pid" 2>/dev/null || true
[[ -d "$(dirname "$published_holdir")" ]]
[[ ! -e "$(dirname "$published_holdir")/build.ok" ]]
rm -f "$renamed_event" "$renamed_gate"
restore_after_interruption rename "$(wc -l < "$build_count")"

# Two empty-cache callers serialize through the per-key lock. The follower's
# explicit waiting event proves it cannot race the partial staging tree; after
# release it reports a revalidated local hit without a second CAS transfer.
rm -rf "$cache/hol-toolchains"
concurrent_event=$tmpdir/concurrent-extract-event
concurrent_release=$tmpdir/concurrent-extract-release
concurrent_done=$tmpdir/concurrent-extract-done
lock_wait_event=$tmpdir/concurrent-lock-wait
rm -f "$concurrent_event" "$concurrent_release" "$concurrent_done" "$lock_wait_event"
mkfifo "$concurrent_event" "$lock_wait_event"
cas_gets_before=$(grep -c '^GET /cas/' "$request_log")
(
  cd "$project"
  exec env PATH="$tarbin:$PATH" \
    HOLBUILD_TEST_REAL_TAR="$real_tar" \
    HOLBUILD_TEST_TAR_EVENT="$concurrent_event" \
    HOLBUILD_TEST_TAR_RELEASE="$concurrent_release" \
    HOLBUILD_TEST_TAR_DONE="$concurrent_done" \
    "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol
) > "$tmpdir/concurrent-first.log" 2>&1 &
first_pid=$!
IFS= read -r _ < "$concurrent_event"
(
  cd "$project"
  exec env HOLBUILD_TEST_TOOLCHAIN_LOCK_WAITING="$lock_wait_event" \
    "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol
) > "$tmpdir/concurrent-second.log" 2>&1 &
second_pid=$!
IFS= read -r _ < "$lock_wait_event"
touch "$concurrent_release"
wait "$first_pid"
wait "$second_pid"
wait_for_file "$concurrent_done" "concurrent extraction completion"
[[ $(grep -c '^GET /cas/' "$request_log") -eq $((cas_gets_before + 1)) ]]
require_file "$(dirname "$published_holdir")/build.ok"
rm -f "$concurrent_event" "$lock_wait_event"

# If the remote AC record is absent, killing a live local build child leaves a
# markerless final path. Restoring the action and invoking again repairs it
# without another local build.
mv "${action_files[0]}" "$tmpdir/action-disabled"
rm -rf "$cache/hol-toolchains"
build_event=$tmpdir/build-event
build_gate=$tmpdir/build-gate
mkfifo "$build_event" "$build_gate"
fallback_log=$tmpdir/interrupted-local-fallback.log
(
  cd "$project"
  exec env \
    HOLBUILD_TEST_BUILD_EVENT="$build_event" \
    HOLBUILD_TEST_BUILD_GATE="$build_gate" \
    "$HOLBUILD_BIN" --remote-cache "$remote_url" buildhol
) > "$fallback_log" 2>&1 &
fallback_pid=$!
IFS= read -r _ < "$build_event"
kill_toolchain_owner
wait "$fallback_pid" 2>/dev/null || true
printf 'continue\n' > "$build_gate"
wait_for_file "$published_holdir/built" "orphaned local build completion"
[[ ! -e "$(dirname "$published_holdir")/build.ok" ]]
rm -f "$build_event" "$build_gate"
mv "$tmpdir/action-disabled" "${action_files[0]}"
builds_after_interrupted_fallback=$(wc -l < "$build_count")
restore_after_interruption local-fallback "$builds_after_interrupted_fallback"

archive_temp_after=$tmpdir/archive-temp-after
archive_temp_leaks=$tmpdir/archive-temp-leaks
archive_temp_snapshot > "$archive_temp_after"
comm -13 "$archive_temp_baseline" "$archive_temp_after" > "$archive_temp_leaks"
if [[ -s "$archive_temp_leaks" ]]; then
  leak_count=$(wc -l < "$archive_temp_leaks")
  record_regression_failure "interrupted restores leaked $leak_count downloaded archive(s)"
  while IFS= read -r leaked; do
    rm -f -- "$leaked"
  done < "$archive_temp_leaks"
fi

if (( ${#regression_failures[@]} > 0 )); then
  printf 'toolchain archive regression failures:\n' >&2
  printf '  - %s\n' "${regression_failures[@]}" >&2
  exit 1
fi
