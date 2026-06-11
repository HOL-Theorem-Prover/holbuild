structure HolbuildTheorySpans =
struct

structure P = HolbuildAnalysisProtocol

fun read_all path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end

fun write_file path text =
  let val out = TextIO.openOut path
  in TextIO.output(out, text); TextIO.closeOut out end

fun int field text =
  case Int.fromString text of
      SOME n => n
    | NONE => raise HolbuildTheoryCheckpoints.Error ("bad analyser " ^ field ^ ": " ^ text)

fun analyser () =
  case HolbuildDependencies.current_analyser_path () of
      SOME path => path
    | NONE => raise HolbuildTheoryCheckpoints.Error "internal error: HOL analyser is not configured"

fun run want source_path =
  let
    val req = OS.FileSys.tmpName ()
    val resp = OS.FileSys.tmpName ()
    val err = OS.FileSys.tmpName ()
    val request = String.concatWith "\n"
      [P.join ["version", P.protocol_version],
       P.join ["command", "analyse"],
       P.join ["file", "1", source_path, want],
       P.join ["end"]] ^ "\n"
    val _ = write_file req request
    val status = OS.Process.system (HolbuildHash.quote (analyser ()) ^ " --request " ^ HolbuildHash.quote req ^
                                    " --response " ^ HolbuildHash.quote resp ^ " 2> " ^ HolbuildHash.quote err)
    val stderr = read_all err handle _ => ""
    val _ = OS.FileSys.remove req handle OS.SysErr _ => ()
    val _ = OS.FileSys.remove err handle OS.SysErr _ => ()
  in
    if OS.Process.isSuccess status then
      let val lines = String.tokens (fn c => c = #"\n") (read_all resp)
          val _ = OS.FileSys.remove resp handle OS.SysErr _ => ()
      in lines end
    else
      let val _ = OS.FileSys.remove resp handle OS.SysErr _ => ()
      in raise HolbuildTheoryCheckpoints.Error ("holbuild-hol-analyser failed for " ^ source_path ^
                                                (if stderr = "" then "" else "\n" ^ stderr)) end
  end

fun parse_boundary fields =
  case fields of
      ["boundary", kind, name, safe_name, theorem_start, theorem_stop, boundary,
       tactic_start, tactic_end, has_attrs, prefix_hash, tactic_text] =>
        {kind = kind, name = name, safe_name = safe_name,
         theorem_start = int "theorem_start" theorem_start,
         theorem_stop = int "theorem_stop" theorem_stop,
         boundary = int "boundary" boundary,
         tactic_start = int "tactic_start" tactic_start,
         tactic_end = int "tactic_end" tactic_end,
         tactic_text = tactic_text,
         has_proof_attrs = has_attrs = "1",
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
         tactic_text = tactic_text}
    | _ => raise HolbuildTheoryCheckpoints.Error "bad analyser termination record"

fun response_records want source_path =
  let
    fun loop lines in_file acc errors =
      case lines of
          [] => raise HolbuildTheoryCheckpoints.Error "analyser response missing end"
        | line :: rest =>
            (case P.split line of
                 ["version", v] =>
                   if v = P.protocol_version then loop rest in_file acc errors
                   else raise HolbuildTheoryCheckpoints.Error ("unsupported analyser protocol version: " ^ v)
               | ["ok"] => loop rest in_file acc errors
               | ["begin-file", "1"] => loop rest true acc errors
               | ["end-file", "1"] => loop rest false acc errors
               | ["end"] => (rev acc, rev errors)
               | ["parse-error", text] => if in_file then loop rest in_file acc (text :: errors) else loop rest in_file acc errors
               | fields => if in_file then loop rest in_file (fields :: acc) errors else loop rest in_file acc errors)
  in
    loop (run want source_path) false [] []
  end

fun scan source_path _ =
  let val (records, _) = response_records "boundaries" source_path
  in map parse_boundary records end

fun scan_strict source_path _ =
  let val (records, _) = response_records "boundaries-strict" source_path
  in map parse_boundary records end

fun scan_with_recovery source_path _ =
  let val (records, errors) = response_records "boundaries-recovering" source_path
  in {boundaries = map parse_boundary records, errors = errors} end

fun scan_terminations_strict source_path _ =
  let val (records, _) = response_records "terminations-strict" source_path
  in map parse_termination records end

fun scan_terminations source_path source_text = scan_terminations_strict source_path source_text

end
