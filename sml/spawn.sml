structure HolbuildSpawn =
struct

(* Poly/ML's own ways to run a child are slow to wait for.  OS.Process.system
   and Posix.Process.waitpid poll waitpid(WNOHANG) with 10ms sleeps in
   between, so every child costs at least 10ms; Unix.execute also does a full
   fork, which costs ~12ms more with a few hundred MB of heap.  Here the child
   is started with posix_spawnp (vfork-like, independent of the heap size), its
   stdout is read from a pipe whose end-of-file wakes the reader immediately,
   and only the short gap between end-of-file and the child becoming
   reapable is polled, in 1ms steps. *)

datatype stderr = Inherit | Merge | Discard

type result = {status : Posix.Process.exit_status, output : string}

(* A pipe end created by one launch must not leak into a child that another
   thread launches before the end is marked close-on-exec.  Every launch that
   creates pipe ends holds this lock until the child has its copies. *)
val launch_mutex = Mutex.mutex ()

fun with_launch_lock f =
  let
    val _ = Mutex.lock launch_mutex
  in
    f () before Mutex.unlock launch_mutex
  end
  handle e => (Mutex.unlock launch_mutex; raise e)

local
  open Foreign
  val libc = loadExecutable ()
  val sym = getSymbol libc
  val file_actions_init =
    buildCall1 (sym "posix_spawn_file_actions_init", cPointer, cInt)
  val file_actions_destroy =
    buildCall1 (sym "posix_spawn_file_actions_destroy", cPointer, cInt)
  val file_actions_adddup2 =
    buildCall3 (sym "posix_spawn_file_actions_adddup2", (cPointer, cInt, cInt), cInt)
  val file_actions_addopen =
    buildCall5 (sym "posix_spawn_file_actions_addopen",
                (cPointer, cInt, cString, cInt, cInt), cInt)
  val attr_init = buildCall1 (sym "posix_spawnattr_init", cPointer, cInt)
  val attr_destroy = buildCall1 (sym "posix_spawnattr_destroy", cPointer, cInt)
  val attr_setflags = buildCall2 (sym "posix_spawnattr_setflags", (cPointer, cShort), cInt)
  val attr_setsigmask =
    buildCall2 (sym "posix_spawnattr_setsigmask", (cPointer, cPointer), cInt)
  val sigemptyset = buildCall1 (sym "sigemptyset", cPointer, cInt)
  val posix_spawnp =
    buildCall6 (sym "posix_spawnp",
                (cStar cInt, cString, cPointer, cPointer, cPointer, cPointer), cInt)

  (* Same value in glibc, musl and macOS. *)
  val POSIX_SPAWN_SETSIGMASK = 0x08
  val O_WRONLY = 1
  (* posix_spawn_file_actions_t, posix_spawnattr_t and sigset_t are opaque
     and platform-sized (at most 336 bytes in glibc); libc initializes them. *)
  val opaque_size = 0w512

  fun with_memory size f =
    let val p = Memory.malloc size
    in f p before Memory.free p handle e => (Memory.free p; raise e) end

  fun c_string s =
    let
      val n = size s
      val p = Memory.malloc (Word.fromInt (n + 1))
      fun copy i =
        if i = n then Memory.set8 (p, Word.fromInt i, 0w0)
        else (Memory.set8 (p, Word.fromInt i, Byte.charToByte (String.sub (s, i)));
              copy (i + 1))
    in
      copy 0; p
    end

  (* A NULL-terminated char*[] for argv and envp. *)
  fun with_string_array strings f =
    let
      val pointers = map c_string strings
      val array = Memory.malloc (#size LowLevel.cTypePointer * Word.fromInt (length strings + 1))
      fun fill (i, []) = Memory.setAddress (array, Word.fromInt i, Memory.null)
        | fill (i, p :: rest) = (Memory.setAddress (array, Word.fromInt i, p); fill (i + 1, rest))
      fun free () = (List.app Memory.free pointers; Memory.free array)
    in
      fill (0, pointers);
      f array before free () handle e => (free (); raise e)
    end

  fun fd_int fd = SysWord.toInt (Posix.FileSys.fdToWord fd)

  fun check name rc =
    if rc = 0 then ()
    else raise OS.SysErr (name ^ " failed with error " ^ Int.toString rc, NONE)

in
  (* Returns NONE when the program could not be started. *)
  fun spawn {program, args, stderr} stdout_fd =
    with_memory opaque_size (fn actions =>
    with_memory opaque_size (fn attr =>
    with_memory opaque_size (fn sigset =>
      let
        val _ = check "posix_spawn_file_actions_init" (file_actions_init actions)
        val _ = check "posix_spawnattr_init" (attr_init attr)
        fun destroy () = (ignore (file_actions_destroy actions); ignore (attr_destroy attr))
        fun launch () =
          let
            val _ = check "posix_spawn_file_actions_adddup2"
                          (file_actions_adddup2 (actions, fd_int stdout_fd, 1))
            val _ =
              case stderr of
                  Inherit => ()
                | Merge =>
                    check "posix_spawn_file_actions_adddup2"
                          (file_actions_adddup2 (actions, fd_int stdout_fd, 2))
                | Discard =>
                    check "posix_spawn_file_actions_addopen"
                          (file_actions_addopen (actions, 2, "/dev/null", O_WRONLY, 0))
            (* Poly/ML blocks every signal in ML threads and the mask survives
               exec, so the child must get an empty one. *)
            val _ = check "sigemptyset" (sigemptyset sigset)
            val _ = check "posix_spawnattr_setsigmask" (attr_setsigmask (attr, sigset))
            val _ = check "posix_spawnattr_setflags" (attr_setflags (attr, POSIX_SPAWN_SETSIGMASK))
            val pid = ref 0
            val rc =
              with_string_array (program :: args) (fn argv =>
              with_string_array (Posix.ProcEnv.environ ()) (fn envp =>
                posix_spawnp (pid, program, actions, attr, argv, envp)))
          in
            if rc = 0 then SOME (Posix.Process.wordToPid (SysWord.fromInt (!pid))) else NONE
          end
      in
        launch () before destroy () handle e => (destroy (); raise e)
      end)))
end

fun read_to_end fd =
  let
    val reader = Posix.IO.mkTextReader {fd = fd, name = "child stdout", initBlkMode = true}
    val input = TextIO.mkInstream (TextIO.StreamIO.mkInstream (reader, ""))
  in
    TextIO.inputAll input before TextIO.closeIn input
    handle e => (TextIO.closeIn input; raise e)
  end

fun reap pid =
  case Posix.Process.waitpid_nh (Posix.Process.W_CHILD pid, []) of
      SOME (_, status) => status
    | NONE => (ignore (Posix.Process.sleep (Time.fromMilliseconds 1)); reap pid)

(* Runs program (searched in PATH) with args and returns its exit status and
   stdout.  A program that cannot be started reports exit status 127, as a
   shell would. *)
fun run request : result =
  let
    val (read_fd, pid) =
      with_launch_lock (fn () =>
        let
          val {infd, outfd} = Posix.IO.pipe ()
          val _ = Posix.IO.setfd (infd, Posix.IO.FD.cloexec)
          val _ = Posix.IO.setfd (outfd, Posix.IO.FD.cloexec)
          val pid = spawn request outfd
                    handle e => (Posix.IO.close infd; Posix.IO.close outfd; raise e)
        in
          Posix.IO.close outfd;
          (infd, pid)
        end)
  in
    case pid of
        NONE => (Posix.IO.close read_fd; {status = Posix.Process.W_EXITSTATUS 0w127, output = ""})
      | SOME pid =>
          let val output = read_to_end read_fd
          in {status = reap pid, output = output} end
  end

fun succeeded ({status, ...} : result) = status = Posix.Process.W_EXITED

end
