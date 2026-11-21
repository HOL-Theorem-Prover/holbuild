structure HolbuildAnalyserDependencyExtract =
struct

structure Path = OS.Path
exception Error of string

datatype token = Word of string | Symbol of char

type t =
  { loads : string list,
    uses : string list,
    extra_deps : string list,
    extra_outputs : string list,
    holdep_mentions : string list }

fun has_suffix suffix s =
  let val n = size s val m = size suffix
  in n >= m andalso String.substring(s, n - m, m) = suffix end

fun is_word_start c = Char.isAlpha c orelse c = #"_"
fun is_word_char c = Char.isAlphaNum c orelse c = #"_" orelse c = #"'"

fun add_unique item items = if List.exists (fn x => x = item) items then items else item :: items

fun insert_sorted item items =
  case items of
      [] => [item]
    | x :: xs =>
        case String.compare(item, x) of
            LESS => item :: items
          | EQUAL => items
          | GREATER => x :: insert_sorted item xs

fun sort_unique items = List.foldl (fn (item, acc) => insert_sorted item acc) [] items

fun holdep_mentions path =
  let
    val reader = HOLSource.fileToReader {quietOpen = false, print = fn _ => ()} path
    val mentions = Holdep_tokens.reader_deps (path, #read reader)
  in
    sort_unique (Binarymap.foldl (fn (name, _, acc) => name :: acc) [] mentions)
  end
  handle Holdep_tokens.LEX_ERROR msg =>
    raise Error ("Holdep failed for " ^ path ^ ": " ^ msg)
       | e as IO.Io _ =>
    raise Error ("Holdep failed for " ^ path ^ ": " ^ General.exnMessage e)

fun read_all path =
  let
    val input = TextIO.openIn path
      handle e => raise Error ("could not read " ^ path ^ ": " ^ General.exnMessage e)
  in
    TextIO.inputAll input before TextIO.closeIn input
    handle e => (TextIO.closeIn input; raise e)
  end

fun scan_string text start =
  let
    val n = size text
    fun sub i = String.sub(text, i)
    fun loop i acc =
      if i >= n then (String.implode (rev acc), i)
      else
        case sub i of
            #"\"" => (String.implode (rev acc), i + 1)
          | #"\\" => if i + 1 < n then loop (i + 2) (sub (i + 1) :: acc) else loop (i + 1) acc
          | c => loop (i + 1) (c :: acc)
  in loop start [] end

fun skip_string text start =
  let
    val n = size text
    fun loop i =
      if i >= n then i
      else
        case String.sub(text, i) of
            #"\"" => i + 1
          | #"\\" => loop (i + 2)
          | _ => loop (i + 1)
  in Int.min(loop start, n) end

fun skip_comment text start =
  let
    val n = size text
    fun sub i = String.sub(text, i)
    fun opens i = i + 1 < n andalso sub i = #"(" andalso sub (i + 1) = #"*"
    fun closes i = i + 1 < n andalso sub i = #"*" andalso sub (i + 1) = #")"
    fun loop depth i =
      if i >= n then i
      else if opens i then loop (depth + 1) (i + 2)
      else if closes i then if depth = 1 then i + 2 else loop (depth - 1) (i + 2)
      else loop depth (i + 1)
  in loop 1 start end

fun scan_word text start =
  let
    val n = size text
    fun loop i = if i < n andalso is_word_char (String.sub(text, i)) then loop (i + 1) else i
    val stop = loop start
  in (String.substring(text, start, stop - start), stop) end

(* The header's tokens: a literal is skipped unread and stands as the
   symbol `"`, which no header line contains. *)
fun tokenize text =
  let
    val n = size text
    fun sub i = String.sub(text, i)
    fun opens_comment i = i + 1 < n andalso sub i = #"(" andalso sub (i + 1) = #"*"
    fun loop i acc =
      if i >= n then rev acc
      else if Char.isSpace (sub i) then loop (i + 1) acc
      else if opens_comment i then loop (skip_comment text (i + 2)) acc
      else if sub i = #"\"" then loop (skip_string text (i + 1)) (Symbol #"\"" :: acc)
      else if is_word_start (sub i) then let val (word, next) = scan_word text i in loop next (Word word :: acc) end
      else loop (i + 1) (Symbol (sub i) :: acc)
  in loop 0 [] end

(* The dependency facts of a script's text in one pass: the literal after
   each `load` or `use`, and the literals of each `holbuild_extra_deps` or
   `holbuild_extra_outputs` list.  Other literals are skipped unread, so a
   script holding large literals costs no more than its text. *)
fun scan_dependencies text =
  let
    val n = size text
    fun sub i = String.sub(text, i)
    fun opens_comment i = i + 1 < n andalso sub i = #"(" andalso sub (i + 1) = #"*"
    fun list_keyword word = word = "holbuild_extra_deps" orelse word = "holbuild_extra_outputs"
    fun bad keyword = raise Error ("expected literal string list after " ^ keyword)
    fun add_list keyword values {loads, uses, extra_deps, extra_outputs} =
      if keyword = "holbuild_extra_deps"
      then {loads = loads, uses = uses, extra_deps = values @ extra_deps, extra_outputs = extra_outputs}
      else {loads = loads, uses = uses, extra_deps = extra_deps, extra_outputs = values @ extra_outputs}
    (* PREVIOUS is the word just read, if the last token was one; LIST the
       keyword and literals of the list being read. *)
    fun loop i previous list (r as {loads, uses, extra_deps, extra_outputs}) =
      if i >= n then (case list of SOME (keyword, _) => bad keyword | NONE => r)
      else if Char.isSpace (sub i) then loop (i + 1) previous list r
      else if opens_comment i then loop (skip_comment text (i + 2)) previous list r
      else if sub i = #"\"" then
        case (list, previous) of
            (SOME (keyword, values), _) =>
              let val (s, next) = scan_string text (i + 1)
              in loop next NONE (SOME (keyword, add_unique s values)) r end
          | (NONE, SOME "load") =>
              let val (s, next) = scan_string text (i + 1)
              in loop next NONE NONE {loads = add_unique s loads, uses = uses, extra_deps = extra_deps,
                                      extra_outputs = extra_outputs} end
          | (NONE, SOME "use") =>
              let val (s, next) = scan_string text (i + 1)
              in loop next NONE NONE {loads = loads, uses = add_unique s uses, extra_deps = extra_deps,
                                      extra_outputs = extra_outputs} end
          | (NONE, _) => loop (skip_string text (i + 1)) NONE NONE r
      else if is_word_start (sub i) then
        case list of
            SOME (keyword, _) => bad keyword
          | NONE => let val (word, next) = scan_word text i in loop next (SOME word) NONE r end
      else
        case (list, sub i, previous) of
            (SOME _, #",", _) => loop (i + 1) NONE list r
          | (SOME (keyword, values), #"]", _) => loop (i + 1) NONE NONE (add_list keyword values r)
          | (SOME (keyword, _), _, _) => bad keyword
          | (NONE, #"[", SOME word) =>
              loop (i + 1) NONE (if list_keyword word then SOME (word, []) else NONE) r
          | (NONE, _, _) => loop (i + 1) NONE NONE r
  in
    loop 0 NONE NONE {loads = [], uses = [], extra_deps = [], extra_outputs = []}
  end

(* Holdep records the dependencies introduced while parsing ordinary ML, but
   HOLSource's header-only Libs declaration is consumed before it emits those
   references.  Preserve it explicitly so a header library is planned as a
   source dependency when its source is available in the implicit HOL package.

   Headers consist of line-leading Theory/Ancestors/Libs directives followed by
   header-element lines.  Do not scan past that region: after Libs, an
   ordinary SML expression may start with any identifier. *)
fun header_libs text =
  let
    fun starts_word word line =
      let
        val n = size word
      in
        size line >= n andalso String.substring(line, 0, n) = word andalso
        (size line = n orelse not (is_word_char (String.sub(line, n))))
      end
    fun is_blank line =
      let
        fun loop i = i >= size line orelse
          (Char.isSpace (String.sub(line, i)) andalso loop (i + 1))
      in
        loop 0
      end
    fun starts_comment line =
      size line >= 2 andalso String.substring(line, 0, 2) = "(*"
    fun is_blank_or_comment line =
      is_blank line orelse starts_comment line
    (* The line starting at START and where the next one starts, read one
       at a time: the header ends long before the source does. *)
    fun line_at start =
      let
        val n = size text
        fun stop i = if i < n andalso String.sub(text, i) <> #"\n" then stop (i + 1) else i
      in
        if start > n then NONE
        else let val e = stop start in SOME (String.substring(text, start, e - start), e + 1) end
      end
    fun skip_qualifier rest =
      let
        fun loop xs =
          case xs of
              [] => []
            | Symbol #"]" :: more => more
            | _ :: more => loop more
      in
        case rest of
            Symbol #"[" :: more => loop more
          | _ => rest
      end
    fun add_elements tokens libs =
      let
        fun loop rest acc =
          case rest of
              Word word :: more => loop (skip_qualifier more) (add_unique word acc)
            | _ :: more => loop more acc
            | [] => acc
      in
        loop tokens libs
      end
    fun header_elements line =
      let
        val tokens = tokenize line
        fun valid depth rest =
          case rest of
              [] => depth = 0
            | Word _ :: more => valid depth more
            | Symbol #"[" :: more => valid (depth + 1) more
            | Symbol #"]" :: more => depth > 0 andalso valid (depth - 1) more
            | Symbol #"," :: more => depth > 0 andalso valid depth more
            | Symbol #"=" :: more => depth > 0 andalso valid depth more
            | _ => false
      in
        if valid 0 tokens then SOME tokens else NONE
      end
    fun after word line = String.extract(line, size word, NONE)
    fun scan current position libs =
      case line_at position of
          NONE => libs
        | SOME (line, more) =>
            if starts_word "Ancestors" line then scan "Ancestors" more libs
            else if starts_word "Libs" line then
              scan "Libs" more
                (add_elements (skip_qualifier (tokenize (after "Libs" line))) libs)
            else if is_blank_or_comment line then scan current more libs
            else if current = "" then libs
            else
              case header_elements line of
                  SOME elements =>
                    scan current more
                      (if current = "Libs" then add_elements elements libs else libs)
                | NONE => libs
    (* The `Theory` line may follow other declarations, so look at every
       line start, in place rather than copying each line. *)
    fun theory_at position =
      let
        val k = size "Theory"
        fun same i = i >= k orelse
          (String.sub(text, position + i) = String.sub("Theory", i) andalso same (i + 1))
      in
        position + k <= size text andalso same 0 andalso
        (position + k = size text orelse not (is_word_char (String.sub(text, position + k))))
      end
    fun find position =
      if theory_at position then
        (case line_at position of SOME (_, more) => scan "" more [] | NONE => [])
      else
        let
          fun next i =
            if i >= size text then []
            else if String.sub(text, i) = #"\n" then find (i + 1)
            else next (i + 1)
        in
          next position
        end
  in
    sort_unique (find 0)
  end

fun extract path =
  let
    (* Holdep reads the file again itself: keep the text no longer than
       the scans that need it. *)
    val ({loads, uses, extra_deps, extra_outputs}, libs) =
      let val text = read_all path in (scan_dependencies text, header_libs text) end
  in
    {loads = sort_unique loads, uses = sort_unique uses,
     extra_deps = sort_unique extra_deps,
     extra_outputs = sort_unique extra_outputs,
     holdep_mentions = sort_unique (holdep_mentions path @ libs)}
  end

end
