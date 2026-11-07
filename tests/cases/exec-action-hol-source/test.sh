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
mkdir -p "$project/src" "$project/shims"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "worker"

[build]
members = ["src"]

[dependencies.holexamples]
from = "hol"
path = "."
manifest = "shims/holexamples.toml"
TOML
cat > "$project/shims/holexamples.toml" <<'TOML'
[holbuild]
minimum_version = "0.10.0"

[project]
name = "holexamples"

[build]
members = ["examples/countchars"]
TOML
# countchars is in a package taken from the HOL checkout, and its ancestor
# sorting in package hol, which holbuild stages itself: both sit under the
# toolchain, so both record their scripts under `$(HOLDIR)`.
cat > "$project/src/useScript.sml" <<'SML'
Theory use
Ancestors countchars
SML

# The worker: every action of the batch, in order, in its own cache root.
link_hol_toolchain_cache "$tmpdir/client"
(cd "$project" && HOLBUILD_CACHE=$tmpdir/client "$HOLBUILD_BIN" --remote-cache "$remote_url" \
   action-spec --upload countcharsTheory) > "$tmpdir/batch.txt"
for target in hol:sortingTheory holexamples:countcharsTheory; do
  grep -q "^action [0-9a-f]* [0-9a-f]* [0-9a-f]* $target\$" "$tmpdir/batch.txt" ||
    { echo "the batch has no action for $target" >&2; cat "$tmpdir/batch.txt" >&2; exit 1; }
done
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
(cd "$project" && HOLBUILD_CACHE=$tmpdir/local "$HOLBUILD_BIN" build countcharsTheory) > "$tmpdir/local.log" 2>&1 ||
  { cat "$tmpdir/local.log" >&2; exit 1; }

while read -r key target; do
  if ! diff <(grep '^blob ' "$tmpdir/worker/actions/$key/manifest") \
            <(grep '^blob ' "$tmpdir/local/actions/$key/manifest") >&2; then
    echo "$target: the worker's outputs (<) differ from the local build's (>)" >&2
    exit 1
  fi
done < "$tmpdir/keys"

# Both name the scripts as HOL would, not by their packages.
for target in hol:sortingTheory holexamples:countcharsTheory; do
  key=$(awk -v want="$target" '$2 == want { print $1 }' "$tmpdir/keys")
  dat=$(awk '$1 == "blob" && $2 == "dat" { print $3 }' "$tmpdir/worker/actions/$key/manifest")
  grep -aq '"$(HOLDIR)"' "$tmpdir/worker/blobs/$dat" &&
    ! grep -aqE '"\$\((hol|holexamples)\)"' "$tmpdir/worker/blobs/$dat" ||
    { echo "$target: the theory does not record its script under \$(HOLDIR)" >&2; exit 1; }
done
