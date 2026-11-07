#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"

make_project() {
  mkdir -p "$1/src"
  { write_schema2_prelude; cat <<'TOML'
[project]
name = "proof-attributes"
[build]
members = ["src"]
TOML
  } > "$1/holproject.toml"
}

# Compiled library readers see the ambient simpset, while context-taking
# tactics also see the context passed by HOL's native attribute wrapper.
cat > "$tmpdir/prelude.sml" <<'SML'
Theory A

open markerLib;
Definition attr_a_def[simp]:
  attr_a = T
End
Definition attr_b_def:
  attr_b = T
End
Definition attr_c_def:
  attr_c = T
End
val _ = augment_srw_ss [simpLib.named_rewrites "ATTR_FRAG" [attr_b_def]];
fun reduced ss tm = rhs (concl (simpLib.SIMP_CONV ss [] tm))
  handle Conv.UNCHANGED => tm;
fun excluded ss =
  aconv (reduced ss ``attr_a``) ``attr_a`` andalso
  aconv (reduced ss ``attr_b``) ``attr_b``;
fun check_excluded () =
  if excluded (srw_ss()) then () else raise Fail "attribute exclusions lost";
fun check_restored () =
  if aconv (reduced (srw_ss()) ``attr_a``) ``T`` andalso
     aconv (reduced (srw_ss()) ``attr_b``) ``T`` andalso
     aconv (reduced (srw_ss()) ``attr_c``) ``attr_c`` then ()
  else raise Fail "attribute scope leaked";
fun early () =
  (check_excluded (); augment_srw_ss [simpLib.rewrites [attr_c_def]]);
fun later () =
  (check_excluded ();
   if aconv (reduced (srw_ss()) ``attr_c``) ``T`` then ()
   else raise Fail "early leaf simpset change lost");
fun event text = print ("ATTR_EVENT " ^ text ^ "\n");
fun flip args =
  (event ("make flip " ^ String.concatWith "|" args);
   fn ss =>
     (event "apply flip";
      if aconv (reduced ss ``attr_a``) ``T`` then
        simpLib.remove_simps ["attr_a_def"] ss
      else simpLib.++ (ss, simpLib.rewrites [attr_a_def])));
fun remove args =
  (event ("make remove " ^ String.concatWith "|" args);
   fn ss => (event "apply remove"; simpLib.remove_simps ["attr_a_def"] ss));
fun nested_tac g =
  (ignore (Tactical.prove (``T``, ACCEPT_TAC TRUTH)); ALL_TAC g);
val modifier_calls = ref 0;
fun stateful _ ss =
  (modifier_calls := !modifier_calls + 1;
   if !modifier_calls = 1 then simpLib.remove_simps ["attr_a_def"] ss else ss);
fun observe () =
  event ("ambient " ^ Bool.toString (aconv (reduced (srw_ss()) ``attr_a``) ``T``));
SML
if grep -q 'val TAC_PROOF_in' "$HOLDIR/src/1/Tactical.sig"; then
  cat >> "$tmpdir/prelude.sml" <<'SML'
val expected_inline_change = false;
fun context_check g ctxt =
  (if excluded (BasicProvers.srw_ss_of ctxt) then ()
   else raise Fail "context exclusions lost";
   ALL_TAC g ctxt);
fun context_observe g ctxt =
  (event ("context " ^ Bool.toString
     (aconv (reduced (BasicProvers.srw_ss_of ctxt) ``attr_a``) ``T``));
   ALL_TAC g ctxt);
SML
else
  cat >> "$tmpdir/prelude.sml" <<'SML'
val expected_inline_change = true;
val context_check = ALL_TAC;
val context_observe = ALL_TAC;
SML
fi

for mode in plain steps; do
  project=$tmpdir/$mode
  make_project "$project"
  cat "$tmpdir/prelude.sml" > "$project/src/AScript.sml"
  cat >> "$project/src/AScript.sml" <<'SML'
Theorem exclusions:
  T /\ T
Proof[exclude_simps=attr_a_def,exclude_frags=ATTR_FRAG]
  (early (); ALL_TAC) >> nested_tac >> context_check >> CONJ_TAC
  >- (later (); ACCEPT_TAC TRUTH)
  >- (if aconv (reduced (srw_ss()) ``attr_c``) ``T`` = expected_inline_change
      then () else raise Fail "inline reader escaped native lexical context";
      later (); ACCEPT_TAC TRUTH)
QED
val _ = check_restored ();
Theorem lexical_list:
  T /\ T
Proof[exclude_simps=attr_a_def,exclude_frags=ATTR_FRAG]
  (early (); CONJ_TAC)
  >>> ALLGOALS ((if aconv (reduced (BasicProvers.srw_ss()) ``attr_c``) ``T`` = expected_inline_change
                then () else raise Fail "list reader escaped native lexical context");
               ACCEPT_TAC TRUTH)
