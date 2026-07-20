#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
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
name = "cache-timeout-discrepancy"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Theorem a_thm:
  T
Proof
  simp[]
QED
SML

metadata=$project/.holbuild/dep/cache-timeout-discrepancy/src/AScript.sml.key

weak_build_log=$tmpdir/weak-build.log
(cd "$project" && "$HOLBUILD_BIN" build --tactic-timeout 0 ATheory) > "$weak_build_log" 2>&1
require_grep "ATheory built" "$weak_build_log"
require_grep '^proof_timeout=none$' "$metadata"

rm -rf "$project/.holbuild"
restore_log=$tmpdir/restore.log
(cd "$project" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" build \
  --allow-cache-timeout-discrepancy --tactic-timeout 60 ATheory) > "$restore_log" 2>&1
require_grep "cache hit: ATheory" "$restore_log"
require_grep "ATheory restored from cache" "$restore_log"
require_grep '^proof_timeout=none$' "$metadata"

up_to_date_log=$tmpdir/up-to-date.log
(cd "$project" && "$HOLBUILD_BIN" --verbose build --emit-output-hashes \
  --allow-cache-timeout-discrepancy --tactic-timeout 60 ATheory) > "$up_to_date_log" 2>&1
require_grep "ATheory is up to date" "$up_to_date_log"
require_grep '^proof_timeout=none$' "$metadata"

strict_log=$tmpdir/strict.log
(cd "$project" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" build \
  --tactic-timeout 60 ATheory) > "$strict_log" 2>&1
require_grep "insufficient tactic-timeout contract" "$strict_log"
require_grep "ATheory built" "$strict_log"
require_grep '^proof_timeout=60.0$' "$metadata"
