structure HolbuildAnalyserTheorySpanExtract =
struct

exception Error of string

type boundary = {kind : string, name : string, safe_name : string, theorem_start : int,
                 theorem_stop : int, boundary : int, tactic_start : int,
                 tactic_end : int, tactic_text : string,
                 has_proof_attrs : bool, prefix_hash : string}

type termination = {name : string, safe_name : string, definition_start : int,
                    definition_stop : int, boundary : int,
                    quote_start : int, quote_end : int, quote_text : string,
                    tactic_start : int, tactic_end : int, tactic_text : string}

fun is_ident c = Char.isAlphaNum c orelse c = #"_" orelse c = #"'"
fun safe_name name =
  let val s = String.map (fn c => if is_ident c then c else #"_") name
  in if s = "" then "unnamed" else s end
fun starts_with text i needle =
  let val n = size text val m = size needle
  in i + m <= n andalso String.substring(text, i, m) = needle end
fun skip_comment text i =
  let val n = size text
      fun loop j depth =
        if j >= n then n
        else if starts_with text j "(*" then loop (j + 2) (depth + 1)
        else if starts_with text j "*)" then if depth = 1 then j + 2 else loop (j + 2) (depth - 1)
        else loop (j + 1) depth
  in loop (i + 2) 1 end
fun skip_ws_comments text i =
  let val n = size text
      fun loop j =
        if j >= n then n
        else if Char.isSpace (String.sub(text, j)) then loop (j + 1)
        else if starts_with text j "(*" then loop (skip_comment text j)
        else j
  in loop i end
fun statement_boundary text i =
  let val j = skip_ws_comments text i
  in if j < size text andalso String.sub(text, j) = #";" then j + 1 else i end
fun slice text start stop =
  if start < 0 orelse stop < start orelse stop > size text then raise Error "AST report span is outside source text"
  else String.substring(text, start, stop - start)
fun prefix_hash text boundary = HolbuildHash.string_sha1 (String.substring(text, 0, boundary))

fun bool_digit true = "1" | bool_digit false = "0"
fun attr_args NONE = [] | attr_args (SOME {attrs, ...}) = #args attrs
fun resume_label_and_attrs id attrs =
  let val args = attr_args attrs
      val (label, rest) = case args of {key, bind = NONE} :: rest => (#2 key, rest) | _ => ("", args)
      fun is_smlname {key = (_, "smlname"), ...} = true | is_smlname _ = false
      val proof_attrs = List.filter (not o is_smlname) rest
      val suffix = if label = "" then "" else "[" ^ label ^ "]"
  in {name = id ^ suffix, has_attrs = not (null proof_attrs)} end

fun parser_reader source_text = let val fed = ref false in fn _ => if !fed then "" else (fed := true; source_text) end
fun ignore_parse_error _ _ _ = ()

fun line_number_at text offset =
  let val limit = Int.min(offset, size text)
      fun loop i line = if i >= limit then line else if String.sub(text, i) = #"\n" then loop (i + 1) (line + 1) else loop (i + 1) line
  in loop 0 1 end
fun column_number_at text offset =
  let val limit = Int.min(offset, size text)
      fun loop i col = if i >= limit then col else if String.sub(text, i) = #"\n" then loop (i + 1) 1 else loop (i + 1) (col + 1)
  in loop 0 1 end
fun source_lines source_text = String.fields (fn c => c = #"\n") source_text
fun nth_line lines n = List.nth(lines, n - 1) handle _ => ""
fun spaces n = String.concat (List.tabulate(Int.max(0, n), fn _ => " "))
fun source_context_text source_text line =
  let val lines = source_lines source_text
      val start = Int.max(1, line - 2)
      val stop = Int.min(length lines, line + 2)
      val width = size (Int.toString stop)
      fun padded n = spaces (width - size (Int.toString n)) ^ Int.toString n
      fun row n = String.concat [if n = line then "> " else "  ", padded n, " | ", nth_line lines n, "\n"]
      fun loop n acc = if n > stop then rev acc else loop (n + 1) (row n :: acc)
  in String.concat (loop start []) end
fun parse_error_text source_path source_text _ (start, _) msg =
  let val line = line_number_at source_text start
      val col = column_number_at source_text start
  in String.concat ["HOL source parse error: ", msg, "\n", "source: ", source_path, ":", Int.toString line, ":", Int.toString col, "\n", source_context_text source_text line] end
fun raise_parse_error source_path source_text loc span msg = raise Error (parse_error_text source_path source_text loc span msg)

fun boundaries_from_result source result =
  let fun boundary kind name theorem_start theorem_stop tactic_start tactic_end has_attrs =
        let val b = statement_boundary source theorem_stop
        in {kind = kind, name = name, safe_name = safe_name name, theorem_start = theorem_start,
            theorem_stop = theorem_stop, boundary = b, tactic_start = tactic_start, tactic_end = tactic_end,
            tactic_text = slice source tactic_start tactic_end, has_proof_attrs = has_attrs,
            prefix_hash = prefix_hash source b} end
      fun loop acc =
        case #parseDec result () of
            NONE => rev acc
          | SOME (HOLSourceAST.HOLTheoremDecl {theorem_, id = (_, name), proof_, tac, stop, ...}) =>
              let val (ts, te) = HOLSourceAST.expSpan tac
                  val has_attrs = case proof_ of SOME {attrs = SOME _, ...} => true | _ => false
              in loop (boundary "theorem" name theorem_ stop ts te has_attrs :: acc) end
          | SOME (HOLSourceAST.HOLResume {resume_, id = (_, id_name), attrs, tac, stop, ...}) =>
              let val (ts, te) = HOLSourceAST.expSpan tac
                  val {name, has_attrs} = resume_label_and_attrs id_name attrs
              in loop (boundary "resume" name resume_ stop ts te has_attrs :: acc) end
          | SOME _ => loop acc
  in loop [] end

fun scan source_path source_text =
  boundaries_from_result source_text (HOLSourceParser.parseSML source_path (parser_reader source_text) ignore_parse_error HOLSourceParser.initialScope)
fun scan_strict source_path source_text =
  boundaries_from_result source_text (HOLSourceParser.parseSML source_path (parser_reader source_text) (raise_parse_error source_path source_text) HOLSourceParser.initialScope)
fun scan_recovering source_path source_text =
  let val errors = ref []
      fun record loc span msg = errors := parse_error_text source_path source_text loc span msg :: !errors
      val result = HOLSourceParser.parseSML source_path (parser_reader source_text) record HOLSourceParser.initialScope
  in {boundaries = boundaries_from_result source_text result, errors = rev (!errors)} end

fun qdecl_start (HOLSourceAST.QuoteLiteral (pos, _)) = pos
  | qdecl_start (HOLSourceAST.QuoteAntiq {caret_, ...}) = caret_
  | qdecl_start (HOLSourceAST.DefinitionLabel {left, ...}) = left
fun qdecl_stop (HOLSourceAST.QuoteLiteral (pos, value)) = pos + size value
  | qdecl_stop (HOLSourceAST.QuoteAntiq {exp, ...}) = #2 (HOLSourceAST.expSpan exp)
  | qdecl_stop (HOLSourceAST.DefinitionLabel {stop, ...}) = stop
fun first_qdecl_start [] fallback = fallback | first_qdecl_start (q :: _) _ = qdecl_start q
fun last_qdecl_stop [] fallback = fallback | last_qdecl_stop [q] _ = qdecl_stop q | last_qdecl_stop (_ :: rest) fallback = last_qdecl_stop rest fallback
fun termination_diagnostics source result =
  let fun quote_start (SOME colon) _ _ = colon + 1 | quote_start NONE quote fallback = first_qdecl_start quote fallback
      fun quote_end quote fallback = last_qdecl_stop quote fallback
      fun diagnostic {definition_, name, colon, quote, termination_, tac, stop} =
        let val qstart = quote_start colon quote definition_
            val qend = Int.min(termination_, quote_end quote termination_)
            val (ts, te) = HOLSourceAST.expSpan tac
            val b = statement_boundary source stop
        in {name = name, safe_name = safe_name name, definition_start = definition_, definition_stop = stop,
            boundary = b, quote_start = qstart, quote_end = qend, quote_text = slice source qstart qend,
            tactic_start = ts, tactic_end = te, tactic_text = slice source ts te} end
      fun loop acc =
        case #parseDec result () of
            NONE => rev acc
          | SOME (HOLSourceAST.HOLDefinition {definition_, id = (_, name), colon, quote, termination = SOME {termination_, tac}, stop, ...}) =>
              loop (diagnostic {definition_ = definition_, name = name, colon = colon, quote = quote, termination_ = termination_, tac = tac, stop = stop} :: acc)
          | SOME _ => loop acc
  in loop [] end
fun scan_terminations_strict source_path source_text =
  termination_diagnostics source_text (HOLSourceParser.parseSML source_path (parser_reader source_text) (raise_parse_error source_path source_text) HOLSourceParser.initialScope)

end
