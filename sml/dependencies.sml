structure HolbuildDependencies =
struct

structure Path = OS.Path

exception Error of string

datatype token = Word of string | StringLit of string | Symbol of char

type t =
  { loads : string list,
    uses : string list,
    extra_deps : string list,
    holdep_mentions : string list }

val cache_version = "holbuild-dependencies-cache-v2"
val extractor_version = "holsource-fileToReader+holdep-tokens+extra-deps-v1"

fun has_suffix suffix s =
  let
    val n = size s
    val m = size suffix
  in
    n >= m andalso String.substring(s, n - m, m) = suffix
  end

fun is_word_start c = Char.isAlpha c orelse c = #"_"
fun is_word_char c = Char.isAlphaNum c orelse c = #"_" orelse c = #"'"

fun add_unique item items =
  if List.exists (fn x => x = item) items then items else item :: items

fun insert_sorted item items =
  case items of
      [] => [item]
    | x :: xs =>
        case String.compare(item, x) of
            LESS => item :: items
          | EQUAL => items
          | GREATER => x :: insert_sorted item xs

fun sort_unique items = List.foldl (fn (item, acc) => insert_sorted item acc) [] items

fun normalize_path path = Path.mkCanonical path handle Path.InvalidArc => path

fun absolute_path path = Path.isAbsolute path handle Path.InvalidArc => false

fun normalize_dep_path source_path dep =
  normalize_path
    (if absolute_path dep then dep else Path.concat(Path.dir source_path, dep))

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

fun resolved_holdep_deps includes path =
  let
    val {deps, ...} = Holdep.main {assumes = [], includes = includes,
                                   diag = fn _ => (), fname = path}
  in
    sort_unique (map (normalize_dep_path path) deps)
  end
  handle Holdep.Holdep_Error msg =>
    raise Error ("Holdep failed for " ^ path ^ ": " ^ msg)
       | Holdep_tokens.LEX_ERROR msg =>
    raise Error ("Holdep failed for " ^ path ^ ": " ^ msg)

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
          | #"\\" =>
              if i + 1 < n then loop (i + 2) (sub (i + 1) :: acc)
              else loop (i + 1) acc
          | c => loop (i + 1) (c :: acc)
  in
    loop start []
  end

fun skip_comment text start =
  let
    val n = size text
    fun sub i = String.sub(text, i)
    fun opens i = i + 1 < n andalso sub i = #"(" andalso sub (i + 1) = #"*"
    fun closes i = i + 1 < n andalso sub i = #"*" andalso sub (i + 1) = #")"
    fun loop depth i =
      if i >= n then i
      else if opens i then loop (depth + 1) (i + 2)
      else if closes i then
        if depth = 1 then i + 2 else loop (depth - 1) (i + 2)
      else loop depth (i + 1)
  in
    loop 1 start
  end

fun scan_word text start =
  let
    val n = size text
    fun loop i =
      if i < n andalso is_word_char (String.sub(text, i)) then loop (i + 1)
      else i
    val stop = loop start
  in
    (String.substring(text, start, stop - start), stop)
  end

fun tokenize text =
  let
    val n = size text
    fun sub i = String.sub(text, i)
    fun opens_comment i = i + 1 < n andalso sub i = #"(" andalso sub (i + 1) = #"*"
    fun loop i acc =
      if i >= n then rev acc
      else if Char.isSpace (sub i) then loop (i + 1) acc
      else if opens_comment i then loop (skip_comment text (i + 2)) acc
      else if sub i = #"\"" then
        let val (s, next) = scan_string text (i + 1)
        in loop next (StringLit s :: acc) end
      else if is_word_start (sub i) then
        let val (word, next) = scan_word text i
        in loop next (Word word :: acc) end
      else loop (i + 1) (Symbol (sub i) :: acc)
  in
    loop 0 []
  end

fun theory_name s = has_suffix "Theory" s andalso size s > size "Theory"

