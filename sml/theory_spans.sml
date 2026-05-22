structure HolbuildTheorySpans =
struct

fun bool_digit true = "1"
  | bool_digit false = "0"

fun proof_unit_report_line kind name theorem_start theorem_stop tactic_start tactic_end has_attrs =
  String.concatWith "\t"
    [kind, name, Int.toString theorem_start, Int.toString theorem_stop,
     Int.toString tactic_start, Int.toString tactic_end, bool_digit has_attrs]

fun attr_args NONE = []
  | attr_args (SOME {attrs, ...}) = #args attrs

fun resume_label_and_attrs id attrs =
  let
    val args = attr_args attrs
    val (label, rest) =
      case args of
          {key, bind = NONE} :: rest => (#2 key, rest)
        | _ => ("", args)
    fun is_smlname {key = (_, "smlname"), ...} = true
      | is_smlname _ = false
    val proof_attrs = List.filter (not o is_smlname) rest
    val suffix = if label = "" then "" else "[" ^ label ^ "]"
  in
    {name = id ^ suffix, has_attrs = not (null proof_attrs)}
  end

fun theorem_report_lines result =
  let
    fun loop acc =
      case #parseDec result () of
          NONE => rev acc
        | SOME (HOLSourceAST.HOLTheoremDecl {theorem_, id = (_, name), proof_, tac, stop, ...}) =>
            let
              val (tactic_start, tactic_end) = HOLSourceAST.expSpan tac
              val has_attrs = case proof_ of SOME {attrs = SOME _, ...} => true | _ => false
              val line = proof_unit_report_line "theorem" name theorem_ stop tactic_start tactic_end has_attrs
            in
              loop (line :: acc)
            end
        | SOME (HOLSourceAST.HOLResume {resume_, id = (_, id_name), attrs, tac, stop, ...}) =>
            let
              val (tactic_start, tactic_end) = HOLSourceAST.expSpan tac
              val {name, has_attrs} = resume_label_and_attrs id_name attrs
              val line = proof_unit_report_line "resume" name resume_ stop tactic_start tactic_end has_attrs
            in
              loop (line :: acc)
            end
        | SOME _ => loop acc
  in
    loop []
  end

fun qdecl_start (HOLSourceAST.QuoteLiteral (pos, _)) = pos
  | qdecl_start (HOLSourceAST.QuoteAntiq {caret_, ...}) = caret_
  | qdecl_start (HOLSourceAST.DefinitionLabel {left, ...}) = left

fun qdecl_stop (HOLSourceAST.QuoteLiteral (pos, value)) = pos + size value
  | qdecl_stop (HOLSourceAST.QuoteAntiq {exp, ...}) = #2 (HOLSourceAST.expSpan exp)
  | qdecl_stop (HOLSourceAST.DefinitionLabel {stop, ...}) = stop

fun first_qdecl_start [] fallback = fallback
  | first_qdecl_start (q :: _) _ = qdecl_start q

fun last_qdecl_stop [] fallback = fallback
  | last_qdecl_stop [q] _ = qdecl_stop q
  | last_qdecl_stop (_ :: rest) fallback = last_qdecl_stop rest fallback

fun slice text start stop =
  if start < 0 orelse stop < start orelse stop > size text then
    raise HolbuildTheoryCheckpoints.Error "AST termination report span is outside source text"
  else String.substring(text, start, stop - start)

fun termination_diagnostics source result =
  let
    fun quote_start (SOME colon) _ _ = colon + 1
      | quote_start NONE quote fallback = first_qdecl_start quote fallback
    fun quote_end quote fallback = last_qdecl_stop quote fallback
    fun diagnostic {definition_, name, colon, quote, termination_, tac, stop} =
      let
        val qstart = quote_start colon quote definition_
        val qend = Int.min(termination_, quote_end quote termination_)
        val (tactic_start, tactic_end) = HOLSourceAST.expSpan tac
        val boundary = HolbuildTheoryCheckpoints.statement_boundary source stop
      in
        {name = name, safe_name = HolbuildTheoryCheckpoints.safe_name name,
         definition_start = definition_, definition_stop = stop, boundary = boundary,
         quote_start = qstart, quote_end = qend,
         quote_text = slice source qstart qend,
         tactic_start = tactic_start, tactic_end = tactic_end,
         tactic_text = slice source tactic_start tactic_end}
      end
    fun loop acc =
      case #parseDec result () of
          NONE => rev acc
        | SOME (HOLSourceAST.HOLDefinition {definition_, id = (_, name), colon, quote,
                                            termination = SOME {termination_, tac}, stop, ...}) =>
            loop (diagnostic {definition_ = definition_, name = name,
                              colon = colon, quote = quote,
                              termination_ = termination_, tac = tac,
                              stop = stop} :: acc)
        | SOME _ => loop acc
  in
    loop []
  end

fun parser_reader source_text =
  let val fed = ref false
  in fn _ => if !fed then "" else (fed := true; source_text) end

fun ignore_parse_error _ _ _ = ()

fun parse_error_text source_path source_text loc span msg =
  (HolbuildTheoryDiagnostics.parse_error source_path source_text loc span msg; "")
  handle Fail text => text

fun raise_parse_error source_path source_text loc span msg =
  raise HolbuildTheoryCheckpoints.Error
    (parse_error_text source_path source_text loc span msg)

fun scan_with_error_handler source_path source_text parse_error =
  let
    val result = HOLSourceParser.parseSML source_path (parser_reader source_text)
                   parse_error HOLSourceParser.initialScope
    val report = String.concatWith "\n" (theorem_report_lines result) ^ "\n"
  in
    HolbuildTheoryCheckpoints.discover_from_report {source = source_text, report = report}
  end

fun scan_with_recovery source_path source_text =
  let
    val errors = ref []
    fun record_parse_error loc span msg =
      errors := parse_error_text source_path source_text loc span msg :: !errors
    val result = HOLSourceParser.parseSML source_path (parser_reader source_text)
                   record_parse_error HOLSourceParser.initialScope
    val report = String.concatWith "\n" (theorem_report_lines result) ^ "\n"
    val boundaries = HolbuildTheoryCheckpoints.discover_from_report {source = source_text, report = report}
  in
    {boundaries = boundaries, errors = rev (!errors)}
  end

fun scan source_path source_text =
  scan_with_error_handler source_path source_text ignore_parse_error

fun scan_strict source_path source_text =
  scan_with_error_handler source_path source_text (raise_parse_error source_path source_text)

fun scan_terminations_with_error_handler source_path source_text parse_error =
  let
    val result = HOLSourceParser.parseSML source_path (parser_reader source_text)
                   parse_error HOLSourceParser.initialScope
  in
    termination_diagnostics source_text result
  end

fun scan_terminations source_path source_text =
  scan_terminations_with_error_handler source_path source_text ignore_parse_error

fun scan_terminations_strict source_path source_text =
  scan_terminations_with_error_handler source_path source_text (raise_parse_error source_path source_text)

end
