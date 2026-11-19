open HolKernel Parse boolLib bossLib;

val _ = new_theory "GoalPrint";

Datatype:
  cell = <| fld : num; flag : bool |>
End

(* A user printer the captured goal printer must still dispatch to. *)
val _ = temp_add_user_printer ("goalprint.fld",
  ``cell_fld (c:cell)``,
  fn _ => fn _ => fn sysprint => fn (ppfns : term_pp_types.ppstream_funs) =>
  fn gravs => fn depth => fn t =>
    smpp.>> (#add_string ppfns "FLD:",
             sysprint {gravs = gravs, binderp = false, depth = depth} (rand t)));

(* Prints the goal with HOL's own term printer, then fails, so holbuild prints
   the same goal for the failed step.  The installed printer is replaced by
   one holbuild's printer ignores: if holbuild fell back to the installed
   printer, the goal would show CUSTOM. *)
fun expected_goal_tac g =
  (TextIO.output (TextIO.stdErr,
     "expected goal:\n" ^ PP.pp_to_string 100 goalStack.std_pp_goal g ^ "\nexpected goal end\n");
   ignore (Parse.set_term_printer (fn _ => PP.add_string "CUSTOM"));
   FAIL_TAC "goal printed" g)

Theorem printed_goal:
  !(x:num) y (r:cell) (l:num list) (s:num set) p q.
    x < y /\ ~ ~p /\ (p ==> ~q) /\ r.fld = x + 1 /\ r.flag /\ l = [x; y; 3] /\
    s = {n | n < x} /\ x - y <= y * 2 /\ (\n. n + x) y = 7 ==>
    LENGTH l > 0 \/ (r with fld := y).fld = y
Proof
  rpt strip_tac >> expected_goal_tac
QED

val _ = export_theory ();
