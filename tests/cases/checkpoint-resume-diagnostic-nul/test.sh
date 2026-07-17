#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "checkpoint-resume-diagnostic-nul"

[build]
members = ["src"]
roots = ["src/PureReproScript.sml"]
tactic_timeout = 180.0
TOML
cp "$SCRIPT_DIR/PureReproScript.sml" "$project/src/PureReproScript.sml"

check_no_nul() {
  python3 - "$@" <<'PY'
from pathlib import Path
import sys

for name in sys.argv[1:]:
    path = Path(name)
    data = path.read_bytes()
    count = data.count(b"\0")
    if count:
        first = data.index(b"\0")
        excerpt = data[max(0, first - 80):first + 120]
        raise SystemExit(
            f"raw NUL bytes in {path}: count={count}, first={first}, excerpt={excerpt!r}"
        )
PY
}

run_expect_failure() {
  local output=$1
  if (cd "$project" && "$HOLBUILD_BIN" -j1 build PureReproTheory) > "$output" 2>&1; then
    echo "NUL diagnostic fixture unexpectedly succeeded" >&2
    exit 1
  fi
  require_grep "failed tactic top input goal:" "$output"
  check_no_nul "$output"
}

first_log=$tmpdir/run-1.bin
run_expect_failure "$first_log"

failure_log="$project/.holbuild/logs/current/checkpoint-resume-diagnostic-nul/PureReproTheory/instrumented-failure.log"
require_file "$failure_log"
check_no_nul "$failure_log"

# Re-enter the failure through retained checkpoint state several times.  The
# original bug was timing/layout-sensitive and appeared in the summarized
# parent diagnostic even though the retained child log remained clean.
for attempt in 2 3 4 5; do
  output=$tmpdir/run-$attempt.bin
  run_expect_failure "$output"
  require_grep "resuming PureReproTheory" "$output"
  require_file "$failure_log"
  check_no_nul "$failure_log"
done
