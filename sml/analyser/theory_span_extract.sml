structure HolbuildAnalyserTheorySpanExtract =
struct

exception Error of string

type boundary = {kind : string, name : string, safe_name : string, theorem_start : int,
                 theorem_stop : int, boundary : int, tactic_start : int,
                 tactic_end : int, tactic_text : string,
                 proof_attrs : (string * string list) list, prefix_hash : string}

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

fun attr_args NONE = [] | attr_args (SOME {attrs, ...}) = #args attrs
fun proof_kvals args =
  map (fn {key = (_, key), bind} =>
    (key, case bind of NONE => [] | SOME {vals, ...} => map #2 vals)) args
fun resume_label_and_attrs id attrs =
  let val args = attr_args attrs
      val (label, rest) = case args of {key, bind = NONE} :: rest => (#2 key, rest) | _ => ("", args)
      fun is_smlname {key = (_, "smlname"), ...} = true | is_smlname _ = false
      fun remove_smlname [] = []
        | remove_smlname (arg :: rest) =
            if is_smlname arg then rest else arg :: remove_smlname rest
      val proof_attrs = proof_kvals (remove_smlname rest)
      val suffix = if label = "" then "" else "[" ^ label ^ "]"
  in {name = id ^ suffix, proof_attrs = proof_attrs} end

fun parser_reader source_text = let val fed = ref false in fn _ => if !fed then "" else (fed := true; source_text) end

fun line_number_at text offset =
  let val limit = Int.min(offset, size text)
      fun loop i line = if i >= limit then line else if String.sub(text, i) = #"\n" then loop (i + 1) (line + 1) else loop (i + 1) line
  in loop 0 1 end
fun column_number_at text offset =
  let val limit = Int.min(offset, size text)
      fun loop i col = if i >= limit then col else if String.sub(text, i) = #"\n" then loop (i + 1) 1 else loop (i + 1) (col + 1)
  in loop 0 1 end
fun line_start text i = if i > 0 andalso String.sub(text, i - 1) <> #"\n" then line_start text (i - 1) else i
fun line_end text i = if i < size text andalso String.sub(text, i) <> #"\n" then line_end text (i + 1) else i
fun spaces n = String.concat (List.tabulate(Int.max(0, n), fn _ => " "))
(* Lines LINE - 2 to LINE + 2 of the source, where LINE holds OFFSET, read
   around OFFSET rather than by splitting the whole source. *)
fun source_context_text source_text offset line =
  let val here = line_start source_text (Int.min(offset, size source_text))
      fun back n start acc =
        if n <= Int.max(1, line - 2) then (n, start) :: acc
        else back (n - 1) (line_start source_text (start - 1)) ((n, start) :: acc)
      fun forward n start acc =
        let val stop = line_end source_text start
        in if n >= line + 2 orelse stop >= size source_text then rev acc
           else forward (n + 1) (stop + 1) ((n + 1, stop + 1) :: acc) end
      val rows = back line here [] @ forward line here []
      val last = #1 (List.last rows)
      val width = size (Int.toString last)
      fun padded n = spaces (width - size (Int.toString n)) ^ Int.toString n
      fun row (n, start) =
        String.concat [if n = line then "> " else "  ", padded n, " | ",
                       String.substring(source_text, start, line_end source_text start - start), "\n"]
  in String.concat (map row rows) end
fun parse_error_text source_path source_text _ (start, _) msg =
  let val line = line_number_at source_text start
      val col = column_number_at source_text start
  in String.concat ["HOL source parse error: ", msg, "\n", "source: ", source_path, ":", Int.toString line, ":", Int.toString col, "\n", source_context_text source_text start line] end

fun qdecl_start (HOLSourceAST.QuoteLiteral (pos, _)) = pos
  | qdecl_start (HOLSourceAST.QuoteAntiq {caret_, ...}) = caret_
  | qdecl_start (HOLSourceAST.DefinitionLabel {left, ...}) = left
fun qdecl_stop (HOLSourceAST.QuoteLiteral (pos, value)) = pos + size value
  | qdecl_stop (HOLSourceAST.QuoteAntiq {exp, ...}) = #2 (HOLSourceAST.expSpan exp)
  | qdecl_stop (HOLSourceAST.DefinitionLabel {stop, ...}) = stop
fun first_qdecl_start [] fallback = fallback | first_qdecl_start (q :: _) _ = qdecl_start q
fun last_qdecl_stop [] fallback = fallback | last_qdecl_stop [q] _ = qdecl_stop q | last_qdecl_stop (_ :: rest) fallback = last_qdecl_stop rest fallback
fun termination_diagnostic source {definition_, name, colon, quote, termination_, tac, stop} =
  let fun quote_start (SOME colon) _ _ = colon + 1 | quote_start NONE quote fallback = first_qdecl_start quote fallback
      val qstart = quote_start colon quote definition_
      val qend = Int.min(termination_, last_qdecl_stop quote termination_)
      val (ts, te) = HOLSourceAST.expSpan tac
      val b = statement_boundary source stop
  in {name = name, safe_name = safe_name name, definition_start = definition_, definition_stop = stop,
      boundary = b, quote_start = qstart, quote_end = qend, quote_text = slice source qstart qend,
      tactic_start = ts, tactic_end = te, tactic_text = slice source ts te} end

(* How a scan treats theorem and resume blocks the parser reported an error
   in.  KeepErrored keeps them and ignores parse errors; Strict fails on the
   first parse error; Recovering drops them and returns the errors.  The
   build instruments the blocks it gets boundaries for, and instrumenting one
   the parser recovered from (a missing QED or Proof, an empty tactic) would
   hide or garble the error: replaying a failed-prefix checkpoint as
   `Theorem name = ...;` closes a block that has no QED.  So the script runs
   it as written and HOL reports the error.  Commands that only show a
   theorem's plan keep such blocks. *)
datatype boundary_mode = KeepErrored | Strict | Recovering

(* The source's theorem boundaries (if BOUNDARIES gives a mode) and its
   termination proofs (if TERMINATIONS), from one parse.  Terminations are
   strict: after a parse error there are none.  With Recovering that error is
   termination_error, so the boundaries still come back; otherwise the scan
   fails with it. *)
fun scan_spans source_path source {boundaries = mode, terminations = want_terminations} =
  let val errors = ref []
      val error_count = ref 0
      fun error_text (loc, span, msg) = parse_error_text source_path source loc span msg
      (* A parse error fails a strict request, so it stops the parse. *)
      val fatal = mode = SOME Strict orelse (want_terminations andalso mode <> SOME Recovering)
      fun record loc span msg =
        if fatal then raise Error (error_text (loc, span, msg))
        else (errors := (loc, span, msg) :: !errors; error_count := !error_count + 1)
      val result = HOLSourceParser.parseSML source_path (parser_reader source) record HOLSourceParser.initialScope
      fun boundary kind name theorem_start theorem_stop tactic_start tactic_end proof_attrs =
        {kind = kind, name = name, theorem_start = theorem_start, theorem_stop = theorem_stop,
         boundary = statement_boundary source theorem_stop, tactic_start = tactic_start,
         tactic_end = tactic_end, proof_attrs = proof_attrs}
      fun loop bs ts =
        let val errors_before = !error_count
            val dec = #parseDec result ()
            val keep = case mode of
                           NONE => false
                         | SOME KeepErrored => true
                         | SOME _ => !error_count = errors_before
        in
          case dec of
              NONE => (rev bs, rev ts)
            | SOME (HOLSourceAST.HOLTheoremDecl {theorem_, id = (_, name), proof_, tac, stop, ...}) =>
                if not keep then loop bs ts
                else
                  let val (s, e) = HOLSourceAST.expSpan tac
                      val proof_attrs = case proof_ of SOME {attrs, ...} => proof_kvals (attr_args attrs) | NONE => []
                  in loop (boundary "theorem" name theorem_ stop s e proof_attrs :: bs) ts end
            | SOME (HOLSourceAST.HOLResume {resume_, id = (_, id_name), attrs, tac, stop, ...}) =>
                if not keep then loop bs ts
                else
                  let val (s, e) = HOLSourceAST.expSpan tac
                      val {name, proof_attrs} = resume_label_and_attrs id_name attrs
                  in loop (boundary "resume" name resume_ stop s e proof_attrs :: bs) ts end
            | SOME (HOLSourceAST.HOLDefinition {definition_, id = (_, name), colon, quote, termination = SOME {termination_, tac}, stop, ...}) =>
                if not want_terminations orelse !error_count > 0 then loop bs ts
                else
                  loop bs (termination_diagnostic source
                             {definition_ = definition_, name = name, colon = colon, quote = quote,
                              termination_ = termination_, tac = tac, stop = stop} :: ts)
            | SOME _ => loop bs ts
        end
      val (pending, terminations) = loop [] []
      val parse_errors = rev (!errors)
      val first_error = case parse_errors of [] => NONE | e :: _ => SOME (error_text e)
      val (terminations, termination_error) =
        case first_error of
            SOME _ => ([], if want_terminations then first_error else NONE)
          | NONE => (terminations, NONE)
      val hashes = HolbuildHash.prefix_sha256s source (map #boundary pending)
      fun finish ({kind, name, theorem_start, theorem_stop, boundary, tactic_start, tactic_end, proof_attrs}, hash) =
        {kind = kind, name = name, safe_name = safe_name name, theorem_start = theorem_start,
         theorem_stop = theorem_stop, boundary = boundary, tactic_start = tactic_start, tactic_end = tactic_end,
         tactic_text = slice source tactic_start tactic_end, proof_attrs = proof_attrs, prefix_hash = hash}
  in
    {boundaries = ListPair.map finish (pending, hashes),
     errors = if mode = SOME Recovering then map error_text parse_errors else [],
     terminations = terminations,
     termination_error = termination_error}
  end

fun scan source_path source_text =
  #boundaries (scan_spans source_path source_text {boundaries = SOME KeepErrored, terminations = false})

end