fun extract_string_args keyword tokens =
  let
    fun loop rest acc =
      case rest of
          Word word :: StringLit value :: xs =>
            if word = keyword then loop xs (add_unique value acc)
            else loop (StringLit value :: xs) acc
        | _ :: xs => loop xs acc
        | [] => acc
  in
    loop tokens []
  end

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
            if word = keyword then
              let val (values, rest') = list xs []
              in loop rest' (values @ acc) end
            else loop (Symbol #"[" :: xs) acc
        | Word _ :: _ :: _ =>
            (case rest of _ :: xs => loop xs acc | [] => acc)
        | _ :: xs => loop xs acc
        | [] => acc
  in
    loop tokens []
  end

fun extract_uncached path =
  let
    val tokens = tokenize (read_all path)
    val loads = extract_string_args "load" tokens
    val uses = extract_string_args "use" tokens
    val extra_deps = extract_string_list_args "holbuild_extra_deps" tokens
  in
    {loads = sort_unique loads, uses = sort_unique uses,
     extra_deps = sort_unique extra_deps,
     holdep_mentions = holdep_mentions path}
  end

fun line_value prefix line =
  if String.isPrefix prefix line then SOME (String.extract(line, size prefix, NONE))
  else NONE

fun values prefix lines = List.mapPartial (line_value prefix) lines

fun read_cache cache_path source_hash =
  let
    val text = read_all cache_path
    val lines = String.tokens (fn c => c = #"\n") text
  in
    case lines of
        version :: extractor :: hash_line :: rest =>
          if version = cache_version andalso
             extractor = "extractor=" ^ extractor_version andalso
             hash_line = "source_sha1=" ^ source_hash then
            SOME {loads = values "load=" rest,
                  uses = values "use=" rest,
                  extra_deps = values "extra_dep=" rest,
                  holdep_mentions = values "mention=" rest}
          else NONE
      | _ => NONE
  end
  handle _ => NONE

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if OS.FileSys.access(path, []) handle OS.SysErr _ => false then ()
  else (ensure_dir (Path.dir path); OS.FileSys.mkDir path handle OS.SysErr _ => ())

fun ensure_parent path = ensure_dir (Path.dir path)

fun cache_text source_hash ({loads, uses, extra_deps, holdep_mentions} : t) =
  String.concatWith "\n"
    ([cache_version,
      "extractor=" ^ extractor_version,
      "source_sha1=" ^ source_hash] @
     map (fn value => "load=" ^ value) loads @
     map (fn value => "use=" ^ value) uses @
     map (fn value => "extra_dep=" ^ value) extra_deps @
     map (fn value => "mention=" ^ value) holdep_mentions) ^ "\n"

fun write_cache cache_path source_hash deps =
  let
    val tmp = cache_path ^ ".tmp"
    val _ = ensure_parent cache_path
    val out = TextIO.openOut tmp
    val _ = (TextIO.output(out, cache_text source_hash deps); TextIO.closeOut out)
            handle e => (TextIO.closeOut out; raise e)
    val _ = OS.FileSys.remove cache_path handle OS.SysErr _ => ()
    val _ = OS.FileSys.rename {old = tmp, new = cache_path}
            handle e => (OS.FileSys.remove tmp handle OS.SysErr _ => (); raise e)
  in
    ()
  end

fun extract_cached_with_hash {cache_path, source_path, source_hash} =
  case read_cache cache_path source_hash of
      SOME deps => deps
    | NONE =>
        let
          val deps = extract_uncached source_path
          val _ = write_cache cache_path source_hash deps handle _ => ()
        in
          deps
        end

fun extract_cached {cache_path, source_path} =
  extract_cached_with_hash {cache_path = cache_path,
                            source_path = source_path,
                            source_hash = HolbuildHash.file_sha1 source_path}

fun cache_root () =
  case OS.Process.getEnv "HOLBUILD_CACHE" of
      SOME path => SOME path
    | NONE =>
        (case OS.Process.getEnv "XDG_CACHE_HOME" of
             SOME base => SOME (Path.concat(base, "holbuild"))
           | NONE =>
               case OS.Process.getEnv "HOME" of
                   SOME home => SOME (Path.concat(Path.concat(home, ".cache"), "holbuild"))
                 | NONE => NONE)

fun external_cache_path root source_hash =
  Path.concat(root, Path.concat("deps", Path.concat("external", source_hash ^ ".deps")))

fun extract_global_cached_with_hash {source_path, source_hash} =
  case cache_root () of
      NONE => extract_uncached source_path
    | SOME root =>
        extract_cached_with_hash {cache_path = external_cache_path root source_hash,
                                  source_path = source_path,
                                  source_hash = source_hash}

fun extract_global_cached source_path =
  extract_global_cached_with_hash {source_path = source_path,
                                   source_hash = HolbuildHash.file_sha1 source_path}

fun extract path = extract_uncached path

fun describe ({loads, uses, extra_deps, holdep_mentions} : t) =
  let
    fun line label values =
      case values of
          [] => ()
        | _ => print ("  " ^ label ^ ": " ^ String.concatWith ", " values ^ "\n")
  in
    line "loads" loads;
    line "uses" uses;
    line "extra deps" extra_deps;
    line "Holdep mentions" holdep_mentions
  end

end