QED
val _ = check_restored ();
Theorem lexical_selector:
  T /\ T
Proof[exclude_simps=attr_a_def,exclude_frags=ATTR_FRAG]
  (early (); CONJ_TAC)
  >~ (if aconv (reduced (srw_ss()) ``attr_c``) ``T`` = expected_inline_change
      then [`T`] else raise Fail "selector reader escaped native lexical context")
  >- (later (); ACCEPT_TAC TRUTH)
  >> ACCEPT_TAC TRUTH
QED
val _ = check_restored ();
Theorem custom:
  T
Proof[flip=first second,remove=third,flip=fourth]
  (observe (); ALL_TAC) >> context_observe >> ACCEPT_TAC TRUTH
QED
val _ = check_restored ();
Theorem lexical_reader:
  T
Proof[stateful]
  (event ("lexical " ^ Bool.toString (aconv (reduced (srw_ss()) ``attr_a``) ``T``)); ALL_TAC)
  >> ACCEPT_TAC TRUTH
QED
val _ = check_restored ();
Theorem partial:
  T /\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >- suspend "right"
QED
Resume partial[right,smlname=resumed_proof,exclude_simps=attr_a_def,exclude_frags=ATTR_FRAG]:
  (early (); ALL_TAC) >> context_check
  >> ((if aconv (reduced (srw_ss()) ``attr_c``) ``T`` = expected_inline_change
       then () else raise Fail "Resume reader escaped native lexical context");
      later (); ACCEPT_TAC TRUTH)
QED
Finalise partial
val _ = check_restored ();
val _ = export_theory ();
SML
  flags=(--no-cache)
  [[ "$mode" != plain ]] || flags+=(--skip-proof-steps)
  [[ "$mode" != steps ]] || flags+=(--trace-steps)
  if ! (cd "$project" && HOLBUILD_ECHO_CHILD_LOGS=1 "$HOLBUILD_BIN" build "${flags[@]}" ATheory) > "$tmpdir/$mode.log" 2>&1; then
    cat "$tmpdir/$mode.log" >&2
    exit 1
  fi
  grep '^ATTR_EVENT ' "$tmpdir/$mode.log" > "$tmpdir/$mode.events"
done
cmp "$tmpdir/plain.events" "$tmpdir/steps.events"
for ext in sml sig dat; do
  cmp "$tmpdir/plain/.holbuild/obj/src/ATheory.$ext" "$tmpdir/steps/.holbuild/obj/src/ATheory.$ext"
done
require_grep 'holbuild proof-ir before theorem=exclusions' "$tmpdir/steps.log"
require_grep 'holbuild proof-ir before theorem=partial\[right\]' "$tmpdir/steps.log"
require_file "$(find "$tmpdir/steps/.holbuild/checkpoints" -name 'exclusions_end_of_proof.save' -print -quit)"

# Restored navigation heaps must retain history, but no temporary simpset.
cat > "$tmpdir/navigation.sml" <<'SML'
val _ = check_restored ();
val _ = if isSome (!HolbuildProofRuntime.proof_factories_ref) then
          raise Fail "temporary factories survived in end checkpoint" else ();
val _ = HolbuildProofRuntime.backup_n 1;
val _ = if null (HolbuildProofRuntime.history_top_goals ()) then
          raise Fail "missing attributed proof history" else ();
val _ = print "ATTR_NAVIGATION_OK\n";
SML
for name in exclusions custom partial_right_; do
  end_state=$(find "$tmpdir/steps/.holbuild/checkpoints" -name "${name}_end_of_proof.save" -print -quit)
  expected='[("exclude_simps", ["attr_a_def"]), ("exclude_frags", ["ATTR_FRAG"])]'
  if [[ "$name" == custom ]]; then
    expected='[("flip", ["first", "second"]), ("remove", ["third"]), ("flip", ["fourth"])]'
  fi
  cat > "$tmpdir/metadata.sml" <<SML
val SOME info = !HolbuildProofRuntime.theorem_info_ref;
val _ = if #10 info = $expected then () else raise Fail "attribute metadata changed";
SML
  "$HOLDIR/bin/hol" run --noconfig --holstate "$end_state" "$tmpdir/metadata.sml" "$tmpdir/navigation.sml" > "$tmpdir/navigation-$name.log" 2>&1
  require_grep 'ATTR_NAVIGATION_OK' "$tmpdir/navigation-$name.log"
done

