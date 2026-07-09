structure HolbuildBuiltinManifests =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

val holdir_manifest_name = "builtin:HOLDIR"

fun die msg = raise Error msg

fun readable path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false
fun is_dir path = FS.isDir path handle OS.SysErr _ => false

fun trim text =
  let
    fun ws c = Char.isSpace c
    val n = size text
    fun left i = if i < n andalso ws (String.sub(text, i)) then left (i + 1) else i
    fun right i = if i >= 0 andalso ws (String.sub(text, i)) then right (i - 1) else i
    val l = left 0
    val r = right (n - 1)
  in if r < l then "" else String.substring(text, l, r - l + 1) end

fun has_prefix prefix s =
  size s >= size prefix andalso String.substring(s, 0, size prefix) = prefix

fun strip_comment s =
  case Substring.position "#" (Substring.full s) of
      (pfx, sfx) =>
        if Substring.size sfx = 0 then s else Substring.string pfx

fun read_lines path =
  let
    val input = TextIO.openIn path
    fun loop acc =
      case TextIO.inputLine input of
          NONE => rev acc before TextIO.closeIn input
        | SOME line => loop (line :: acc)
  in
    loop [] handle e => (TextIO.closeIn input; raise e)
  end
  handle IO.Io _ => die ("could not read HOL build sequence file: " ^ path)

fun member x xs = List.exists (fn y => x = y) xs
fun insert_unique x xs = if member x xs then xs else x :: xs

fun remove_one x xs = List.filter (fn y => y <> x) xs
fun setdiff xs ys = List.foldl (fn (y, acc) => remove_one y acc) xs ys

fun extract_bracket left right s =
  if size s > 0 andalso String.sub(s, 0) = left then
    let
      fun find i =
        if i >= size s then die ("malformed HOL build sequence annotation: " ^ s)
        else if String.sub(s, i) = right then
          (String.substring(s, 1, i - 1), String.extract(s, i + 1, NONE))
        else find (i + 1)
    in
      find 1
    end
  else ("", s)

fun drop_selftest s =
  let
    fun loop i = if i < size s andalso String.sub(s, i) = #"!" then loop (i + 1) else i
    val n = loop 0
  in
    (n, String.extract(s, n, NONE))
  end

fun sequence_dirs holdir seq_rel =
  let
    val tools = Path.concat(holdir, "tools")
    fun abs_include rel = Path.mkCanonical (Path.concat(tools, rel))
    fun abs_seq rel = if Path.isAbsolute rel then rel else Path.concat(holdir, rel)
    fun parse_file visited path acc =
      let
        val canonical = Path.mkCanonical path handle Path.InvalidArc => path
        val _ = if member canonical visited then die ("recursive HOL build sequence include: " ^ canonical) else ()
        val visited = canonical :: visited
        fun parse_line (line, acc) =
          let val line0 = trim line
          in
            if line0 = "" then acc
            else if has_prefix "#include " line0 then
              let val include_rel = trim (String.extract(line0, size "#include ", NONE))
              in parse_file visited (abs_include include_rel) acc end
            else if has_prefix "#" line0 then acc
            else
              let
                val body = trim (strip_comment line0)
              in
                if body = "" then acc
                else
                  let
                    val (mlsys, rest1) = extract_bracket #"[" #"]" body
                    val (kernel, rest2) = extract_bracket #"(" #")" rest1
                    val (selftest, dir0) = drop_selftest rest2
                  in
                    if (mlsys = "" orelse mlsys = "poly") andalso
                       (kernel = "" orelse kernel = "stdknl") andalso
                       selftest = 0 andalso dir0 <> "**KERNEL**" then
                      let val path = Path.concat(holdir, dir0)
                      in if is_dir path then insert_unique dir0 acc else acc end
                    else acc
                  end
              end
          end
      in
        List.foldl parse_line acc (read_lines canonical)
      end
  in
    rev (parse_file [] (abs_seq seq_rel) [])
  end

fun implicit_hol_members holdir =
  let
    val full_sequence = Path.concat(holdir, "tools/build/build-sequence")
  in
    if not (readable full_sequence) then []
    else
      let
        val full = sequence_dirs holdir "tools/build/build-sequence"
        val toolchain = sequence_dirs holdir (HolbuildHolToolchainConfig.sequence_file (#sequence HolbuildHolToolchainConfig.default))
      in
        setdiff full toolchain
      end
  end

fun toml_string s =
  "\"" ^ String.translate (fn #"\\" => "\\\\" | #"\"" => "\\\"" | c => str c) s ^ "\""

fun manifest_text members =
  String.concatWith "\n"
    ( ["# Built-in manifest for the reserved HOL dependency.",
       "# The shared toolchain builds the configured HOL sequence into sigobj;",
       "# remaining default-build sequence directories are exposed as source.",
       "",
       "[holbuild]",
       "schema = 2",
       "",
       "[project]",
       "name = \"hol\"",
       "version = \"builtin-implicit-hol\"",
       "",
       "[build]",
       "members = ["] @
      map (fn member => "  " ^ toml_string member ^ ",") members @
      ["]",
       "exclude_globs = [",
       "  \"*/selftest.sml\",",
       "  \"*/test.sml\",",
       "  \"*/tests/*\",",
       "  \"*/theory_tests/*\",",
       "  \"*/examples/*\",",
       "  \"*/Manual/*\",",
       "  \"src/emit/MLton/*\",",
       "  \"src/portableML/mlton/*\",",
       "  \"src/portableML/mosml/*\",",
       "  \"src/simp/src/mosml/*\",",
       "  \"src/tracing/no/*\",",
       "  \"src/num/reduce/conv-old/*\",",
       "]",
       ""] )

fun holdir_manifest_text holdir = manifest_text (implicit_hol_members holdir)

end
