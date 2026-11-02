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
  { put_action : HolbuildCacheBackend.action_publish_policy ->
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

fun has_prefix prefix s =
  size s >= size prefix andalso String.substring(s, 0, size prefix) = prefix

fun trim_newline s =
  if size s > 0 andalso String.sub(s, size s - 1) = #"\n" then
    String.substring(s, 0, size s - 1)
  else s

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
    val n = loop 0
  in
    String.substring(s, 0, n)
  end

fun blob_ref line =
  let val clean = trim_newline line
  in
    case String.tokens Char.isSpace clean of
        ["blob", _, hash] => SOME hash
      | _ =>
          if has_prefix "blob=" clean then SOME (take_token (String.extract(clean, 5, NONE)))
          else if has_prefix "blob-sha1=" clean then SOME (take_token (String.extract(clean, 10, NONE)))
          else NONE
  end

fun unique_blobs manifest_text =
  let
    fun add (hash, hashes) =
      if List.exists (fn existing => existing = hash) hashes then hashes else hash :: hashes
    fun line (text, hashes) =
      case blob_ref text of
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
    | HolbuildCacheBackend.Failed detail => raise Error ("destination cache blob publish failed: " ^ hash ^ " (" ^ detail ^ ")")

fun copy_blob source destination tmp_dir hash (uploaded, reused) =
  let
    val path = temp_blob_path tmp_dir hash
    val (uploaded', reused') =
      (fetch_blob_or_raise source hash path;
       publish_blob_or_raise destination hash path)
      handle e => (remove_file path; raise e)
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
    | HolbuildCacheBackend.Failed detail => raise Error ("destination cache action publish failed: " ^ key ^ " (" ^ detail ^ ")")

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
