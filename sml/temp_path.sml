structure HolbuildTempPath =
struct

val counter = ref 0
val mutex = Mutex.mutex ()

(* Name generation must not create a file or alter the process umask. *)
fun suffix () =
  let
    val _ = Mutex.lock mutex
    val id = (counter := !counter + 1; !counter) before Mutex.unlock mutex
  in
    SysWord.toString (Posix.Process.pidToWord (Posix.ProcEnv.getpid ())) ^
    "-" ^ Int.toString id
  end

fun near path extension =
  OS.Path.concat (OS.Path.dir path,
    "." ^ OS.Path.file path ^ "." ^ suffix () ^ extension)

fun temporary label =
  OS.Path.concat (Option.getOpt (OS.Process.getEnv "TMPDIR", "/tmp"),
    "holbuild-" ^ label ^ "-" ^ suffix ())

end
