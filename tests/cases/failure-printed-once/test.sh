#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "failure-printed-once"

[build]
roots = ["AScript.sml"]
TOML
cat > "$project/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem bad_thm:
  F
Proof
  FAIL_TAC "failure printed once marker"
QED
val _ = export_theory();
SML

# A failed proof's diagnostic is printed once, on stderr, whatever -j picks
# (serial or parallel scheduler); the error at exit names it in one line.
# With stdout discarded, as callers that only read stderr do, nothing is lost.
for jobs in 1 2; do
  stderr=$tmpdir/stderr-$jobs.log
  status=0
  (cd "$project" && "$HOLBUILD_BIN" -j"$jobs" build ATheory) > /dev/null 2> "$stderr" || status=$?
  [[ $status -eq 1 ]] || { echo "-j$jobs: expected exit 1, got $status" >&2; cat "$stderr" >&2; exit 1; }
  for line in '^fragment: FAIL_TAC "failure printed once marker"$' '^plan position: ' '^child failure:$'; do
    [[ $(grep -c "$line" "$stderr") -eq 1 ]] ||
      { echo "-j$jobs: '$line' is not printed exactly once on stderr" >&2; cat "$stderr" >&2; exit 1; }
  done
  # The diagnostic starts on its own line after the theory's heading, so its
  # theorem line stands alone, as in a remote failure's diagnostic.
  grep -A1 "^ATheory failed:$" "$stderr" | grep -q "^theorem: bad_thm (line 3)$" ||
    { echo "-j$jobs: no 'ATheory failed:' heading before the theorem line" >&2; cat "$stderr" >&2; exit 1; }
  require_grep "^holbuild: theorem: bad_thm (line 3): .*failure printed once marker.* (full diagnostic above)$" "$stderr"
done
