#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A worker's build of a theory from HOL's own sources must give the same bytes
# as a local build of the same key: the cache keeps one entry per key, so any
# difference splits it into two families.

tmpdir=$(make_temp_dir)
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
unset HOLBUILD_REMOTE_CACHE_URL

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "worker"

[build]
members = ["src"]
TOML
# mergesort is a HOL library theory that holbuild stages itself, in package hol.
cat > "$project/src/useScript.sml" <<'SML'
Theory use
Ancestors mergesort
SML

# The worker: every action of the batch, in order, in its own cache root.
link_hol_toolchain_cache "$tmpdir/client"
(cd "$project" && HOLBUILD_CACHE=$tmpdir/client "$HOLBUILD_BIN" --remote-cache "$remote_url" \
   action-spec --upload mergesortTheory) > "$tmpdir/batch.txt"
grep -q '^action [0-9a-f]* [0-9a-f]* [0-9a-f]* hol:mergesortTheory$' "$tmpdir/batch.txt" ||
  { cat "$tmpdir/batch.txt" >&2; exit 1; }
link_hol_toolchain_cache "$tmpdir/worker"
mkdir -p "$tmpdir/cwd"
while read -r _ key _ spec target; do
  (cd "$tmpdir/cwd" && HOLBUILD_CACHE=$tmpdir/worker "$HOLBUILD_BIN" --remote-cache "$remote_url" \
     exec-action "$spec" --cache-limit-gb 1000 --result "$tmpdir/result") > "$tmpdir/worker.log" 2>&1 ||
    { echo "worker failed on $target" >&2; cat "$tmpdir/worker.log" "$tmpdir/result" >&2; exit 1; }
  require_grep '^status=built$' "$tmpdir/result"
  echo "$key $target" >> "$tmpdir/keys"
done < <(grep '^action ' "$tmpdir/batch.txt")

# The local build, from source in another cache root, without the remote.
link_hol_toolchain_cache "$tmpdir/local"
(cd "$project" && HOLBUILD_CACHE=$tmpdir/local "$HOLBUILD_BIN" build mergesortTheory) > "$tmpdir/local.log" 2>&1 ||
  { cat "$tmpdir/local.log" >&2; exit 1; }

while read -r key target; do
  if ! diff <(grep '^blob ' "$tmpdir/worker/actions/$key/manifest") \
            <(grep '^blob ' "$tmpdir/local/actions/$key/manifest") >&2; then
    echo "$target: the worker's outputs (<) differ from the local build's (>)" >&2
    exit 1
  fi
done < "$tmpdir/keys"
