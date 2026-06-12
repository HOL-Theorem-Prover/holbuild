structure HolbuildAnalyserMain =
struct

structure P = HolbuildAnalysisProtocol
structure D = HolbuildAnalyserDependencyExtract
structure S = HolbuildAnalyserTheorySpanExtract
structure PI = HolbuildAnalyserProofIrExtract

exception Error of string

type file_req = {id : string, path : string, wants : string list}

fun die msg = raise Error msg

fun read_all path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end

fun write_file path text =
  let val out = TextIO.openOut path
  in TextIO.output(out, text); TextIO.closeOut out end

fun member x xs = List.exists (fn y => x = y) xs

fun parse_request path =
  let
    val lines = String.tokens (fn c => c = #"\n") (read_all path)
    fun loop lines files =
      case lines of
          [] => die "request missing end"
        | line :: rest =>
            (case P.split line of
                 ["version", v] => if v = P.protocol_version then loop rest files else die ("unsupported protocol version: " ^ v)
               | ["command", "analyse"] => loop rest files
               | "file" :: id :: file :: wants => loop rest ({id = id, path = file, wants = wants} :: files)
               | ["end"] => rev files
               | [] => loop rest files
               | fields => die ("bad request line: " ^ line))
  in
    loop lines []
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

fun branch_phase_text HolbuildProofIr.BranchStart = "start"
  | branch_phase_text HolbuildProofIr.BranchSuffix = "suffix"
  | branch_phase_text HolbuildProofIr.BranchClose = "close"

fun emit_step step =
  case step of
      HolbuildProofIr.StepTactic {start_pos, end_pos, label, program} =>
        P.join ["proof-step", "tactic", Int.toString start_pos, Int.toString end_pos, label, program]
    | HolbuildProofIr.StepList {start_pos, end_pos, label, program} =>
        P.join ["proof-step", "list", Int.toString start_pos, Int.toString end_pos, label, program]
    | HolbuildProofIr.StepChoice {start_pos, end_pos, label, program, alternatives} =>
        P.join (["proof-step", "choice", Int.toString start_pos, Int.toString end_pos, label, program] @ alternatives)
    | HolbuildProofIr.StepListChoice {start_pos, end_pos, label, program, alternatives} =>
        P.join (["proof-step", "list-choice", Int.toString start_pos, Int.toString end_pos, label, program] @ alternatives)
    | HolbuildProofIr.StepThen1 {start_pos, end_pos, first_label, label, list_suffix, first_program, second_program} =>
        P.join ["proof-step", "then1", Int.toString start_pos, Int.toString end_pos, label,
                if list_suffix then "1" else "0", first_label, first_program, second_program]
    | HolbuildProofIr.StepGentleThen1 {start_pos, end_pos, label, list_suffix, first_program, second_program} =>
        P.join ["proof-step", "gentle-then1", Int.toString start_pos, Int.toString end_pos, label,
                if list_suffix then "1" else "0", first_program, second_program]
    | HolbuildProofIr.StepBranch {start_pos, end_pos, label, program, phase} =>
        P.join ["proof-step", "branch", Int.toString start_pos, Int.toString end_pos, label, program, branch_phase_text phase]
    | HolbuildProofIr.StepBranchList {start_pos, end_pos, label, program} =>
        P.join ["proof-step", "branch-list", Int.toString start_pos, Int.toString end_pos, label, program]
    | HolbuildProofIr.StepPlain {start_pos, end_pos, label, program} =>
        P.join ["proof-step", "plain", Int.toString start_pos, Int.toString end_pos, label, program]

fun emit_proof_plan ({name, tactic_start, tactic_end, steps} : PI.theorem_plan) =
  P.join ["begin-proof-ir", name, Int.toString tactic_start, Int.toString tactic_end] ::
  map emit_step steps @
  [P.join ["end-proof-ir", name]]

fun proof_ir_lines path wants =
  if member "proof-ir" wants then List.concat (map emit_proof_plan (PI.plans path)) else []

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
    val proof_ir_lines = proof_ir_lines path wants
  in
    P.join ["begin-file", id] :: deps_lines @ span_lines @ proof_ir_lines @ [P.join ["end-file", id]]
  end

fun response files =
  String.concatWith "\n" ([P.join ["version", P.protocol_version], P.join ["ok"]] @
                          List.concat (map analyse_file files) @
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
