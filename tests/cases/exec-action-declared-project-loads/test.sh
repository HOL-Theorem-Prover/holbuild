#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A worker builds a theory whose library names project modules in
# `[actions] loads`, one of them a source holding only a signature.  A worker's
# action root has no project file, so HOL's load path doesn't cover the
# project's object directories: the library must load these by path.

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
mkdir -p "$project/lib" "$project/thy"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "worker"

[build]
members = ["lib", "thy"]

[actions.implLib]
loads = ["shapeSig"]

[actions.useLib]
loads = ["shapeSig", "implLib"]
TOML
cat > "$project/lib/shapeSig.sml" <<'SML'
signature shapeSig = sig val width : int end
SML
cat > "$project/lib/implLib.sml" <<'SML'
structure implLib :> shapeSig = struct val width = 3 end
SML
cat > "$project/lib/useLib.sml" <<'SML'
structure useLib = struct val width = implLib.width end
SML
cat > "$project/thy/useScript.sml" <<'SML'
Theory use
Libs useLib

Theorem width_ok = boolTheory.TRUTH before ignore useLib.width
SML

link_hol_toolchain_cache "$tmpdir/client"
(cd "$project" && HOLBUILD_CACHE=$tmpdir/client "$HOLBUILD_BIN" --remote-cache "$remote_url" \
   action-spec --upload useTheory) > "$tmpdir/batch.txt"
link_hol_toolchain_cache "$tmpdir/worker"
mkdir -p "$tmpdir/cwd"
while read -r _ _ _ spec target; do
  (cd "$tmpdir/cwd" && HOLBUILD_CACHE=$tmpdir/worker "$HOLBUILD_BIN" --remote-cache "$remote_url" \
     exec-action "$spec" --cache-limit-gb 1000 --result "$tmpdir/result") > "$tmpdir/worker.log" 2>&1 ||
    { echo "worker failed on $target" >&2; cat "$tmpdir/worker.log" "$tmpdir/result" >&2; exit 1; }
  require_grep '^status=built$' "$tmpdir/result"
done < <(grep '^action ' "$tmpdir/batch.txt")
grep -q '^action .* worker:useTheory$' "$tmpdir/batch.txt" ||
  { echo "the batch has no action for worker:useTheory" >&2; cat "$tmpdir/batch.txt" >&2; exit 1; }
