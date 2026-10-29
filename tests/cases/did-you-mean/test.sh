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

# The ranking on its own: nearest first, ties in string order, case ignored,
# at most three, nothing for a far miss or for the name itself.
cat > "$tmpdir/suggest-test.sml" <<'SML'
val _ = OS.FileSys.chDir (valOf (OS.Process.getEnv "HOLBUILD_ROOT"));
use "sml/suggest.sml";
fun show label names = print (label ^ ": [" ^ String.concatWith "," names ^ "]\n");
val _ = show "tie" (HolbuildSuggest.nearest "fooThm" ["fpoThm", "fooThn", "faoThm", "foxThm", "fooThm"]);
val _ = show "ranked" (HolbuildSuggest.nearest "abcdefgh" ["abcdefaa", "abcdefgz", "abcdxxxx"]);
val _ = show "case" (HolbuildSuggest.nearest "length_append" ["LENGTH_APPEND", "length_appendx"]);
val _ = show "far" (HolbuildSuggest.nearest "zzzzzz" ["build", "buildhol", "run"]);
SML
"${HOLBUILD_POLY:-poly}" < "$tmpdir/suggest-test.sml" > "$tmpdir/suggest-test.log" 2>&1 || {
  cat "$tmpdir/suggest-test.log" >&2
  exit 1
}
require_grep "^tie: \[faoThm,fooThn,foxThm\]$" "$tmpdir/suggest-test.log"
require_grep "^ranked: \[abcdefgz,abcdefaa\]$" "$tmpdir/suggest-test.log"
require_grep "^case: \[LENGTH_APPEND,length_appendx\]$" "$tmpdir/suggest-test.log"
require_grep "^far: \[\]$" "$tmpdir/suggest-test.log"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "did-you-mean"

[build]
members = ["src"]

[[heap]]
name = "main"
output = ".holbuild/heap/main.save"
objects = ["AlphaTheory"]

[[executable]]
name = "runtests"
output = "runtests.exe"
objects = ["runtests"]
TOML
for name in Alpha Alphb Gamma; do
  cat > "$project/src/${name}Script.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "$name";
Theorem truth_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
Definition count_down_def:
  count_down n = if n = 0 then 0 else count_down (n - 1)
Termination
  WF_REL_TAC `measure I` >> simp[]
End
val _ = export_theory();
SML
done

# Runs holbuild in the project, expecting it to fail; the log is $tmpdir/$1.log.
expect_failure() {
  local name=$1
  shift
  if (cd "$project" && "$HOLBUILD_BIN" "$@") > "$tmpdir/$name.log" 2>&1; then
    echo "holbuild $* unexpectedly succeeded" >&2
    exit 1
  fi
}

expect_failure near GammaTheroy
require_grep "^holbuild: unknown build target: GammaTheroy$" "$tmpdir/near.log"
require_grep "^did you mean GammaTheory?$" "$tmpdir/near.log"

expect_failure tie AlphcTheory
require_grep "^did you mean AlphaTheory, AlphbTheory?$" "$tmpdir/tie.log"

expect_failure far Zebra
require_grep "^holbuild: unknown build target: Zebra$" "$tmpdir/far.log"
if grep -q "did you mean" "$tmpdir/far.log"; then
  echo "far miss got a suggestion" >&2
  exit 1
fi

# A mistyped command falls through to build as a target.
expect_failure command biuld
require_grep "^holbuild: unknown build target: biuld$" "$tmpdir/command.log"
require_grep "^did you mean build?$" "$tmpdir/command.log"

expect_failure command-help biuld --help
require_grep "^holbuild: unknown command: biuld$" "$tmpdir/command-help.log"
require_grep "^did you mean build?$" "$tmpdir/command-help.log"

expect_failure cache cache gcc
require_grep "^did you mean gc?$" "$tmpdir/cache.log"

expect_failure heap heap mian
require_grep "^holbuild: unknown heap target: mian$" "$tmpdir/heap.log"
require_grep "^did you mean main?$" "$tmpdir/heap.log"

# Only names of the command's own kind are suggested.
expect_failure executable executable runtest
require_grep "^holbuild: unknown executable target: runtest$" "$tmpdir/executable.log"
require_grep "^did you mean runtests?$" "$tmpdir/executable.log"
expect_failure heap-kind heap runtest
require_grep "^holbuild: unknown heap target: runtest$" "$tmpdir/heap-kind.log"
if grep -q "did you mean" "$tmpdir/heap-kind.log"; then
  echo "heap suggested an executable" >&2
  exit 1
fi

expect_failure plan-theory execution-plan GamaTheory:truth_thm
require_grep "^holbuild: theory not found for execution-plan: GamaTheory$" "$tmpdir/plan-theory.log"
require_grep "^did you mean GammaTheory?$" "$tmpdir/plan-theory.log"

expect_failure plan-theorem execution-plan GammaTheory:truth_thn
require_grep "^holbuild: proof unit not found for execution-plan: GammaTheory:truth_thn$" "$tmpdir/plan-theorem.log"
require_grep "^did you mean truth_thm?$" "$tmpdir/plan-theorem.log"

expect_failure plan-termination execution-plan GammaTheory:count_dwn_def
require_grep "^did you mean count_down_def?$" "$tmpdir/plan-termination.log"
