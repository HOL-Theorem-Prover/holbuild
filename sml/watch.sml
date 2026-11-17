structure HolbuildWatch =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

type watch_set = {paths : string list, manifest_dirs : string list, input_files : string list}

fun quote s = HolbuildToolchain.quote s

fun readable path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false
fun exists path = FS.access(path, []) handle OS.SysErr _ => false
fun is_dir path = FS.isDir path handle OS.SysErr _ => false

fun add_unique path paths =
  if path = "" orelse List.exists (fn existing => existing = path) paths then paths
  else path :: paths

fun add_existing path paths = if exists path then add_unique path paths else paths
fun add_readable path paths = if readable path then add_unique path paths else paths

fun package_member_path package member =
  HolbuildProject.abs_under (HolbuildProject.package_root package) member

fun generator_paths package generator paths =
  let
    val root = HolbuildProject.package_root package
    fun add_rel (rel, acc) = add_existing (HolbuildProject.abs_under root rel) acc
  in
    List.foldl add_rel (List.foldl add_rel paths (HolbuildProject.generator_inputs generator))
               (HolbuildProject.generator_outputs generator)
  end

fun package_paths (package, paths) =
  let
    val paths = add_readable (HolbuildProject.package_manifest package) paths
    val paths = List.foldl (fn (member, acc) => add_existing (package_member_path package member) acc)
                           paths
                           (HolbuildProject.package_members package)
  in
    List.foldl (fn (generator, acc) => generator_paths package generator acc)
               paths
               (HolbuildProject.package_generators package)
  end

(* The path to watch for an extra-input declaration DECL relative to BASE in
   the package at ROOT: the file or directory it names or, for a glob, the
   directory of its literal prefix, since a glob is matched against every file
   below BASE.  While that path is missing, its nearest existing ancestor in the
   package, whose recursive watch sees it appear. *)
