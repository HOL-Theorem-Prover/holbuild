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

dep=$tmpdir/dep
project=$tmpdir/project
mkdir -p "$dep/src" "$project/src"

{
  write_schema2_prelude
  cat <<'TOML'
[project]
name = "dep"

[build]
members = ["src"]
TOML
} > "$dep/holproject.toml"
cat > "$dep/src/BaseScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Base";
val _ = new_constant ("magic", ``:bool``);
val magic_ax = new_axiom ("magic_ax", ``magic``);
val _ = export_theory();
SML
dep_rev=$(init_git_repo "$dep")

{
  write_schema2_prelude
  cat <<TOML
[project]
name = "consumer"

[build]
members = ["src"]

[dependencies.dep]
git = "$dep"
rev = "$dep_rev"
TOML
} > "$project/holproject.toml"
cat > "$project/src/CleanScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Clean";
Theorem clean_thm:
  T
Proof
  simp[]
QED
val _ = export_theory();
SML
cat > "$project/src/CheatScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Cheat";
Theorem fine_thm:
  T
Proof
  simp[]
QED
Theorem cheated_thm:
  F
Proof
  cheat
QED
val _ = export_theory();
SML
cat > "$project/src/UsesScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open BaseTheory;
val _ = new_theory "Uses";
Theorem uses_thm:
  magic
Proof
  ACCEPT_TAC magic_ax
QED
val _ = export_theory();
SML

# Expects the check of $1 to exit with status $2; leaves its output in $log.
run_check() {
  local selector=$1 expected=$2 status
  log=$tmpdir/check-${selector//:/-}.log
  set +e
  (cd "$project" && "$HOLBUILD_BIN" check "$selector") > "$log" 2>&1
  status=$?
  set -e
  if [[ $status -ne $expected ]]; then
    echo "check $selector exited $status, expected $expected" >&2
    cat "$log" >&2
    exit 1
  fi
}

require_no_grep() {
  local pattern=$1 path=$2
  if grep -q "$pattern" "$path"; then
    echo "unexpected pattern '$pattern' in $path" >&2
    cat "$path" >&2
    exit 1
  fi
}

# HOL's own axioms (bool's ETA_AX, SELECT_AX, ...) are not findings.
run_check CleanTheory 0
require_grep "CleanTheory built" "$log"
require_grep "^CleanTheory: clean (1 theorem)$" "$log"
require_no_grep "axiom" "$log"

run_check CheatTheory 1
require_grep "^CheatTheory.cheated_thm: cheat$" "$log"
require_grep "^CheatTheory: 1 finding$" "$log"
require_no_grep "fine_thm" "$log"

run_check CheatTheory:fine_thm 0
require_grep "^CheatTheory.fine_thm: clean (1 theorem)$" "$log"

run_check CheatTheory:cheated_thm 1
require_grep "^CheatTheory.cheated_thm: cheat$" "$log"

# Theorems loaded from disk do not record the axioms they use, so an axiom
# anywhere in the ancestry outside HOL is a finding, here in a dependency.
run_check UsesTheory 1
require_grep "^BaseTheory.magic_ax: axiom$" "$log"
require_grep "^UsesTheory: 1 finding$" "$log"

run_check CheatTheory:missing_thm 1
require_grep "holbuild: theorem not found: CheatTheory.missing_thm" "$log"

run_check MissingTheory 1
require_grep "holbuild: theory not found for check: MissingTheory" "$log"

run_check CheatTheory: 1
require_grep "holbuild: check requires THEORY or THEORY:THEOREM" "$log"

help_log=$tmpdir/help.log
"$HOLBUILD_BIN" check --help > "$help_log"
require_grep "holbuild \[GLOBAL OPTIONS\] check THEORY\[:THEOREM\]" "$help_log"