for mode in plain steps; do
  project=$tmpdir/failure-$mode
  make_project "$project"
  cat "$tmpdir/prelude.sml" > "$project/src/AScript.sml"
  if [[ "$mode" == plain ]]; then
    prover='Tactical.TAC_PROOF'
    if grep -q 'val TAC_PROOF_in' "$HOLDIR/src/1/Tactical.sig"; then
      prover='Tactical.TAC_PROOF_in ctxt'
    fi
  else
    prover='HolbuildProofRuntime.proof_ir_prover ()'
    if grep -q 'val TAC_PROOF_in' "$HOLDIR/src/1/Tactical.sig"; then
      prover='HolbuildProofRuntime.proof_ir_prover ctxt'
    fi
  fi
  context_arg=''
  if grep -q 'val TAC_PROOF_in' "$HOLDIR/src/1/Tactical.sig"; then
    context_arg='fn ctxt => '
  fi
  cat >> "$project/src/AScript.sml" <<SML
val _ = Tactical.set_prover (${context_arg}fn gt =>
  $prover gt handle e =>
    (check_restored (); print "ATTR_EXCEPTION_UNWOUND\n"; raise e));
SML
  cat >> "$project/src/AScript.sml" <<'SML'
Theorem failure:
  T /\ F
Proof[exclude_simps=attr_a_def,exclude_frags=ATTR_FRAG]
  (early (); ALL_TAC) >> CONJ_TAC >- ACCEPT_TAC TRUTH
  >- (later (); FAIL_TAC "attribute leaf failure")
QED
SML
  flags=(--no-cache)
  [[ "$mode" != plain ]] || flags+=(--skip-proof-steps)
  if (cd "$project" && HOLBUILD_ECHO_CHILD_LOGS=1 "$HOLBUILD_BIN" build "${flags[@]}" ATheory) > "$tmpdir/failure-$mode.log" 2>&1; then
    echo "attributed failure unexpectedly succeeded ($mode)" >&2
    exit 1
  fi
  require_grep 'ATTR_EXCEPTION_UNWOUND' "$project/.holbuild/logs/current/proof-attributes/ATheory/build.log"
done
require_grep 'fragment:.*later' "$tmpdir/failure-steps.log"
require_grep 'plan position:' "$tmpdir/failure-steps.log"
sed -n '/holbuild failed tactic top input goal:/,/holbuild end failed tactic top input goal/p' "$tmpdir/failure-steps/.holbuild/logs/current/proof-attributes/ATheory/build.log" > "$tmpdir/failure-goal.log"
require_grep 'F' "$tmpdir/failure-goal.log"
if grep -q '/\\' "$tmpdir/failure-goal.log"; then
  echo 'failure reported the initial goal instead of the failing leaf input' >&2
  exit 1
fi
if find "$tmpdir/failure-steps/.holbuild/checkpoints" -name 'failure_*.save*' | grep -q .; then
  echo 'attributed failure saved an unsafe checkpoint' >&2
  exit 1
fi

for timeout_kind in leaf selector; do
  project=$tmpdir/timeout-$timeout_kind
  make_project "$project"
  cat "$tmpdir/prelude.sml" > "$project/src/AScript.sml"
  cat >> "$project/src/AScript.sml" <<'SML'
fun slow g = (OS.Process.sleep (Time.fromSeconds 4); ALL_TAC g);
Theorem timeout:
  T /\ T
Proof[exclude_simps=attr_a_def]
SML
  if [[ "$timeout_kind" == leaf ]]; then
    echo '  CONJ_TAC >- ACCEPT_TAC TRUTH >- (slow >> ACCEPT_TAC TRUTH)' >> "$project/src/AScript.sml"
  else
    echo '  CONJ_TAC >~ (OS.Process.sleep (Time.fromSeconds 4); [`T`]) >> ACCEPT_TAC TRUTH' >> "$project/src/AScript.sml"
  fi
  echo QED >> "$project/src/AScript.sml"
  log=$tmpdir/timeout-$timeout_kind.log
  if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$log" 2>&1; then
    echo "attributed $timeout_kind escaped the default step timeout" >&2
    exit 1
  fi
  require_grep '2.5' "$log"
  if [[ "$timeout_kind" == leaf ]]; then
    require_grep 'fragment:.*slow' "$log"
  else
    require_grep 'OS.Process.sleep' "$log"
  fi
  if find "$project/.holbuild/checkpoints" -name 'timeout_*.save*' | grep -q .; then
    echo 'attributed timeout saved an unsafe checkpoint' >&2
    exit 1
  fi
done

ATTR_TEST_TMP="$tmpdir" "${HOLBUILD_POLY:-poly}" -q --error-exit --gcthreads=1 \
  < "$SCRIPT_DIR/checkpoint-policy.sml" > "$tmpdir/checkpoint-policy.log" 2>&1 || {
    cat "$tmpdir/checkpoint-policy.log" >&2
    exit 1
  }
require_grep 'ATTR_POLICY_OK' "$tmpdir/checkpoint-policy.log"
