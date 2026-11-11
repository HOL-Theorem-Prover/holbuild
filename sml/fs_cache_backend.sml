structure HolbuildFSCacheBackend : HOLBUILD_FS_CACHE_BACKEND =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

datatype t = FSCache of {root : string}

fun filesystem root = FSCache {root = root}

fun default () =
  filesystem (HolbuildCacheConfig.cache_root ())
  handle HolbuildCacheConfig.Error msg => raise Error msg

fun root (FSCache {root}) = root

fun path_exists path = FS.access(path, []) handle OS.SysErr _ => false

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if path_exists path then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun ensure_parent path = ensure_dir (Path.dir path)

fun temp_near path =
  HolbuildTempPath.near path ".tmp"

fun remove_file path = FS.remove path handle OS.SysErr _ => ()

fun rename_replace {old, new} =
  FS.rename {old = old, new = new}
  handle OS.SysErr _ =>
    (FS.remove new handle OS.SysErr _ => ();
     FS.rename {old = old, new = new})

fun read_text path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end

fun write_text path text =
  let
    val _ = ensure_parent path
    val tmp = temp_near path
    val output = TextIO.openOut tmp
      handle e => raise Error ("could not write " ^ path ^ ": " ^ General.exnMessage e)
    fun close_output () = TextIO.closeOut output handle _ => ()
  in
    (TextIO.output(output, text);
     TextIO.closeOut output;
     rename_replace {old = tmp, new = path})
    handle e => (close_output (); remove_file tmp; raise e)
  end

fun copy_binary src dst =
  let
    val input = BinIO.openIn src
      handle e => raise Error ("could not read " ^ src ^ ": " ^ General.exnMessage e)
    val _ = ensure_parent dst
    val tmp = temp_near dst
    val output = BinIO.openOut tmp
      handle e => (BinIO.closeIn input; raise Error ("could not write " ^ dst ^ ": " ^ General.exnMessage e))
    fun close_input () = BinIO.closeIn input handle _ => ()
    fun close_output () = BinIO.closeOut output handle _ => ()
    fun loop () =
      let val chunk = BinIO.inputN(input, 65536)
      in
        if Word8Vector.length chunk = 0 then ()
        else (BinIO.output(output, chunk); loop ())
      end
  in
    (loop ();
     BinIO.closeIn input;
     BinIO.closeOut output;
     rename_replace {old = tmp, new = dst})
    handle e => (close_input (); close_output (); remove_file tmp; raise e)
  end

fun link_or_copy {src, dst} =
  copy_binary src dst
  handle Error msg => raise Error msg
       | e => raise Error ("could not link or copy " ^ src ^ " to " ^ dst ^ ": " ^ General.exnMessage e)

fun file_hash_matches path hash =
  path_exists path andalso HolbuildHash.file_sha256 path = hash
  handle _ => false

fun actions_dir cache = Path.concat(root cache, "actions")
fun blobs_dir cache = Path.concat(root cache, "blobs")
fun tmp_dir cache = Path.concat(root cache, "tmp")
fun locks_dir cache = Path.concat(root cache, "locks")

fun action_dir cache key = Path.concat(actions_dir cache, key)
fun action_manifest cache key = Path.concat(action_dir cache key, "manifest")
fun blob_path cache hash = Path.concat(blobs_dir cache, hash)

(* Automatic GC triggers on the bytes written into a cache since its last GC:
   the sum of the root's journal, where each command that wrote appends one
   line at exit, plus what this process has written and not yet appended.
   Every GC replaces the journal with 0. *)
val growth = ref (Redblackmap.mkDict String.compare : (string, Position.int) Redblackmap.dict)
val growth_lock = Mutex.mutex ()

fun with_growth f =
  (Mutex.lock growth_lock;
   (f () before Mutex.unlock growth_lock) handle e => (Mutex.unlock growth_lock; raise e))

fun add_growth cache bytes =
  with_growth (fn () =>
    growth := Redblackmap.insert (!growth, root cache,
                                   bytes + Option.getOpt (Redblackmap.peek (!growth, root cache), 0)))

