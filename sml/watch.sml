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
    List.foldl (fn (extra, acc) => add_existing (HolbuildProject.extra_input_absolute_path extra) acc)
               paths
               extras
  end

fun watch_paths project index =
  let
    val paths = []
    val paths = add_readable (#manifest project) paths
    val paths = add_readable (Path.concat(#root project, ".holconfig.toml")) paths
    val paths = List.foldl package_paths paths (HolbuildProject.packages project)
    val paths = List.foldl source_paths paths index
  in
    rev paths
  end

fun ensure_inotifywait () =
  if OS.Process.isSuccess (OS.Process.system "command -v inotifywait >/dev/null 2>&1") then ()
  else raise Error "build --watch requires inotifywait; install inotify-tools or use normal holbuild build"

fun sleep_debounce () = OS.Process.sleep (Time.fromReal 0.25)

fun inotify_command paths =
  "inotifywait -q -r --exclude " ^ quote "(^|/)(\\.[^/]+|_build)/" ^
  " -e close_write,move,create,delete,attrib -- " ^
  String.concatWith " " (map quote paths) ^ " >/dev/null 2>&1"

fun wait_for_change paths =
  case paths of
      [] => raise Error "build --watch has no files or directories to watch"
    | _ =>
        let
          val status = HolbuildToolchain.run ["sh", "-c", inotify_command paths]
        in
          if HolbuildToolchain.success status then sleep_debounce ()
          else raise Error "inotifywait failed while watching project inputs"
        end

end
