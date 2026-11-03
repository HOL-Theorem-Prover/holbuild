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

fun command_output run_command command =
  let
    val {status, output = text} = run_command (command ^ " 2>&1")
  in
    if OS.Process.isSuccess status then text
    else die ("command failed: " ^ command ^ "\n" ^ text)
  end
  handle e as Error _ => raise e
       | e as HolbuildProcessGroup.Error _ => raise e
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
    val toolchain_rel = HolbuildHolToolchainConfig.sequence_file (#sequence HolbuildHolToolchainConfig.default)
    val toolchain_path = Path.concat(holdir, toolchain_rel)
    (* sortingLib is an optional HOL library: it is not named by the default
       build sequence, but HOLSource's `Libs sortingLib` header form requires
       its source to be buildable when using the reduced upto-hol toolchain. *)
    val optional_roots =
      if is_dir (Path.concat(holdir, "src/sort")) then ["src/sort"] else []
  in
    if readable toolchain_path then
      setdiff full (sequence_dirs holdir toolchain_rel) @ optional_roots
    else
      (* A missing reduced sequence selects the legacy full-build fallback, so
         every default-sequence source is already part of the toolchain. *)
      []
  end

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

type graph_node = {id : int, target : string, dependencies : int list,
                   toplevel_compile : bool}

(* Older Holmake versions do not escape command strings as JSON. Read only
   the fields needed here, rather than parsing those commands or running them. *)
fun graph_nodes text =
  let
    fun field name line =
      let val prefix = "\"" ^ name ^ "\" : "
          val line = trim line
      in
        if has_prefix prefix line then SOME (String.extract(line, size prefix, NONE))
        else NONE
      end
    fun integers value =
      List.mapPartial Int.fromString
        (String.tokens (fn c => not (Char.isDigit c)) value)
    fun compile line =
      case field "command" line of
          NONE => false
        | SOME value =>
            let val words = String.tokens Char.isSpace value
            in
              has_prefix "\"%%MOSCOWML_INDICATOR%% " value andalso
              member "-c" words andalso member "-toplevel" words
            end
    fun loop [] _ _ _ _ acc = rev acc
      | loop (line :: rest) id target deps toplevel acc =
          if trim line = "}" orelse trim line = "}," then
            loop rest NONE "" [] false
              (case id of
                   NONE => acc
                 | SOME id => {id = id, target = target, dependencies = deps,
                               toplevel_compile = toplevel} :: acc)
          else
            case field "node_id" line of
                SOME value => loop rest (Int.fromString value) target deps toplevel acc
              | NONE =>
                  (case json_target_value line of
                       SOME value => loop rest id value deps toplevel acc
                     | NONE =>
                         (case field "dependencies" line of
                              SOME value => loop rest id target (integers value) toplevel acc
                            | NONE => loop rest id target deps (toplevel orelse compile line) acc))
  in
    loop (split_lines text) NONE "" [] false []
  end

(* Toplevel compiler recipes declare object prerequisites that Holdep cannot
   infer when a signature or functor name differs from its source filename.
   Ordinary rules can have build-only prerequisites, so leave those alone. *)
fun compile_loads holdir members (nodes : graph_node list) =
  let
    val by_id = List.foldl (fn (node, dict) => Binarymap.insert(dict, #id node, node))
                  (Binarymap.mkDict Int.compare) nodes
    fun source_object path =
      case rel_under holdir path of
          NONE => false
        | SOME rel =>
            let val base = #base (Path.splitBaseExt path)
                val source = base ^ ".sml"
                val script =
                  if has_suffix "Theory" base then
                    String.substring(base, 0, size base - size "Theory") ^ "Script.sml"
                  else source
            in
              has_suffix ".uo" rel andalso
              member (#dir (Path.splitDirFile rel)) members andalso
              (readable source orelse readable script)
            end
    fun logical path = #base (Path.splitBaseExt (#file (Path.splitDirFile path)))
    fun load id =
      case Binarymap.peek(by_id, id) of
          NONE => NONE
        | SOME {target, ...} =>
            if source_object target orelse
               (has_suffix ".uo" target andalso
                #dir (Path.splitDirFile target) = Path.concat(holdir, "sigobj")) then
              SOME (logical target)
            else NONE
    fun policy ({target, dependencies, toplevel_compile, ...} : graph_node) =
      if not toplevel_compile orelse not (source_object target) then NONE
      else
        case List.mapPartial load dependencies of
            [] => NONE
          | loads => SOME (logical target, rev (List.foldl (fn (load, acc) => insert_unique load acc) [] loads))
  in
    List.mapPartial policy nodes
  end

fun holmake_sources run_command holdir roots =
  if null roots then {members = [], loads = []}
  else
    let
      val holmake = Path.concat(Path.concat(holdir, "bin"), "Holmake")
      val command = String.concatWith " "
        (map quote (holmake :: "--no-project" :: "--dirs" :: "--json" :: roots))
      val text = command_output run_command ("cd " ^ quote holdir ^ " && " ^ command)
      fun add_line (line, acc) =
        case json_target_value line of
            NONE => acc
          | SOME target =>
              (case member_dir_from_target holdir target of
                   NONE => acc
                 | SOME dir => insert_unique dir acc)
      val members = rev (List.foldl add_line roots (split_lines text))
    in
      {members = members, loads = compile_loads holdir members (graph_nodes text)}
    end

fun generate {holdir, manifest_path, members_path, run_command} =
  let
    val {members, loads} = holmake_sources run_command holdir (post_toolchain_roots holdir)
    val member_text = String.concatWith "\n" members ^ (if null members then "" else "\n")
    fun policy (logical, loads) =
      "\n[actions." ^ HolbuildBuiltinManifests.toml_string logical ^ "]\nloads = [" ^
      String.concatWith ", " (map HolbuildBuiltinManifests.toml_string loads) ^ "]\n"
    val manifest = HolbuildBuiltinManifests.manifest_text members ^
                   String.concat (map policy loads)
  in
    write_file members_path member_text;
    write_file manifest_path manifest
  end

end
