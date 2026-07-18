structure HolbuildCacheArchive =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

val format = "holbuild-hbx-v1"
val payload_dir = "holbuild-cache"

type metadata =
  {created_at : string option,
   source_repo : string option,
   source_rev : string option,
   hol_repo : string option,
   hol_rev : string option}

val empty_metadata : metadata =
  {created_at = NONE,
   source_repo = NONE,
   source_rev = NONE,
   hol_repo = NONE,
   hol_rev = NONE}

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

fun tar_operation operation =
  operation () handle HolbuildTar.Error msg => raise Error msg

fun require_cache_member {path, kind, ...} =
  let
    val in_payload =
      path = payload_dir orelse String.isPrefix (payload_dir ^ "/") path
    val supported_kind =
      case kind of
          HolbuildTar.Regular => true
        | HolbuildTar.Directory => true
        | _ => false
  in
    if not in_payload then
      raise Error ("cache archive member is outside " ^ payload_dir ^ ": " ^ path)
    else if not supported_kind then
      raise Error ("cache archive contains a link: " ^ path)
    else ()
  end

fun inspect_archive {archive_path, stage_dir} =
  let
    val {members, ...} =
      tar_operation
        (fn () => HolbuildTar.inspect
          {archive_path = archive_path, destination = stage_dir, capture = NONE})
  in
    List.app require_cache_member members
  end

fun tar_create {stage_dir, archive_tmp} =
  (tar_operation
     (fn () => HolbuildTar.create
       {archive_path = archive_tmp,
        sources = [(stage_dir, [payload_dir])],
        excludes = [],
        hard_dereference = false});
   inspect_archive {archive_path = archive_tmp, stage_dir = stage_dir})

fun tar_extract {archive_path, stage_dir} =
  (inspect_archive {archive_path = archive_path, stage_dir = stage_dir};
   tar_operation
     (fn () => HolbuildTar.extract
       {archive_path = archive_path, destination = stage_dir});
   inspect_archive {archive_path = archive_path, stage_dir = stage_dir})

fun rename_new {old, new} =
  FS.rename {old = old, new = new}
  handle OS.SysErr (msg, _) => raise Error ("could not install archive " ^ new ^ ": " ^ msg)

fun fs_source cache : HolbuildCacheTransfer.source =
  {get_action = HolbuildFSCacheBackend.get_action cache,
   fetch_blob = HolbuildFSCacheBackend.fetch_blob cache}

fun fs_destination cache : HolbuildCacheTransfer.destination =
  {put_action = HolbuildFSCacheBackend.put_action cache,
   publish_blob = HolbuildFSCacheBackend.publish_blob cache}

