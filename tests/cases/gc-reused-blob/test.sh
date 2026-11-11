#!/usr/bin/env bash
set -euo pipefail

_HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'rm -rf "$tmpdir"' EXIT

cache=$tmpdir/cache
mkdir -p "$cache/actions" "$cache/blobs" "$cache/tmp"
printf 'reused output\n' > "$tmpdir/output"
hash=$(sha256sum "$tmpdir/output" | cut -d' ' -f1)
cp "$tmpdir/output" "$cache/blobs/$hash"
touch -d '10 days ago' "$cache/blobs/$hash"

HOLBUILD_ROOT=${HOLBUILD_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)} \
HOLBUILD_CACHE="$cache" BLOB_HASH="$hash" BLOB_SRC="$tmpdir/output" \
  poly --script "$SCRIPT_DIR/race.sml" > "$tmpdir/race.log" 2>&1 ||
  { cat "$tmpdir/race.log" >&2; exit 1; }
require_grep "blob-kept" "$tmpdir/race.log"
