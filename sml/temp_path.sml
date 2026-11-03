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

val temporary_dir = ref NONE
val temporary_mutex = Mutex.mutex ()

fun private_temporary_dir () =
  (Mutex.lock temporary_mutex;
   (case !temporary_dir of
        SOME dir => dir
      | NONE =>
          let
            val root = Option.getOpt (OS.Process.getEnv "TMPDIR", "/tmp")
            fun create () =
              let val dir = OS.Path.concat (root, "holbuild-" ^ suffix ())
              in
                (Posix.FileSys.mkdir (dir, Posix.FileSys.S.irwxu); dir)
                handle e as OS.SysErr (_, SOME code) =>
                  if code = Posix.Error.exist then create () else raise e
              end
            val dir = create ()
            val _ = OS.Process.atExit (fn () => OS.FileSys.rmDir dir handle OS.SysErr _ => ())
            val _ = temporary_dir := SOME dir
          in dir end)
   before Mutex.unlock temporary_mutex)
  handle e => (Mutex.unlock temporary_mutex; raise e)

(* Shared temporary roots need an atomically reserved, private namespace. *)
fun temporary label =
  OS.Path.concat (private_temporary_dir (), label ^ "-" ^ suffix ())

end