fun manifest_value text =
  String.translate (fn #"\n" => " " | #"\r" => " " | c => str c) text

fun optional_manifest_line name value =
  case value of
      SOME text => [name ^ "=" ^ manifest_value text]
    | NONE => []

fun metadata_manifest_lines ({created_at, source_repo, source_rev, hol_repo, hol_rev} : metadata) =
  ["holbuild_version=" ^ HolbuildVersion.version] @
  optional_manifest_line "created_at" created_at @
  optional_manifest_line "source_repo" source_repo @
  optional_manifest_line "source_rev" source_rev @
  optional_manifest_line "hol_repo" hol_repo @
  optional_manifest_line "hol_rev" hol_rev

fun manifest_text {keys, targets, metadata} =
  String.concatWith "\n"
    ([format,
      "created_by=holbuild " ^ HolbuildVersion.version] @
     metadata_manifest_lines metadata @
     ["target_count=" ^ Int.toString (length targets),
      "action_count=" ^ Int.toString (length keys)] @
     map (fn target => "target " ^ target) targets @
     map (fn key => "action " ^ key) keys) ^ "\n"

fun action_key_line line =
  case String.tokens Char.isSpace line of
      ["action", key] => SOME key
    | _ => NONE

fun action_keys_from_manifest text =
  List.mapPartial action_key_line (String.tokens (fn c => c = #"\n") text)

type export_entry =
  {key : string,
   package : string,
   logical : string,
   source_path : string,
   root : bool}

fun safe_package_dir package =
  let
    fun safe_char c = if Char.isAlphaNum c orelse c = #"_" orelse c = #"-" then str c else "_"
    val readable = String.translate safe_char package
    val base = if readable = "" then "package" else readable
    val hash = HolbuildHash.string_sha1 package
  in
    base ^ "-" ^ String.substring(hash, 0, 12)
  end

fun package_dir payload {root, package} =
  if root then Path.concat(payload, "project")
  else Path.concat(Path.concat(payload, "deps"), safe_package_dir package)

fun unique_strings values =
  let
    fun member value = List.exists (fn existing => existing = value)
    fun add (value, kept) = if member value kept then kept else value :: kept
  in
    rev (List.foldl add [] values)
  end

fun entry_key ({key, ...} : export_entry) = key
fun entry_package ({package, ...} : export_entry) = package
fun entry_root ({root, ...} : export_entry) = root

fun same_package left right =
  entry_package left = entry_package right andalso entry_root left = entry_root right

fun group_entries entries =
  let
    fun add (entry, groups) =
      let
        fun loop acc rest =
          case rest of
              [] => rev ((entry, [entry]) :: acc)
            | (representative, members) :: more =>
                if same_package representative entry then
                  rev acc @ ((representative, entry :: members) :: more)
                else loop ((representative, members) :: acc) more
      in
        loop [] groups
      end
  in
    map (fn (representative, members) => (representative, rev members))
        (List.foldl add [] entries)
  end

fun package_manifest_text representative entries =
  String.concatWith "\n"
    (["holbuild-hbx-package-v1",
      "role=" ^ (if entry_root representative then "project" else "dependency"),
      "package=" ^ entry_package representative,
      "action_count=" ^ Int.toString (length entries)] @
     List.concat
       (map (fn {key, logical, source_path, ...} =>
               ["action " ^ key,
                "logical " ^ key ^ " " ^ logical,
                "source " ^ key ^ " " ^ source_path])
            entries)) ^ "\n"

fun write_package_action_ref payload package_path key =
  let
    val source_manifest = Path.concat(Path.concat(Path.concat(payload, "actions"), key), "manifest")
    val destination_manifest = Path.concat(Path.concat(Path.concat(package_path, "actions"), key), "manifest")
  in
    write_text destination_manifest (read_text source_manifest)
  end

fun write_package_group payload (representative, entries) =
  let
    val dir = package_dir payload {root = entry_root representative, package = entry_package representative}
    val _ = write_text (Path.concat(dir, "manifest")) (package_manifest_text representative entries)
  in
    List.app (write_package_action_ref payload dir o entry_key) entries
  end

fun write_package_index payload entries =
  List.app (write_package_group payload) (group_entries entries)

fun manifest_path payload = Path.concat(payload, "manifest")

fun require_manifest payload =
  let
    val path = manifest_path payload
    val text = read_text path
      handle e => raise Error ("could not read cache archive manifest: " ^ General.exnMessage e)
  in
    if String.isPrefix (format ^ "\n") text then text
    else raise Error ("unsupported cache archive format in " ^ path)
  end

fun create_export {archive_path, source, entries, targets, metadata} =
  if path_exists archive_path then
    raise Error ("cache archive already exists: " ^ archive_path)
  else
    let
      val keys = unique_strings (map entry_key entries)
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
       write_package_index payload entries;
       write_text (manifest_path payload) (manifest_text {keys = keys, targets = targets, metadata = metadata});
       tar_create {stage_dir = stage_dir, archive_tmp = archive_tmp};
       rename_new {old = archive_tmp, new = archive_path};
       remove_tree stage_dir)
      handle e => (cleanup (); raise e)
    end

fun create_with_targets {archive_path, source, keys, targets} =
  create_export {archive_path = archive_path,
                 source = source,
                 entries = map (fn key => {key = key, package = "", logical = "", source_path = "", root = true}) keys,
                 targets = targets,
                 metadata = empty_metadata}

fun create {archive_path, source, keys} =
  create_with_targets {archive_path = archive_path, source = source, keys = keys, targets = []}

fun with_entries {archive_path, f} =
  let
    val stage_dir = temp_dir_near archive_path
    val payload = Path.concat(stage_dir, payload_dir)
    val cache = HolbuildFSCacheBackend.filesystem payload
    fun cleanup () = remove_tree stage_dir handle _ => ()
  in
    (ensure_dir stage_dir;
     tar_extract {archive_path = archive_path, stage_dir = stage_dir};
     let
       val manifest = require_manifest payload
       val keys = action_keys_from_manifest manifest
     in
       f {source = fs_source cache, keys = keys} before cleanup ()
     end)
    handle e => (cleanup (); raise e)
  end

fun with_reader {archive_path, f} =
  with_entries {archive_path = archive_path, f = fn {source, ...} => f source}

end