fun take_growth root =
  with_growth (fn () =>
    case Redblackmap.peek (!growth, root) of
        NONE => 0
      | SOME bytes => (growth := #1 (Redblackmap.remove (!growth, root)); bytes))

fun growth_journal cache = Path.concat(locks_dir cache, "gc-growth.journal")

(* One short O_APPEND write per command, so concurrent commands need no lock;
   a line lost to a concurrent reset only delays the next trigger. *)
fun flush_growth () =
  let
    val pending = with_growth (fn () => Redblackmap.listItems (!growth) before
                                         growth := Redblackmap.mkDict String.compare)
    fun append (root, bytes) =
      let
        val path = growth_journal (filesystem root)
        val _ = ensure_parent path
        val output = TextIO.openAppend path
      in
        TextIO.output (output, Position.toString bytes ^ "\n") handle e => (TextIO.closeOut output; raise e);
        TextIO.closeOut output
      end
      handle IO.Io _ => () | OS.SysErr _ => ()
  in
    List.app append (List.filter (fn (_, bytes) => bytes > 0) pending)
  end

fun growth_since_gc cache =
  let
    val journal =
      List.foldl (fn (line, sum) => sum + Option.getOpt (Position.fromString line, 0))
                 0 (String.tokens (fn c => c = #"\n") (read_text (growth_journal cache)))
      handle IO.Io _ => 0
  in
    journal + with_growth (fn () => Option.getOpt (Redblackmap.peek (!growth, root cache), 0))
  end

fun reset_growth cache =
  (ignore (take_growth (root cache)); write_text (growth_journal cache) "0\n")

val manifest_growth_bytes : Position.int = 1048576

fun ensure_layout cache =
  (ensure_dir (actions_dir cache); ensure_dir (blobs_dir cache); ensure_dir (tmp_dir cache))

fun take_token s =
  let
    fun loop i =
      if i >= size s then i
      else
        case String.sub(s, i) of
            #" " => i
          | #"\t" => i
          | #"\n" => i
          | _ => loop (i + 1)
  in
    String.substring(s, 0, loop 0)
  end

fun blob_ref line =
  case String.tokens Char.isSpace line of
      ["blob", _, hash] => SOME hash
    | _ =>
        if String.isPrefix "blob=" line then SOME (take_token (String.extract(line, 5, NONE)))
        else NONE

fun touch path = FS.setTime(path, NONE) handle OS.SysErr _ => ()

(* GC snapshots the blobs live manifests reference, then sweeps unreferenced
   blobs older than its cutoff. A build that reuses an old blob does not
   rewrite it, so its manifest, if written after the snapshot, would not keep
   the blob from the sweep. Refreshing each referenced blob first does. *)
fun write_action cache {key, text} =
  (List.app (fn line => Option.app (touch o blob_path cache) (blob_ref line))
            (String.tokens (fn c => c = #"\n") text);
   write_text (action_manifest cache key) text;
   add_growth cache manifest_growth_bytes)

fun remove_action cache key = remove_file (action_manifest cache key)

fun touch_action cache key = touch (action_manifest cache key)

fun get_action cache key =
  SOME (read_text (action_manifest cache key)) handle _ => NONE

fun existing_action_result cache policy key expected actual =
  case policy of
      HolbuildCacheBackend.PutIfAbsent => HolbuildCacheBackend.Conflict (action_manifest cache key)
    | HolbuildCacheBackend.PutIfAbsentOrSame =>
        if actual = expected then HolbuildCacheBackend.AlreadyPresent
        else
          let
            val resident = HolbuildTheoryCacheManifest.cache_manifest_contract key actual
            val incoming = HolbuildTheoryCacheManifest.cache_manifest_contract key expected
          in
            if #non_timeout_text resident <> #non_timeout_text incoming then
              HolbuildCacheBackend.Conflict (action_manifest cache key)
            else if HolbuildTheoryCacheManifest.timeout_at_least_as_strong
                      (#proof_timeout resident) (#proof_timeout incoming) then
              HolbuildCacheBackend.AlreadyPresent
            else
              (* Keep an original manifest: reconciliation never claims a check
                 that neither publisher recorded. *)
              (write_action cache {key = key, text = expected}; HolbuildCacheBackend.Published)
          end
          handle HolbuildTheoryCacheManifest.Error _ =>
            HolbuildCacheBackend.Conflict (action_manifest cache key)

fun has_blob cache hash = path_exists (blob_path cache hash)

fun verify_blob cache hash = file_hash_matches (blob_path cache hash) hash

(* dst is a local filesystem path where the caller wants the blob materialized. *)
fun fetch_blob cache {hash, dst} =
  let
    val blob = blob_path cache hash
    fun corrupt detail = HolbuildCacheBackend.Corrupt (detail ^ ": " ^ hash)
  in
    if not (path_exists blob) then HolbuildCacheBackend.Miss
    else
      (* Hashing the copy alone checks the cached blob as well. *)
      (link_or_copy {src = blob, dst = dst};
       if file_hash_matches dst hash then HolbuildCacheBackend.Hit
       else (remove_file dst; corrupt "cache blob SHA256 mismatch"))
  end
  handle Error msg => HolbuildCacheBackend.Corrupt msg
       | e => HolbuildCacheBackend.Corrupt (General.exnMessage e)

(* src is a local filesystem path containing bytes to store under hash. *)
fun publish_blob cache {hash, src} =
  let
    val blob = blob_path cache hash
    val _ =
      if file_hash_matches src hash then ()
      else raise Error ("blob SHA256 mismatch: expected " ^ hash)
  in
    if verify_blob cache hash then HolbuildCacheBackend.AlreadyPresent
    else
      (copy_binary src blob;
       if verify_blob cache hash then
         (add_growth cache (FS.fileSize blob); HolbuildCacheBackend.Published)
       else HolbuildCacheBackend.Conflict blob)
  end
  handle Error msg => HolbuildCacheBackend.Conflict msg
       | e => HolbuildCacheBackend.Conflict (General.exnMessage e)

(* Transfer owns src and its source backend verified it before returning Hit.
   Rename preserves those bytes; a cross-filesystem copy uses the validating
   publisher instead. Concurrent publishers install the same content hash. *)
fun consume_verified_blob cache (request as {hash, src}) =
  let val blob = blob_path cache hash
  in
    (ensure_parent blob;
     FS.rename {old = src, new = blob};
     add_growth cache (FS.fileSize blob);
     HolbuildCacheBackend.Published)
    handle e as OS.SysErr (_, SOME err) =>
      if err = Posix.Error.xdev then publish_blob cache request
      else HolbuildCacheBackend.Conflict (General.exnMessage e)
  end
  handle e => HolbuildCacheBackend.Conflict (General.exnMessage e)

fun action_lock cache key = Path.concat(locks_dir cache, "action-" ^ key ^ ".lock")

datatype action_lock_handle = ActionLockHandle of HolbuildFileLock.t

fun try_acquire_action_lock cache key =
  (case HolbuildFileLock.try_acquire_path {path = action_lock cache key, obsolete_kind = SOME "action cache"} of
       SOME lock => SOME (ActionLockHandle lock)
     | NONE => NONE)
  handle HolbuildFileLock.Error _ => NONE

fun release_action_lock (ActionLockHandle lock) = HolbuildFileLock.release lock

(* fcntl locks serialize processes, not threads in one process. *)
val action_mutexes = ref (Redblackmap.mkDict String.compare)
val action_mutexes_lock = Mutex.mutex ()

fun action_mutex cache key =
  let
    val path = action_lock cache key
    val _ = Mutex.lock action_mutexes_lock
    val mutex =
      case Redblackmap.peek (!action_mutexes, path) of
          SOME mutex => mutex
        | NONE =>
            let val mutex = Mutex.mutex ()
            in action_mutexes := Redblackmap.insert (!action_mutexes, path, mutex); mutex end
  in
    Mutex.unlock action_mutexes_lock;
    mutex
  end

fun with_action_mutex cache key f =
  let val mutex = action_mutex cache key
      val _ = Mutex.lock mutex
  in
    (f () before Mutex.unlock mutex)
    handle e => (Mutex.unlock mutex; raise e)
  end

fun with_action_publish_lock cache key publish skip =
  with_action_mutex cache key (fn () =>
    case try_acquire_action_lock cache key of
        SOME lock =>
          ((publish () before release_action_lock lock)
           handle e => (release_action_lock lock; raise e))
      | NONE => skip ())

fun with_action_publish_lock_wait cache key publish =
  with_action_mutex cache key (fn () =>
    let
      val path = action_lock cache key
      val _ = HolbuildFileLock.remove_obsolete_lock_dir "action cache" path
      val lock = HolbuildFileLock.acquire_exclusive_path_wait {path = path}
    in
      (publish () before HolbuildFileLock.release lock)
      handle e => (HolbuildFileLock.release lock; raise e)
    end)

fun put_action cache policy {key, text} =
  with_action_publish_lock_wait cache key (fn () =>
    case get_action cache key of
        SOME old => existing_action_result cache policy key text old
      | NONE => (write_action cache {key = key, text = text}; HolbuildCacheBackend.Published))

end
