#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# Proofs run in the context handed to the installed prover, not in whatever the
# live context has become.  Only a context-taking HOL hands one over.
if ! grep -q "val TAC_PROOF_in" "$HOLDIR/src/1/Tactical.sig"; then
  echo "skipping: HOL has the legacy tactic ABI"
  exit 0
fi

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

make_project() {
  local p=$1
  local name=$2
  mkdir -p "$p/src"
  cat > "$p/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "$name"

[build]
members = ["src"]
TOML
}

# Each proof starts with diverge_tac, which changes the live context after the
# prover was handed its own: a Data slot marker and the overload `hbpick`, which
# the explicit context resolves to the constant hb_b and the live one leaves a
# variable matching any goal.  Every later step, probe and nested proof must
# still see the explicit context.
context_prelude() {
  cat <<'SML'
Definition hb_a_def:
  hb_a = T
End

Definition hb_b_def:
  hb_b = T
End

Theorem hb_a_thm:
  hb_a
Proof
  REWRITE_TAC [hb_a_def]
QED

Theorem hb_b_thm:
  hb_b
Proof
  REWRITE_TAC [hb_b_def]
QED

val marker =
  Context.Data.new {name = "holbuild-test.marker", empty = "", pp = fn s => s};

fun reset_context () =
  (Context.Data.write marker "explicit";
   Parse.temp_overload_on ("hbpick", “hb_b”));

fun diverge_tac g ctxt =
  (Context.Data.write marker "ambient";
   Parse.temp_clear_overloads_on "hbpick";
   ALL_TAC g ctxt);

fun expect_explicit what ctxt =
  if Context.Data.get marker ctxt = "explicit" then ()
  else raise mk_HOL_ERR "AScript" what
         ("ran in the " ^ Context.Data.get marker ctxt ^ " context");

fun check_tac g ctxt = (expect_explicit "check_tac" ctxt; ALL_TAC g ctxt);
fun check_lt gs ctxt = (expect_explicit "check_lt" ctxt; ALL_LT gs ctxt);
fun nested_tac g ctxt =
  (ignore (Tactical.prove_in ctxt (“T”, check_tac >> ACCEPT_TAC TRUTH));
   ALL_TAC g ctxt);
SML
}

project=$tmpdir/explicit
make_project "$project" explicit-proof-context
{
  echo "Theory A"
  echo
  context_prelude
  cat <<'SML'

val _ = reset_context ();
Theorem tactic_step:
  p ⇒ p
Proof
  diverge_tac >> check_tac >> DISCH_TAC >> FIRST_ASSUM ACCEPT_TAC
QED

val _ = reset_context ();
Theorem list_tactic_step:
  p ⇒ p
Proof
  diverge_tac >>> check_lt >> DISCH_TAC >> FIRST_ASSUM ACCEPT_TAC
QED

val _ = reset_context ();
Theorem nested_proof:
  p ⇒ p
Proof
  diverge_tac >> nested_tac >> DISCH_TAC >> FIRST_ASSUM ACCEPT_TAC
QED

val _ = reset_context ();
Theorem select_matching_first:
  (p ⇒ p) ∧ hb_a ∧ hb_b
Proof
  diverge_tac >> rpt CONJ_TAC
  >~ [‘hbpick’] >- ACCEPT_TAC hb_b_thm
  >- (DISCH_TAC >> FIRST_ASSUM ACCEPT_TAC)
  >- ACCEPT_TAC hb_a_thm
QED

val _ = reset_context ();
Theorem select_matching_all:
  (p ⇒ p) ∧ hb_a ∧ hb_b
Proof
  diverge_tac >> rpt CONJ_TAC
  >>~ [‘hbpick’] >- ACCEPT_TAC hb_b_thm
  >- (DISCH_TAC >> FIRST_ASSUM ACCEPT_TAC)
  >- ACCEPT_TAC hb_a_thm
QED
SML
} > "$project/src/AScript.sml"

build_log=$tmpdir/explicit.log
if ! (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$build_log" 2>&1; then
  cat "$build_log" >&2
  echo "proofs did not run in the context handed to the prover" >&2
  exit 1
fi

# A failed-prefix checkpoint is taken after diverge_tac, so the resumed process
# starts with the live context already changed; the replayed suffix must still
# run in the context the original proof was handed.
resume_project=$tmpdir/resume
make_project "$resume_project" explicit-proof-context-resume
write_resume_script() {
  local suffix=$1
  {
    echo "Theory A"
    echo
    context_prelude
    cat <<SML

val _ = reset_context ();
Theorem resumed:
  p ⇒ p
Proof
  diverge_tac >> check_tac >> $suffix
QED
SML
  } > "$resume_project/src/AScript.sml"
}

write_resume_script 'FAIL_TAC "seed failure"'
seed_log=$tmpdir/seed.log
if (cd "$resume_project" && "$HOLBUILD_BIN" build ATheory) >"$seed_log" 2>&1; then
  echo "expected seed proof to fail" >&2
  exit 1
fi
require_grep "seed failure" "$seed_log"
require_file "$(find "$resume_project/.holbuild/checkpoints" -name 'resumed_failed_prefix.save' -print -quit)"

write_resume_script 'check_tac >>> check_lt >> nested_tac >> DISCH_TAC >> FIRST_ASSUM ACCEPT_TAC'
resume_log=$tmpdir/resume.log
if ! (cd "$resume_project" && "$HOLBUILD_BIN" build ATheory) >"$resume_log" 2>&1; then
  cat "$resume_log" >&2
  echo "resumed failed prefix did not run in the original proof's context" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in resumed" "$resume_log"
