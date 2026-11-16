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

  (* goalStack.expand_listf_in came later.  Without it, goalStack.expand_listf
     hands the list tactic Context.snapshot(); the step ignores that and runs
     in the context it was given instead, which needs no context pin. *)
  val context_goalstack = declares "src/proofman/goalStack.sig" "expand_listf_in"

  val proof_interception =
    "  type proof_factories = {tactics : (string * (unit -> Tactical.tactic)) list,\n" ^
    "                          list_tactics : (string * (unit -> Tactical.list_tactic)) list}\n" ^
    "  type proof_runner = proof_factories option -> proof_context -> Tactical.goal -> Thm.thm\n" ^
    "  fun intercept_proof (runner : unit -> proof_runner option ref) make factories =\n" ^
    "    lift_context_tactic (fn ctxt => fn goal =>\n" ^
    "      case !(runner ()) of\n" ^
    "          NONE => run_tactic ctxt (make ()) goal\n" ^
    "        | SOME run =>\n" ^
    "            (runner () := NONE;\n" ^
    "             let val th = run factories ctxt goal\n" ^
    "             in ([], fn [] => th | _ => raise Fail \"proof IR validation received theorems\") end))\n"

  val legacy =
    "structure HolbuildTacticCompat = struct\n" ^
    "  type proof_context = unit\n" ^
    "  fun lift_tactic (run : Tactical.goal -> Tactical.goal list * Tactical.validation) : Tactical.tactic = run\n" ^
    "  fun lift_context_tactic (run : proof_context -> Tactical.goal -> Tactical.goal list * Tactical.validation) : Tactical.tactic = run ()\n" ^
    "  fun lift_list_tactic (run : Tactical.goal list -> Tactical.goal list * Tactical.list_validation) : Tactical.list_tactic = run\n" ^
    "  fun run_tactic (_ : proof_context) (tactic : Tactical.tactic) (goal : Tactical.goal) = tactic goal\n" ^
    "  fun delay_tactic make = lift_context_tactic (fn ctxt => fn goal => run_tactic ctxt (make ()) goal)\n" ^
    "  fun tac_proof (_ : proof_context) goal_tactic = Tactical.TAC_PROOF goal_tactic\n" ^
    "  fun expand_listf (_ : proof_context) list_tactic gstk = goalStack.expand_listf list_tactic gstk\n" ^
    "  fun install_prover (prover : proof_context -> Tactical.goal * Tactical.tactic -> Thm.thm) = Tactical.set_prover (prover ())\n" ^
    "  type pin = unit\n" ^
    "  fun caller_pin () = ()\n" ^
    "  fun run_in_pin () f x = f x\n" ^
    "  fun restore_pin () = ()\n" ^
    "  fun pinned_writes_stay_in_pin () = false\n" ^
    proof_interception ^
    "end;\n"

  val contextual_expand_listf =
    if context_goalstack then
      "  fun expand_listf ctxt list_tactic gstk = goalStack.expand_listf_in ctxt list_tactic gstk\n"
    else
      "  fun expand_listf ctxt (list_tactic : Tactical.list_tactic) gstk =\n" ^
      "    goalStack.expand_listf (fn goals => fn _ => list_tactic goals ctxt) gstk\n"

  val context_pins =
    (* A proof step runs on a thread of its own (the step timeout), which starts
       unpinned.  When the caller is pinned (a deferred proof on a worker
       thread), the step runs in a pin holding the caller's context, and
       restore_pin writes the step's final context back into the caller's pin,
       as an unpinned step's writes land in the live context. *)
    "  type pin = Context.t option ref\n" ^
    "  fun caller_pin () : pin = ref (if Context.is_pinned () then SOME (Context.live ()) else NONE)\n" ^
    "  fun run_in_pin (pin : pin) f x =\n" ^
    "    case !pin of\n" ^
    "        NONE => f x\n" ^
    "      | SOME ctxt =>\n" ^
    "          Context.with_context ctxt (fn x =>\n" ^
    "            let val y = f x handle e => (pin := SOME (Context.live ()); raise e)\n" ^
    "            in pin := SOME (Context.live ()); y end) x\n" ^
    "  fun restore_pin (pin : pin) = case !pin of NONE => () | SOME ctxt => Context.restore ctxt\n" ^
    (* Whether a restore by a pinned thread lands in its pin, as HOL has
       done since 2026-10 (before, its writes went to the live context): a
       fresh session slot, set in a pin, read inside and outside it. *)
    "  fun pinned_writes_stay_in_pin () =\n" ^
    "    let\n" ^
    "      val slot = Context.Data.new {name = \"holbuild-pin-probe-\" ^ Time.toString (Time.now ()),\n" ^
    "                                   empty = false, pp = Bool.toString}\n" ^
    "      val live = Context.live ()\n" ^
    "      val inside =\n" ^
    "        Context.with_context live\n" ^
    "          (fn () => (Context.restore (Context.Data.put slot true live);\n" ^
    "                     Context.Data.get slot (Context.live ()))) ()\n" ^
    "      val outside = Context.Data.get slot (Context.live ())\n" ^
    "    in\n" ^
    "      if outside then (Context.restore live; false) else inside\n" ^
    "    end\n" ^
    ""

  val contextual =
    "structure HolbuildTacticCompat = struct\n" ^
    "  type proof_context = Context.t\n" ^
    "  fun lift_tactic (run : Tactical.goal -> Tactical.goal list * Tactical.validation) : Tactical.tactic = fn goal => fn _ => run goal\n" ^
    "  fun lift_context_tactic (run : proof_context -> Tactical.goal -> Tactical.goal list * Tactical.validation) : Tactical.tactic = fn goal => fn ctxt => run ctxt goal\n" ^
    "  fun lift_list_tactic (run : Tactical.goal list -> Tactical.goal list * Tactical.list_validation) : Tactical.list_tactic = fn goals => fn _ => run goals\n" ^
    "  fun run_tactic ctxt (tactic : Tactical.tactic) (goal : Tactical.goal) = tactic goal ctxt\n" ^
    "  fun delay_tactic make = lift_context_tactic (fn ctxt => fn goal => run_tactic ctxt (make ()) goal)\n" ^
    "  fun tac_proof ctxt goal_tactic = Tactical.TAC_PROOF_in ctxt goal_tactic\n" ^
    contextual_expand_listf ^
    "  fun install_prover (prover : proof_context -> Tactical.goal * Tactical.tactic -> Thm.thm) = Tactical.set_prover prover\n" ^
    context_pins ^
    proof_interception ^
    "end;\n"
in
  val _ = compile (if context_tactics then contextual else legacy)
end