fun extra_input_watch_path root base decl =
  let
    val literal = Substring.takel (fn c => c <> #"*" andalso c <> #"?") (Substring.full decl)
    val path =
      if Substring.size literal = size decl then decl
      else Substring.string (Substring.dropr (fn c => c <> #"/") literal)
    fun existing path =
      if exists path orelse not (String.isPrefix (root ^ "/") path) then path
      else existing (Path.dir path)
  in
    existing (Path.mkCanonical (if Path.isAbsolute path then path else Path.concat(base, path)))
  end

(* The extra-input declarations of a source, each with the directory it is
   relative to: those of its action policy and of its own holbuild_extra_deps. *)
fun extra_input_decls (source : HolbuildSourceIndex.source) =
  let
    val source_path = #source_path source
    val manifest_decls =
      map (fn extra => (#package_root source, HolbuildProject.extra_input_path extra))
          (HolbuildProject.action_extra_inputs (#policy source))
    val source_decls =
      if readable source_path then
        map (fn decl => (Path.dir source_path, decl))
            (#extra_deps (HolbuildDependencies.extract_textual source_path))
      else []
  in
    manifest_decls @ source_decls
  end

(* Adds a source and the paths to watch for its extra inputs. *)
fun source_paths (source : HolbuildSourceIndex.source, paths) =
  List.foldl
    (fn ((base, decl), acc) =>
      add_existing (extra_input_watch_path (Path.mkCanonical (#package_root source)) base decl) acc)
    (add_readable (#source_path source) paths)
    (extra_input_decls source)

(* The files a declaration names, as the build expands it into action inputs;
   none while it names nothing, which the build reports. *)
fun expand_input base decl =
  map #2 (HolbuildBuildPlan.expand_extra_dep base decl)
  handle HolbuildBuildPlan.Error _ => [] | OS.SysErr _ => []

(* The files of the extra and generator inputs.  They may lie in a member
   directory or match a glob, so the watched paths alone don't list them. *)
fun input_files packages index =
  let
    fun generator_files package =
      List.concat
        (map (fn generator =>
               List.concat (map (expand_input (HolbuildProject.package_root package))
                                (HolbuildProject.generator_inputs generator)))
             (HolbuildProject.package_generators package))
    fun source_files source =
      List.concat (map (fn (base, decl) => expand_input base decl) (extra_input_decls source))
  in
    List.concat (map source_files index @ map generator_files packages)
  end

(* The directories whose manifests are in use. A manifest that takes
   precedence (holbuild.toml beside holproject.toml) or a .holconfig.toml can
   appear there without touching any watched path, so these directories are
   watched non-recursively. All events, not just creation: when a new manifest
   is invalid the watch set cannot be recomputed and does not contain it, and
   fixing or removing it must still be noticed. *)
fun manifest_dirs project packages =
  let
    fun add_manifest_dir (manifest, dirs) =
      if readable manifest then add_unique (Path.dir manifest) dirs else dirs
  in
    List.foldl add_manifest_dir
               (add_manifest_dir (#manifest project, []))
               (map HolbuildProject.package_manifest packages)
  end

fun watch_paths_with resolution project index =
  let
    val paths = []
    val paths = add_readable (#manifest project) paths
    val paths = add_readable (Path.concat(#root project, ".holconfig.toml")) paths
    val graph = HolbuildProjectGraph.resolve
                  {project = project, resolution = resolution}
    val packages = HolbuildProjectGraph.packages graph
    val paths = List.foldl package_paths paths packages
    val paths = List.foldl source_paths paths index
  in
    {paths = rev paths, manifest_dirs = rev (manifest_dirs project packages),
     input_files = input_files packages index}
  end

fun watch_paths project index =
  watch_paths_with HolbuildProject.standard_resolution project index

fun ensure_inotifywait () =
  if OS.Process.isSuccess (OS.Process.system "command -v inotifywait >/dev/null 2>&1") then ()
  else raise Error "build --watch requires inotifywait; install inotify-tools or use normal holbuild build"

fun sleep_debounce () = OS.Process.sleep (Time.fromReal 0.25)

(* The watched files and the input files, with their content hashes, sorted by
   path.  inotifywait only starts after a build, so an edit made during the
   build fires no event; comparing this from before the build with after it
   finds such an edit.  A file that can't be read is left out: the build
   reports it. *)
fun snapshot ({paths, input_files, ...} : watch_set) =
  let
    fun add_hash (path, hashes) =
      Binarymap.insert (hashes, path, HolbuildHash.file_sha256 path)
      handle IO.Io _ => hashes | OS.SysErr _ => hashes
  in
    Binarymap.listItems
      (List.foldl add_hash (Binarymap.mkDict String.compare)
                  (List.filter (not o is_dir) paths @ input_files))
  end

fun regex_escape text =
  String.translate
    (fn c => if Char.contains ".[]()*+?{}|^$\\" c then "\\" ^ str c else str c)
    text

fun drop_trailing_slashes path =
  if size path > 1 andalso String.isSuffix "/" path
  then drop_trailing_slashes (String.substring(path, 0, size path - 1))
  else path

(* A directory below another watched one adds nothing to the exclusion, and
   the pattern is one argument, which Linux caps at 128 KiB. *)
fun outermost_dirs dirs =
  let
    fun below parent dir = String.isPrefix (parent ^ "/") dir
  in
    List.filter (fn dir => not (List.exists (fn other => below other dir) dirs)) dirs
  end

(* Changes in holbuild's own .holbuild/, in .git/ and in _build/ don't
   matter.  inotifywait matches --exclude against each event's full path, so
   those names are anchored below the watched directories: an ancestor with
   such a name must not hide every event under it. *)
fun exclude_option paths =
  case outermost_dirs (map drop_trailing_slashes (List.filter is_dir paths)) of
      [] => ""
    | dirs =>
        " --exclude " ^
        quote ("^(" ^ String.concatWith "|" (map regex_escape dirs) ^
               ")/(.*/)?(\\.holbuild|\\.git|_build)/")

(* The watched paths are read from PATHS_FILE, one per line: all of them on
   the command line would exceed the 128 KiB cap on one argument for a big
   project.  A path starting with @ would read as an exclusion there. *)
fun inotify_tree_command paths_file paths =
  "inotifywait -q -r" ^ exclude_option paths ^
  " -e close_write,move,create,delete,attrib --fromfile " ^ quote paths_file ^
  " >/dev/null 2>&1"

fun inotify_dirs_command dirs =
  "inotifywait -q -e close_write,move,create,delete,attrib -- " ^
  String.concatWith " " (map quote dirs) ^ " >/dev/null 2>&1"

(* Two inotifywait processes, since one invocation is either recursive or not:
   the tree watch on the inputs, and a flat watch on the manifest directories.
   The first to exit decides; its status is the command's status. *)
fun inotify_command paths_file ({paths, manifest_dirs, ...} : watch_set) =
  String.concatWith "\n"
    [inotify_tree_command paths_file paths ^ " &",
     "tree=$!",
     inotify_dirs_command manifest_dirs ^ " &",
     "dirs=$!",
     "while kill -0 \"$tree\" 2>/dev/null && kill -0 \"$dirs\" 2>/dev/null; do sleep 0.2; done",
     "if kill -0 \"$tree\" 2>/dev/null; then first=$dirs; other=$tree; else first=$tree; other=$dirs; fi",
     "kill \"$other\" 2>/dev/null",
     "wait \"$other\" 2>/dev/null",
     "wait \"$first\""]

fun write_paths_file file paths =
  let
    val out = TextIO.openOut file
    fun write_line path = TextIO.output (out, path ^ "\n")
  in
    (List.app write_line paths; TextIO.closeOut out)
    handle e => (TextIO.closeOut out handle IO.Io _ => (); raise e)
  end

fun wait_for_change (watch_set as {paths, ...}) =
  case paths of
      [] => raise Error "build --watch has no files or directories to watch"
    | _ =>
        let
          val paths_file = HolbuildTempPath.temporary "watch-paths"
          fun remove_paths_file () = FS.remove paths_file handle OS.SysErr _ => ()
          val status =
            (write_paths_file paths_file paths;
             HolbuildToolchain.run ["sh", "-c", inotify_command paths_file watch_set])
            handle e => (remove_paths_file (); raise e)
          val _ = remove_paths_file ()
        in
          if HolbuildToolchain.success status then sleep_debounce ()
          else raise Error "inotifywait failed while watching project inputs"
        end

end
