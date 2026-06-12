#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

write_project() {
  local project=$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "cache-cross-artifact-root"

[build]
members = ["src"]
TOML
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
  cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib ATheory;
val _ = new_theory "B";
Theorem b_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
}

first=$tmpdir/first
second=$tmpdir/second
write_project "$first"
cp -R "$first" "$second"

first_log=$tmpdir/first.log
(cd "$first" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" build BTheory) > "$first_log" 2>&1
require_grep "ATheory built" "$first_log"
require_grep "BTheory built" "$first_log"

second_log=$tmpdir/second.log
(cd "$second" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" build BTheory) > "$second_log" 2>&1
require_grep "cache hit: ATheory source/dependency key=" "$second_log"
require_grep "cache hit: BTheory parent-output key=" "$second_log"
require_grep "ATheory restored from cache" "$second_log"
require_grep "BTheory restored from cache" "$second_log"
if grep -q "built" "$second_log"; then
  echo "second build rebuilt instead of restoring entirely from cache" >&2
  cat "$second_log" >&2
  exit 1
fi
if grep -q "cache miss:" "$second_log"; then
  echo "second build had cache misses" >&2
  cat "$second_log" >&2
  exit 1
fi
if grep -q "path-dependent" "$second_log"; then
  echo "second build needed path-dependent cache key for path-independent sources" >&2
  cat "$second_log" >&2
  exit 1
fi
