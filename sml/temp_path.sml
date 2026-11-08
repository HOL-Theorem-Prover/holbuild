structure HolbuildTempPath =
struct

val counter = ref 0
val mutex = Mutex.mutex ()
(* Initialize at runtime: PolyML.export preserves compile-time values. *)
val token = ref NONE

fun new_token () =
  let
    fun fallback () = Time.toNanoseconds (Time.now ())
    val number =
      (let
         val input = BinIO.openIn "/dev/urandom"
         val bytes = (BinIO.inputN (input, 8) before BinIO.closeIn input)
                     handle e => (BinIO.closeIn input; raise e)
       in
         if Word8Vector.length bytes = 8 then
           Word8Vector.foldl (fn (byte, n) => n * 256 + Word8.toLargeInt byte) 0 bytes
         else fallback ()
       end) handle IO.Io _ => fallback () | OS.SysErr _ => fallback ()
    val hex = IntInf.fmt StringCvt.HEX (number mod 18446744073709551616)
  in
    StringCvt.padLeft #"0" 16 hex
  end

(* Name generation must not create a file or alter the process umask. *)
fun suffix () =
  (Mutex.lock mutex;
   (let
      val process_token =
        case !token of
            SOME value => value
          | NONE => let val value = new_token () in token := SOME value; value end
      val _ = counter := !counter + 1
    in
      SysWord.toString (Posix.Process.pidToWord (Posix.ProcEnv.getpid ())) ^
      "-" ^ process_token ^ "-" ^ Int.toString (!counter)
    end before Mutex.unlock mutex))
  handle e => (Mutex.unlock mutex; raise e)

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
