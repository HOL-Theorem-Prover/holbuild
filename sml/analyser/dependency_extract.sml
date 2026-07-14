structure HolbuildAnalyserDependencyExtract =
struct

structure Path = OS.Path
exception Error of string

datatype token = Word of string | StringLit of string | Symbol of char

type t =
  { loads : string list,
    uses : string list,
    extra_deps : string list,
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

fun tokenize text =
  let
    val n = size text
    fun sub i = String.sub(text, i)
    fun opens_comment i = i + 1 < n andalso sub i = #"(" andalso sub (i + 1) = #"*"
    fun loop i acc =
      if i >= n then rev acc
      else if Char.isSpace (sub i) then loop (i + 1) acc
      else if opens_comment i then loop (skip_comment text (i + 2)) acc
      else if sub i = #"\"" then let val (s, next) = scan_string text (i + 1) in loop next (StringLit s :: acc) end
      else if is_word_start (sub i) then let val (word, next) = scan_word text i in loop next (Word word :: acc) end
      else loop (i + 1) (Symbol (sub i) :: acc)
  in loop 0 [] end

fun extract_string_args keyword tokens =
  let
    fun loop rest acc =
      case rest of
          Word word :: StringLit value :: xs => if word = keyword then loop xs (add_unique value acc) else loop (StringLit value :: xs) acc
        | _ :: xs => loop xs acc
        | [] => acc
  in loop tokens [] end

fun extract_string_list_args keyword tokens =
  let
    fun list rest acc =
      case rest of
          Symbol #"]" :: xs => (rev acc, xs)
        | StringLit value :: xs => list xs (add_unique value acc)
        | Symbol #"," :: xs => list xs acc
        | _ => raise Error ("expected literal string list after " ^ keyword)
    fun loop rest acc =
      case rest of
          Word word :: Symbol #"[" :: xs =>
            if word = keyword then let val (values, rest') = list xs [] in loop rest' (values @ acc) end
            else loop (Symbol #"[" :: xs) acc
        | _ :: xs => loop xs acc
        | [] => acc
  in loop tokens [] end

(* Holdep records the dependencies introduced while parsing ordinary ML, but
   HOLSource's header-only Libs declaration is consumed before it emits those
   references.  Preserve it explicitly so a header library is planned as a
   source dependency when its source is available in the implicit HOL package. *)
fun header_stop_word word =
  List.exists (fn stop => stop = word)
    ["val", "fun", "open", "local", "structure", "signature", "datatype",
     "type", "exception", "Type", "Definition", "Theorem", "Triviality", "Lemma",
     "Corollary", "Datatype", "Overload", "Inductive", "CoInductive",
     "End", "Resume", "Finalise"]

fun header_libs tokens =
  let
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
    fun section current rest libs =
      case rest of
          [] => libs
        | Word "Ancestors" :: more => section "Ancestors" more libs
        | Word "Libs" :: more => section "Libs" more libs
        | Word word :: more =>
            if header_stop_word word then libs
            else if current = "Libs" then
              section current (skip_qualifier more) (add_unique word libs)
            else section current (skip_qualifier more) libs
        | _ :: more => section current more libs
    fun find rest =
      case rest of
          Word "Theory" :: Word _ :: more => section "" more []
        | _ :: more => find more
        | [] => []
  in
    sort_unique (find tokens)
  end

fun extract path =
  let
    val tokens = tokenize (read_all path)
    val loads = extract_string_args "load" tokens
    val uses = extract_string_args "use" tokens
    val extra_deps = extract_string_list_args "holbuild_extra_deps" tokens
  in
    {loads = sort_unique loads, uses = sort_unique uses,
     extra_deps = sort_unique extra_deps,
     holdep_mentions = sort_unique (holdep_mentions path @ header_libs tokens)}
  end

end
