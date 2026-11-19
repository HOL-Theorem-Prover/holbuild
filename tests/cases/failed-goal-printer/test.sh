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
name = "failed-goal-printer"

[build]
members = ["src"]
roots = ["src/GoalPrintScript.sml"]
tactic_timeout = 180.0
TOML
cp "$SCRIPT_DIR/GoalPrintScript.sml" "$project/src/GoalPrintScript.sml"

output=$tmpdir/build.log
if (cd "$project" && "$HOLBUILD_BIN" -j1 build GoalPrintTheory) > "$output" 2>&1; then
  echo "goal printer fixture unexpectedly succeeded" >&2
  exit 1
fi
instrumented_log=$(awk -F'instrumented log: ' '/instrumented log: / {print $2}' "$output" | tail -n 1)
require_file "$instrumented_log"

# holbuild prints the failed step's goal through its cached term printer; it
# must match what HOL's own printer gave for the same goal byte for byte.
python3 - "$instrumented_log" <<'PY'
import sys

text = open(sys.argv[1], encoding="utf-8").read()

def between(start, end):
    if start not in text:
        raise SystemExit(f"missing {start!r} in {sys.argv[1]}")
    rest = text.split(start, 1)[1]
    if end not in rest:
        raise SystemExit(f"missing {end!r} in {sys.argv[1]}")
    return rest.split(end, 1)[0]

expected = between("expected goal:\n", "\nexpected goal end\n")
printed = between("holbuild failed tactic top input goal:\n",
                  "holbuild end failed tactic top input goal\n")
if "FLD:" not in expected or "0.  " not in expected:
    raise SystemExit("fixture goal lost its user-printed field or assumptions:\n" + expected)
if printed != expected + "\n":
    raise SystemExit("holbuild's goal differs from HOL's printer:\n--- HOL\n" + expected +
                     "\n--- holbuild\n" + printed)
PY
