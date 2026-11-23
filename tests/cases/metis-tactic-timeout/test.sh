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
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "metis-timeout"

[build]
members = ["src"]
tactic_timeout = 0.2
TOML

# Steps naming metis get 5 s even though the project's timeout is 0.2 s.
cat > "$project/src/MetisScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Metis";
fun sleep_tac seconds g = (OS.Process.sleep (Time.fromReal seconds); ACCEPT_TAC TRUTH g);
structure X = struct
  fun metis_tac _ = sleep_tac 3.0;
  val METIS_TAC = metis_tac;
  val Z3_TAC = ALL_TAC;
end;
structure Nested = struct structure M = X; end;
(* Other work in the same opaque leaf shares the longer budget. *)
Theorem mixed: T
Proof
  (fn g => (sleep_tac 3.0 g; bossLib.metis_tac [] g))
QED
open X;
Theorem bare: T
Proof
  metis_tac []
QED
Theorem qualified: T
Proof
  X.metis_tac []
QED
Theorem reexported: T
Proof
  Nested.M.METIS_TAC []
QED
(* An SMT call anywhere in the step leaves it untimed, metis or not. *)
Theorem smt_wins: T
Proof
  (fn g => (ignore X.metis_tac; ignore X.Z3_TAC; sleep_tac 5.5 g))
QED
val _ = export_theory();
SML
(cd "$project" && "$HOLBUILD_BIN" build MetisTheory) > "$tmpdir/metis.log" 2>&1 ||
  { cat "$tmpdir/metis.log" >&2; exit 1; }
require_file "$project/.holbuild/obj/src/MetisTheory.dat"
require_grep 'proof_timeout=0.2' "$project/.holbuild/dep/metis-timeout/src/MetisScript.sml.key"

check_timeout() {
  local name=$1 limit=$2 tactic=$3
  cat > "$project/src/SlowScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Slow";
fun sleep_tac seconds g = (OS.Process.sleep (Time.fromReal seconds); ACCEPT_TAC TRUTH g);
val slow_tac = sleep_tac 0.65;
val metis_tac_slow = slow_tac;
structure X = struct fun metis_tac _ = ALL_TAC; end;
Theorem slow: T
Proof
  $tactic
QED
val _ = export_theory();
SML
  if (cd "$project" && "$HOLBUILD_BIN" build --no-cache --force=full --skip-checkpoints SlowTheory) > "$tmpdir/$name.log" 2>&1; then
    echo "step escaped its ${limit}s budget: $name" >&2
    exit 1
  fi
  require_grep "tactic timed out after ${limit}s while building SlowTheory" "$tmpdir/$name.log"
}
check_timeout over_budget 5.0 '(fn g => (sleep_tac 8.0 g; X.metis_tac [] g))'
# Strings, comments, HOL terms and longer identifiers must not extend a budget,
# and a metis call in a later planned step must not extend the earlier step's.
check_timeout ordinary 0.2 'slow_tac'
check_timeout string 0.2 '(fn g => (ignore "X.metis_tac"; slow_tac g))'
check_timeout comment 0.2 '(fn g => ((* metis_tac *) slow_tac g))'
check_timeout quotation 0.2 '(fn g => (ignore ``metis_tac:bool``; slow_tac g))'
check_timeout identifier 0.2 'metis_tac_slow'
check_timeout separate 0.2 'slow_tac >> X.metis_tac []'
