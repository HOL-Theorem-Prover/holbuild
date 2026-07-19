structure HolbuildToolchain =
struct

structure Path = OS.Path
structure FS = OS.FileSys

datatype kernel_variant = datatype HolbuildHolToolchainConfig.kernel_variant
val kernel_variant_name = HolbuildHolToolchainConfig.kernel_variant_name
val kernel_variant_tracing = HolbuildHolToolchainConfig.kernel_variant_tracing

type t = {holdir : string, maxheap : int option, kernel_variant : kernel_variant}

exception Error of string

fun executable {holdir, ...} parts =
  List.foldl (fn (part, acc) => Path.concat(acc, part)) holdir parts

fun hol tc = executable tc ["bin", "hol"]
fun holmake tc = executable tc ["bin", "Holmake"]
fun base_state tc = executable tc ["bin", "hol.state"]

fun poly_runtime_args ({maxheap, ...} : t) =
  case maxheap of
      NONE => []
    | SOME n => ["--maxheap", Int.toString n]

fun hol_subcommand_argv tc subcommand =
  hol tc :: poly_runtime_args tc @ [subcommand]

fun quote s =
  "'" ^ String.translate (fn #"'" => "'\\''" | c => str c) s ^ "'"

fun command argv = String.concatWith " " (map quote argv)

fun success status = OS.Process.isSuccess status

fun timing_field text =
  String.translate (fn #"\t" => " " | #"\n" => " " | c => str c) text

fun timing_line {kind, argv, output, status, start, finish} =
  let
    val ms = Time.toMilliseconds (Time.-(finish, start))
    val fields =
      ["tool", "kind=" ^ timing_field kind,
       "status=" ^ (if success status then "ok" else "fail"),
       "ms=" ^ LargeInt.toString ms,
       "argc=" ^ Int.toString (length argv),
       "argv0=" ^ timing_field (case argv of [] => "" | first :: _ => first)] @
      (case output of NONE => [] | SOME path => ["output=" ^ timing_field path])
  in
    String.concatWith "\t" fields ^ "\n"
  end

fun timing_log_path () = OS.Process.getEnv "HOLBUILD_TIMING_LOG"

fun append_timing entry =
  case timing_log_path () of
      NONE => ()
    | SOME path =>
        let val out = TextIO.openAppend path
        in TextIO.output(out, entry); TextIO.closeOut out end
        handle _ => ()

fun timing_log_enabled () = Option.isSome (timing_log_path ())

fun lower_text text = String.map Char.toLower text

fun timing_detail_level () =
  case OS.Process.getEnv "HOLBUILD_TIMING_DETAIL" of
      SOME value => detail_level_value value
    | NONE =>
        (case OS.Process.getEnv "HOLBUILD_TIMING_LEVEL" of
             SOME value => detail_level_value value
           | NONE => 0)
and detail_level_value value =
  case lower_text value of
      "" => 0
    | "coarse" => 0
    | "normal" => 0
    | "fine" => 1
    | "detail" => 1
    | "trace" => 2
    | text =>
        (case Int.fromString text of
             SOME n => Int.max(0, n)
           | NONE => 0)

fun timing_detail_at level = timing_log_enabled () andalso timing_detail_level () >= level

fun phase_line_milliseconds {name, status, ms, fields} =
  String.concatWith "\t"
    (["phase",
      "name=" ^ timing_field name,
      "status=" ^ timing_field status,
      "ms=" ^ LargeInt.toString ms] @ map timing_field fields) ^ "\n"

fun phase_line {name, status, start, finish} =
  phase_line_milliseconds
    {name = name, status = status,
     ms = Time.toMilliseconds (Time.-(finish, start)), fields = []}

fun record_phase_detail level name elapsed fields =
  if timing_detail_at level then
    append_timing
      (phase_line_milliseconds
         {name = name, status = "ok", ms = Time.toMilliseconds elapsed, fields = fields})
  else ()

fun time_phase name f =
  let val start = Time.now ()
  in
    (let
       val result = f ()
       val finish = Time.now ()
       val _ = append_timing (phase_line {name = name, status = "ok", start = start, finish = finish})
     in
       result
     end)
    handle e =>
      let
        val finish = Time.now ()
        val _ = append_timing (phase_line {name = name, status = "fail", start = start, finish = finish})
      in
        raise e
      end
  end

fun timed_system kind argv output run =
  let
    val start = Time.now ()
    val status = run ()
    val finish = Time.now ()
    val _ = append_timing (timing_line {kind = kind, argv = argv, output = output,
                                        status = status, start = start, finish = finish})
  in
    status
  end

fun cleanup_active_children () = HolbuildProcessGroup.cleanup_active_children ()
fun run_tracked_shell script = HolbuildProcessGroup.run_shell script

fun timed_shell kind argv output script =
  timed_system kind argv output (fn () => run_tracked_shell script)

fun run argv =
  timed_shell "run" argv NONE (command argv)

fun run_interactive argv =
  timed_system "run_interactive" argv NONE (fn () => OS.Process.system (command argv))

fun run_in_dir dir argv =
  timed_shell "run_in_dir" argv NONE ("cd " ^ quote dir ^ " && " ^ command argv)

fun run_in_dir_to_file dir argv output =
  timed_shell "run_in_dir_to_file" argv (SOME output)
    ("cd " ^ quote dir ^ " && " ^ command argv ^ " > " ^ quote output ^ " 2>&1")

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if FS.access(path, []) handle OS.SysErr _ => false then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun ensure_parent path = ensure_dir (Path.dir path)

fun readable path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false

fun require_readable path =
  if readable path then () else raise Error ("required toolchain file not readable: " ^ path)

fun hash_text text = HolbuildHash.string_sha1 text

fun file_hash path = (require_readable path; HolbuildHash.file_sha1 path)

fun toolchain_key tc =
  hash_text
    (String.concatWith "\n"
       ["holbuild-toolchain-v1",
        "kernel_variant=" ^ kernel_variant_name (#kernel_variant tc),
        "hol=" ^ file_hash (hol tc),
        "base_state=" ^ file_hash (base_state tc)] ^ "\n")

fun sml_string s =
  "\"" ^ String.translate
    (fn #"\\" => "\\\\"
      | #"\"" => "\\\""
      | #"\n" => "\\n"
      | #"\t" => "\\t"
      | c => str c) s ^ "\""

fun sml_list values = "[" ^ String.concatWith ", " (map sml_string values) ^ "]"

fun has_suffix suffix text =
  let
    val n = size text
    val m = size suffix
  in
    n >= m andalso String.substring(text, n - m, m) = suffix
  end

fun is_directory path = FS.isDir path handle OS.SysErr _ => false

fun directory_entries path =
  let
    val stream = FS.openDir path
      handle OS.SysErr _ => raise Error ""
    fun loop entries =
      case FS.readDir stream of
          NONE => rev entries
        | SOME entry => loop (entry :: entries)
  in
    (loop [] before FS.closeDir stream)
    handle e => (FS.closeDir stream; raise e)
  end
  handle _ => []

fun loadable_object_file name = has_suffix ".ui" name orelse has_suffix ".uo" name

fun directory_has_loadable_object path = List.exists loadable_object_file (directory_entries path)

fun add_unique_path path paths = if List.exists (fn existing => existing = path) paths then paths else path :: paths

fun load_path_dirs_under root =
  let
    fun visit path dirs =
      if not (is_directory path) then dirs
      else
        let
          val dirs' = if directory_has_loadable_object path then add_unique_path path dirs else dirs
          fun child entry = Path.concat(path, entry)
          fun visible_subdir entry = entry <> ".hol" andalso is_directory (child entry)
        in
          List.foldl (fn (entry, acc) => visit (child entry) acc)
                     dirs'
                     (List.filter visible_subdir (directory_entries path))
        end
  in
    visit root []
  end

fun package_object_root package =
  Path.concat(HolbuildProject.package_artifact_root package, "obj")

fun run_context_load_path_dirs packages =
  rev (List.foldl
         (fn (package, dirs) =>
             List.foldl (fn (path, acc) => add_unique_path path acc)
                        dirs
                        (load_path_dirs_under (package_object_root package)))
         [] packages)

fun runtime_helper_path () =
  Path.concat(HolbuildRuntimePaths.source_root, "sml/holbuild_runtime.sml")

fun runtime_line () = "use " ^ sml_string (runtime_helper_path ()) ^ ";"

fun run_load_line name = "val _ = HolbuildRuntime.load " ^ sml_string name ^ ";"

fun write_run_context (project : HolbuildProject.t) packages =
  let
    val root = HolbuildProject.artifact_root project
    val hol_dir = Path.concat(root, ".holbuild")
    val context = Path.concat(hol_dir, "holbuild-run-context.sml")
    val load_dirs = run_context_load_path_dirs packages
    val _ = ensure_dir hol_dir
    val out = TextIO.openOut context
      handle e => raise Error ("could not write " ^ context ^ ": " ^ General.exnMessage e)
    fun line s = TextIO.output(out, s ^ "\n")
  in
    line "(* generated by holbuild; safe to delete *)";
    line ("val _ = loadPath := " ^ sml_list load_dirs ^ " @ !loadPath;");
    line (runtime_line ());
    List.app (line o run_load_line) (#run_loads project);
    TextIO.closeOut out;
    context
  end

end
