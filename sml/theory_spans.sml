structure HolbuildTheorySpans =
struct

structure P = HolbuildAnalysisProtocol

fun int field text =
  case Int.fromString text of
      SOME n => n
    | NONE => raise HolbuildTheoryCheckpoints.Error ("bad analyser " ^ field ^ ": " ^ text)

fun analyser () =
  case HolbuildDependencies.current_analyser_path () of
      SOME path => path
    | NONE => raise HolbuildTheoryCheckpoints.Error "internal error: HOL analyser is not configured"

fun run wants source_path =
  let
    val request = String.concatWith "\n"
      [P.join ["version", P.protocol_version],
       P.join ["command", "analyse"],
       P.join (["file", "1", source_path] @ wants),
       P.join ["end"]] ^ "\n"
    val result as {output, response, ...} =
      HolbuildDependencies.run_analyser {analyser = analyser (), request = request, capture_stderr = true}
  in
    print output;
    case response of
        SOME text => String.tokens (fn c => c = #"\n") text
      | NONE => raise HolbuildTheoryCheckpoints.Error ("holbuild-hol-analyser failed for " ^ source_path ^
          "\n" ^ HolbuildDependencies.analyser_failure result)
  end

fun parse_boundary fields =
  case fields of
      ["boundary", kind, name, safe_name, theorem_start, theorem_stop, boundary,
       tactic_start, tactic_end, proof_attrs, prefix_hash, tactic_text] =>
        {kind = kind, name = name, safe_name = safe_name,
         theorem_start = int "theorem_start" theorem_start,
         theorem_stop = int "theorem_stop" theorem_stop,
         boundary = int "boundary" boundary,
         tactic_start = int "tactic_start" tactic_start,
         tactic_end = int "tactic_end" tactic_end,
         tactic_text = tactic_text,
         proof_attrs = P.decode_proof_attrs proof_attrs,
         prefix_hash = prefix_hash}
    | _ => raise HolbuildTheoryCheckpoints.Error "bad analyser boundary record"

fun parse_termination fields =
  case fields of
      ["termination", name, safe_name, definition_start, definition_stop, boundary,
       quote_start, quote_end, tactic_start, tactic_end, quote_text, tactic_text] =>
        {name = name, safe_name = safe_name,
         definition_start = int "definition_start" definition_start,
         definition_stop = int "definition_stop" definition_stop,
         boundary = int "boundary" boundary,
         quote_start = int "quote_start" quote_start,
         quote_end = int "quote_end" quote_end,
         quote_text = quote_text,
         tactic_start = int "tactic_start" tactic_start,
         tactic_end = int "tactic_end" tactic_end,
         tactic_text = tactic_text,
         proof_ir_plan = NONE}
    | _ => raise HolbuildTheoryCheckpoints.Error "bad analyser termination record"

fun response_records wants source_path =
  let
    fun incomplete detail =
      raise HolbuildTheoryCheckpoints.Error
        ("incomplete analyser response for " ^ source_path ^ ": " ^ detail)
    fun loop lines in_file completed acc errors =
      case lines of
          [] => incomplete "missing end"
        | line :: rest =>
            (case P.split line of
                 ["version", v] =>
                   if v = P.protocol_version then loop rest in_file completed acc errors
                   else raise HolbuildTheoryCheckpoints.Error ("unsupported analyser protocol version: " ^ v)
               | ["ok"] => loop rest in_file completed acc errors
               | ["begin-file", "1"] =>
                   if in_file orelse completed then incomplete "duplicate begin-file"
                   else loop rest true completed acc errors
               | ["end-file", "1"] =>
                   if in_file then loop rest false true acc errors
                   else incomplete "end-file without begin-file"
               | ["end"] =>
                   if in_file then incomplete "missing end-file"
                   else if completed then (rev acc, rev errors)
                   else incomplete "missing file envelope"
               | ["parse-error", text] =>
                   if in_file then loop rest in_file completed acc (text :: errors)
                   else loop rest in_file completed acc errors
               | fields =>
                   if in_file then loop rest in_file completed (fields :: acc) errors
                   else loop rest in_file completed acc errors)
  in
    loop (run wants source_path) false false [] []
  end

fun boundary_record fields =
  case fields of
      "boundary" :: _ => true
    | _ => false

fun termination_record fields =
  case fields of
      "termination" :: _ => true
    | _ => false

(* Why the response has no terminations although the source has a parse
   error the boundaries were recovered from. *)
fun termination_error records =
  case List.find (fn "terminations-error" :: _ => true | _ => false) records of
      SOME [_, text] => SOME text
    | SOME _ => raise HolbuildTheoryCheckpoints.Error "bad analyser terminations-error record"
    | NONE => NONE

fun scan source_path _ =
  let val (records, _) = response_records ["boundaries"] source_path
  in map parse_boundary records end

fun scan_strict source_path _ =
  let val (records, _) = response_records ["boundaries-strict"] source_path
  in map parse_boundary records end

fun scan_with_recovery source_path _ =
  let val (records, errors) = response_records ["boundaries-recovering"] source_path
  in {boundaries = map parse_boundary (List.filter boundary_record records),
      errors = errors} end

fun scan_terminations_strict source_path _ =
  let val (records, _) = response_records ["terminations-strict"] source_path
  in map parse_termination (List.filter termination_record records) end

fun scan_boundaries_and_terminations_recovering_strict source_path _ =
  let val (records, errors) =
        response_records ["boundaries-recovering", "terminations-strict"] source_path
  in
    {boundaries = map parse_boundary (List.filter boundary_record records),
     errors = errors,
     terminations = map parse_termination (List.filter termination_record records),
     termination_error = termination_error records}
  end

(* As scan_boundaries_and_terminations_recovering_strict, with each
   boundary's and termination's proof-IR plan expression and factories, in
   their order, from the same analyser process. *)
fun scan_with_proof_ir_plans source_path _ =
  let
    val (records, errors) =
      response_records ["boundaries-recovering", "terminations-strict", "proof-ir-plans"] source_path
    val boundaries = map parse_boundary (List.filter boundary_record records)
    val terminations = map parse_termination (List.filter termination_record records)
    val plans = List.mapPartial (fn "begin-proof-ir" :: fields => SOME fields | _ => NONE) records
    fun plan prefix (i, fields) =
      case fields of
          [id, _, _, _, expr, factories] =>
            if id = prefix ^ Int.toString i then SOME (expr, factories)
            else raise HolbuildTheoryCheckpoints.Error ("bad proof-IR response id: " ^ id ^ ", expected " ^
                                                        prefix ^ Int.toString i)
        | _ => raise HolbuildTheoryCheckpoints.Error "bad analyser proof-IR record"
    fun numbered xs = ListPair.zip (List.tabulate (length xs, fn i => i), xs)
    val nb = length boundaries
  in
    if length plans <> nb + length terminations then
      raise HolbuildTheoryCheckpoints.Error
        ("incomplete analyser response for " ^ source_path ^ ": " ^ Int.toString (length plans) ^
         " proof-IR plans for " ^ Int.toString nb ^ " boundaries and " ^
         Int.toString (length terminations) ^ " terminations")
    else
      {boundaries = boundaries, errors = errors, terminations = terminations,
       termination_error = termination_error records,
       boundary_plans = map (plan "b") (numbered (List.take (plans, nb))),
       termination_plans = map (plan "t") (numbered (List.drop (plans, nb)))}
  end

end
