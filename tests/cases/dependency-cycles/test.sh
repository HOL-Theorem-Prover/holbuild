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

expect_build_failure() {
  local project=$1
  local target=$2
  local pattern=$3
  local log=$tmpdir/$project.log
  if (cd "$tmpdir/$project" && "$HOLBUILD_BIN" build --dry-run "$target") > "$log" 2>&1; then
    echo "dependency cycle unexpectedly accepted: $project" >&2
    exit 1
  fi
  require_grep "$pattern" "$log"
}

make_project() {
  local project=$1
  mkdir -p "$tmpdir/$project/src"
  cat > "$tmpdir/$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "cycles"

[build]
members = ["src"]
TOML
}

make_project sml_cycle
cat > "$tmpdir/sml_cycle/src/A.sml" <<'SML'
load "B";
structure A = struct val x = B.x end
SML
cat > "$tmpdir/sml_cycle/src/B.sml" <<'SML'
load "A";
structure B = struct val x = A.x end
SML
expect_build_failure sml_cycle A "dependency cycle: A -> B -> A"

make_project theory_cycle
cat > "$tmpdir/theory_cycle/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open BTheory;
val _ = new_theory "A";
val _ = export_theory();
SML
cat > "$tmpdir/theory_cycle/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open ATheory;
val _ = new_theory "B";
val _ = export_theory();
SML
expect_build_failure theory_cycle ATheory "dependency cycle: ATheory -> BTheory -> ATheory"

make_project mixed_cycle
cat > "$tmpdir/mixed_cycle/src/A.sml" <<'SML'
structure A = struct
  val name = BTheory.grammars
end
SML
cat > "$tmpdir/mixed_cycle/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
load "A";
val _ = new_theory "B";
val _ = export_theory();
SML
expect_build_failure mixed_cycle BTheory "dependency cycle: BTheory -> A -> BTheory"

make_project unresolved_load
cat > "$tmpdir/unresolved_load/src/A.sml" <<'SML'
load "Missing";
structure A = struct val x = 1 end
SML
expect_build_failure unresolved_load A "unresolved load Missing in cycles:src/A.sml"

make_project unsupported_use
cat > "$tmpdir/unsupported_use/src/A.sml" <<'SML'
use "other.sml";
structure A = struct val x = 1 end
SML
expect_build_failure unsupported_use A "unsupported use other.sml in cycles:src/A.sml"
