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

(* The extra-output root of the source's package, where a dependency's
   theories write their extra outputs (HolbuildProject.package_extra_output_root),
   while it holds outputs from the package's current source; the next build
   empties one that doesn't. *)
fun extra_output_root packages (source : HolbuildSourceIndex.source) =
  case List.find (fn package => HolbuildProject.package_name package = #package source) packages of
      SOME package =>
        (case HolbuildProject.package_extra_output_root package of
             SOME root =>
               if HolbuildSourceIndex.extra_output_root_current package root then SOME root else NONE
           | NONE => NONE)
    | NONE => NONE

(* The extra-input declarations of a source, each with the directory it is
   relative to and the root bounding that directory: those of its action
   policy and of its own holbuild_extra_deps.  In a dependency, each relative
   declaration is relative both to a directory of the package's source tree
   and to the matching one under its extra-output root, as the build reads
   the package's declared outputs from there. *)
fun extra_input_decls packages (source : HolbuildSourceIndex.source) =
  let
    val source_path = #source_path source
    val package_root = Path.mkCanonical (#package_root source)
    val output_root = extra_output_root packages source
    fun under root dir = if dir = "" then root else Path.concat(root, dir)
    fun bases dir decl =
      case output_root of
          NONE => [(package_root, under package_root dir, decl)]
        | SOME root =>
            if Path.isAbsolute decl then [(package_root, under package_root dir, decl)]
            else [(package_root, under package_root dir, decl),
                  (Path.mkCanonical root, under (Path.mkCanonical root) dir, decl)]
    val manifest_decls =
      List.concat (map (fn extra => bases "" (HolbuildProject.extra_input_path extra))
                       (HolbuildProject.action_extra_inputs (#policy source)))
    val script_dir = Path.dir (HolbuildSourceIndex.normalize_path (#relative_path source))
    val source_decls =
      if readable source_path then
        List.concat
          (map (fn decl =>
                  case output_root of
                      NONE => [(package_root, Path.dir source_path, decl)]
                    | SOME _ => bases script_dir decl)
               (#extra_deps (HolbuildDependencies.extract_textual source_path)))
      else []
  in
    manifest_decls @ source_decls
  end

(* Adds a source and the paths to watch for its extra inputs. *)
fun source_paths packages (source : HolbuildSourceIndex.source, paths) =
  List.foldl
    (fn ((root, base, decl), acc) =>
      add_existing (extra_input_watch_path root base decl) acc)
    (add_readable (#source_path source) paths)
    (extra_input_decls packages source)

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
      List.concat (map (fn (_, base, decl) => expand_input base decl) (extra_input_decls packages source))
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
    val paths = List.foldl (source_paths packages) paths index
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

(* Every watched path is watched through a symlink, <links>/<n>, and the paths
   are read from files, one per line.  The paths could otherwise be too long
   for the command line, since Linux caps one argument at 128 KiB: the paths
   themselves, and the exclusion pattern, which would have to name every
   watched directory.  A symlink also keeps a path with a newline in it
   intact in the files.

   Changes in holbuild's own .holbuild/, in .git/ and in _build/ don't
   matter.  inotifywait matches --exclude against each event's full path, so
   those names are matched below the watched directories only: an ancestor
   with such a name must not hide every event under it.  A symlink names the
   watched directory by a path with no such ancestor, and one pattern covers
   them all. *)
fun exclude_option links =
  " --exclude " ^
  quote ("^" ^ regex_escape links ^ "/[0-9]+/(.*/)?(\\.holbuild|\\.git|_build)/")

fun inotify_tree_command links paths_file =
  "inotifywait -q -r" ^ exclude_option links ^
  " -e close_write,move,create,delete,attrib --fromfile " ^ quote paths_file ^
  " >/dev/null 2>&1"

fun inotify_dirs_command dirs_file =
  "inotifywait -q -e close_write,move,create,delete,attrib --fromfile " ^
  quote dirs_file ^ " >/dev/null 2>&1"

(* Two inotifywait processes, since one invocation is either recursive or not:
   the tree watch on the inputs, and a flat watch on the manifest directories.
   The first to exit decides; its status is the command's status. *)
fun inotify_command links paths_file dirs_file =
  String.concatWith "\n"
    [inotify_tree_command links paths_file ^ " &",
     "tree=$!",
     inotify_dirs_command dirs_file ^ " &",
     "dirs=$!",
     "while kill -0 \"$tree\" 2>/dev/null && kill -0 \"$dirs\" 2>/dev/null; do sleep 0.2; done",
     "if kill -0 \"$tree\" 2>/dev/null; then first=$dirs; other=$tree; else first=$tree; other=$dirs; fi",
     "kill \"$other\" 2>/dev/null",
     "wait \"$other\" 2>/dev/null",
     "wait \"$first\""]

fun absolute path =
  if Path.isAbsolute path then path
  else Path.mkAbsolute {path = path, relativeTo = FS.getDir ()}

(* Makes the links directory and a file listing the links to PATHS, and
   another for DIRS, runs F on their names, and removes them. *)
fun with_watch_files paths dirs f =
  let
    val links = HolbuildTempPath.temporary "watch-links"
    val paths_file = HolbuildTempPath.temporary "watch-paths"
    val dirs_file = HolbuildTempPath.temporary "watch-dirs"
    val made = ref []
    val count = ref 0
    fun link path =
      let
        val link = Path.concat (links, Int.toString (!count))
        val _ = count := !count + 1
      in
        Posix.FileSys.symlink {old = absolute path, new = link};
        made := link :: !made;
        link
      end
    fun write_list file paths =
      let val out = TextIO.openOut file
      in
        (List.app (fn path => TextIO.output (out, link path ^ "\n")) paths;
         TextIO.closeOut out)
        handle e => (TextIO.closeOut out handle IO.Io _ => (); raise e)
      end
    fun cleanup () =
      (List.app (fn link => FS.remove link handle OS.SysErr _ => ()) (!made);
       FS.rmDir links handle OS.SysErr _ => ();
       FS.remove paths_file handle OS.SysErr _ => ();
       FS.remove dirs_file handle OS.SysErr _ => ())
    fun run () =
      (Posix.FileSys.mkdir (links, Posix.FileSys.S.irwxu);
       write_list paths_file paths;
       write_list dirs_file dirs;
       f links paths_file dirs_file)
  in
    (run () before cleanup ()) handle e => (cleanup (); raise e)
  end

fun wait_for_change ({paths, manifest_dirs, ...} : watch_set) =
  case paths of
      [] => raise Error "build --watch has no files or directories to watch"
    | _ =>
        let
          val status =
            with_watch_files paths manifest_dirs
              (fn links => fn paths_file => fn dirs_file =>
                 HolbuildToolchain.run
                   ["sh", "-c", inotify_command links paths_file dirs_file])
        in
          if HolbuildToolchain.success status then sleep_debounce ()
          else raise Error "inotifywait failed while watching project inputs"
        end

end
