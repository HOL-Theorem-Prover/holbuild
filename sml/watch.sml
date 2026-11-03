structure HolbuildWatch =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

fun quote s = HolbuildToolchain.quote s

fun readable path = FS.access(path, [FS.A_READ]) handle OS.SysErr _ => false
fun exists path = FS.access(path, []) handle OS.SysErr _ => false

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

fun source_paths (source : HolbuildSourceIndex.source, paths) =
  let
    val paths = add_readable (#source_path source) paths
    val extras = HolbuildProject.action_extra_inputs (#policy source)
  in
    List.foldl
      (fn (extra, acc) =>
        add_existing
          (Path.concat(#package_root source, HolbuildProject.extra_input_path extra))
          acc)
      paths
      extras
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
    {paths = rev paths, manifest_dirs = rev (manifest_dirs project packages)}
  end

fun watch_paths project index =
  watch_paths_with HolbuildProject.standard_resolution project index

fun ensure_inotifywait () =
  if OS.Process.isSuccess (OS.Process.system "command -v inotifywait >/dev/null 2>&1") then ()
  else raise Error "build --watch requires inotifywait; install inotify-tools or use normal holbuild build"

fun sleep_debounce () = OS.Process.sleep (Time.fromReal 0.25)

fun inotify_tree_command paths =
  "inotifywait -q -r --exclude " ^ quote "/(\\.holbuild|\\.git|_build)/" ^
  " -e close_write,move,create,delete,attrib -- " ^
  String.concatWith " " (map quote paths) ^ " >/dev/null 2>&1"

fun inotify_dirs_command dirs =
  "inotifywait -q -e close_write,move,create,delete,attrib -- " ^
  String.concatWith " " (map quote dirs) ^ " >/dev/null 2>&1"

(* Two inotifywait processes, since one invocation is either recursive or not:
   the tree watch on the inputs, and a flat watch on the manifest directories.
   The first to exit decides; its status is the command's status. *)
fun inotify_command {paths, manifest_dirs} =
  String.concatWith "\n"
    [inotify_tree_command paths ^ " &",
     "tree=$!",
     inotify_dirs_command manifest_dirs ^ " &",
     "dirs=$!",
     "while kill -0 \"$tree\" 2>/dev/null && kill -0 \"$dirs\" 2>/dev/null; do sleep 0.2; done",
     "if kill -0 \"$tree\" 2>/dev/null; then first=$dirs; other=$tree; else first=$tree; other=$dirs; fi",
     "kill \"$other\" 2>/dev/null",
     "wait \"$other\" 2>/dev/null",
     "wait \"$first\""]

fun wait_for_change (watch_set as {paths, ...}) =
  case paths of
      [] => raise Error "build --watch has no files or directories to watch"
    | _ =>
        let
          val status = HolbuildToolchain.run ["sh", "-c", inotify_command watch_set]
        in
          if HolbuildToolchain.success status then sleep_debounce ()
          else raise Error "inotifywait failed while watching project inputs"
        end

end
