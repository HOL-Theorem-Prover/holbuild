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
export HOLBUILD_FORCE_COUNTER_DIR="$tmpdir/counters"
mkdir -p "$HOLBUILD_FORCE_COUNTER_DIR"

count_file() {
  local name=$1
  local path="$HOLBUILD_FORCE_COUNTER_DIR/$name"
  [[ -f "$path" ]] || { echo 0; return; }
  wc -c < "$path" | tr -d ' '
}

require_counts() {
  local c=$1 b=$2 a=$3 label=$4
  [[ "$(count_file C)" = "$c" ]] || { echo "$label: expected C count $c, got $(count_file C)" >&2; exit 1; }
  [[ "$(count_file B)" = "$b" ]] || { echo "$label: expected B count $b, got $(count_file B)" >&2; exit 1; }
  [[ "$(count_file A)" = "$a" ]] || { echo "$label: expected A count $a, got $(count_file A)" >&2; exit 1; }
}

dep=$tmpdir/dep
project=$tmpdir/project
mkdir -p "$dep/src" "$project/src"
export HOLBUILD_FORCE_DEP="$dep"

cat > "$dep/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "dep"

[build]
members = ["src"]

[actions.CTheory]
cache = false
TOML
cat > "$dep/src/CScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
fun bump name =
  case OS.Process.getEnv "HOLBUILD_FORCE_COUNTER_DIR" of
      SOME dir =>
        let val out = TextIO.openAppend (OS.Path.concat(dir, name))
        in TextIO.output(out, "x"); TextIO.closeOut out end
    | NONE => raise Fail "missing HOLBUILD_FORCE_COUNTER_DIR";
val _ = bump "C";
val _ = new_theory "C";
val c_thm = store_thm("c_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML

dep_rev=$(init_git_repo "$dep")
{
  write_schema2_prelude
  cat <<TOML
[project]
name = "force-levels"

[build]
members = ["src"]

[dependencies.dep]
git = "$dep"
rev = "$dep_rev"

[actions.ATheory]
cache = false

[actions.BTheory]
cache = false
TOML
} > "$project/holproject.toml"
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open CTheory;
fun bump name =
  case OS.Process.getEnv "HOLBUILD_FORCE_COUNTER_DIR" of
      SOME dir =>
        let val out = TextIO.openAppend (OS.Path.concat(dir, name))
        in TextIO.output(out, "x"); TextIO.closeOut out end
    | NONE => raise Fail "missing HOLBUILD_FORCE_COUNTER_DIR";
val _ = bump "B";
val _ = new_theory "B";
val b_thm = store_thm("b_thm", ``T``, ACCEPT_TAC CTheory.c_thm);
val _ = export_theory();
SML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open BTheory;
fun bump name =
  case OS.Process.getEnv "HOLBUILD_FORCE_COUNTER_DIR" of
      SOME dir =>
        let val out = TextIO.openAppend (OS.Path.concat(dir, name))
        in TextIO.output(out, "x"); TextIO.closeOut out end
    | NONE => raise Fail "missing HOLBUILD_FORCE_COUNTER_DIR";
val _ = bump "A";
val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC BTheory.b_thm);
val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/initial.log" 2>&1
require_counts 1 1 1 initial

(cd "$project" && "$HOLBUILD_BIN" build --force=theory ATheory) > "$tmpdir/force-theory.log" 2>&1
require_counts 1 1 2 force-theory
require_grep "ATheory built" "$tmpdir/force-theory.log"

(cd "$project" && "$HOLBUILD_BIN" build --force-project ATheory) > "$tmpdir/force-project.log" 2>&1
require_counts 1 2 3 force-project
require_grep "BTheory built" "$tmpdir/force-project.log"
require_grep "ATheory built" "$tmpdir/force-project.log"

(cd "$project" && "$HOLBUILD_BIN" build --force=full ATheory) > "$tmpdir/force-full.log" 2>&1
require_counts 2 3 4 force-full
require_grep "CTheory built" "$tmpdir/force-full.log"
require_grep "BTheory built" "$tmpdir/force-full.log"
require_grep "ATheory built" "$tmpdir/force-full.log"

(cd "$project" && "$HOLBUILD_BIN" build --force ATheory) > "$tmpdir/bare-force.log" 2>&1
require_counts 3 4 5 bare-force
