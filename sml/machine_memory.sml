(* Machine-global memory admission (--cooperate-dir DIR).

   Independent holbuild processes that share DIR start a HOL child only while
   the reservations of all their running children, plus the new one, fit the
   byte budget in DIR/budget, and while the memory in use on the machine
   (MemTotal less MemAvailable) plus the new one fits it too.  Every child is
   charged the same --child-charge, an expected size rather than its
   --max-heap ceiling, so the second check is what holds children back when
   the running ones grow past their charge.  This bounds admission; it does
   not enforce RSS.

   A reservation is a file DIR/lease-* holding its byte charge.  It counts
   while some process holds an flock(2) on it.  The parent creates and locks
   it while holding DIR/lock, and the child inherits that descriptor, so the
   kernel drops the reservation when the last process of the child's group
   exits, even if the parent was killed.  An unlocked lease no longer counts
   and is removed, when permissions allow, by whoever scans next.  Nothing
   expires by time.

   Every holbuild process that shares DIR reads DIR/budget under DIR/lock at
   each admission.  An operator resizes the domain by replacing that file
   while holding DIR/lock; existing reservations then drain, and new
   admissions use the new value. *)
structure HolbuildMachineMemory =
struct

structure Path = OS.Path

exception Error of string

(* budget_mb is checked against DIR/budget at the first admission only, so
   that a later resize doesn't fail this process. *)
type settings = {dir : string, budget_mb : int option, charge_mb : int}

val settings : settings option ref = ref NONE

fun configure s = settings := SOME s

val mib = 1024 * 1024

(* The --child-charge default caps it at this, or at --max-heap if lower. *)
val default_charge_mb = 3072

local
  open Foreign
  val libc = loadExecutable ()
  val flock_call = buildCall2 (getSymbol libc "flock", (cInt, cInt), cInt)
  (* LOCK_EX and LOCK_NB have these values on Linux and the BSDs. *)
  val lock_ex = 2
  val lock_nb = 4
in
  fun try_lock fd =
    flock_call (SysWord.toInt (Posix.FileSys.fdToWord fd), lock_ex + lock_nb) = 0
end

val file_mode =
  Posix.FileSys.S.flags [Posix.FileSys.S.irusr, Posix.FileSys.S.iwusr,
                         Posix.FileSys.S.irgrp, Posix.FileSys.S.iroth]

fun lock_path dir = Path.concat(dir, "lock")
fun budget_path dir = Path.concat(dir, "budget")

fun sys_error path msg = Error (path ^ ": " ^ msg)

fun close fd = Posix.IO.close fd handle OS.SysErr _ => ()

(* Another thread may launch a child between open and setfd; holding the
   launch lock keeps descriptors from leaking into it.  A leaked DIR/lock
   descriptor would block every admission while that child runs. *)
fun open_cloexec opener =
  HolbuildSpawn.with_launch_lock
    (fn () => let val fd = opener () in Posix.IO.setfd (fd, Posix.IO.FD.cloexec); fd end)

(* Existing files are opened without O_CREAT: with fs.protected_regular, an
   O_CREAT open of another user's file in a sticky directory fails. *)
fun open_existing path =
  SOME (open_cloexec (fn () => Posix.FileSys.openf (path, Posix.FileSys.O_RDONLY, Posix.FileSys.O.flags [])))
  handle OS.SysErr (msg, err) =>
    if err = SOME Posix.Error.noent then NONE else raise sys_error path msg

fun write_all fd text =
  ignore (Posix.IO.writeVec (fd, Word8VectorSlice.full (Byte.stringToBytes text)))

(* Creates path with text and mode 0644 regardless of umask, so other users
   sharing the directory can read and lock it.  Returns NONE if it exists. *)
fun create_file path text =
  let
    val fd = open_cloexec (fn () =>
               Posix.FileSys.createf (path, Posix.FileSys.O_WRONLY, Posix.FileSys.O.excl, file_mode))
  in
    (Posix.FileSys.fchmod (fd, file_mode); write_all fd text; SOME fd)
    handle OS.SysErr (msg, _) => (close fd; raise sys_error path msg)
  end
  handle OS.SysErr (msg, err) =>
    if err = SOME Posix.Error.exist then NONE else raise sys_error path msg

fun read_number path fd =
  let
    val text = Byte.bytesToString (Posix.IO.readVec (fd, 64))
               handle OS.SysErr (msg, _) => raise sys_error path msg
    fun digits s = size s > 0 andalso CharVector.all Char.isDigit s
  in
    case String.tokens Char.isSpace text of
        [n] => if digits n then valOf (Int.fromString n)
               else raise Error (path ^ ": expected a decimal byte count, got " ^ HolbuildHash.quote text)
      | _ => raise Error (path ^ ": expected a decimal byte count, got " ^ HolbuildHash.quote text)
  end

fun ensure_dir path =
  if path = "" orelse (OS.FileSys.isDir path handle OS.SysErr _ => false) then ()
  else (ensure_dir (Path.dir path); OS.FileSys.mkDir path handle OS.SysErr _ => ())

fun open_lock dir =
  let val path = lock_path dir
  in
    case open_existing path of
        SOME fd => fd
      | NONE =>
          (ensure_dir dir;
           Option.app close (create_file path "");
           case open_existing path of
               SOME fd => fd
             | NONE => raise Error (path ^ " exists but cannot be opened"))
  end

(* DIR/lock is held only for a scan of DIR, so a minute without it means it
   is stuck, or this filesystem refuses flock: fail rather than hang. *)
val coordinator_attempts = 3000
val coordinator_poll = Time.fromMilliseconds 20

fun with_coordinator dir f =
  let
    val fd = open_lock dir
    fun wait 0 = raise Error ("could not lock " ^ lock_path dir ^
                              " for a minute: another process holds it, or the filesystem does not support flock")
      | wait n = if try_lock fd then () else (OS.Process.sleep coordinator_poll; wait (n - 1))
  in
    (wait coordinator_attempts; f () before close fd) handle e => (close fd; raise e)
  end

(* MemTotal and MemAvailable in bytes, NONE where /proc/meminfo or the field
   is missing.  Tests point HOLBUILD_TEST_MEMINFO at a stand-in file. *)
fun meminfo () =
  let
    val path = Option.getOpt (OS.Process.getEnv "HOLBUILD_TEST_MEMINFO", "/proc/meminfo")
    val ins = TextIO.openIn path
    val lines = String.tokens (fn c => c = #"\n") (TextIO.inputAll ins before TextIO.closeIn ins)
    fun field name =
      List.foldl (fn (line, NONE) =>
                     (case String.tokens Char.isSpace line of
                          [label, n, "kB"] => if label = name then Option.map (fn n => n * 1024) (Int.fromString n) else NONE
                        | _ => NONE)
                   | (_, found) => found)
                 NONE lines
  in
    {total = field "MemTotal:", available = field "MemAvailable:"}
  end
  handle IO.Io _ => {total = NONE, available = NONE}

fun mem_total () = #total (meminfo ())

(* MemTotal less a quarter (at least 1 GiB) for the OS, page cache and
   holbuild parents. *)
fun default_budget dir =
  case mem_total () of
      SOME total =>
        let val budget = total - Int.max (1024 * mib, total div 4)
        in
          if budget > 0 then budget
          else raise Error ("machine memory is too small for a default budget in " ^ dir ^
                            "; pass --machine-max-mem MB")
        end
    | NONE => raise Error ("cannot read MemTotal from /proc/meminfo to create " ^ budget_path dir ^
                           "; pass --machine-max-mem MB")

(* Called under DIR/lock. *)
fun current_budget dir budget_mb =
  let val path = budget_path dir
  in
    case open_existing path of
        SOME fd =>
          let val budget = read_number path fd before close fd
          in
            case budget_mb of
                SOME mb =>
                  if mb * mib = budget then budget
                  else raise Error ("--machine-max-mem " ^ Int.toString mb ^ " (" ^
                                    Int.toString (mb * mib) ^ " bytes) conflicts with " ^
                                    Int.toString budget ^ " bytes in " ^ path)
              | NONE => budget
          end
      | NONE =>
          let val budget = case budget_mb of SOME mb => mb * mib | NONE => default_budget dir
          in
            case create_file path (Int.toString budget ^ "\n") of
                SOME fd => (close fd; budget)
              | NONE => raise Error (path ^ " appeared while holding " ^ lock_path dir)
          end
  end

fun remove_file path = OS.FileSys.remove path handle OS.SysErr _ => ()

(* A lease that this process can lock has no holder left: remove it (another
   user's stale lease in a sticky directory cannot be removed, and is just
   not counted).  A lease that can't be read is an error rather than zero. *)
fun lease_charge dir name =
  let val path = Path.concat(dir, name)
  in
    case open_existing path of
        NONE => 0
      | SOME fd =>
          ((if try_lock fd then (remove_file path; 0) else read_number path fd) before close fd)
          handle e => (close fd; raise e)
  end

fun lease_names dir =
  let
    val stream = OS.FileSys.openDir dir
    fun loop acc =
      case OS.FileSys.readDir stream of
          NONE => acc
        | SOME name => loop (if String.isPrefix "lease-" name then name :: acc else acc)
  in
    (loop [] before OS.FileSys.closeDir stream)
    handle e => (OS.FileSys.closeDir stream; raise e)
  end
  handle OS.SysErr (msg, _) => raise sys_error dir msg

fun reserved_bytes dir = List.foldl (fn (name, sum) => sum + lease_charge dir name) 0 (lease_names dir)

type lease = {path : string, fd : Posix.IO.file_desc}

fun create_lease dir charge : lease =
  let
    val path = Path.concat(dir, "lease-" ^ HolbuildTempPath.suffix ())
  in
    case create_file path (Int.toString charge ^ "\n") of
        NONE => create_lease dir charge
      | SOME fd =>
          if try_lock fd then {path = path, fd = fd}
          else (close fd; remove_file path; raise Error ("could not lock new lease " ^ path))
  end

(* Closes the parent's copy; never LOCK_UN, which would also unlock the
   child's inherited copy.  The child's group holds the lock until its last
   process exits (the parent watcher lingers a few hundred milliseconds), and
   the next scan removes the file. *)
fun release ({fd, ...} : lease) = close fd

(* Wait carries why, for the status line. *)
datatype attempt = Admitted of lease | Wait of string

fun mib_text bytes = Int.toString (bytes div mib) ^ " MiB"

fun retry_delay () =
  Time.fromMilliseconds (500 + Time.toMicroseconds (Time.now ()) mod 250000 div 1000)

(* MemAvailable must cover the new child plus the memory outside the budget:
   the memory in use on the machine plus the child fits the budget (and
   MemTotal).  Without MemAvailable, admission rests on the reservations
   alone. *)
fun live_shortfall budget charge =
  case meminfo () of
      {total = SOME total, available = SOME available} =>
        if available >= Int.max (0, total - budget) + charge then NONE
        else SOME (mib_text (total - available) ^ " of " ^ mib_text budget ^
                   " in use on the machine (MemTotal less MemAvailable)")
    | _ => NONE

fun acquire {dir, budget_mb, charge_mb} =
  let
    val charge = charge_mb * mib
    val cleanups = HolbuildProcessGroup.cleanup_count ()
    fun check_not_stopped () =
      if HolbuildProcessGroup.cleanup_count () = cleanups then ()
      else raise Error "build stopped while waiting for machine memory"
    fun try () =
      with_coordinator dir (fn () =>
        let
          val budget = current_budget dir budget_mb
          val _ = settings := SOME {dir = dir, budget_mb = NONE, charge_mb = charge_mb}
        in
          if charge > budget then
            raise Error ("a child's reservation of " ^ mib_text charge ^ " (--child-charge, by default --max-heap up to " ^
                         Int.toString default_charge_mb ^ " MiB) exceeds the machine budget of " ^
                         mib_text budget ^ " in " ^ budget_path dir)
          else
            let val reserved = reserved_bytes dir
            in
              if reserved + charge > budget then
                Wait (mib_text reserved ^ " of " ^ mib_text budget ^ " reserved in " ^ dir)
              else
                case live_shortfall budget charge of
                    NONE => Admitted (create_lease dir charge)
                  | SOME why => Wait why
            end
        end)
    fun loop waiting =
      case try () of
          Admitted lease =>
            ((check_not_stopped () handle e => (release lease; raise e));
             if waiting then HolbuildStatus.set_waiting_for_memory NONE else ();
             lease)
        | Wait why =>
            (check_not_stopped ();
             (if waiting then ()
              else HolbuildStatus.set_waiting_for_memory
                     (SOME ("needs " ^ mib_text charge ^ ", " ^ why)));
             OS.Process.sleep (retry_delay ());
             loop true)
  in
    loop false
  end

(* Runs launch with a reserved lease descriptor that the child must inherit,
   or with NONE when cooperation is off. *)
fun with_reservation launch =
  case !settings of
      NONE => launch NONE
    | SOME s =>
        let val lease = acquire s
        in
          (launch (SOME (#fd lease)) before release lease)
          handle e => (release lease; raise e)
        end

end
