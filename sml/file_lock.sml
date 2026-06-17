structure HolbuildFileLock =
struct
structure Path = OS.Path
structure FS = OS.FileSys
exception Error of string
datatype t = FileLock of {fd : Posix.IO.file_desc, path : string}
fun quote s = "'" ^ String.translate (fn #"'" => "'\\''" | c => str c) s ^ "'"
fun exists path = FS.access(path, []) handle OS.SysErr _ => false
fun ensure_dir path = if path = "" orelse path = "." orelse exists path then () else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())
fun read_text path = let val f = TextIO.openIn path fun close () = TextIO.closeIn f handle _ => () in (TextIO.inputAll f before close ()) handle e => (close (); raise e) end
fun write_text path text = let val f = TextIO.openOut path fun close () = TextIO.closeOut f handle _ => () in (TextIO.output(f, text); close ()) handle e => (close (); raise e) end
fun remove_file path = FS.remove path handle OS.SysErr _ => ()
fun remove_tree path =
  if path = "" orelse path = "." orelse path = "/" then raise Error ("refusing to remove unsafe lock path: " ^ path)
  else ignore (OS.Process.system ("rm -rf " ^ quote path))
fun remove_obsolete_lock_dir kind path =
  if (FS.isDir path handle OS.SysErr _ => false) then
    (TextIO.output(TextIO.stdErr, "holbuild: warning: removing obsolete directory " ^ kind ^ " lock: " ^ path ^ "\n"); remove_tree path)
  else ()
fun pid_text pid = LargeInt.toString (SysWord.toLargeInt (Posix.Process.pidToWord pid))
fun current_pid_text () = pid_text (Posix.ProcEnv.getpid ())
fun trim text = if size text > 0 andalso String.sub(text, size text - 1) = #"\n" then String.substring(text, 0, size text - 1) else text
fun current_host () = trim (read_text "/proc/sys/kernel/hostname") handle _ => Option.getOpt(OS.Process.getEnv "HOSTNAME", "unknown")
fun current_pid_namespace () = FS.readLink "/proc/self/ns/pid" handle _ => "unknown"
fun current_boot_id () = trim (read_text "/proc/sys/kernel/random/boot_id") handle _ => "unknown"
fun proc_starttime pid =
  let
    fun after_comm [] = NONE | after_comm (#")" :: #" " :: rest) = SOME (String.implode rest) | after_comm (_ :: rest) = after_comm rest
    val rest = Option.valOf (after_comm (String.explode (read_text (Path.concat(Path.concat("/proc", pid), "stat")))))
  in List.nth(String.tokens Char.isSpace rest, 19) end handle _ => "unknown"
fun owner_value key owner =
  let
    val prefix = key ^ "="
    fun value line = if String.isPrefix prefix line then SOME (String.extract(line, size prefix, NONE)) else NONE
    fun first [] = NONE | first (line :: rest) = (case value line of SOME v => SOME v | NONE => first rest)
  in first (String.tokens (fn c => c = #"\n") owner) end
fun owner_summary owner =
  let fun field name = case owner_value name owner of SOME value => name ^ "=" ^ value | NONE => name ^ "=unknown"
  in String.concatWith " " [field "command", field "pid", field "cwd"] end
fun lock_mode () = Posix.FileSys.S.flags [Posix.FileSys.S.irusr, Posix.FileSys.S.iwusr, Posix.FileSys.S.irgrp, Posix.FileSys.S.iwgrp, Posix.FileSys.S.iroth, Posix.FileSys.S.iwoth]
fun open_lock_file path = Posix.FileSys.createf(path, Posix.FileSys.O_RDWR, Posix.FileSys.O.flags [], lock_mode ())
fun close_fd fd = Posix.IO.close fd handle OS.SysErr _ => ()
fun set_close_on_exec fd = (Posix.IO.setfd(fd, Posix.IO.FD.flags [Posix.IO.getfd fd, Posix.IO.FD.cloexec]) handle OS.SysErr _ => ())
fun whole_file_lock ltype = Posix.IO.FLock.flock {ltype = ltype, whence = Posix.IO.SEEK_SET, start = 0, len = 0, pid = NONE}
fun try_lock_fd fd = (ignore (Posix.IO.setlk(fd, whole_file_lock Posix.IO.F_WRLCK)); true) handle OS.SysErr _ => false
fun blocking_lock_owner fd =
  (case Posix.IO.FLock.pid (Posix.IO.getlk(fd, whole_file_lock Posix.IO.F_WRLCK)) of SOME pid => SOME (pid_text pid) | NONE => NONE)
  handle OS.SysErr _ => NONE
fun try_acquire_path {path, obsolete_kind} =
  let val _ = ensure_dir (Path.dir path) val _ = Option.app (fn kind => remove_obsolete_lock_dir kind path) obsolete_kind val fd = open_lock_file path val _ = set_close_on_exec fd
  in if try_lock_fd fd then SOME (FileLock {fd = fd, path = path}) else (close_fd fd; NONE) end
  handle OS.SysErr (msg, _) => raise Error ("could not acquire lock: " ^ path ^ ": " ^ msg)
fun release (FileLock {fd, ...}) = close_fd fd
fun path (FileLock {path, ...}) = path
end
