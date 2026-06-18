structure HolbuildCacheArchive =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

val format = "holbuild-hbx-v1"
val payload_dir = "holbuild-cache"

fun quote s = HolbuildHash.quote s

fun path_exists path = FS.access(path, []) handle OS.SysErr _ => false

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if path_exists path then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun remove_file path = FS.remove path handle OS.SysErr _ => ()

fun remove_tree path =
  if path = "" orelse path = "." orelse path = "/" then
    raise Error ("refusing to remove unsafe archive path: " ^ path)
  else ignore (OS.Process.system ("rm -rf " ^ quote path))

fun read_text path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end

fun write_text path text =
  let
    val _ = ensure_dir (Path.dir path)
    val output = TextIO.openOut path
      handle e => raise Error ("could not write " ^ path ^ ": " ^ General.exnMessage e)
    fun close () = TextIO.closeOut output handle _ => ()
  in
    (TextIO.output(output, text); TextIO.closeOut output)
    handle e => (close (); raise e)
  end

fun temp_dir_near path =
  Path.concat(Path.dir path,
              "." ^ Path.file path ^ "." ^ Path.file (FS.tmpName ()) ^ ".d")

fun temp_file_near path =
  Path.concat(Path.dir path,
              "." ^ Path.file path ^ "." ^ Path.file (FS.tmpName ()) ^ ".tmp")

fun run command error =
  if OS.Process.isSuccess (OS.Process.system command) then ()
  else raise Error error

fun tar_create {stage_dir, archive_tmp} =
  run ("tar -C " ^ quote stage_dir ^ " -cf " ^ quote archive_tmp ^ " " ^ quote payload_dir)
      ("could not create cache archive: " ^ archive_tmp)

fun tar_extract {archive_path, stage_dir} =
  run ("tar -C " ^ quote stage_dir ^ " -xf " ^ quote archive_path)
      ("could not extract cache archive: " ^ archive_path)

fun rename_new {old, new} =
  FS.rename {old = old, new = new}
  handle OS.SysErr (msg, _) => raise Error ("could not install archive " ^ new ^ ": " ^ msg)

fun fs_source cache : HolbuildCacheTransfer.source =
  {get_action = HolbuildFSCacheBackend.get_action cache,
   fetch_blob = HolbuildFSCacheBackend.fetch_blob cache}

fun fs_destination cache : HolbuildCacheTransfer.destination =
  {put_action = HolbuildFSCacheBackend.put_action cache,
   publish_blob = HolbuildFSCacheBackend.publish_blob cache}

fun manifest_text keys =
  String.concatWith "\n"
    ([format,
      "created_by=holbuild " ^ HolbuildVersion.version,
      "action_count=" ^ Int.toString (length keys)] @
     map (fn key => "action " ^ key) keys) ^ "\n"

fun manifest_path payload = Path.concat(payload, "manifest")

fun require_manifest payload =
  let
    val path = manifest_path payload
    val text = read_text path
      handle e => raise Error ("could not read cache archive manifest: " ^ General.exnMessage e)
  in
    if String.isPrefix (format ^ "\n") text then ()
    else raise Error ("unsupported cache archive format in " ^ path)
  end

fun create {archive_path, source, keys} =
  if path_exists archive_path then
    raise Error ("cache archive already exists: " ^ archive_path)
  else
    let
      val stage_dir = temp_dir_near archive_path
      val archive_tmp = temp_file_near archive_path
      val payload = Path.concat(stage_dir, payload_dir)
      val cache = HolbuildFSCacheBackend.filesystem payload
      fun cleanup () = (remove_file archive_tmp; remove_tree stage_dir handle _ => ())
    in
      (ensure_dir payload;
       HolbuildFSCacheBackend.ensure_layout cache;
       ignore (HolbuildCacheTransfer.copy_entries
                 {source = source,
                  destination = fs_destination cache,
                  tmp_dir = HolbuildFSCacheBackend.tmp_dir cache}
                 keys);
       write_text (manifest_path payload) (manifest_text keys);
       tar_create {stage_dir = stage_dir, archive_tmp = archive_tmp};
       rename_new {old = archive_tmp, new = archive_path};
       remove_tree stage_dir)
      handle e => (cleanup (); raise e)
    end

fun with_reader {archive_path, f} =
  let
    val stage_dir = temp_dir_near archive_path
    val payload = Path.concat(stage_dir, payload_dir)
    val cache = HolbuildFSCacheBackend.filesystem payload
    fun cleanup () = remove_tree stage_dir handle _ => ()
  in
    (ensure_dir stage_dir;
     tar_extract {archive_path = archive_path, stage_dir = stage_dir};
     require_manifest payload;
     f (fs_source cache) before cleanup ())
    handle e => (cleanup (); raise e)
  end

end
