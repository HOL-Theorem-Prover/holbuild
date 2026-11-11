#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"
classify="$HOLBUILD_ROOT/tools/release-breaking.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.org
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.org
cd "$tmpdir"
git init -q
mkdir -p tests/golden/key-dumps
echo key-1 > tests/golden/key-dumps/fixture.keys
git add . && git commit -qm base && git tag v1

expect() {
  local want=$1 base=$2 tag=$3 pattern=$4 status=0 output
  output=$("$classify" "$base" "$tag") || status=$?
  if [[ $status -ne $want ]] || ! grep -q -- "$pattern" <<< "$output"; then
    echo "release-breaking $base $tag: exit $status (want $want), output:" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

echo change > other && git add other && git commit -qm "Fix a bug" && git tag v2
expect 0 v1 v2 '^$'

echo key-2 > tests/golden/key-dumps/fixture.keys
git commit -qam "Change cache keys" && git tag v3
expect 1 v1 v3 'cache keys changed'
expect 0 v3 v3 '^$'

echo more >> other
git commit -qam "Change the export default" -m "Breaking-change: export writes a source capsule by default" && git tag v4
expect 1 v3 v4 '^Breaking-change: export writes a source capsule by default$'
# Measured from the last published release, later tags carry earlier breaks.
expect 1 v1 v4 'cache keys changed'
expect 1 v1 v4 '^Breaking-change: export'
