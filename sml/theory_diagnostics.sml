structure HolbuildTheoryDiagnostics =
struct

fun first_some f values =
  case values of
      [] => NONE
    | x :: xs =>
        case f x of
            SOME y => SOME y
          | NONE => first_some f xs

fun find_substring needle haystack =
  let
    val n = size needle
    val h = size haystack
    val first = if n = 0 then #"\000" else String.sub(needle, 0)
    (* The first character is checked before a substring is made, which
       keeps a scan of a whole log cheap. *)
    fun at i = String.sub(haystack, i) = first andalso String.substring(haystack, i, n) = needle
    fun loop i = if i + n > h then NONE else if at i then SOME i else loop (i + 1)
  in
    if n = 0 then NONE else loop 0
  end

val diagnostic_footer = "holbuild: diagnostic log v1\t"

fun primary_log NONE text = text
  | primary_log (SOME end_pos) text = String.substring (text, 0, Int.max (0, Int.min (end_pos, size text)))

(* Metadata follows the worker's own reports at EOF. Read only the record
   count the worker gave, even if the child printed similar text. *)
fun remote_diagnostic text =
  let
    fun previous_line stop =
      let
        fun start i =
          if i < 0 orelse String.sub (text, i) = #"\n" then i + 1 else start (i - 1)
        val ending = stop - 1
        val begin = start (ending - 1)
      in
        (begin, String.substring (text, begin, ending - begin))
      end
    val (footer_start, footer) = if String.isSuffix "\n" text then previous_line (size text) else (0, "")
    fun records 0 start acc = SOME (start, acc)
      | records n start acc =
          if start = 0 orelse String.sub (text, start - 1) <> #"\n" then NONE
          else let val (begin, record) = previous_line start
               in records (n - 1) begin (record :: acc) end
  in
    if not (String.isPrefix diagnostic_footer footer) then NONE
    else
      case String.fields (fn c => c = #"\t") (String.extract (footer, size diagnostic_footer, NONE)) of
          [primary, child, count] =>
            (case (Int.fromString primary, Int.fromString child, Int.fromString count) of
                 (SOME primary_end, SOME child_end, SOME n) =>
                   if primary_end < 0 orelse primary_end > child_end orelse n < 0 orelse n > 8 then NONE
                   else
                     (case records n footer_start [] of
                          SOME (start, records) =>
                            if child_end > start then NONE
                            else SOME {primary = primary_log (SOME primary_end) text, records = records}
                        | NONE => NONE)
               | _ => NONE)
        | _ => NONE
  end
  handle Overflow => NONE

fun line_number_at text offset =
  let
    val limit = Int.min(offset, size text)
    fun loop i line =
      if i >= limit then line
      else if String.sub(text, i) = #"\n" then loop (i + 1) (line + 1)
      else loop (i + 1) line
  in
    loop 0 1
  end

fun column_number_at text offset =
  let
    val limit = Int.min(offset, size text)
    fun loop i col =
      if i >= limit then col
      else if String.sub(text, i) = #"\n" then loop (i + 1) 1
      else loop (i + 1) (col + 1)
  in
    loop 0 1
  end

fun source_lines source_text = String.fields (fn c => c = #"\n") source_text

fun nth_line lines n = List.nth(lines, n - 1) handle _ => ""

fun repeat_text text n = String.concat (List.tabulate(Int.max(0, n), fn _ => text))
fun spaces n = repeat_text " " n

fun source_context_text source_text line =
  let
    val lines = source_lines source_text
    val start = Int.max(1, line - 2)
    val stop = Int.min(length lines, line + 2)
    val width = size (Int.toString stop)
    fun padded n = spaces (width - size (Int.toString n)) ^ Int.toString n
    fun row n =
      String.concat [if n = line then "> " else "  ", padded n, " | ", nth_line lines n, "\n"]
    fun loop n acc = if n > stop then rev acc else loop (n + 1) (row n :: acc)
  in
    String.concat (loop start [])
  end

fun source_context_text_span source_text {start_offset, end_offset} =
  let
    val lines = source_lines source_text
    val start_line = line_number_at source_text start_offset
    val start_col = column_number_at source_text start_offset
    val end_line = line_number_at source_text (Int.max(start_offset, end_offset - 1))
    val start = Int.max(1, start_line - 2)
    val stop = Int.min(length lines, end_line + 2)
    val width = size (Int.toString stop)
    fun padded n = spaces (width - size (Int.toString n)) ^ Int.toString n
    fun underline n =
      if start_line <> end_line orelse n <> start_line then ""
      else
        let val caret_count = Int.max(1, end_offset - start_offset)
        in String.concat ["  ", spaces width, " | ", spaces (start_col - 1), repeat_text "^" caret_count, "\n"] end
    fun row n =
      String.concat [if n >= start_line andalso n <= end_line then "> " else "  ",
                     padded n, " | ", nth_line lines n, "\n",
                     underline n]
    fun loop n acc = if n > stop then rev acc else loop (n + 1) (row n :: acc)
  in
    String.concat (loop start [])
  end

(* A lexical scan for a diagnostic, after HOL has already rejected the script. *)
local
  datatype quotation = Delimited of string | Statement | Terms | Verbatim

  fun body "Theorem" = SOME Statement
    | body "Triviality" = SOME Statement
    | body "Definition" = SOME Terms
    | body "Datatype" = SOME Terms
    | body "Inductive" = SOME Terms
    | body "CoInductive" = SOME Terms
    | body "Quote" = SOME Verbatim
    | body _ = NONE

  fun boundary word =
    Option.isSome (body word) orelse
    List.exists (fn kw => word = kw)
      ["Theory", "Resume", "Finalise", "Type", "Overload", "Proof", "QED", "Termination", "End"]

  fun body_stop word =
    boundary word orelse
    List.exists (fn kw => word = kw)
      ["val", "fun", "structure", "signature", "datatype", "type", "local", "open", "include",
       "exception", "infix", "infixr", "nonfix", "abstype", "eqtype", "functor"]

  fun closing #"(" = #")"
    | closing #"[" = #"]"
    | closing _ = #"}"
in
fun unclosed_delimiter source stop accepts =
  let
    val n = size source
    fun char i = if i < n then String.sub (source, i) else #"\000"
    fun at i token = i + size token <= n andalso String.substring (source, i, size token) = token
    fun skip pred i = if i < n andalso pred (char i) then skip pred (i + 1) else i
    fun id c = Char.isAlphaNum c orelse c = #"_" orelse c = #"'"
    val symbolic = Char.contains "!%&$#+-/:<=>?@\\~^|*"
    fun col_zero i = i = 0 orelse char (i - 1) = #"\n"
    fun word i j = String.substring (source, i, j - i)

    fun comment i depth =
      if i >= n then i
      else if at i "(*" then comment (i + 2) (depth + 1)
      else if at i "*)" then if depth = 1 then i + 2 else comment (i + 2) (depth - 1)
      else comment (i + 1) depth

    fun literal i close multiline =
      if i >= n orelse (not multiline andalso char i = #"\n") then i
      else if at i close then i + size close
      else if char i = #"\\" then
        if Char.isSpace (char (i + 1)) then
          let val gap = skip Char.isSpace (i + 1)
          in literal (if char gap = #"\\" then gap + 1 else gap) close multiline end
        else literal (Int.min (n, i + 2)) close multiline
      else literal (i + 1) close multiline

    val opener = ref NONE
    exception Done of (char * int) option
    fun finish () = raise Done (!opener)
    fun site i stack =
      if Option.isSome (!opener) orelse i < stop then ()
      else
        case stack of
            (item as (c, _)) :: _ =>
              if i = stop andalso accepts c then opener := SOME item else finish ()
          | [] => finish ()

    fun code i stack pending resume =
      (site i stack;
       if i >= n then finish ()
       else if at i "(*" then code (comment (i + 2) 1) stack pending resume
       else if at i "\"" orelse at i "#\"" then
         code (literal (i + (if char i = #"#" then 2 else 1)) "\"" false) stack pending resume
       else if at i "`" then
         let val delimiter = if at i "``" then "``" else "`"
         in quote (i + size delimiter) (Delimited delimiter) (fn j => code j stack pending resume) end
       else if at i "\226\128\152" then
         quote (i + 3) (Delimited "\226\128\153") (fn j => code j stack pending resume)
       else if at i "\226\128\156" then
         quote (i + 3) (Delimited "\226\128\157") (fn j => code j stack pending resume)
       else
         let val c = char i in
           if Char.contains "([{" c then code (i + 1) ((c, i) :: stack) pending resume
           else if Char.contains ")]}" c then
             (case stack of
                  (item as (left, _)) :: rest =>
                    if closing left <> c then code (i + 1) stack pending resume
                    else if SOME item = !opener then raise Done NONE
                    else
                      (case (rest, resume) of
                           ([], SOME continue) => continue (i + 1)
                         | _ => code (i + 1) rest pending resume)
                | [] => code (i + 1) [] pending resume)
           else if Char.isAlpha c orelse c = #"'" then
             let
               val j = skip id (i + 1)
               val name = word i j
               val hol_keyword =
                 col_zero i andalso char j <> #"." andalso
                 (boundary name orelse name = "Ancestors" orelse name = "Libs") andalso
                 (name <> "Datatype" orelse char (skip (Char.contains " \t") j) = #":")
             in
               if hol_keyword then
                 if Option.isSome (!opener) then finish ()
                 else code j [] (body name) NONE
               else code j stack pending resume
             end
           else if symbolic c then
             let val j = skip symbolic (i + 1) in
               case (c, j = i + 1, pending, stack) of
                   (#":", true, SOME kind, []) =>
                     quote j kind (fn k => code k [] NONE NONE)
                 | (#"=", true, SOME Statement, []) => code j [] NONE resume
                 | _ => code j stack pending resume
             end
           else code (i + 1) stack pending resume
         end)
    and quote i kind continue =
      (site i [];
       if i >= n then finish ()
       else
         case kind of
             Delimited close =>
               if at i close andalso (close <> "`" orelse not (at i "``"))
               then continue (i + size close)
               else quote_body i kind continue
           | _ => quote_body i kind continue)
    and quote_body i kind continue =
      if at i "(*" then quote (comment (i + 2) 1) kind continue
      else if at i "``" then quote (i + 2) kind continue
      else if at i "\"" then quote (literal (i + 1) "\"" true) kind continue
      else if at i "\226\128\185" then quote (literal (i + 3) "\226\128\186" true) kind continue
      else if at i "\194\171" then quote (literal (i + 2) "\194\187" true) kind continue
      else if at i "^^" then quote (skip (fn c => c = #"^") (i + 2)) kind continue
      else if at i "^(" then
        code (i + 2) [(#"(", i + 1)] NONE (SOME (fn j => quote j kind continue))
      else if col_zero i andalso Char.isAlpha (char i) then
        let
          val j = skip id (i + 1)
          val name = word i j
        in
          case kind of
              Delimited _ => quote j kind continue
            | Verbatim => if name = "End" then continue i else quote j kind continue
            | _ => if body_stop name then continue i else quote j kind continue
        end
      else quote (i + 1) kind continue
  in
    code 0 [] NONE NONE handle Done result => result
  end
end

fun decimal text =
  if text <> "" andalso CharVector.all Char.isDigit text then Int.fromString text else NONE
  handle Overflow => NONE

(* HOL's child parser appends a range as C-C2 or C-L2:C2. *)
fun source_position location =
  let
    fun position path line col =
      case (decimal line, decimal col) of
          (SOME l, SOME c) => SOME {path = String.concatWith ":" (rev path), line = l, col = c}
        | _ => NONE
    fun range text =
      case String.fields (fn c => c = #"-") text of
          [start, stop] =>
            if Option.isSome (decimal stop) then SOME start else NONE
        | _ => NONE
  in
    case rev (String.fields (fn c => c = #":") location) of
        last :: previous :: rest =>
          (case (range previous, decimal last, rest) of
               (SOME start, SOME _, line :: (path as _ :: _)) => position path line start
             | _ => if null rest then NONE else position rest previous (Option.getOpt (range last, last)))
      | _ => NONE
  end

fun source_offset text line col =
  let
    val n = size text
    fun seek i l =
      if l = line then
        let
          fun column j c =
            if c = col then SOME j
            else if j >= n orelse String.sub (text, j) = #"\n" then NONE
            else column (j + 1) (c + 1)
        in column i 1 end
      else if i >= n then NONE
      else seek (i + 1) (if String.sub (text, i) = #"\n" then l + 1 else l)
  in
    if line < 1 orelse col < 1 then NONE else seek 0 1
  end

fun delimiter_note source_path source_text message (line, col) =
  let
    fun note accepts =
      case Option.mapPartial (fn i => unclosed_delimiter source_text i accepts)
                             (source_offset source_text line col) of
          NONE => NONE
        | SOME (c, i) =>
            let val line = line_number_at source_text i
            in SOME (String.concat
                  [HolbuildStatus.unclosed_delimiter_note_prefix, String.str c, "' opened at ", source_path, ":",
                  Int.toString line, ":", Int.toString (column_number_at source_text i), "\n",
                  HolbuildStatus.unclosed_delimiter_excerpt_prefix, nth_line (source_lines source_text) line])
            end
  in
    case message of
        "expected closing parenthesis" => note (fn c => c = #"(")
      | "expected close delimiter" => note (fn _ => true)
      | "expected 'QED'" => note (fn _ => true)
      | "expected 'End'" => note (fn _ => true)
      | _ => NONE
  end

fun append_note text NONE = text
  | append_note text (SOME note) = text ^ (if String.isSuffix "\n" text then "" else "\n") ^ note ^ "\n"

fun annotate_analyser_parse_error source_path source_text text =
  let
    val error_prefix = "HOL source parse error: "
    val source_prefix = "source: " ^ source_path ^ ":"
    fun find (header :: location :: rest) =
          if String.isPrefix error_prefix header andalso String.isPrefix source_prefix location then
            let
              val msg = String.extract (header, size error_prefix, NONE)
            in
              case source_position (String.extract (location, size "source: ", NONE)) of
                  SOME {line, col, ...} => delimiter_note source_path source_text msg (line, col)
                | NONE => NONE
            end
          else find (location :: rest)
      | find _ = NONE
  in
    append_note text (find (source_lines text))
  end

fun child_parse_error source_path line =
  let val marker = ": parse error: " in
    case find_substring marker line of
        NONE => NONE
      | SOME i =>
          (case source_position (String.substring (line, 0, i)) of
               SOME {path, line = source_line, col} =>
                 if OS.Path.file path = OS.Path.file source_path then
                   SOME (String.extract (line, i + size marker, NONE), (source_line, col))
                 else NONE
             | NONE => NONE)
  end

fun child_delimiter_note source_path source_text line =
  Option.mapPartial (fn (message, location) => delimiter_note source_path source_text message location)
                    (child_parse_error source_path line)

fun has_child_parse_error source_path text =
  List.exists (Option.isSome o child_parse_error source_path) (source_lines text)

fun take_static_error_block [] acc = rev acc
  | take_static_error_block (line :: rest) acc =
      if String.isPrefix "Uncaught exception" line then rev acc
      else take_static_error_block rest (line :: acc)

fun static_error_marker line =
  case find_substring ": error: " line of
      SOME marker => SOME marker
    | NONE => find_substring ": parse error: " line

fun find_static_error_block [] = NONE
  | find_static_error_block (line :: rest) =
      if Option.isSome (static_error_marker line) then
        SOME (take_static_error_block rest [line])
      else find_static_error_block rest

fun parse_decimal_prefix text start =
  let
    val n = size text
    fun scan i =
      if i < n andalso Char.isDigit (String.sub(text, i)) then scan (i + 1) else i
    val stop = scan start
  in
    if stop = start then NONE
    else Int.fromString (String.substring(text, start, stop - start))
  end

fun marker_line_after marker text =
  case find_substring marker text of
      NONE => NONE
    | SOME i => parse_decimal_prefix text (i + size marker)

(* `path:line: error:` from Poly or `path:line:col: parse error:` from HOL's
   source parser; the path itself may contain colons. *)
fun parse_static_error_location line =
  case static_error_marker line of
      NONE => NONE
    | SOME marker =>
        let
          val location = String.substring (line, 0, marker)
          fun located path_fields line_no =
            {path = String.concatWith ":" (rev path_fields), line = line_no}
        in
          case source_position location of
              SOME {path, line, ...} => SOME {path = path, line = line}
            | NONE =>
                (case rev (String.fields (fn c => c = #":") location) of
                     last :: (path as _ :: _) => Option.map (located path) (decimal last)
                   | _ => NONE)
        end

(* Staged scripts carry location pragmas, so Poly reports lines of the source
   script itself; errors in other files (the preload) have no source line. *)
fun source_line_from_static_error source_path source_text block =
  case block of
      [] => NONE
    | first :: _ =>
        case parse_static_error_location first of
            NONE => NONE
          | SOME {path, line} =>
              if OS.Path.file path = OS.Path.file source_path andalso
                 1 <= line andalso line <= length (source_lines source_text)
              then SOME line
              else NONE

fun source_line_from_loc_marker source_text block =
  case marker_line_after "(*#loc " (String.concatWith "\n" block) of
      SOME line => if line <= length (source_lines source_text) then SOME line else NONE
    | NONE => NONE

fun static_error_source_line source_path source_text block =
  case source_line_from_static_error source_path source_text block of
      SOME line => SOME line
    | NONE => source_line_from_loc_marker source_text block

(* The first line of what a fleet worker appends to a theory's log after
   the child's output: why its pipelined attempt was given up, or why the
   action failed. *)
fun worker_report line =
  String.isPrefix "holbuild: pipeline: building plain:" line orelse
  String.isPrefix "holbuild: exec-action failed:" line

(* Older workers do not record where their own reports begin. *)
fun legacy_child_log text =
  let
    val lines = source_lines text
    fun take [] acc = rev acc
      | take (line :: rest) acc =
          if worker_report line then rev acc else take rest (line :: acc)
  in
    String.concatWith "\n" (take lines [])
  end

fun static_error_summary source_path source_text text =
  case find_static_error_block (source_lines text) of
      NONE => NONE
    | SOME block =>
        let
          val source_context =
            case static_error_source_line source_path source_text block of
                NONE => ""
              | SOME line =>
                  String.concat
                    ["source: ", source_path, ":", Int.toString line, "\n",
                     source_context_text source_text line]
        in
          SOME (append_note
            (String.concat ["static error:\n", String.concat (map (fn line => line ^ "\n") block), source_context])
            (child_delimiter_note source_path source_text (hd block)))
        end

fun proof_unit_label (checkpoint : HolbuildTheoryCheckpoints.boundary) =
  if #kind checkpoint = "resume" then "resume" else "theorem"

fun source_span_end_location source_text start_offset end_offset =
  let
    val last_offset = Int.max(start_offset, end_offset - 1)
  in
    (line_number_at source_text last_offset, column_number_at source_text last_offset + 1)
  end

fun source_span_range source_text start_offset end_offset =
  let
    val start_line = line_number_at source_text start_offset
    val start_col = column_number_at source_text start_offset
    val (end_line, end_col) = source_span_end_location source_text start_offset end_offset
  in
    if start_line = end_line then
      String.concat [Int.toString start_line, ":", Int.toString start_col, "-", Int.toString end_col]
    else
      String.concat [Int.toString start_line, ":", Int.toString start_col, "-",
                     Int.toString end_line, ":", Int.toString end_col]
  end

fun source_span_range_explicit source_text start_offset end_offset =
  let
    val start_line = line_number_at source_text start_offset
    val start_col = column_number_at source_text start_offset
    val (end_line, end_col) = source_span_end_location source_text start_offset end_offset
  in
    String.concat [Int.toString start_line, ":", Int.toString start_col, "-",
                   Int.toString end_line, ":", Int.toString end_col]
  end

fun source_span_text source_path source_text start_offset end_offset =
  let
    val range = source_span_range source_text start_offset end_offset
  in
    String.concat ["source: ", source_path, ":", range, "\n",
                   source_context_text_span source_text {start_offset = start_offset, end_offset = end_offset}]
  end

val termination_goal_prefix = "holbuild termination condition goal for "
val termination_goal_end = "holbuild termination condition goal end"
val termination_definition_start_prefix = "holbuild termination definition start for "
val termination_definition_end_prefix = "holbuild termination definition end for "

fun has_suffix suffix text =
  let val n = size text
      val m = size suffix
  in n >= m andalso String.substring(text, n - m, m) = suffix end

fun drop_suffix suffix text =
  if has_suffix suffix text then String.substring(text, 0, size text - size suffix) else text

fun parse_termination_goal_marker line =
  if not (String.isPrefix termination_goal_prefix line) then NONE
  else
    let
      val rest = drop_suffix ":" (String.extract(line, size termination_goal_prefix, NONE))
    in
      case find_substring " at " rest of
          NONE => NONE
        | SOME at_pos =>
            let
              val name = String.substring(rest, 0, at_pos)
              val start_text = String.extract(rest, at_pos + size " at ", NONE)
            in
              Option.map (fn definition_start => {name = name, definition_start = definition_start})
                         (Int.fromString start_text)
            end
    end

datatype termination_goal_record =
  TerminationGoal of {name : string, definition_start : int, lines : string list}

fun last_termination_goal lines =
  let
    fun finish NONE best = best
      | finish (SOME {name, definition_start, lines}) _ =
          SOME (TerminationGoal {name = name, definition_start = definition_start, lines = rev lines})
    fun loop [] current best = finish current best
      | loop (line :: rest) current best =
          if String.isPrefix termination_definition_start_prefix line orelse
             String.isPrefix termination_definition_end_prefix line then loop rest NONE NONE
          else case current of
              SOME {name, definition_start, lines} =>
                if line = termination_goal_end then
                  loop rest NONE (SOME (TerminationGoal {name = name, definition_start = definition_start, lines = rev lines}))
                else loop rest (SOME {name = name, definition_start = definition_start, lines = line :: lines}) best
            | NONE =>
                case parse_termination_goal_marker line of
                    SOME {name, definition_start} =>
                      loop rest (SOME {name = name, definition_start = definition_start, lines = []}) best
                  | NONE => loop rest NONE best
  in
    loop lines NONE NONE
  end

fun termination_by_start definition_start terminations =
  List.find (fn (termination : HolbuildTheoryCheckpoints.termination) =>
               #definition_start termination = definition_start)
            terminations

fun termination_source_summary source_path source_text (termination : HolbuildTheoryCheckpoints.termination) goal_lines =
  let
    val definition_line = line_number_at source_text (#definition_start termination)
    val proof_line = line_number_at source_text (#tactic_start termination)
    val goal_text = String.concat (map (fn line => line ^ "\n") goal_lines)
  in
    String.concat
      ["termination: ", #name termination, " (line ", Int.toString definition_line, ")\n",
       "proof: line ", Int.toString proof_line, "\n",
       source_span_text source_path source_text (#tactic_start termination) (#tactic_end termination),
       "termination condition goal:\n",
       goal_text]
  end

fun summarize_termination_goal_source source_path source_text terminations text =
  case last_termination_goal (source_lines text) of
      NONE => NONE
    | SOME (TerminationGoal {definition_start, lines, ...}) =>
        Option.map (fn termination => termination_source_summary source_path source_text termination lines)
                   (termination_by_start definition_start terminations)

fun quoted_after marker line =
  case find_substring marker line of
      NONE => NONE
    | SOME start =>
        let
          val quote_start = start + size marker
          fun scan i =
            if i >= size line then NONE
            else if String.sub(line, i) = #"\"" then
              SOME (String.substring(line, quote_start, i - quote_start))
            else scan (i + 1)
        in
          scan quote_start
        end

val failed_theorem_prefix = "holbuild failed theorem: "

fun failed_theorem_marker line =
  if String.isPrefix failed_theorem_prefix line then
    SOME (String.extract(line, size failed_theorem_prefix, NONE))
  else NONE

fun find_failed_theorem_name lines =
  case first_some failed_theorem_marker lines of
      SOME name => SOME name
    | NONE => first_some (quoted_after "Failed to prove theorem \"") lines

fun clamp_relative checkpoint offset =
  Int.max(0, Int.min(size (#tactic_text checkpoint), offset))

fun explicit_span checkpoint (start_pos, end_pos) =
  let
    val start = clamp_relative checkpoint start_pos
    val stop = clamp_relative checkpoint end_pos
    val width = Int.max(1, stop - start)
  in
    {offset = #tactic_start checkpoint + start, width = width}
  end

fun end_span checkpoint end_pos =
  let val relative = Int.max(0, Int.min(size (#tactic_text checkpoint) - 1, end_pos - 1))
  in {offset = #tactic_start checkpoint + relative, width = 1} end

fun skip_whitespace source_text limit offset =
  if offset >= limit orelse offset >= size source_text then offset
  else if Char.isSpace (String.sub(source_text, offset)) then skip_whitespace source_text limit (offset + 1)
  else offset

fun skip_branch_close_layout source_text limit offset =
  let
    fun loop current =
      if current >= limit then current
      else if Char.isSpace (String.sub(source_text, current)) then loop (current + 1)
      else if HolbuildTheoryCheckpoints.starts_with_bounded source_text limit current "(*" then
        loop (HolbuildTheoryCheckpoints.skip_comment_bounded source_text limit current)
      else current
  in
    loop offset
  end

val hol_quote_open = String.implode [Char.chr 226, Char.chr 128, Char.chr 152]
val hol_quote_close = String.implode [Char.chr 226, Char.chr 128, Char.chr 153]
val hol_double_quote_open = String.implode [Char.chr 226, Char.chr 128, Char.chr 156]
val hol_double_quote_close = String.implode [Char.chr 226, Char.chr 128, Char.chr 157]

fun symbolic_char c =
  not (Char.isSpace c) andalso not (HolbuildDependencies.is_word_char c) andalso
  not (List.exists (fn delimiter => c = delimiter)
                 [#"(", #")", #"[", #"]", #"{", #"}", #",", #";", #"\"", #"`"])

fun symbolic_token_boundary source_text limit offset =
  offset >= limit orelse not (symbolic_char (String.sub(source_text, offset))) orelse
  HolbuildTheoryCheckpoints.starts_with_bounded source_text limit offset hol_quote_open orelse
  HolbuildTheoryCheckpoints.starts_with_bounded source_text limit offset hol_quote_close orelse
  HolbuildTheoryCheckpoints.starts_with_bounded source_text limit offset hol_double_quote_open orelse
  HolbuildTheoryCheckpoints.starts_with_bounded source_text limit offset hol_double_quote_close

fun branch_close_continuation source_text limit offset =
  let
    val start = skip_branch_close_layout source_text limit offset
    fun symbolic opn =
      if HolbuildTheoryCheckpoints.starts_with_bounded source_text limit start opn then
        let val next = start + size opn
        in
          if symbolic_token_boundary source_text limit next then SOME opn else NONE
        end
      else NONE
    fun identifier opn =
      if HolbuildTheoryCheckpoints.starts_with_bounded source_text limit start opn then
        let val next = start + size opn
        in
          if next >= limit orelse not (HolbuildDependencies.is_word_char (String.sub(source_text, next))) then SOME opn
          else NONE
        end
      else NONE
  in
    case first_some symbolic [">>>", ">>", "\\\\", ">-", ">|"] of
        SOME opn => SOME opn
      | NONE => first_some identifier ["THEN_LT", "THEN1", "THENL", "THEN"]
  end

fun branch_close_note source_text limit label branch_close start_offset end_offset =
  if label <> "branch close" orelse not branch_close then ""
  else
    case branch_close_continuation source_text limit end_offset of
        SOME opn =>
          let val (end_line, end_col) = source_span_end_location source_text start_offset end_offset
          in
            String.concat
              ["note: this 'by'/'suffices_by'/'>-' branch body ended at ",
               Int.toString end_line, ":", Int.toString end_col,
               " with unsolved goal(s); the '", opn,
               " ...' tactics after it are outside this branch and did not run. ",
               "Wrap a multi-step branch proof in parentheses: P by (tac1 >> tac2) or >- (tac1 >> tac2).\n"]
          end
      | NONE =>
          String.concat
            ["note: branch body at ", source_span_range_explicit source_text start_offset end_offset,
             " left unsolved goal(s); if preceding steps were meant to stay inside one branch, ",
             "check grouping: '>>' and '>-' associate left as (tac1 >> tac2) >- tac3.\n"]

fun checkpoint_source_summary source_path source_text (checkpoint : HolbuildTheoryCheckpoints.boundary) label branch_close {offset, width} =
  let
    val theorem_line = line_number_at source_text (#theorem_start checkpoint)
    val proof_line = line_number_at source_text (#tactic_start checkpoint)
    val end_offset = Int.min(size source_text, offset + Int.max(1, width))
  in
    String.concat
      [proof_unit_label checkpoint, ": ", #name checkpoint, " (line ", Int.toString theorem_line, ")\n",
       "proof: line ", Int.toString proof_line, "\n",
       "fragment: ", label, "\n",
       source_span_text source_path source_text offset end_offset,
       branch_close_note source_text (#tactic_end checkpoint) label branch_close offset end_offset]
  end

fun finish_span source_text (checkpoint : HolbuildTheoryCheckpoints.boundary) =
  let
    val finish_offset = skip_whitespace source_text (#theorem_stop checkpoint) (#tactic_end checkpoint)
  in
    {offset = finish_offset, width = 1}
  end

fun failed_theorem_source_summary source_path source_text checkpoints label theorem_name failed_span failed_end branch_close =
  case List.find (fn (checkpoint : HolbuildTheoryCheckpoints.boundary) => #name checkpoint = theorem_name) checkpoints of
      NONE => NONE
    | SOME checkpoint =>
        SOME (checkpoint_source_summary source_path source_text checkpoint label branch_close
                (case failed_span of
                     SOME (start_pos, end_pos) =>
                       if start_pos = end_pos andalso has_suffix " finish" label then finish_span source_text checkpoint
                       else explicit_span checkpoint (start_pos, end_pos)
                   | NONE =>
                       case failed_end of
                           SOME end_pos => end_span checkpoint end_pos
                         | NONE => {offset = #tactic_start checkpoint, width = 1}))

val goal_state_start_marker = "holbuild failed tactic top input goal:"
val goal_state_end_marker = "holbuild end failed tactic top input goal"
val remaining_goals_marker = "holbuild failed tactic input goal count: "
val failed_fragment_prefix = "holbuild goal state at failed fragment: "
val failed_fragment_end_prefix = "holbuild failed fragment end: "
val failed_fragment_span_prefix = "holbuild failed fragment span: "
val plan_position_prefix = "holbuild plan position: "

fun skip_line_break text offset =
  if offset < size text andalso String.sub(text, offset) = #"\n" then offset + 1
  else offset

fun top_goal_state_from_text text =
  case find_substring goal_state_start_marker text of
      NONE => NONE
    | SOME start =>
        let
          val content_start = skip_line_break text (start + size goal_state_start_marker)
          val rest = String.extract(text, content_start, NONE)
        in
          case find_substring goal_state_end_marker rest of
              SOME rel_end =>
                SOME {top_goal = String.substring(text, content_start, rel_end), marker_truncated = false}
            | NONE =>
                SOME {top_goal = String.substring(text, content_start,
                                                  size text - content_start),
                      marker_truncated = true}
        end

fun remaining_goals_from_text text = marker_line_after remaining_goals_marker text

fun plan_position_from_text text =
  case find_substring plan_position_prefix text of
      NONE => NONE
    | SOME start =>
        let
          val content_start = start + size plan_position_prefix
          val rest = String.extract(text, content_start, NONE)
          val line = hd (String.fields (fn c => c = #"\n") rest) handle _ => ""
        in
          if line = "" then NONE else SOME line
        end

(* The whole log: whatever ran before the failure (metis chatter, say) can
   push the goal state any distance from its start. *)
fun read_goal_state text =
  case top_goal_state_from_text text of
      NONE => NONE
    | SOME {top_goal, marker_truncated} =>
        SOME {remaining_goals = remaining_goals_from_text text,
              top_goal = top_goal,
              marker_truncated = marker_truncated}

fun find_failed_fragment_label lines =
  first_some
    (fn line =>
        if String.isPrefix failed_fragment_prefix line then
          SOME (String.extract(line, size failed_fragment_prefix, NONE))
        else NONE)
    lines

fun find_failed_fragment_end lines =
  first_some
    (fn line =>
        if String.isPrefix failed_fragment_end_prefix line then
          Int.fromString (String.extract(line, size failed_fragment_end_prefix, NONE))
        else NONE)
    lines

fun parse_span_line text =
  case String.tokens Char.isSpace text of
      [start, stop] =>
        (case (Int.fromString start, Int.fromString stop) of
             (SOME a, SOME b) => SOME (a, b)
           | _ => NONE)
    | _ => NONE

fun find_failed_fragment_span lines =
  first_some
    (fn line =>
        if String.isPrefix failed_fragment_span_prefix line then
          parse_span_line (String.extract(line, size failed_fragment_span_prefix, NONE))
        else NONE)
    lines

fun has_branch_close_plan_position lines =
  Option.isSome
    (first_some
       (fn line =>
           if String.isPrefix plan_position_prefix line then
             case String.tokens Char.isSpace
                                (String.extract(line, size plan_position_prefix, NONE)) of
                 _ :: "end" :: ">-" :: "solved" :: _ => SOME ()
               | _ => NONE
           else NONE)
       lines)

fun truncate_goal_state text =
  let val limit = HolbuildDiagnosticLimits.goal_state ()
  in
    if limit = 0 orelse size text <= limit then (false, text)
    else (true, String.substring(text, 0, limit))
  end

fun remaining_goals_summary NONE = ""
  | remaining_goals_summary (SOME n) = "failed tactic input goals: " ^ Int.toString n ^ "\n"

fun all_goals_log_summary log_available (SOME n) =
      if log_available andalso n > 1 then "all failed tactic input goals are in the instrumented log\n" else ""
  | all_goals_log_summary _ NONE = ""

fun truncation_summary log_available preview =
  if log_available then
    String.concat ["top goal truncated; showing first ",
                   Int.toString (size preview), " bytes; full top goal is in the instrumented log referenced below\n"]
  else
    String.concat ["top goal truncated; showing first ",
                   Int.toString (size preview), " bytes\n"]

fun goal_state_summary log_available {remaining_goals, top_goal, marker_truncated} =
  let
    val (text_truncated, preview) = truncate_goal_state top_goal
    val truncated = marker_truncated orelse text_truncated
    val truncation_line = if truncated then truncation_summary log_available preview else ""
  in
    String.concat
      ["failed tactic top input goal:\n",
       remaining_goals_summary remaining_goals,
       all_goals_log_summary log_available remaining_goals,
       truncation_line,
       preview,
       if size preview = 0 orelse String.sub(preview, size preview - 1) <> #"\n" then "\n" else ""]
  end

fun summarize_goal_state_with_log_reference log_available text =
  Option.map (goal_state_summary log_available) (read_goal_state text)
  handle _ => NONE

fun plan_position_summary text =
  Option.map (fn position => "plan position: " ^ position ^ "\n")
             (plan_position_from_text text)
  handle _ => NONE

fun child_failure_line line =
  String.isPrefix "Couldn't load HOL base-state" line orelse
  String.isPrefix "HOL message:" line orelse
  String.isPrefix "error in " line orelse
  String.isPrefix "Uncaught exception" line orelse
  Option.isSome (find_substring "Exception raised" line)

fun take_n n lines acc =
  if n <= 0 then rev acc
  else
    case lines of
        [] => rev acc
      | line :: rest => take_n (n - 1) rest (line :: acc)

fun child_failure_excerpt lines =
  let
    (* Keep preceding output separate from the cause. Leave out the
       runtime markers that carry per-run values. *)
    fun runtime_marker line = String.isPrefix "holbuild " line
    fun scan [] _ failure terminal = (failure, terminal)
      | scan (remaining as line :: rest) preceding failure terminal =
          if runtime_marker line then scan rest preceding failure terminal
          else
            scan rest (take_n 10 (line :: preceding) [])
              (if child_failure_line line then SOME remaining else failure)
              (if String.isPrefix "Uncaught exception" line then SOME (line, rev preceding)
               else terminal)
    fun raw_excerpt [] = []
      | raw_excerpt (line :: rest) =
          if runtime_marker line then raw_excerpt rest
          else line :: raw_excerpt rest
  in
    case scan lines [] NONE NONE of
        (_, SOME (line, [])) => SOME [line]
      | (_, SOME (line, preceding)) => SOME (line :: "preceding HOL output:" :: preceding)
      | (failure, NONE) => Option.map (fn rest => raw_excerpt (take_n 12 rest [])) failure
  end

fun child_failure_summary text =
  let val lines = source_lines text
  in
    case child_failure_excerpt lines of
        NONE => NONE
      | SOME excerpt =>
          SOME ("child failure:\n" ^ String.concat (map (fn line => line ^ "\n") excerpt))
  end
  handle _ => NONE

fun failed_termination_source_summary source_path source_text terminations label name failed_span failed_end branch_close =
  case List.find (fn (termination : HolbuildTheoryCheckpoints.termination) => #name termination = name) terminations of
      NONE => NONE
    | SOME termination =>
        let
          val tactic_size = size (#tactic_text termination)
          fun bounded n = Int.max(0, Int.min(tactic_size, n))
          val (relative, width) =
            case failed_span of
                SOME (start_pos, end_pos) =>
                  let val start = bounded start_pos
                      val stop = bounded end_pos
                  in (start, Int.max(1, stop - start)) end
              | NONE =>
                  (case failed_end of
                       SOME end_pos => (Int.max(0, bounded end_pos - 1), 1)
                     | NONE => (0, 1))
          val offset = #tactic_start termination + relative
          val end_offset = Int.min(#tactic_end termination, offset + width)
        in
          SOME (String.concat
            ["termination: ", #name termination, " (line ",
             Int.toString (line_number_at source_text (#definition_start termination)), ")\n",
             "proof: line ", Int.toString (line_number_at source_text (#tactic_start termination)), "\n",
             "fragment: ", label, "\n",
             source_span_text source_path source_text offset (Int.max(offset + 1, end_offset)),
             branch_close_note source_text (#tactic_end termination) label branch_close offset (Int.max(offset + 1, end_offset))])
        end

fun summarize_failed_fragment_source source_path source_text checkpoints terminations text =
  let
    val lines = source_lines text
    val label = find_failed_fragment_label lines
    val failed_end = find_failed_fragment_end lines
    val failed_span = find_failed_fragment_span lines
    val branch_close = has_branch_close_plan_position lines andalso Option.isSome failed_span
  in
    case (label, find_failed_theorem_name lines) of
        (SOME label', SOME theorem_name) =>
          (case failed_theorem_source_summary source_path source_text checkpoints label' theorem_name failed_span failed_end branch_close of
               SOME summary => SOME summary
             | NONE => failed_termination_source_summary source_path source_text terminations label' theorem_name failed_span failed_end branch_close)
      | _ => NONE
  end
  handle _ => NONE

fun field_after key line =
  let
    val needle = key ^ "="
    val n = size line
    val m = size needle
    fun scan i =
      if i + m > n then NONE
      else if String.substring(line, i, m) = needle then
        let
          val start = i + m
          fun stop j = if j >= n orelse Char.isSpace (String.sub(line, j)) then j else stop (j + 1)
        in
          SOME (String.substring(line, start, stop start - start))
        end
      else scan (i + 1)
  in
    scan 0
  end

fun proof_trace_line line =
  String.isPrefix "holbuild proof-ir " line

fun proof_trace_after_line line =
  String.isPrefix "holbuild proof-ir after " line

fun failed_trace_theorem lines =
  case List.filter (fn line => proof_trace_after_line line andalso
                               String.isSubstring "status=failed" line) lines of
      [] => NONE
    | failed => field_after "theorem" (List.last failed)

(* The runtime quotes fields so user text and goal layout never introduce
   marker lines. The declaration reader reports failures outside a proof. *)
fun additional_failures source_path source_text checkpoints terminations records : HolbuildStatus.additional_failure list =
  let
    val prefix = "holbuild secondary failure: "
    fun source_line kind declaration_start position =
      let
        fun line start stop finish =
          Option.map (line_number_at source_text)
            (if position = "finish" then SOME finish
             else Option.map (fn offset => Int.min (stop, start + Int.max (offset, 0)))
                             (Int.fromString position))
      in
        if kind = "termination" then
          Option.mapPartial (fn termination =>
            line (#tactic_start termination) (#tactic_end termination)
                 (skip_whitespace source_text (#boundary termination) (#tactic_end termination)))
            (List.find (fn termination => #definition_start termination = declaration_start)
                       (terminations : HolbuildTheoryCheckpoints.termination list))
        else
          Option.mapPartial (fn checkpoint =>
            line (#tactic_start checkpoint) (#tactic_end checkpoint)
                 (#offset (finish_span source_text checkpoint)))
            (List.find (fn checkpoint => #theorem_start checkpoint = declaration_start)
                       (checkpoints : HolbuildTheoryCheckpoints.boundary list))
      end
    fun compact value =
      String.map (fn #"\n" => #" " | #"\r" => #" " | c => c)
        (Substring.string (Substring.dropl Char.isSpace (Substring.dropr Char.isSpace (Substring.full value))))
    fun decode line =
      case String.fields (fn c => c = #"\t") (String.extract (line, size prefix, NONE)) of
          [kind, start, name, position, message, goal] =>
            (case (Int.fromString start, String.fromString name, String.fromString message, String.fromString goal) of
                 (SOME declaration_start, SOME name, SOME error, SOME top_goal) =>
                   SOME {theorem = compact name, line = source_line kind declaration_start position,
                         error = compact error, top_goal = compact top_goal}
               | _ => NONE)
        | _ => NONE
    val terminal_prefix = "holbuild secondary terminal error: "
    fun terminal line =
      case String.fields (fn c => c = #"\t") (String.extract (line, size terminal_prefix, NONE)) of
          [kind, encoded] =>
            Option.map (fn error =>
              let
                val block = if kind = "source" then find_static_error_block (source_lines error) else NONE
              in
                case block of
                    SOME (lines as first :: _) =>
                      let
                        val summary = compact (String.concatWith " " (take_n 3 lines []))
                        val note = child_delimiter_note source_path source_text first
                        val error = summary ^ (case note of SOME text => "\n" ^ text | NONE => "")
                      in
                        {theorem = "", line = static_error_source_line source_path source_text lines,
                         error = error, top_goal = ""}
                      end
                  | _ => {theorem = "", line = NONE, error = compact error, top_goal = ""}
              end)
              (String.fromString encoded)
        | _ => NONE
    fun parse line =
      if String.isPrefix prefix line then decode line
      else if String.isPrefix terminal_prefix line then terminal line
      else NONE
  in
    List.mapPartial parse records
  end

fun summarize_trace_steps text =
  let
    val lines = source_lines text
    val trace_lines = List.filter proof_trace_line lines
    val focused =
      case failed_trace_theorem trace_lines of
          NONE => trace_lines
        | SOME theorem => List.filter (fn line => field_after "theorem" line = SOME theorem) trace_lines
  in
    if null focused then NONE
    else SOME ("holbuild proof-ir trace:\n" ^ String.concat (map (fn line => line ^ "\n") focused))
  end
  handle _ => NONE

end
