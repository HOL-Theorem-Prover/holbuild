#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
tmpdir=$(make_temp_dir)
trap 'rm -rf "$tmpdir"' EXIT

# Exercise both shared-parser interfaces without building another HOL revision.
cat > "$tmpdir/check.sml" <<'SML'
val _ = OS.FileSys.chDir (valOf (OS.Process.getEnv "HOLBUILD_ROOT"));
use "sml/analyser/tactic_parse_capabilities.sml";
fun check true = () | check false = raise Fail "parser compatibility assertion";
val detect = HolbuildTacticParseCapabilities.has_token_spans;
val _ = check (not (detect "datatype 'a tac_expr = Then of 'a tac_expr list | By of 'a * 'a tac_expr"));
val _ = check (detect "datatype 'a tac_expr = Then of 'a tac_expr list\n | By of 'a\t* 'a * 'a tac_expr");
val _ = check ((detect "| By of 'a * int * 'a tac_expr"; false)
               handle Fail _ => true);

structure TacticParse = struct
  datatype 'a tac_expr = Then of 'a tac_expr list
    | By of 'a * 'a tac_expr
    | SufficesBy of 'a * 'a tac_expr
    | LThen1 of 'a tac_expr
end;
use "sml/analyser/tactic_parse_adapter_legacy.sml";
val _ = check (case HolbuildTacticParseAdapter.view (TacticParse.By (7, TacticParse.Then [])) of
  HolbuildTacticParseAdapter.ByNode (7, TacticParse.Then []) => true | _ => false);
val _ = check (case HolbuildTacticParseAdapter.view (TacticParse.SufficesBy (8, TacticParse.Then [])) of
  HolbuildTacticParseAdapter.SufficesByNode (8, TacticParse.Then []) => true | _ => false);
val _ = check (case HolbuildTacticParseAdapter.view (TacticParse.LThen1 (TacticParse.Then [])) of
  HolbuildTacticParseAdapter.Then1Node (TacticParse.Then []) => true | _ => false);
val _ = check (case HolbuildTacticParseAdapter.view (TacticParse.Then []) of
  HolbuildTacticParseAdapter.Other (TacticParse.Then []) => true | _ => false);

structure TacticParse = struct
  datatype 'a tac_expr = Then of 'a tac_expr list
    | By of 'a * 'a * 'a tac_expr
    | SufficesBy of 'a * 'a * 'a tac_expr
    | LThen1 of 'a * 'a tac_expr
end;
use "sml/analyser/tactic_parse_adapter_token_spans.sml";
val _ = check (case HolbuildTacticParseAdapter.view (TacticParse.By (7, 99, TacticParse.Then [])) of
  HolbuildTacticParseAdapter.ByNode (7, TacticParse.Then []) => true | _ => false);
val _ = check (case HolbuildTacticParseAdapter.view (TacticParse.SufficesBy (8, 99, TacticParse.Then [])) of
  HolbuildTacticParseAdapter.SufficesByNode (8, TacticParse.Then []) => true | _ => false);
val _ = check (case HolbuildTacticParseAdapter.view (TacticParse.LThen1 (99, TacticParse.Then [])) of
  HolbuildTacticParseAdapter.Then1Node (TacticParse.Then []) => true | _ => false);
val _ = check (case HolbuildTacticParseAdapter.view (TacticParse.Then []) of
  HolbuildTacticParseAdapter.Other (TacticParse.Then []) => true | _ => false);
val _ = print "parser compatibility passed\n";
val _ = OS.Process.exit OS.Process.success;
SML
"${HOLBUILD_POLY:-poly}" < "$tmpdir/check.sml" > "$tmpdir/check.log" 2>&1 || {
  cat "$tmpdir/check.log"
  exit 1
}
require_grep 'parser compatibility passed' "$tmpdir/check.log"
if grep -Eq 'error:|Exception-' "$tmpdir/check.log"; then
  cat "$tmpdir/check.log"
  exit 1
fi

# The legacy planner must preserve standalone atomic source text, but still
# group atoms when synthesizing nested expressions.
cat > "$tmpdir/legacy-leaves.sml" <<SML
Meta.load "HOLSourceParser";
use "$HOLBUILD_ROOT/sml/proof_ir_types.sml";
use "$HOLBUILD_ROOT/sml/proof_ir.sml";
val _ = let
  open HolbuildProofIrPlanner
  fun check true = () | check false = raise Fail "legacy leaf spelling";
  val atom = TacAtomic (10, (0, 6));
  val _ = check (HolbuildProofIr.step_program (tactic_step "NO_TAC" atom) = "NO_TAC");
  val _ = check (tactic_program "NO_TAC" atom = "(NO_TAC)");
  val _ = check (HolbuildProofIr.step_program
    (tactic_step "(NO_TAC)" (TacAtomic (10, (0, 8)))) = "(NO_TAC)");
  val _ = check (tactic_program "NO_TAC" (TacTry ((0, 6), atom)) =
    "Tactical.TRY((NO_TAC))");
in print "legacy leaf spelling passed\\n" end;
OS.Process.exit OS.Process.success;
SML
"$HOLDIR/bin/hol" < "$tmpdir/legacy-leaves.sml" > "$tmpdir/legacy-leaves.log" 2>&1
require_grep 'legacy leaf spelling passed' "$tmpdir/legacy-leaves.log"
if grep -Eq 'error:|Exception-' "$tmpdir/legacy-leaves.log"; then
  cat "$tmpdir/legacy-leaves.log"
  exit 1
fi
