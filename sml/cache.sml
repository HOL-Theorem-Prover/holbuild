structure HolbuildCache =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

val default_retention_days = 7

fun has_prefix prefix s =
  size s >= size prefix andalso String.substring(s, 0, size prefix) = prefix

fun quote s =
  "'" ^ String.translate (fn #"'" => "'\\''" | c => str c) s ^ "'"

fun path_exists path = FS.access(path, []) handle OS.SysErr _ => false

fun filesystem_cache root = HolbuildFSCacheBackend.filesystem root

fun default_backend () =
  HolbuildFSCacheBackend.default ()
  handle HolbuildFSCacheBackend.Error msg => raise Error msg

fun cache_root () = HolbuildFSCacheBackend.root (default_backend ())

fun actions_dir root = HolbuildFSCacheBackend.actions_dir (filesystem_cache root)
fun blobs_dir root = HolbuildFSCacheBackend.blobs_dir (filesystem_cache root)
fun tmp_dir root = HolbuildFSCacheBackend.tmp_dir (filesystem_cache root)
fun locks_dir root = HolbuildFSCacheBackend.locks_dir (filesystem_cache root)
fun action_dir root key = HolbuildFSCacheBackend.action_dir (filesystem_cache root) key
fun action_manifest root key = HolbuildFSCacheBackend.action_manifest (filesystem_cache root) key
fun blob_path root hash = HolbuildFSCacheBackend.blob_path (filesystem_cache root) hash

fun touch path = FS.setTime(path, NONE) handle OS.SysErr _ => ()

fun ensure_layout root = HolbuildFSCacheBackend.ensure_layout (filesystem_cache root)

fun get_action root key = HolbuildFSCacheBackend.get_action (filesystem_cache root) key
fun put_action root request = HolbuildFSCacheBackend.put_action (filesystem_cache root) request
fun write_action root request = HolbuildFSCacheBackend.write_action (filesystem_cache root) request
fun remove_action root key = HolbuildFSCacheBackend.remove_action (filesystem_cache root) key
fun touch_action root key = HolbuildFSCacheBackend.touch_action (filesystem_cache root) key
fun has_blob root hash = HolbuildFSCacheBackend.has_blob (filesystem_cache root) hash
fun fetch_blob root request = HolbuildFSCacheBackend.fetch_blob (filesystem_cache root) request
fun publish_blob root request = HolbuildFSCacheBackend.publish_blob (filesystem_cache root) request

fun children dir =
  if not (path_exists dir) then []
  else
    let
      val stream = FS.openDir dir
      fun loop acc =
        case FS.readDir stream of
            NONE => rev acc
          | SOME name =>
            if name = "." orelse name = ".." then loop acc
            else loop (Path.concat(dir, name) :: acc)
      val result = loop [] handle e => (FS.closeDir stream; raise e)
    in
      FS.closeDir stream;
      result
    end

fun remove_tree path =
  if path = "" orelse path = "." orelse path = "/" then
    raise Error ("refusing to remove unsafe cache path: " ^ path)
  else
    let val status = OS.Process.system ("rm -rf " ^ quote path)
    in
      if OS.Process.isSuccess status then ()
      else raise Error ("failed to remove cache path: " ^ path)
    end

fun stale cutoff path =
  Time.<(FS.modTime path, cutoff) handle OS.SysErr _ => false

fun retention_cutoff days =
  if days < 0 then raise Error "retention days must be non-negative"
  else Time.-(Time.now(), Time.fromSeconds (IntInf.fromInt (days * 86400)))

fun read_lines path =
  let
    val input = TextIO.openIn path
    fun loop acc =
      case TextIO.inputLine input of
          NONE => rev acc
        | SOME line => loop (line :: acc)
      val lines = loop [] handle e => (TextIO.closeIn input; raise e)
  in
    TextIO.closeIn input;
    lines
  end

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

fun empty_blob_set () = Redblackset.empty String.compare

fun add_blob (blob, blobs) = Redblackset.add(blobs, blob)

fun manifest_path action_dir = Path.concat(action_dir, "manifest")

fun action_live_blobs action_dir =
  let val manifest = manifest_path action_dir
  in
    if path_exists manifest then
      List.foldl
        (fn (line, blobs) =>
            case blob_ref line of
                NONE => blobs
              | SOME blob => add_blob (blob, blobs))
        (empty_blob_set ())
        (read_lines manifest)
    else empty_blob_set ()
  end

fun collect_live_actions cutoff actions_dir =
  let
    fun one (action_dir, (live_blobs, removed)) =
      let val manifest = manifest_path action_dir
      in
        if path_exists manifest then
          if stale cutoff manifest then
            (remove_tree action_dir; (live_blobs, removed + 1))
          else
            (Redblackset.union(live_blobs, action_live_blobs action_dir),
             removed)
        else if stale cutoff action_dir then
          (remove_tree action_dir; (live_blobs, removed + 1))
        else
          (live_blobs, removed)
      end
  in
    List.foldl one (empty_blob_set (), 0) (children actions_dir)
  end

fun remove_stale_children cutoff dir =
  List.foldl
    (fn (path, removed) =>
        if stale cutoff path then (remove_tree path; removed + 1) else removed)
    0
    (children dir)

fun remove_obsolete_action_lock_dirs cutoff dir =
  List.foldl
    (fn (path, removed) =>
        if has_prefix "action-" (Path.file path) andalso (FS.isDir path handle OS.SysErr _ => false) andalso stale cutoff path then
          (remove_tree path; removed + 1)
        else removed)
    0
    (children dir)

fun blob_name path = Path.file path

fun sweep_blobs cutoff live_blobs blobs_dir =
  List.foldl
    (fn (path, removed) =>
        if stale cutoff path andalso not (Redblackset.member(live_blobs, blob_name path)) then
          (remove_tree path; removed + 1)
        else removed)
    0
    (children blobs_dir)

fun gc_lock_path root = Path.concat(locks_dir root, "gc.lock")
fun gc_lock_owner_path lock = lock ^ ".owner"

datatype gc_lock = GcLock of HolbuildFileLock.t

fun gc_lock_owner () =
  String.concatWith "\n"
    ["holbuild-cache-gc-lock-v1",
     "command=cache gc",
     "pid=" ^ HolbuildFileLock.current_pid_text (),
     "pid_ns=" ^ HolbuildFileLock.current_pid_namespace (),
     "starttime=" ^ HolbuildFileLock.proc_starttime "self",
     "boot_id=" ^ HolbuildFileLock.current_boot_id (),
     "cwd=" ^ FS.getDir (),
     "host=" ^ HolbuildFileLock.current_host (),
     "started=" ^ Time.toString (Time.now ())] ^ "\n"

fun current_gc_lock_owner lock =
  SOME (HolbuildFileLock.read_text (gc_lock_owner_path lock)) handle _ => NONE

fun unavailable_gc_lock_owner () =
  String.concatWith "\n"
    ["holbuild-cache-gc-lock-v1",
     "command=cache gc",
     "pid=unknown",
     "cwd=unknown"] ^ "\n"

fun cache_gc_lock_error lock owner =
  Error ("cache gc already running\n" ^
         "lock: " ^ lock ^ "\n" ^
         "owner: " ^ HolbuildFileLock.owner_summary owner)

fun acquire_lock root =
  let val lock_path = gc_lock_path root
  in
    case HolbuildFileLock.try_acquire_path {path = lock_path, obsolete_kind = SOME "cache gc"} of
        SOME lock =>
          ((HolbuildFileLock.write_text (gc_lock_owner_path lock_path) (gc_lock_owner ());
            GcLock lock)
           handle e => (HolbuildFileLock.release lock; raise e))
      | NONE =>
          let val owner = Option.getOpt(current_gc_lock_owner lock_path, unavailable_gc_lock_owner ())
          in raise cache_gc_lock_error lock_path owner end
  end
  handle HolbuildFileLock.Error msg => raise Error ("could not acquire cache gc lock: " ^ msg)

fun release_gc_lock (GcLock lock) =
  (HolbuildFileLock.remove_file (gc_lock_owner_path (HolbuildFileLock.path lock));
   HolbuildFileLock.release lock)

fun with_lock root f =
  let val lock = acquire_lock root
  in
    (f () before release_gc_lock lock)
    handle e => (release_gc_lock lock; raise e)
  end

fun with_action_publish_lock root key publish skip =
  HolbuildFSCacheBackend.with_action_publish_lock (filesystem_cache root) key publish skip

fun gc_root root days =
  if not (path_exists root) then
    print ("cache not found: " ^ root ^ "\n")
  else
    let
      val cutoff = retention_cutoff days
      val actions_dir = Path.concat(root, "actions")
      val blobs_dir = Path.concat(root, "blobs")
      val tmp_dir = Path.concat(root, "tmp")
      fun run () =
        let
          val tmp_removed = remove_stale_children cutoff tmp_dir
          val lock_removed = remove_obsolete_action_lock_dirs cutoff (locks_dir root)
          val (live_blobs, actions_removed) = collect_live_actions cutoff actions_dir
          val blobs_removed = sweep_blobs cutoff live_blobs blobs_dir
        in
          print ("cache gc: removed tmp=" ^ Int.toString tmp_removed ^
                 " locks=" ^ Int.toString lock_removed ^
                 " actions=" ^ Int.toString actions_removed ^
                 " blobs=" ^ Int.toString blobs_removed ^ "\n")
        end
    in
      with_lock root run
    end

fun parse_days text =
  case Int.fromString text of
      SOME n => n
    | NONE => raise Error ("invalid retention days: " ^ text)

fun parse_gc_args args =
  let
    fun loop days rest =
      case rest of
          [] => days
        | "--retention-days" :: n :: xs => loop (parse_days n) xs
        | "--days" :: n :: xs => loop (parse_days n) xs
        | arg :: _ => raise Error ("unknown cache gc option: " ^ arg)
  in
    loop default_retention_days args
  end

fun gc args =
  let val days = parse_gc_args args
  in gc_root (cache_root ()) days end

fun dispatch args =
  case args of
      "gc" :: rest => gc rest
    | [] => raise Error "cache command requires subcommand: gc"
    | cmd :: _ => raise Error ("unknown cache command: " ^ cmd)

end
