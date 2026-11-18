Theory TerminalFailure
Ancestors bool

val _ = ((raise mk_HOL_ERR "Optional" "branch" "handled diagnostic")
         handle e as HOL_ERR _ => print (Feedback.exn_to_string e));

Theorem continued:
  T
Proof
  ACCEPT_TAC TRUTH
QED

val _ = print (String.concat (List.tabulate (16, fn _ => "continued output\n")));
val _ = print "HOL message: terminal context\n";
val _ = raise Fail "terminal child failure";
