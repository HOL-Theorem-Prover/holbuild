#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A worker's failed theory is a disk failure, which the fleet retries, when
# the worker's disk is below the free-space floor afterwards, though a small
# write would still fit; a proof failure otherwise.  The floor is set just
# above and just below what statvfs reports, which checks the fields read.

tmpdir=$(make_temp_dir)
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "df"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

val _ = raise Fail "expected failure";
SML
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload ATheory) > "$tmpdir/batch.txt"
spec=$(awk '$1 == "action" && $5 == "df:ATheory" { print $4 }' "$tmpdir/batch.txt")
[[ -n "$spec" ]] || { cat "$tmpdir/batch.txt" >&2; exit 1; }

cache=$tmpdir/worker
link_hol_toolchain_cache "$cache"

# worker NAME FLOOR FAILURE: exec-action of A with HOLBUILD_TEST_DISK_FLOOR
# FLOOR must fail as FAILURE.
worker() {
  HOLBUILD_TEST_DISK_FLOOR=$2 HOLBUILD_CACHE=$cache "$HOLBUILD_BIN" --remote-cache "$remote_url" \
    exec-action "$spec" --cache-limit-gb 1000 --result "$tmpdir/$1.result" > "$tmpdir/$1.log" 2>&1 || true
  grep -qx "failure=$3" "$tmpdir/$1.result" || {
    echo "worker $1 with floor $2: wanted failure=$3" >&2
    cat "$tmpdir/$1.result" "$tmpdir/$1.log" >&2
    exit 1
  }
}

# Free bytes and inodes for unprivileged users; GNU stat's %d is f_ffree,
# which is f_favail on Linux filesystems.
read -r blocks block_size inodes < <(stat -f -c '%a %S %d' "$cache")
bytes=$((blocks * block_size))
margin=$((2 * 1024 * 1024 * 1024))

worker bytes-above "$((bytes + margin)) 0" disk
if (( bytes > 2 * margin )); then
  worker bytes-below "$((bytes - margin)) 0" proof
fi
if (( inodes > 0 )); then
  worker inodes-above "0 $((inodes + 100000))" disk
  if (( inodes > 200000 )); then
    worker inodes-below "0 $((inodes - 100000))" proof
  fi
fi
