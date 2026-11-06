#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"
project=$tmpdir/project
mkdir -p "$project"
cat > "$project/holproject.toml" <<TOML
[project]
name = "resume-failure"
[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"
[build]
roots = ["AScript.sml"]
TOML

write_script() {
  local tactic=$1
  cat > "$project/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib markerLib;
val _ = new_theory "A";
(* A controlled instrumentation-only failure, independent of tactic ABI. *)
fun only_plain () =
  case #lookupVal PolyML.globalNameSpace "holbuild_begin_theorem" of
      NONE => ACCEPT_TAC TRUTH
    | SOME _ => FAIL_TAC "instrumented Resume failure";
Theorem partial:
  T /\\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >- suspend "right"
QED
Resume partial[right]:
  $tactic
QED
Finalise partial
val _ = export_theory();
SML
}

log_dir=$project/.holbuild/logs/current/resume-failure/ATheory
failure_log=$log_dir/instrumented-failure.log
write_script 'only_plain ()'
(cd "$project" && "$HOLBUILD_BIN" build --skip-proof-steps ATheory) > "$tmpdir/plain.log" 2>&1
require_grep 'ATheory built' "$tmpdir/plain.log"
if (cd "$project" && "$HOLBUILD_BIN" build --force=theory ATheory) > "$tmpdir/instrumented.log" 2>&1; then
  echo 'instrumentation-only Resume failure was accepted' >&2
  exit 1
fi
require_grep 'instrumented Resume failure' "$tmpdir/instrumented.log"
require_grep 'partial\[right\]' "$tmpdir/instrumented.log"
require_file "$failure_log"

write_script 'ALL_TAC >> FAIL_TAC "outright Resume failure"'
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/outright.log" 2>&1; then
  echo 'outright Resume failure was accepted' >&2
  exit 1
fi
require_grep 'outright Resume failure' "$tmpdir/outright.log"
require_grep 'partial\[right\]' "$tmpdir/outright.log"
require_grep 'outright Resume failure' "$failure_log"

write_script 'ALL_TAC >> ACCEPT_TAC TRUTH'
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/fixed.log" 2>&1
require_grep 'from: failed-prefix checkpoint in partial_right_' "$tmpdir/fixed.log"
require_grep 'ATheory built' "$tmpdir/fixed.log"
require_no_file "$failure_log"
