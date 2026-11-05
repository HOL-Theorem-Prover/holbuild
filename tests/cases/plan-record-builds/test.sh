#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# Builds that plan from the plan record behave as builds that plan in full:
# they rebuild what the cache lacks, honour --force, warn about unreachable
# roots and apply tactic timeouts. Builds run in check mode.

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"
export HOLBUILD_PLAN_RECORD=check

hol_rev=$(holbuild_pinned_hol_rev)

make_project() {
  local dir=$1 extra=${2:-}
  mkdir -p "$dir/src"
  cat > "$dir/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$hol_rev"

[project]
name = "record_builds"

[build]
members = ["src"]
$extra
TOML
  cat > "$dir/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
  cat > "$dir/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open ATheory;
val _ = new_theory "B";
val b_thm = store_thm("b_thm", ``T``, ACCEPT_TAC ATheory.a_thm);
val _ = export_theory();
SML
  sleep 1.1
}

# Builds in DIR with ARGS into LOG; prints the line saying how it planned.
build() {
  local dir=$1 log=$2
  shift 2
  if ! (cd "$dir" && "$HOLBUILD_BIN" --verbose build "$@") > "$log" 2>&1; then
    cat "$log" >&2
    echo "build $* failed in $dir" >&2
    exit 1
  fi
  grep -m1 '^holbuild: plan: ' "$log" | sed 's/^holbuild: plan: //'
}

expect_build() {
  local expected=$1 dir=$2 log=$3
  shift 3
  local got
  got=$(build "$dir" "$log" "$@")
  if [[ "$got" != "$expected"* ]]; then
    echo "$dir: expected plan '$expected', got '$got'" >&2
    exit 1
  fi
}

require_no_grep() {
  local pattern=$1 path=$2
  if grep -q "$pattern" "$path"; then
    echo "unexpected pattern '$pattern' in $path" >&2
    exit 1
  fi
}

cache_miss_and_force() {
  local p=$tmpdir/builds
  make_project "$p"
  expect_build "full (no plan record" "$p" "$tmpdir/first.log"
  # An edit the cache has never seen: both theories rebuild from the record.
  printf '\n(* edited *)\n' >> "$p/src/AScript.sml"
  expect_build "from record (1 files rehashed, 2 keys changed)" "$p" "$tmpdir/edit.log"
  require_no_grep "ATheory is up to date" "$tmpdir/edit.log"
  require_no_grep "BTheory is up to date" "$tmpdir/edit.log"
  require_grep "BTheory" "$tmpdir/edit.log"
  expect_build "from record" "$p" "$tmpdir/noop.log"
  require_grep "BTheory is up to date" "$tmpdir/noop.log"
  # A theory whose key came from the record, missing from every cache.
  rm -rf "$tmpdir/cache/actions" "$p/.holbuild/obj/src/BTheory".* "$p/.holbuild/dep/record_builds/src/BScript.sml".*
  expect_build "from record (0 files rehashed, 0 keys changed)" "$p" "$tmpdir/miss.log"
  require_no_grep "BTheory is up to date" "$tmpdir/miss.log"
  require_no_grep "BTheory restored from cache" "$tmpdir/miss.log"
  require_file "$p/.holbuild/obj/src/BTheory.dat"
  expect_build "full (no plan record" "$p" "$tmpdir/force1.log" --force
  expect_build "from record" "$p" "$tmpdir/force2.log" --force
  require_no_grep "BTheory is up to date" "$tmpdir/force2.log"
  require_no_grep "BTheory restored from cache" "$tmpdir/force2.log"
}

warn_unreachable() {
  local p=$tmpdir/unreachable
  make_project "$p" 'roots = ["src/AScript.sml"]'
  expect_build "full (no plan record" "$p" "$tmpdir/unreachable1.log" --dry-run --warn-unreachable
  expect_build "from record" "$p" "$tmpdir/unreachable2.log" --dry-run --warn-unreachable
  for log in unreachable1 unreachable2; do
    require_grep "unreachable: record_builds:src/BScript.sml (BTheory)" "$tmpdir/$log.log"
  done
}

