(* Machine-global memory admission (--cooperate-dir DIR).

   Independent holbuild processes that share DIR start a HOL child only while
   the reservations of all their running children, plus the new one, fit the
   byte budget in DIR/budget.  A child reserves its --max-heap plus a fixed
   allowance for memory outside the Poly/ML heap.  This bounds admission; it
   does not enforce RSS.

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

type settings = {dir : string, budget_mb : int option, maxheap : int option}

val settings : settings option ref = ref NONE

fun configure s = settings := SOME s

val mib = 1024 * 1024
val child_overhead = 1024 * mib

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
  case open_existing (lock_path dir) of
      SOME fd => fd
    | NONE =>
        (ensure_dir dir;
         case create_file (lock_path dir) "" of
             SOME fd => (close fd; open_lock dir)
           | NONE => open_lock dir)

fun with_coordinator dir f =
  let
    val fd = open_lock dir
    fun wait () = if try_lock fd then () else (OS.Process.sleep (Time.fromMilliseconds 20); wait ())
  in
    (wait (); f () before close fd) handle e => (close fd; raise e)
  end

fun mem_total () =
  let
    val ins = TextIO.openIn "/proc/meminfo"
    val text = TextIO.inputAll ins before TextIO.closeIn ins
    fun kib line =
      case String.tokens Char.isSpace line of
          ["MemTotal:", n, "kB"] => Int.fromString n
        | _ => NONE
  in
    Option.map (fn n => n * 1024)
      (List.foldl (fn (line, NONE) => kib line | (_, found) => found) NONE
                  (String.tokens (fn c => c = #"\n") text))
  end
  handle IO.Io _ => NONE

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

datatype attempt = Admitted of lease | Wait of {reserved : int, budget : int}

fun mib_text bytes = Int.toString (bytes div mib) ^ " MiB"

fun retry_delay () =
  Time.fromMilliseconds (500 + Time.toMicroseconds (Time.now ()) mod 250000 div 1000)

fun acquire {dir, budget_mb, maxheap} =
  let
    val charge =
      case maxheap of
          SOME mb => mb * mib + child_overhead
        | NONE => raise Error "--cooperate-dir requires --max-heap MB, which sizes each child's reservation"
    fun try () =
      with_coordinator dir (fn () =>
        let val budget = current_budget dir budget_mb
        in
          if charge > budget then
            raise Error ("a child's reservation of " ^ mib_text charge ^ " (--max-heap plus " ^
                         mib_text child_overhead ^ ") exceeds the machine budget of " ^
                         mib_text budget ^ " in " ^ budget_path dir)
          else
            let val reserved = reserved_bytes dir
            in
              if reserved + charge <= budget then Admitted (create_lease dir charge)
              else Wait {reserved = reserved, budget = budget}
            end
        end)
    fun loop waiting =
      case try () of
          Admitted lease =>
            (if waiting then HolbuildStatus.set_waiting_for_memory NONE else (); lease)
        | Wait {reserved, budget} =>
            ((if waiting then ()
              else HolbuildStatus.set_waiting_for_memory
                     (SOME ("needs " ^ mib_text charge ^ ", " ^ mib_text reserved ^ " of " ^
                            mib_text budget ^ " reserved in " ^ dir)));
             OS.Process.sleep (retry_delay ());
             loop true)
  in
    loop false
  end

(* Closes the parent's copy; never LOCK_UN, which would also unlock the
   child's inherited copy.  The child's group holds the lock until its last
   process exits (the parent watcher lingers a few hundred milliseconds), and
   the next scan removes the file. *)
fun release ({fd, ...} : lease) = close fd

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
