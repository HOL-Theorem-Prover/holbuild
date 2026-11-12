#!/usr/bin/env bash
# Usage: tools/release-key-inventory.sh OLD_HOLBUILD NEW_HOLBUILD [ACTION-SPEC ARGUMENT...]
#
# Run in a scratch checkout of a consumer project, with its remote cache
# configured as for its builds.  Plans the project with `action-spec` under
# both holbuild binaries (no theory is built) and lists the theories whose
# cached results OLD restores but NEW can't: a cache-key change the golden
# key dump missed.  Theories neither release can restore yet are ignored.
# Exits 1 only when it lists any; command errors exit at least 2.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 OLD_HOLBUILD NEW_HOLBUILD [ACTION-SPEC ARGUMENT...]" >&2
  exit 2
fi
old=$1
new=$2
shift 2

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$old" action-spec "$@" > "$tmp/old.batch" || {
  status=$?
  [[ $status -ne 1 ]] || status=2
  exit "$status"
}
"$new" action-spec "$@" > "$tmp/new.batch" || {
  status=$?
  [[ $status -ne 1 ]] || status=2
  exit "$status"
}
# Batch lines: action <input_key> <ac-key> <spec-sha256> <package>:<logical>
awk '$1 == "action" { print $5 }' "$tmp/old.batch" | sort -u > "$tmp/old"
awk '$1 == "action" { print $5 }' "$tmp/new.batch" | sort -u > "$tmp/new"
comm -13 "$tmp/old" "$tmp/new" > "$tmp/lost"

lost=$(wc -l < "$tmp/lost" | tr -d ' ')
echo "uncached with $old: $(wc -l < "$tmp/old" | tr -d ' ')"
echo "uncached with $new: $(wc -l < "$tmp/new" | tr -d ' ')"
if [[ "$lost" -ne 0 ]]; then
  echo "$lost theories restore with $old but not with $new:"
  cat "$tmp/lost"
  exit 1
fi
echo "no theory restorable with $old is lost with $new"
