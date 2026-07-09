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

project=$tmpdir/project
mkdir -p "$project/src"

cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "entry-timeouts"

[build]
members = ["src"]
roots = ["src/AScript.sml", "src/BScript.sml"]

[build.root_tactic_timeouts]
"src/AScript.sml" = 0.1
"src/BScript.sml" = 1.0
TOML

cat > "$project/src/DepScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Dep";
fun slow_tac g = (OS.Process.sleep (Time.fromReal 0.45); ACCEPT_TAC TRUTH g);
Theorem dep_slow:
  T
Proof
  slow_tac
QED
val _ = export_theory();
SML

cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open DepTheory;
val _ = new_theory "A";
Theorem a_thm:
  T
Proof
  ACCEPT_TAC DepTheory.dep_slow
QED
val _ = export_theory();
SML

cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open DepTheory;
val _ = new_theory "B";
Theorem b_thm:
  T
Proof
  ACCEPT_TAC DepTheory.dep_slow
QED
val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/context.log"
require_grep "root tactic_timeout: src/AScript.sml = 0.1" "$tmpdir/context.log"
require_grep "root tactic_timeout: src/BScript.sml = 1" "$tmpdir/context.log"

if (cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/b.log" 2>&1; then
  echo "direct BTheory build ignored stricter entry point reaching shared dependency" >&2
  exit 1
fi
require_grep "tactic timed out after 0.1s while building DepTheory: slow_tac" "$tmpdir/b.log"

(cd "$project" && "$HOLBUILD_BIN" build --tactic-timeout 1.0 BTheory) > "$tmpdir/b-cli.log" 2>&1
require_file "$project/.holbuild/obj/src/DepTheory.dat"
require_file "$project/.holbuild/obj/src/BTheory.dat"
require_grep "proof_timeout=1.0" "$project/.holbuild/dep/entry-timeouts/src/DepScript.sml.key"

if (cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/b-after-cli.log" 2>&1; then
  echo "lax cached success satisfied stricter entry-point timeout" >&2
  exit 1
fi
require_grep "tactic timed out after 0.1s while building DepTheory: slow_tac" "$tmpdir/b-after-cli.log"

(cd "$project" && "$HOLBUILD_BIN" build --tactic-timeout 1.0 ATheory BTheory) > "$tmpdir/cli-override.log" 2>&1
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_file "$project/.holbuild/obj/src/BTheory.dat"

root_groups_project=$tmpdir/root-groups
mkdir -p "$root_groups_project/gen"
cat > "$root_groups_project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "root-groups-timeout"

[build]
members = ["gen"]
root_groups = ["generated"]
tactic_timeout = 1.0

[build.groups.generated]
include_globs = ["gen/*Script.sml"]

[build.root_tactic_timeouts]
"gen/GroupScript.sml" = 0.1
TOML

cat > "$root_groups_project/gen/GroupScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Group";
fun slow_tac g = (OS.Process.sleep (Time.fromReal 0.45); ACCEPT_TAC TRUTH g);
Theorem group_slow:
  T
Proof
  slow_tac
QED
val _ = export_theory();
SML

if (cd "$root_groups_project" && "$HOLBUILD_BIN" build) > "$tmpdir/root-groups.log" 2>&1; then
  echo "root_groups default build ignored root_tactic_timeouts" >&2
  exit 1
fi
require_grep "tactic timed out after 0.1s while building GroupTheory: slow_tac" "$tmpdir/root-groups.log"

roots_group_project=$tmpdir/roots-group
mkdir -p "$roots_group_project/gen"
cat > "$roots_group_project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "roots-group-timeout"

[build]
members = ["gen"]
roots = ["@generated"]
tactic_timeout = 1.0

[build.groups.generated]
include_globs = ["gen/*Script.sml"]

[build.root_tactic_timeouts]
"gen/BetaScript.sml" = 0.1
TOML

cat > "$roots_group_project/gen/AlphaScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Alpha";
Theorem alpha_fast:
  T
Proof
  simp[]
QED
val _ = export_theory();
SML

cat > "$roots_group_project/gen/BetaScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Beta";
fun slow_tac g = (OS.Process.sleep (Time.fromReal 0.45); ACCEPT_TAC TRUTH g);
Theorem beta_slow:
  T
Proof
  slow_tac
QED
val _ = export_theory();
SML

if (cd "$roots_group_project" && "$HOLBUILD_BIN" build) > "$tmpdir/roots-group.log" 2>&1; then
  echo "roots @group build ignored grouped root_tactic_timeouts" >&2
  exit 1
fi
require_grep "tactic timed out after 0.1s while building BetaTheory: slow_tac" "$tmpdir/roots-group.log"
