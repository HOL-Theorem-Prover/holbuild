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
  Path.concat(Path.dir path,
              "." ^ Path.file path ^ "." ^ Path.file (FS.tmpName ()) ^ ".tmp")

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

fun file_hash_matches path hash =
  path_exists path andalso HolbuildHash.file_sha1 path = hash
  handle _ => false

fun actions_dir cache = Path.concat(root cache, "actions")
fun blobs_dir cache = Path.concat(root cache, "blobs")
fun tmp_dir cache = Path.concat(root cache, "tmp")
fun locks_dir cache = Path.concat(root cache, "locks")

fun action_dir cache key = Path.concat(actions_dir cache, key)
fun action_manifest cache key = Path.concat(action_dir cache key, "manifest")
fun blob_path cache hash = Path.concat(blobs_dir cache, hash)

fun ensure_layout cache =
  (ensure_dir (actions_dir cache); ensure_dir (blobs_dir cache); ensure_dir (tmp_dir cache))

fun write_action cache {key, text} = write_text (action_manifest cache key) text

fun remove_action cache key = remove_file (action_manifest cache key)

fun touch_action cache key = FS.setTime(action_manifest cache key, NONE) handle OS.SysErr _ => ()

fun get_action cache key =
  SOME (read_text (action_manifest cache key)) handle _ => NONE

fun put_action cache {key, text} =
  let val path = action_manifest cache key
  in
    case get_action cache key of
        SOME old =>
          if old = text then HolbuildCacheBackend.AlreadyPresent
          else HolbuildCacheBackend.Conflict path
      | NONE => (write_action cache {key = key, text = text}; HolbuildCacheBackend.Published)
  end

fun has_blob cache hash = file_hash_matches (blob_path cache hash) hash

fun fetch_blob cache {hash, dst} =
  let val blob = blob_path cache hash
  in
    if not (path_exists blob) then HolbuildCacheBackend.Miss
    else if not (file_hash_matches blob hash) then HolbuildCacheBackend.Corrupt blob
    else
      (copy_binary blob dst;
       if file_hash_matches dst hash then HolbuildCacheBackend.Hit
       else HolbuildCacheBackend.Corrupt dst)
  end
  handle Error msg => HolbuildCacheBackend.Corrupt msg
       | e => HolbuildCacheBackend.Corrupt (General.exnMessage e)

fun publish_blob cache {hash, src} =
  let val blob = blob_path cache hash
  in
    if has_blob cache hash then HolbuildCacheBackend.AlreadyPresent
    else
      (copy_binary src blob;
       if has_blob cache hash then HolbuildCacheBackend.Published
       else HolbuildCacheBackend.Conflict blob)
  end
  handle Error msg => HolbuildCacheBackend.Conflict msg
       | e => HolbuildCacheBackend.Conflict (General.exnMessage e)

fun action_lock cache key = Path.concat(locks_dir cache, "action-" ^ key ^ ".lock")

datatype action_lock_handle = ActionLockHandle of HolbuildFileLock.t

fun try_acquire_action_lock cache key =
  (case HolbuildFileLock.try_acquire_path {path = action_lock cache key, obsolete_kind = SOME "action cache"} of
       SOME lock => SOME (ActionLockHandle lock)
     | NONE => NONE)
  handle HolbuildFileLock.Error _ => NONE

fun release_action_lock (ActionLockHandle lock) = HolbuildFileLock.release lock

fun with_action_publish_lock cache key publish skip =
  case try_acquire_action_lock cache key of
      SOME lock =>
        ((publish () before release_action_lock lock)
         handle e => (release_action_lock lock; raise e))
    | NONE => skip ()

end
