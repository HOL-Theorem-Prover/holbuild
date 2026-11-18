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
name = "smt-timeout"

[build]
members = ["src"]
tactic_timeout = 0.2
TOML

cat > "$project/src/SmtScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Smt";
structure X = struct
  fun slow_tac g = (OS.Process.sleep (Time.fromReal 0.65); ACCEPT_TAC TRUTH g);
  val Z3_TAC = slow_tac;
  val CVC_TAC = slow_tac;
  val Z3_ORACLE_TAC = slow_tac;
  val CVC_ORACLE_TAC = slow_tac;
  val YICES_TAC = slow_tac;
  fun GENERIC_SMT_TAC _ = slow_tac;
  fun z3_tac _ = slow_tac;
  fun z3o_tac _ = slow_tac;
  fun cvc_tac _ = slow_tac;
  fun cvco_tac _ = slow_tac;
end;
structure HolSmtLib = X;
structure Nested = struct structure Smt = X; end;
open X;
Theorem bare: T
Proof
  Z3_TAC
QED
Theorem qualified: T
Proof
  HolSmtLib.Z3_TAC
QED
Theorem reexported: T
Proof
  Nested.Smt.CVC_TAC
QED
Theorem z3_oracle: T
Proof
  X.Z3_ORACLE_TAC
QED
Theorem cvc_oracle: T
Proof
  CVC_ORACLE_TAC
QED
Theorem yices: T
Proof
  YICES_TAC
QED
Theorem generic: T
Proof
  GENERIC_SMT_TAC ()
QED
Theorem z3_facts: T
Proof
  z3_tac []
QED
Theorem z3o_facts: T
Proof
  X.z3o_tac []
QED
Theorem cvc_facts: T
Proof
  cvc_tac []
QED
Theorem cvco_facts: T
Proof
  X.cvco_tac []
QED
(* Other work in the same opaque leaf shares the exemption. *)
Theorem mixed: T
Proof
  (fn g => (OS.Process.sleep (Time.fromReal 0.65); X.Z3_TAC g))
QED
Theorem string_gap: T
Proof
  (fn g => (ignore "gap\
                  \"; X.Z3_TAC g))
QED
val _ = export_theory();
SML
(cd "$project" && "$HOLBUILD_BIN" build SmtTheory) > "$tmpdir/smt.log" 2>&1 ||
  { cat "$tmpdir/smt.log" >&2; exit 1; }
require_file "$project/.holbuild/obj/src/SmtTheory.dat"
require_grep 'proof_timeout=0.2' "$project/.holbuild/dep/smt-timeout/src/SmtScript.sml.key"

# Strings, comments, HOL terms and longer identifiers must not exempt a leaf.
# An SMT call in a later planned step must not exempt the earlier slow step.
check_timeout() {
  local name=$1 tactic=$2
  cat > "$project/src/SlowScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Slow";
fun slow_tac g = (OS.Process.sleep (Time.fromReal 0.65); ACCEPT_TAC TRUTH g);
val Z3_TAC_slow = slow_tac;
structure X = struct val Z3_TAC = ALL_TAC; end;
Theorem slow: T
Proof
  $tactic
QED
val _ = export_theory();
SML
  if (cd "$project" && "$HOLBUILD_BIN" build --no-cache --force=full --skip-checkpoints SlowTheory) > "$tmpdir/$name.log" 2>&1; then
    echo "non-SMT step escaped its timeout: $name" >&2
    exit 1
  fi
  require_grep 'tactic timed out after 0.2s while building SlowTheory' "$tmpdir/$name.log"
}
check_timeout ordinary 'slow_tac'
check_timeout string '(fn g => (ignore "X.Z3_TAC"; slow_tac g))'
check_timeout comment '(fn g => ((* outer (* Z3_TAC *) comment *) slow_tac g))'
check_timeout quotation '(fn g => (ignore ``Z3_TAC:bool``; slow_tac g))'
check_timeout identifier 'Z3_TAC_slow'
check_timeout separate 'slow_tac >> X.Z3_TAC'
