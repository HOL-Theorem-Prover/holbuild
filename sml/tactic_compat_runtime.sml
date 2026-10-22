(* This file is loaded into both legacy and context-taking HOL heaps.  Keep the
   version-specific tactic types inside dynamically compiled source so this
   loader itself type-checks against either ABI. *)
local
  fun compile source =
    let
      val stream = TextIO.openString
        (HOLSource.fromString {quietOpen = false, print = fn _ => ()} source)
      fun input () = TextIO.input1 stream
    in
      (while not (TextIO.endOfStream stream) do PolyML.compiler (input, []) ();
       TextIO.closeIn stream)
      handle e => (TextIO.closeIn stream; raise e)
    end

  fun read_text path =
    let
      val input = TextIO.openIn path
      val text = TextIO.inputAll input
      val _ = TextIO.closeIn input
    in
      text
    end

  fun declares path name =
    String.isSubstring ("val " ^ name)
      (read_text (OS.Path.concat(Globals.HOLDIR, path)))

  (* TAC_PROOF_in was introduced with the context-taking tactic ABI.  Probe the
     installed HOL signature rather than ordering Git revisions or compiling a
     deliberately ill-typed expression, which would emit a misleading error. *)
  val context_tactics = declares "src/1/Tactical.sig" "TAC_PROOF_in"

  (* goalStack.expand_listf_in came later.  Without it, goalStack runs a step
     in Context.snapshot(), so a step whose context differs from the live one
     pins that context on the thread running it.  Only then: while any pin is
     held, every ambient read in the process (mk_const included) takes a
     slower path.  The pin is per step, never around the whole proof, so it
     is not held while a checkpoint is saved and nested proofs never pin. *)
  val context_goalstack = declares "src/proofman/goalStack.sig" "expand_listf_in"

  val legacy =
    "structure HolbuildTacticCompat = struct\n" ^
    "  type proof_context = unit\n" ^
    "  fun lift_tactic (run : Tactical.goal -> Tactical.goal list * Tactical.validation) : Tactical.tactic = run\n" ^
    "  fun lift_context_tactic (run : proof_context -> Tactical.goal -> Tactical.goal list * Tactical.validation) : Tactical.tactic = run ()\n" ^
    "  fun lift_list_tactic (run : Tactical.goal list -> Tactical.goal list * Tactical.list_validation) : Tactical.list_tactic = run\n" ^
    "  fun run_tactic (_ : proof_context) (tactic : Tactical.tactic) (goal : Tactical.goal) = tactic goal\n" ^
    "  fun tac_proof (_ : proof_context) goal_tactic = Tactical.TAC_PROOF goal_tactic\n" ^
    "  fun expand_listf (_ : proof_context) list_tactic gstk = goalStack.expand_listf list_tactic gstk\n" ^
    "  fun install_prover (prover : proof_context -> Tactical.goal * Tactical.tactic -> Thm.thm) = Tactical.set_prover (prover ())\n" ^
    "end;\n"

  val contextual_expand_listf =
    if context_goalstack then
      "  fun expand_listf ctxt list_tactic gstk = goalStack.expand_listf_in ctxt list_tactic gstk\n"
    else
      "  fun expand_listf ctxt list_tactic gstk =\n" ^
      "    if PolyML.pointerEq (ctxt, Context.snapshot ()) then goalStack.expand_listf list_tactic gstk\n" ^
      "    else if Context.is_pinned () then\n" ^
      "      raise Fail \"holbuild cannot run a proof step in its own context on a thread that already has a context pin\"\n" ^
      "    else Context.with_context ctxt (goalStack.expand_listf list_tactic) gstk\n"

  val contextual =
    "structure HolbuildTacticCompat = struct\n" ^
    "  type proof_context = Context.t\n" ^
    "  fun lift_tactic (run : Tactical.goal -> Tactical.goal list * Tactical.validation) : Tactical.tactic = fn goal => fn _ => run goal\n" ^
    "  fun lift_context_tactic (run : proof_context -> Tactical.goal -> Tactical.goal list * Tactical.validation) : Tactical.tactic = fn goal => fn ctxt => run ctxt goal\n" ^
    "  fun lift_list_tactic (run : Tactical.goal list -> Tactical.goal list * Tactical.list_validation) : Tactical.list_tactic = fn goals => fn _ => run goals\n" ^
    "  fun run_tactic ctxt (tactic : Tactical.tactic) (goal : Tactical.goal) = tactic goal ctxt\n" ^
    "  fun tac_proof ctxt goal_tactic = Tactical.TAC_PROOF_in ctxt goal_tactic\n" ^
    contextual_expand_listf ^
    "  fun install_prover (prover : proof_context -> Tactical.goal * Tactical.tactic -> Thm.thm) = Tactical.set_prover prover\n" ^
    "end;\n"
in
  val _ = compile (if context_tactics then contextual else legacy)
end
