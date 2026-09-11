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

  (* TAC_PROOF_in was introduced with the context-taking tactic ABI.  Probe the
     installed HOL signature rather than ordering Git revisions or compiling a
     deliberately ill-typed expression, which would emit a misleading error. *)
  val context_tactics =
    String.isSubstring "val TAC_PROOF_in"
      (read_text (OS.Path.concat(Globals.HOLDIR, "src/1/Tactical.sig")))

  val legacy =
    "structure HolbuildTacticCompat = struct\n" ^
    "  fun lift_tactic run goal = run goal\n" ^
    "  fun lift_list_tactic run goals = run goals\n" ^
    "  fun run_tactic tactic goal = tactic goal\n" ^
    "  fun install_prover prover = Tactical.set_prover prover\n" ^
    "end;\n"

  val contextual =
    "structure HolbuildTacticCompat = struct\n" ^
    "  fun lift_tactic run goal _ = run goal\n" ^
    "  fun lift_list_tactic run goals _ = run goals\n" ^
    "  fun run_tactic tactic goal = tactic goal (Context.snapshot ())\n" ^
    "  fun install_prover prover = Tactical.set_prover (fn _ => prover)\n" ^
    "end;\n"
in
  val _ = compile (if context_tactics then contextual else legacy)
end
