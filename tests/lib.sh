#!/usr/bin/env bash

require_file() {
  local path=$1
  [[ -f "$path" ]] || { echo "missing expected file: $path" >&2; exit 1; }
}

require_no_file() {
  local path=$1
  if [[ -e "$path" ]]; then
    echo "unexpected file exists: $path" >&2
    exit 1
  fi
}

require_grep() {
  local pattern=$1
  local path=$2
  grep -q "$pattern" "$path" || {
    echo "missing expected pattern '$pattern' in $path" >&2
    exit 1
  }
}

make_temp_dir() {
  mktemp -d "${TMPDIR:-/tmp}/holbuild-test.XXXXXX"
}

cleanup_temp_dir() {
  local dir=$1
  local keep=${HOLBUILD_KEEP_TEST_LOGS:-}
  if [[ -n "$keep" && "$keep" != 0 && "$keep" != false ]]; then
    echo "keeping holbuild test temp dir: $dir" >&2
  else
    rm -rf "$dir"
  fi
}

start_remote_cache_server() {
  local root=$1
  local state_dir=$2
  local control_dir=${3:-}
  local lib_dir port_file
  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  port_file=$state_dir/server.port
  request_log=$state_dir/requests.log
  mkdir -p "$root" "$state_dir"
  [[ -z "$control_dir" ]] || mkdir -p "$control_dir"
  : > "$request_log"
  python3 "$lib_dir/fixtures/remote_cache_server.py" \
    "$root" "$port_file" "$request_log" "$control_dir" &
  server_pid=$!
  for _ in {1..100}; do
    [[ -s "$port_file" ]] && break
    sleep 0.01
  done
  [[ -s "$port_file" ]] || {
    echo "remote cache server did not start" >&2
    return 1
  }
  remote_url="http://127.0.0.1:$(< "$port_file")"
}

holbuild_pinned_hol_rev() {
  if [[ -n "${HOLBUILD_TEST_HOL_REV:-}" ]]; then
    printf '%s\n' "$HOLBUILD_TEST_HOL_REV"
  else
    tr -d '[:space:]' < "${HOLBUILD_ROOT:?HOLBUILD_ROOT not set}/vendor/hol/REV"
  fi
}

write_schema2_prelude() {
  cat <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

TOML
}

init_git_repo() {
  local dir=$1
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name "holbuild test"
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" add .
  git -C "$dir" commit -q --no-gpg-sign -m init
  git -C "$dir" rev-parse HEAD
}

link_hol_toolchain_cache() {
  local cache=$1
  mkdir -p "$cache"
  if [[ -n "${HOLBUILD_TEST_GLOBAL_CACHE:-}" && -d "$HOLBUILD_TEST_GLOBAL_CACHE/hol-toolchains" && ! -e "$cache/hol-toolchains" ]]; then
    ln -s "$HOLBUILD_TEST_GLOBAL_CACHE/hol-toolchains" "$cache/hol-toolchains"
  fi
}

use_case_cache() {
  local cache=$1
  link_hol_toolchain_cache "$cache"
  export HOLBUILD_CACHE="$cache"
}

# A fake HOL checkout whose bin/build produces a minimal toolchain without
# Poly/ML. Gates: HOLBUILD_TEST_BUILD_EVENT/GATE pause the build, and
# HOLBUILD_TEST_FAKE_HOL_EVENT/GATE pause the built bin/hol. Requires
# HOLBUILD_TEST_BUILD_COUNT.
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
if [ -n "${HOLBUILD_TEST_FAKE_HOL_EVENT:-}" ]; then
  printf 'observed\n' > "$HOLBUILD_TEST_FAKE_HOL_EVENT"
fi
if [ -n "${HOLBUILD_TEST_FAKE_HOL_GATE:-}" ]; then
  cat "$HOLBUILD_TEST_FAKE_HOL_GATE" >/dev/null
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
# HOL bakes its build directory as getcwd reports it, symlinks resolved.
ln -s "$(pwd -P)/src/runtime/Runtime.sml" sigobj/Runtime.uo
SH
  chmod +x "$hol/bin/build"
}

# Fake poly/polyc for HOLBUILD_POLY/HOLBUILD_POLYC, pairing with write_fake_hol.
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
  printf 'holbuild-hol-analyser holbuild-hol-analyser-v2\n'
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
