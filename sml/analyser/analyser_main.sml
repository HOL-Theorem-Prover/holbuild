structure HolbuildAnalyserMain =
struct

structure P = HolbuildAnalysisProtocol
structure D = HolbuildAnalyserDependencyExtract
structure S = HolbuildAnalyserTheorySpanExtract
structure PI = HolbuildAnalyserProofIrExtract

exception Error of string

type file_req = {id : string, path : string, wants : string list}
type proof_req = {id : string, name : string, tactic_start : int, tactic_end : int, tactic_text : string}
datatype request = Analyse of file_req list | ProofIrPlan of proof_req list

fun die msg = raise Error msg

fun read_all path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end

fun write_file path text =
  let val out = TextIO.openOut path
  in TextIO.output(out, text); TextIO.closeOut out end

fun member x xs = List.exists (fn y => x = y) xs

fun parse_int field text =
  case Int.fromString text of SOME n => n | NONE => die ("bad " ^ field ^ ": " ^ text)

fun parse_request path =
  let
    val lines = String.tokens (fn c => c = #"\n") (read_all path)
    fun loop lines command files proofs =
      case lines of
          [] => die "request missing end"
        | line :: rest =>
            (case P.split line of
                 ["version", v] => if v = P.protocol_version then loop rest command files proofs else die ("unsupported protocol version: " ^ v)
               | ["command", "analyse"] => loop rest (SOME "analyse") files proofs
               | ["command", "proof-ir-plan"] => loop rest (SOME "proof-ir-plan") files proofs
               | "file" :: id :: file :: wants => loop rest command ({id = id, path = file, wants = wants} :: files) proofs
               | ["theorem", id, name, tactic_start, tactic_end, tactic_text] =>
                   loop rest command files ({id = id, name = name,
                                             tactic_start = parse_int "tactic_start" tactic_start,
                                             tactic_end = parse_int "tactic_end" tactic_end,
                                             tactic_text = tactic_text} :: proofs)
               | ["end"] =>
                   (case command of
                        SOME "analyse" => Analyse (rev files)
                      | SOME "proof-ir-plan" => ProofIrPlan (rev proofs)
                      | _ => die "request missing command")
               | [] => loop rest command files proofs
               | fields => die ("bad request line: " ^ line))
  in
    loop lines NONE [] []
  end

fun emit_deps ({loads, uses, extra_deps, holdep_mentions} : D.t) =
  map (fn x => P.join ["load", x]) loads @
  map (fn x => P.join ["use", x]) uses @
  map (fn x => P.join ["extra-dep", x]) extra_deps @
  map (fn x => P.join ["mention", x]) holdep_mentions

fun read_all_file path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end

fun emit_boundary ({kind, name, safe_name, theorem_start, theorem_stop, boundary, tactic_start,
                    tactic_end, tactic_text, has_proof_attrs, prefix_hash} : S.boundary) =
  P.join ["boundary", kind, name, safe_name, Int.toString theorem_start, Int.toString theorem_stop,
          Int.toString boundary, Int.toString tactic_start, Int.toString tactic_end,
          if has_proof_attrs then "1" else "0", prefix_hash, tactic_text]

fun emit_termination ({name, safe_name, definition_start, definition_stop, boundary, quote_start,
                       quote_end, quote_text, tactic_start, tactic_end, tactic_text} : S.termination) =
  P.join ["termination", name, safe_name, Int.toString definition_start, Int.toString definition_stop,
          Int.toString boundary, Int.toString quote_start, Int.toString quote_end,
          Int.toString tactic_start, Int.toString tactic_end, quote_text, tactic_text]

fun sml_string s = "\"" ^ String.toString s ^ "\""
fun sml_int n = Int.toString n
fun sml_list xs = "[" ^ String.concatWith ", " xs ^ "]"

fun step_sml step =
  case step of
      HolbuildProofIr.StepTactic {start_pos, end_pos, label, program} =>
        "HolbuildProofIr.StepTactic {start_pos=" ^ sml_int start_pos ^ ", end_pos=" ^ sml_int end_pos ^
        ", label=" ^ sml_string label ^ ", program=" ^ sml_string program ^ "}"
    | HolbuildProofIr.StepList {start_pos, end_pos, label, program} =>
        "HolbuildProofIr.StepList {start_pos=" ^ sml_int start_pos ^ ", end_pos=" ^ sml_int end_pos ^
        ", label=" ^ sml_string label ^ ", program=" ^ sml_string program ^ "}"
    | HolbuildProofIr.StepChoice {start_pos, end_pos, label, program, alternatives} =>
        "HolbuildProofIr.StepChoice {start_pos=" ^ sml_int start_pos ^ ", end_pos=" ^ sml_int end_pos ^
        ", label=" ^ sml_string label ^ ", program=" ^ sml_string program ^ ", alternatives=" ^ sml_list (map sml_string alternatives) ^ "}"
    | HolbuildProofIr.StepListChoice {start_pos, end_pos, label, program, alternatives} =>
        "HolbuildProofIr.StepListChoice {start_pos=" ^ sml_int start_pos ^ ", end_pos=" ^ sml_int end_pos ^
        ", label=" ^ sml_string label ^ ", program=" ^ sml_string program ^ ", alternatives=" ^ sml_list (map sml_string alternatives) ^ "}"
    | HolbuildProofIr.StepEach {start_pos, end_pos, body} =>
        "HolbuildProofIr.StepEach {start_pos=" ^ sml_int start_pos ^ ", end_pos=" ^ sml_int end_pos ^
        ", body=" ^ plan_sml body ^ "}"
    | HolbuildProofIr.StepSelectFirstSolve {start_pos, end_pos, body} =>
        "HolbuildProofIr.StepSelectFirstSolve {start_pos=" ^ sml_int start_pos ^ ", end_pos=" ^ sml_int end_pos ^
        ", body=" ^ plan_sml body ^ "}"
    | HolbuildProofIr.StepCases {start_pos, end_pos, cases} =>
        "HolbuildProofIr.StepCases {start_pos=" ^ sml_int start_pos ^ ", end_pos=" ^ sml_int end_pos ^
        ", cases=" ^ sml_list (map plan_sml cases) ^ "}"
    | HolbuildProofIr.StepPlain {start_pos, end_pos, label, program} =>
        "HolbuildProofIr.StepPlain {start_pos=" ^ sml_int start_pos ^ ", end_pos=" ^ sml_int end_pos ^
        ", label=" ^ sml_string label ^ ", program=" ^ sml_string program ^ "}"

and plan_sml steps = sml_list (map step_sml steps)

fun emit_step step =
  case step of
      HolbuildProofIr.StepTactic {start_pos, end_pos, label, program} =>
        [P.join ["proof-step", "tactic", Int.toString start_pos, Int.toString end_pos, label, program]]
    | HolbuildProofIr.StepList {start_pos, end_pos, label, program} =>
        [P.join ["proof-step", "list", Int.toString start_pos, Int.toString end_pos, label, program]]
    | HolbuildProofIr.StepChoice {start_pos, end_pos, label, program, alternatives} =>
        [P.join (["proof-step", "choice", Int.toString start_pos, Int.toString end_pos, label, program] @ alternatives)]
    | HolbuildProofIr.StepListChoice {start_pos, end_pos, label, program, alternatives} =>
        [P.join (["proof-step", "list-choice", Int.toString start_pos, Int.toString end_pos, label, program] @ alternatives)]
    | HolbuildProofIr.StepEach {start_pos, end_pos, body} =>
        P.join ["proof-step", "each", Int.toString start_pos, Int.toString end_pos] :: emit_steps body @
        [P.join ["proof-step", "end", Int.toString start_pos, Int.toString end_pos]]
    | HolbuildProofIr.StepSelectFirstSolve {start_pos, end_pos, body} =>
        P.join ["proof-step", "select-first-solve", Int.toString start_pos, Int.toString end_pos] :: emit_steps body @
        [P.join ["proof-step", "end", Int.toString start_pos, Int.toString end_pos]]
    | HolbuildProofIr.StepCases {start_pos, end_pos, cases} =>
        let
          fun emit_case (i, body) =
            P.join ["proof-step", "case", Int.toString start_pos, Int.toString end_pos, Int.toString i] :: emit_steps body
          val indexed = ListPair.zip (List.tabulate(length cases, fn i => i + 1), cases)
        in
          P.join ["proof-step", "cases", Int.toString start_pos, Int.toString end_pos] ::
          List.concat (map emit_case indexed) @
          [P.join ["proof-step", "end", Int.toString start_pos, Int.toString end_pos]]
        end
    | HolbuildProofIr.StepPlain {start_pos, end_pos, label, program} =>
        [P.join ["proof-step", "plain", Int.toString start_pos, Int.toString end_pos, label, program]]
and emit_steps steps = List.concat (map emit_step steps)

fun emit_proof_plan ({name, tactic_start, tactic_end, steps} : PI.theorem_plan) =
  P.join ["begin-proof-ir", name, Int.toString tactic_start, Int.toString tactic_end, plan_sml steps] ::
  emit_steps steps @
  [P.join ["end-proof-ir", name]]

fun emit_proof_plan_with_id id ({name, tactic_start, tactic_end, steps} : PI.theorem_plan) =
  P.join ["begin-proof-ir", id, name, Int.toString tactic_start, Int.toString tactic_end, plan_sml steps] ::
  emit_steps steps @
  [P.join ["end-proof-ir", id]]

fun span_lines path wants =
  let val text = read_all_file path
  in
    if member "boundaries-recovering" wants then
      let val {boundaries, errors} = S.scan_recovering path text
      in map emit_boundary boundaries @ map (fn e => P.join ["parse-error", e]) errors end
    else if member "boundaries-strict" wants then map emit_boundary (S.scan_strict path text)
    else if member "boundaries" wants then map emit_boundary (S.scan path text)
    else if member "terminations-strict" wants then map emit_termination (S.scan_terminations_strict path text)
    else []
  end

fun analyse_file ({id, path, wants} : file_req) =
  let
    val deps_lines = if null wants orelse member "deps" wants then emit_deps (D.extract path) else []
    val span_lines = span_lines path wants
  in
    P.join ["begin-file", id] :: deps_lines @ span_lines @ [P.join ["end-file", id]]
  end

fun proof_ir_plan_response items =
  let
    fun one ({id, name, tactic_start, tactic_end, tactic_text} : proof_req) =
      emit_proof_plan_with_id id (PI.plan_text {name = name, tactic_start = tactic_start,
                                                tactic_end = tactic_end, tactic_text = tactic_text})
  in List.concat (map one items) end

fun response req =
  String.concatWith "\n" ([P.join ["version", P.protocol_version], P.join ["ok"]] @
                          (case req of Analyse files => List.concat (map analyse_file files)
                                     | ProofIrPlan items => proof_ir_plan_response items) @
                          [P.join ["end"]]) ^ "\n"

fun arg_value flag args =
  case args of
      [] => NONE
    | x :: y :: rest => if x = flag then SOME y else arg_value flag (y :: rest)
    | _ :: rest => arg_value flag rest

fun main args =
  if member "--version" args then (print ("holbuild-hol-analyser " ^ P.analyser_format_version ^ "\n"); OS.Process.success)
  else
    case (arg_value "--request" args, arg_value "--response" args) of
        (SOME req, SOME resp) =>
          ((write_file resp (response (parse_request req)); OS.Process.success)
           handle Error msg => (TextIO.output(TextIO.stdErr, msg ^ "\n"); OS.Process.failure)
                | D.Error msg => (TextIO.output(TextIO.stdErr, msg ^ "\n"); OS.Process.failure)
                | S.Error msg => (TextIO.output(TextIO.stdErr, msg ^ "\n"); OS.Process.failure)
                | PI.Error msg => (TextIO.output(TextIO.stdErr, msg ^ "\n"); OS.Process.failure)
                | e => (TextIO.output(TextIO.stdErr, General.exnMessage e ^ "\n"); OS.Process.failure))
      | _ => (TextIO.output(TextIO.stdErr, "usage: holbuild-hol-analyser --request FILE --response FILE\n"); OS.Process.failure)

end
