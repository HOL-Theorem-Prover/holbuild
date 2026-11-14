#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# holbuild's own runtime starts with a 128 MB heap floor (sml/driver_main.c),
# which the Poly/ML runtime reports in its heap-size log.
heap_minimum() {
  local log=$tmpdir/heap-$1.log
  shift
  "$HOLBUILD_BIN" --debug heapsize --logfile "$log" "$@" --version > /dev/null
  sed -n 's/.*Initial heap .* minimum \([^ ]*\) maximum.*/\1/p' "$log"
}

minimum=$(heap_minimum default)
[ "$minimum" = 128.00M ] || {
  echo "expected holbuild's heap floor to be 128.00M, got '$minimum'" >&2
  exit 1
}

# A --minheap the user gives still wins over the floor.
minimum=$(heap_minimum user --minheap=256)
[ "$minimum" = 256.00M ] || {
  echo "expected --minheap=256 to set the floor to 256.00M, got '$minimum'" >&2
  exit 1
}
