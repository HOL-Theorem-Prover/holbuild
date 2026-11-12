#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
tmpdir=$(make_temp_dir)
trap 'rm -rf "$tmpdir"' EXIT

export HOLBUILD_PROCESS_TEST_DIR="$tmpdir"
"${HOLBUILD_POLY:-poly}" -q --error-exit --script "$SCRIPT_DIR/check.sml" \
  > "$tmpdir/check.log" 2>&1 || {
  cat "$tmpdir/check.log" >&2
  exit 1
}
require_grep "process-group cancellation tests passed" "$tmpdir/check.log"
