#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"
cd "$tmpdir"

cat > holproject.toml <<TOML
$(write_schema2_prelude)

[project]
name = "analyser-parse-error"

[build]
roots = ["AScript.sml"]
TOML

# The lone opening quote leaves no string body for HOL's dependency reader.
printf 'Theory A\nval _ = print "' > AScript.sml
status=0
"$HOLBUILD_BIN" build --dry-run ATheory > dry.log 2>&1 || status=$?
if [[ $status != 1 ]]; then
  cat dry.log >&2
  echo "expected exit 1 for the unclosed string, got $status" >&2
  exit 1
fi
require_grep 'AScript\.sml:2:15: parse error: unclosed string literal' dry.log

printf 'Theory A\nval _ = print ""\n' > AScript.sml
"$HOLBUILD_BIN" build --dry-run ATheory > dry.log 2>&1
require_grep 'ATheory' dry.log
