structure HolbuildCacheTransfer =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

type source =
  { get_action : HolbuildCacheBackend.action_key -> HolbuildCacheBackend.manifest_text option,
    fetch_blob : {hash : HolbuildCacheBackend.blob_hash,
                  dst : HolbuildCacheBackend.local_path} -> HolbuildCacheBackend.fetch_result }

type destination =
  (* has_blob must establish usable content, not just pathname existence.
     publish_blob receives a transfer-owned file verified by fetch_blob. *)
  { has_blob : HolbuildCacheBackend.blob_hash -> bool,
    put_action : HolbuildCacheBackend.action_publish_policy ->
                 {key : HolbuildCacheBackend.action_key,
                  text : HolbuildCacheBackend.manifest_text} -> HolbuildCacheBackend.publish_result,
    publish_blob : {hash : HolbuildCacheBackend.blob_hash,
                    src : HolbuildCacheBackend.local_path} -> HolbuildCacheBackend.publish_result }

type entry_result =
  { key : HolbuildCacheBackend.action_key,
    blobs : int,
    uploaded_blobs : int,
    reused_blobs : int,
    action : HolbuildCacheBackend.publish_result }

fun unique_blobs manifest_text =
  let
    fun add (hash, hashes) =
      if List.exists (fn existing => existing = hash) hashes then hashes else hash :: hashes
    fun line (text, hashes) =
      case HolbuildFSCacheBackend.blob_ref text of
          SOME hash => add (hash, hashes)
        | NONE => hashes
  in
    rev (List.foldl line [] (String.tokens (fn c => c = #"\n") manifest_text))
  end

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if FS.access(path, []) handle OS.SysErr _ => false then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun remove_file path = FS.remove path handle OS.SysErr _ => ()

val temp_blob_counter = ref 0
val temp_blob_mutex = Mutex.mutex ()

fun next_temp_blob_id () =
  (Mutex.lock temp_blob_mutex;
   (temp_blob_counter := !temp_blob_counter + 1; !temp_blob_counter)
   before Mutex.unlock temp_blob_mutex)

(* Unique per copy: concurrent copies of one blob (parallel build workers,
   prefetch, other holbuild processes) share tmp_dir. *)
fun temp_blob_path tmp_dir hash =
  Path.concat(tmp_dir, String.concat ["holbuild-cache-transfer-", hash, "-",
                                      HolbuildFileLock.current_pid_text (), "-",
                                      Int.toString (next_temp_blob_id ()), ".blob"])

fun fetch_blob_or_raise (source : source) hash path =
  case #fetch_blob source {hash = hash, dst = path} of
      HolbuildCacheBackend.Hit => ()
    | HolbuildCacheBackend.Miss => raise Error ("source cache blob missing: " ^ hash)
    | HolbuildCacheBackend.Corrupt detail => raise Error ("source cache blob corrupt: " ^ hash ^ " (" ^ detail ^ ")")

fun publish_blob_or_raise (destination : destination) hash path =
  case #publish_blob destination {hash = hash, src = path} of
      HolbuildCacheBackend.Published => (1, 0)
    | HolbuildCacheBackend.AlreadyPresent => (0, 1)
    | HolbuildCacheBackend.Skipped => (0, 0)
    | HolbuildCacheBackend.Conflict detail => raise Error ("destination cache blob conflict: " ^ hash ^ " (" ^ detail ^ ")")

val no_space = "No space left on device"

(* Built once, into the executable's heap: the probe runs after a failed
   copy, and allocating its 1 MB there in one piece takes Poly/ML 5.9.2's
   large-object path, which can run a small heap out of store. *)
val probe_chunk = Word8Vector.tabulate (65536, fn _ => 0w0)

local
  open Foreign
  val statvfs = buildCall2 (getSymbol (loadExecutable ()) "statvfs", (cString, cPointer), cInt)
  (* Foreign resolves a symbol on its first call without a lock. *)
  val statvfs_mutex = Mutex.mutex ()
  val darwin = List.exists (fn field => field = ("sysname", "Darwin")) o Posix.ProcEnv.uname
  val word = SysWord.toLargeInt
  val word32 = Word32.toLargeInt
in
(* The bytes and inodes statvfs says unprivileged users may still take on
   the filesystem holding dir, or NONE where it fails.  Glibc's struct
   statvfs on 64-bit Linux has 64-bit fields; Darwin's counts are 32-bit,
   after two 64-bit sizes.  A filesystem with no fixed inode count (btrfs)
   reports 0 inodes in all, and has no inode limit. *)
fun disk_free dir =
  let
    val buf = Memory.malloc 0w128
    fun read () =
      if statvfs (dir, buf) <> 0 then NONE
      else if darwin () then
        SOME {bytes = word (Memory.get64 (buf, 0w1)) * word32 (Memory.get32 (buf, 0w6)),
              inodes = if Memory.get32 (buf, 0w7) = 0w0 then NONE
                       else SOME (word32 (Memory.get32 (buf, 0w9)))}
      else
        SOME {bytes = word (Memory.get64 (buf, 0w1)) * word (Memory.get64 (buf, 0w4)),
              inodes = if Memory.get64 (buf, 0w5) = 0w0 then NONE
                       else SOME (word (Memory.get64 (buf, 0w7)))}
  in
    (Mutex.lock statvfs_mutex;
     (read () before (Mutex.unlock statvfs_mutex; Memory.free buf))
     handle e => (Mutex.unlock statvfs_mutex; Memory.free buf; raise e))
  end
end

(* Below these a worker's disk counts as full: the free space a fleet
   worker waits for before it claims an action, and a few theories' files.  A test may
   set others, as "BYTES INODES" in HOLBUILD_TEST_DISK_FLOOR. *)
fun disk_floor () =
  case Option.map (String.tokens Char.isSpace) (OS.Process.getEnv "HOLBUILD_TEST_DISK_FLOOR") of
      SOME [bytes, inodes] =>
        (case (IntInf.fromString bytes, IntInf.fromString inodes) of
             (SOME b, SOME i) => {bytes = b, inodes = i}
           | _ => raise Error "HOLBUILD_TEST_DISK_FLOOR must be \"BYTES INODES\"")
    | SOME _ => raise Error "HOLBUILD_TEST_DISK_FLOOR must be \"BYTES INODES\""
    | NONE => {bytes = 4 * 1024 * 1024 * 1024, inodes = 1024}

(* Whether the filesystem holding dir is below the floor. *)
fun below_disk_floor dir =
  case disk_free dir of
      SOME {bytes, inodes} =>
        let val floor = disk_floor ()
        in
          bytes < #bytes floor orelse
          (case inodes of SOME n => n < #inodes floor | NONE => false)
        end
    | NONE => false

(* Whether the filesystem holding dir can't take a small write (1 MB). *)
fun out_of_space dir =
  let val probe = Path.concat(dir, ".holbuild-space-probe")
  in
    (let val out = BinIO.openOut probe
     in
       (let fun write 0 = () | write n = (BinIO.output (out, probe_chunk); write (n - 1))
        in write 16 end;
        BinIO.closeOut out)
       handle e => (BinIO.closeOut out handle _ => (); raise e)
     end;
     remove_file probe;
     false)
    handle e => (remove_file probe; String.isSubstring no_space (General.exnMessage e))
  end

(* A download that filled the disk need not say so (curl reports only a
   failed write, or leaves a short file), and removing it frees the space:
   probe while it is still there. *)
fun copy_blob source (destination : destination) tmp_dir hash (uploaded, reused) =
  if #has_blob destination hash then (uploaded, reused + 1)
  else
  let
    val path = temp_blob_path tmp_dir hash
    val (uploaded', reused') =
      (fetch_blob_or_raise source hash path;
       publish_blob_or_raise destination hash path)
      handle e =>
        let val full = out_of_space (Path.dir path)
        in
          remove_file path;
          if full andalso not (String.isSubstring no_space (General.exnMessage e)) then
            raise Error ("cache blob " ^ hash ^ ": " ^ no_space)
          else raise e
        end
  in
    remove_file path;
    (uploaded + uploaded', reused + reused')
  end

fun put_action_or_raise (destination : destination) key text =
  case #put_action destination HolbuildCacheBackend.PutIfAbsentOrSame {key = key, text = text} of
      result as HolbuildCacheBackend.Published => result
    | result as HolbuildCacheBackend.AlreadyPresent => result
    | result as HolbuildCacheBackend.Skipped => result
    | HolbuildCacheBackend.Conflict detail => raise Error ("destination cache action conflict: " ^ key ^ " (" ^ detail ^ ")")

fun copy_entry {source, destination, tmp_dir} key =
  let
    val manifest_text =
      case #get_action source key of
          SOME text => text
        | NONE => raise Error ("source cache action missing: " ^ key)
    val blobs = unique_blobs manifest_text
    val _ = ensure_dir tmp_dir
    val (uploaded, reused) =
      List.foldl (fn (hash, counts) => copy_blob source destination tmp_dir hash counts)
                 (0, 0)
                 blobs
    val action = put_action_or_raise destination key manifest_text
  in
    {key = key, blobs = length blobs, uploaded_blobs = uploaded,
     reused_blobs = reused, action = action}
  end

fun copy_entries transfer keys = map (copy_entry transfer) keys

end
