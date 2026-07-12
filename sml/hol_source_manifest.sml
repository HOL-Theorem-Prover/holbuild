structure HolbuildHolSourceManifest =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

fun die msg = raise Error msg
fun quote s = HolbuildHash.quote s
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

fun has_prefix prefix s = size s >= size prefix andalso String.substring(s, 0, size prefix) = prefix
fun has_suffix suffix s =
  let val n = size s val m = size suffix
  in n >= m andalso String.substring(s, n - m, m) = suffix end

fun strip_comment s =
  case Substring.position "#" (Substring.full s) of
      (pfx, sfx) => if Substring.size sfx = 0 then s else Substring.string pfx

fun read_lines path =
  let
    val input = TextIO.openIn path
    fun loop acc =
      case TextIO.inputLine input of
          NONE => rev acc before TextIO.closeIn input
        | SOME line => loop (line :: acc)
  in loop [] handle e => (TextIO.closeIn input; raise e) end
  handle IO.Io _ => die ("could not read HOL build sequence file: " ^ path)

fun write_file path text =
  let val out = TextIO.openOut path
  in TextIO.output(out, text); TextIO.closeOut out end

fun command_output command =
  let
    val tmp = FS.tmpName ()
    val status = OS.Process.system (command ^ " > " ^ quote tmp ^ " 2>&1")
    val input = TextIO.openIn tmp
    val text = TextIO.inputAll input before TextIO.closeIn input
    val _ = FS.remove tmp handle OS.SysErr _ => ()
  in
    if OS.Process.isSuccess status then text
    else die ("command failed: " ^ command ^ "\n" ^ text)
  end
  handle e as Error _ => raise e
       | e => die ("command failed: " ^ command ^ ": " ^ General.exnMessage e)

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
    in find 1 end
  else ("", s)

fun drop_selftest s =
  let
    fun loop i = if i < size s andalso String.sub(s, i) = #"!" then loop (i + 1) else i
    val n = loop 0
  in (n, String.extract(s, n, NONE)) end

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
              parse_file visited (abs_include (trim (String.extract(line0, size "#include ", NONE)))) acc
            else if has_prefix "#" line0 then acc
            else
              let val body = trim (strip_comment line0)
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
                       selftest = 0 andalso dir0 <> "**KERNEL**" andalso is_dir (Path.concat(holdir, dir0)) then
                      insert_unique dir0 acc
                    else acc
                  end
              end
          end
      in List.foldl parse_line acc (read_lines canonical) end
  in rev (parse_file [] (abs_seq seq_rel) []) end

fun post_toolchain_roots holdir =
  let
    val full = sequence_dirs holdir "tools/build/build-sequence"
    val toolchain = sequence_dirs holdir (HolbuildHolToolchainConfig.sequence_file (#sequence HolbuildHolToolchainConfig.default))
  in setdiff full toolchain end

fun split_lines text = String.tokens (fn c => c = #"\n") text

fun json_target_value line =
  let val s = trim line
      val prefix = "\"target\" : \""
  in
    if not (has_prefix prefix s) then NONE
    else
      let
        fun find i =
          if i >= size s then NONE
          else if String.sub(s, i) = #"\"" then SOME (String.substring(s, size prefix, i - size prefix))
          else find (i + 1)
      in find (size prefix) end
  end

fun rel_under root path =
  let val root' = if has_suffix "/" root then root else root ^ "/"
  in if has_prefix root' path then SOME (String.extract(path, size root', NONE)) else NONE end

fun source_target path =
  (has_suffix ".sml" path orelse has_suffix ".sig" path) andalso
  not (String.isSubstring "/.hol/" path) andalso
  not (String.isSubstring "/sigobj/" path)

fun member_dir_from_target holdir target =
  case rel_under holdir target of
      NONE => NONE
    | SOME rel => if source_target rel then SOME (#dir (Path.splitDirFile rel)) else NONE

fun holmake_source_dirs holdir roots =
  if null roots then []
  else
    let
      val holmake = Path.concat(Path.concat(holdir, "bin"), "Holmake")
      val command = String.concatWith " "
        (map quote (holmake :: "--no-project" :: "--dirs" :: "--json" :: roots))
      val text = command_output ("cd " ^ quote holdir ^ " && " ^ command)
      (* Temporary workaround for https://github.com/HOL-Theorem-Prover/HOL/issues/2021:
         Holmake --json can emit invalid JSON because command strings are not escaped.
         We only need target fields, so scan those lines directly until holbuild can
         depend on fixed HOL JSON. *)
      fun add_line (line, acc) =
        case json_target_value line of
            NONE => acc
          | SOME target =>
              (case member_dir_from_target holdir target of
                   NONE => acc
                 | SOME dir => insert_unique dir acc)
    in
      rev (List.foldl add_line roots (split_lines text))
    end

fun members holdir = holmake_source_dirs holdir (post_toolchain_roots holdir)

fun add_minimum_version path =
  let
    val lines = read_lines path
    val has_minimum =
      List.exists (fn line => String.isPrefix "minimum_version = " line) lines
    fun add [] = []
      | add (line :: rest) =
          if line = "[holbuild]" then
            line :: ("minimum_version = \"" ^
                     HolbuildBuiltinManifests.manifest_minimum_version ^ "\"") ::
            add rest
          else line :: add rest
  in
    if has_minimum then ()
    else write_file path (String.concatWith "\n" (add lines) ^ "\n")
  end

fun generate {holdir, manifest_path, members_path} =
  let
    val members = members holdir
    val member_text = String.concatWith "\n" members ^ (if null members then "" else "\n")
    val manifest = HolbuildBuiltinManifests.manifest_text members
  in
    write_file members_path member_text;
    write_file manifest_path manifest
  end

end