tactic_timeouts() {
  local p=$tmpdir/timeouts
  make_project "$p" '
[build.theory_tactic_timeouts]
"src/BScript.sml" = 7.0'
  expect_build "full (no plan record" "$p" "$tmpdir/timeout1.log"
  printf '\n(* edited *)\n' >> "$p/src/AScript.sml"
  expect_build "from record" "$p" "$tmpdir/timeout2.log"
  require_grep "proof_timeout=7.0" "$p/.holbuild/dep/record_builds/src/BScript.sml.key"
}

root_tactic_timeouts() {
  local p=$tmpdir/root-timeouts
  make_project "$p" 'roots = ["src/BScript.sml"]

[build.root_tactic_timeouts]
"src/BScript.sml" = 1.0'
  expect_build "full (no plan record" "$p" "$tmpdir/root-timeout1.log"
  printf '\n(* edited *)\n' >> "$p/src/AScript.sml"
  expect_build "from record (1 files rehashed, 2 keys changed)" "$p" "$tmpdir/root-timeout2.log"
  # Under the default of 2.5 s, the root's own timeout covers its closure.
  require_grep "proof_timeout=1.0" "$p/.holbuild/dep/record_builds/src/AScript.sml.key"
  # A target that leaves out the root plans in full: the root's closure
  # gives the target its timeout.
  expect_build "full (no plan record" "$p" "$tmpdir/root-timeout3.log" --dry-run ATheory
  expect_build "full (a root with its own tactic timeout is not selected)" "$p" "$tmpdir/root-timeout4.log" --dry-run ATheory
}

# A theory may write an SML source that another action names as an input;
# the source exists only once that theory has run.
generated_extra_input() {
  local p=$tmpdir/generated
  make_project "$p" '
[actions.UseTheory]
deps = ["GenTheory"]
extra_inputs = ["src/GenML.sml"]'
  cat > "$p/src/GenScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Gen";
fun holbuild_extra_outputs (_ : string list) = ();
val () = holbuild_extra_outputs ["GenML.sml"];
val () = let val out = TextIO.openOut "GenML.sml"
         in TextIO.output (out, "structure GenML = struct val x = 42 end\n"); TextIO.closeOut out end;
val _ = export_theory();
SML
  cat > "$p/src/UseScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Use";
val _ = export_theory();
SML
  expect_build "full (no plan record" "$p" "$tmpdir/generated1.log"
  require_grep "plan record not written: theories write SML sources" "$tmpdir/generated1.log"
  require_file "$p/src/GenML.sml"
}

# A generator that runs for BTheory's declared input rewrites a file
# ATheory, planned first, hashed through its directory: BTheory's key comes
# from the new content, so the next plan gives it the same key.
generator_rewrites_input() {
  local p=$tmpdir/generator
  make_project "$p" '
[actions.ATheory]
extra_inputs = ["data"]

[actions.BTheory]
extra_inputs = ["data/g.txt"]

[[generate]]
name = "copy"
command = ["cp", "in.txt", "data/g.txt"]
inputs = ["in.txt"]
outputs = ["data/g.txt"]'
  cat > "$p/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "B";
val _ = export_theory();
SML
  mkdir -p "$p/data"
  echo one > "$p/in.txt"
  build "$p" "$tmpdir/generator1.log" > /dev/null
  echo two > "$p/in.txt"
  build "$p" "$tmpdir/generator2.log" > /dev/null
  require_grep two "$p/data/g.txt"
  cp "$p/.holbuild/dep/record_builds/src/BScript.sml.key" "$tmpdir/generator2.key"
  build "$p" "$tmpdir/generator3.log" > /dev/null
  if ! cmp -s "$tmpdir/generator2.key" "$p/.holbuild/dep/record_builds/src/BScript.sml.key"; then
    echo "a generated input got a key from its old content" >&2
    exit 1
  fi
}

cache_miss_and_force
warn_unreachable
tactic_timeouts
root_tactic_timeouts
generated_extra_input
generator_rewrites_input
