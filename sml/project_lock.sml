structure HolbuildProjectLock =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

datatype project_lock = ProjectLock of HolbuildFileLock.t

val remove_file = HolbuildFileLock.remove_file
val read_text = HolbuildFileLock.read_text
val write_text = HolbuildFileLock.write_text
val current_pid_text = HolbuildFileLock.current_pid_text
val current_host = HolbuildFileLock.current_host
val current_pid_namespace = HolbuildFileLock.current_pid_namespace
val current_boot_id = HolbuildFileLock.current_boot_id
val proc_starttime = HolbuildFileLock.proc_starttime
val owner_summary = HolbuildFileLock.owner_summary
fun project_lock_path (project : HolbuildProject.t) =
  Path.concat(Path.concat(HolbuildProject.artifact_root project, ".holbuild/locks"), "project.lock")

fun project_lock_owner_path lock = lock ^ ".owner"

fun project_lock_owner command =
  String.concatWith "\n"
    ["holbuild-project-lock-v2",
     "command=" ^ command,
     "pid=" ^ current_pid_text (),
     "pid_ns=" ^ current_pid_namespace (),
     "starttime=" ^ proc_starttime "self",
     "boot_id=" ^ current_boot_id (),
     "cwd=" ^ FS.getDir (),
     "host=" ^ current_host (),
     "started=" ^ Time.toString (Time.now ())] ^ "\n"

fun current_lock_owner lock =
  SOME (read_text (project_lock_owner_path lock)) handle _ => NONE

fun project_lock_error lock owner =
  Error ("project is already being modified by another holbuild process\n" ^
         "lock: " ^ lock ^ "\n" ^
         "owner: " ^ owner_summary owner)

fun unavailable_owner () =
  String.concatWith "\n"
    ["holbuild-project-lock-v2",
     "command=unknown",
     "pid=unknown",
     "cwd=unknown"] ^ "\n"

fun acquire project command =
  let
    val lock_path = project_lock_path project
  in
    case HolbuildFileLock.try_acquire_path {path = lock_path, obsolete_kind = SOME "project"} of
        SOME lock =>
          ((write_text (project_lock_owner_path lock_path) (project_lock_owner command);
            ProjectLock lock)
           handle e => (HolbuildFileLock.release lock; raise e))
      | NONE =>
          let val owner = Option.getOpt(current_lock_owner lock_path, unavailable_owner ())
          in raise project_lock_error lock_path owner end
  end
  handle HolbuildFileLock.Error msg =>
    raise Error ("could not acquire project lock for " ^ command ^ ": " ^ msg)

fun release (ProjectLock lock) =
  (remove_file (project_lock_owner_path (HolbuildFileLock.path lock));
   HolbuildFileLock.release lock)

fun with_lock project command f =
  let val lock = acquire project command
  in
    (f () before release lock)
    handle e =>
      (HolbuildToolchain.cleanup_active_children ();
       release lock;
       raise e)
  end

end
