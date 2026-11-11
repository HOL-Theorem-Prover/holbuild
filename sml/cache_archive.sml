structure HolbuildCacheArchive =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

val format = "holbuild-hbx-v2"
val payload_dir = "holbuild-cache"
val capsule_format = "holbuild-hbx-capsule-v1"
val package_part = "holbuild-package"
val source_dir = "source"

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

fun path_exists path = FS.access(path, []) handle OS.SysErr _ => false

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if path_exists path then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun remove_file path = FS.remove path handle OS.SysErr _ => ()

(* Archives can hold a directory without owner access, so staging trees are
   removed as untrusted ones. *)
fun remove_tree path =
  HolbuildRemoveTree.remove_untrusted path handle HolbuildRemoveTree.Error msg => raise Error msg

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
  HolbuildTempPath.near path ".d"

fun temp_file_near path =
  HolbuildTempPath.near path ".tmp"

fun tar_operation operation =
  operation () handle HolbuildTar.Error msg => raise Error msg

fun tar_create {stage_dir, archive_tmp, members} =
  tar_operation
    (fn () => HolbuildTar.create
      {archive_path = archive_tmp,
       sources = [(stage_dir, members)],
       excludes = [],
       hard_dereference = false})

fun tar_extract {archive_path, stage_dir} =
  tar_operation
    (fn () => HolbuildTar.extract
      {archive_path = archive_path, destination = stage_dir})

fun rename_new {old, new} =
  FS.rename {old = old, new = new}
  handle OS.SysErr (msg, _) => raise Error ("could not install archive " ^ new ^ ": " ^ msg)

fun fs_source cache : HolbuildCacheTransfer.source =
  {get_action = HolbuildFSCacheBackend.get_action cache,
   fetch_blob = HolbuildFSCacheBackend.fetch_blob cache}

fun fs_destination cache : HolbuildCacheTransfer.destination =
  {has_blob = HolbuildFSCacheBackend.verify_blob cache,
   put_action = HolbuildFSCacheBackend.put_action cache,
   publish_blob = HolbuildFSCacheBackend.consume_verified_blob cache}

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
    val hash = HolbuildHash.string_sha256 package
  in
    base ^ "-" ^ String.substring(hash, 0, 12)
  end

fun package_view_dir payload {root, package} =
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
    val dir = package_view_dir payload {root = entry_root representative, package = entry_package representative}
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

(* The cache part of an archive: the entries' blobs and manifests, the
   package views and the manifest naming the actions. *)
fun stage_cache stage_dir {source, entries, targets, metadata} =
  let
    val keys = unique_strings (map entry_key entries)
    val payload = Path.concat(stage_dir, payload_dir)
    val cache = HolbuildFSCacheBackend.filesystem payload
  in
    ensure_dir payload;
    HolbuildFSCacheBackend.ensure_layout cache;
    ignore (HolbuildCacheTransfer.copy_entries
              {source = source,
               destination = fs_destination cache,
               tmp_dir = HolbuildFSCacheBackend.tmp_dir cache}
              keys);
    write_package_index payload entries;
    write_text (manifest_path payload) (manifest_text {keys = keys, targets = targets, metadata = metadata})
  end

type capsule_package =
  {name : string,
   version : string option,
   toolchain_key : string,
   root : string,
   files : string list}

fun capsule_manifest_text ({name, version, toolchain_key, ...} : capsule_package) =
  String.concatWith "\n"
    ([capsule_format,
      "name=" ^ manifest_value name] @
     optional_manifest_line "version" version @
     ["toolchain_key=" ^ manifest_value toolchain_key,
      "holbuild_version=" ^ HolbuildVersion.version]) ^ "\n"

(* The staged tree, not the publisher's umask or file modes, decides the
   archive's bytes: directories are 755, files 755 when executable and 644
   otherwise. *)
fun mode_flags flags = Posix.FileSys.S.flags flags
val dir_mode =
  mode_flags [Posix.FileSys.S.irwxu, Posix.FileSys.S.irgrp, Posix.FileSys.S.ixgrp,
              Posix.FileSys.S.iroth, Posix.FileSys.S.ixoth]
val executable_mode = dir_mode
val plain_mode =
  mode_flags [Posix.FileSys.S.irusr, Posix.FileSys.S.iwusr, Posix.FileSys.S.irgrp, Posix.FileSys.S.iroth]

fun ensure_stage_dir path =
  if path_exists path then ()
  else
    (ensure_stage_dir (Path.dir path);
     FS.mkDir path;
     Posix.FileSys.chmod (path, dir_mode))

fun is_executable path =
  Posix.FileSys.S.anySet
    (mode_flags [Posix.FileSys.S.ixusr, Posix.FileSys.S.ixgrp, Posix.FileSys.S.ixoth],
     Posix.FileSys.ST.mode (Posix.FileSys.stat path))

fun stage_source_file root source_root rel =
  let
    val src = Path.concat(root, rel)
    val dst = Path.concat(source_root, rel)
    val _ = ensure_stage_dir (Path.dir dst)
    val executable = is_executable src
  in
    HolbuildFSCacheBackend.copy_binary src dst;
    Posix.FileSys.chmod (dst, if executable then executable_mode else plain_mode)
  end
  handle HolbuildFSCacheBackend.Error msg => raise Error msg
       | OS.SysErr (msg, _) => raise Error ("could not stage snapshot file: " ^ msg)

(* The package part: the manifest and the snapshot's files under source/. *)
fun stage_package stage_dir (package : capsule_package) =
  let
    val dir = Path.concat(stage_dir, package_part)
    val source_root = Path.concat(dir, source_dir)
  in
    ensure_stage_dir source_root;
    List.app (stage_source_file (#root package) source_root) (#files package);
    write_text (Path.concat(dir, "manifest")) (capsule_manifest_text package);
    Posix.FileSys.chmod (Path.concat(dir, "manifest"), plain_mode)
  end

(* An archive of a cache part (the entries of a build), a package part (a
   source snapshot), or both. *)
fun create_capsule {archive_path, cache, package} =
  if path_exists archive_path then
    raise Error ("cache archive already exists: " ^ archive_path)
  else if not (Option.isSome cache) andalso not (Option.isSome package) then
    raise Error "archive has neither a cache part nor a package part"
  else
    let
      val stage_dir = temp_dir_near archive_path
      val archive_tmp = temp_file_near archive_path
      fun cleanup () = (remove_file archive_tmp; remove_tree stage_dir handle _ => ())
      val members =
        (if Option.isSome cache then [payload_dir] else []) @
        (if Option.isSome package then [package_part] else [])
    in
      (ensure_dir stage_dir;
       Option.app (stage_cache stage_dir) cache;
       Option.app (stage_package stage_dir) package;
       tar_create {stage_dir = stage_dir, archive_tmp = archive_tmp, members = members};
       rename_new {old = archive_tmp, new = archive_path};
       remove_tree stage_dir)
      handle e => (cleanup (); raise e)
    end

fun create_export {archive_path, source, entries, targets, metadata} =
  create_capsule {archive_path = archive_path,
                  cache = SOME {source = source, entries = entries, targets = targets, metadata = metadata},
                  package = NONE}

fun create_with_targets {archive_path, source, keys, targets} =
  create_export {archive_path = archive_path,
                 source = source,
                 entries = map (fn key => {key = key, package = "", logical = "", source_path = "", root = true}) keys,
                 targets = targets,
                 metadata = empty_metadata}

fun create {archive_path, source, keys} =
  create_with_targets {archive_path = archive_path, source = source, keys = keys, targets = []}

fun capsule_manifest_path stage_dir = Path.concat(Path.concat(stage_dir, package_part), "manifest")

fun is_capsule stage_dir =
  String.isPrefix (capsule_format ^ "\n") (read_text (capsule_manifest_path stage_dir))
  handle _ => false

(* The spelling an archive uses for `part` (a bare name, or one with a leading
   `./`) when it holds that part itself or anything under it. *)
fun part_member names part =
  let
    fun holds spelling =
      List.exists (fn name => name = spelling orelse String.isPrefix (spelling ^ "/") name) names
  in
    if holds part then SOME part
    else if holds ("./" ^ part) then SOME ("./" ^ part)
    else NONE
  end

fun checked_names archive_path =
  tar_operation (fn () => HolbuildTar.checked_names archive_path)

(* Only the cache part and the capsule manifest are unpacked, so a capsule's
   source files are never written. *)
fun with_entries {archive_path, f} =
  let
    val names = checked_names archive_path
    val manifest_member = Path.concat(package_part, "manifest")
    val cache_member = part_member names payload_dir
    val wanted = List.mapPartial (part_member names) [payload_dir, manifest_member]
    val stage_dir = temp_dir_near archive_path
    val payload = Path.concat(stage_dir, payload_dir)
    val cache = HolbuildFSCacheBackend.filesystem payload
    fun cleanup () = remove_tree stage_dir handle _ => ()
  in
    (ensure_dir stage_dir;
     if null wanted then ()
     else tar_operation (fn () => HolbuildTar.extract_members
            {archive_path = archive_path, destination = stage_dir, members = wanted});
     let
       (* A capsule without a cache part holds no actions. *)
       val keys =
         if not (Option.isSome cache_member) andalso is_capsule stage_dir then []
         else action_keys_from_manifest (require_manifest payload)
     in
       f {source = fs_source cache, keys = keys} before cleanup ()
     end)
    handle e => (cleanup (); raise e)
  end

fun with_reader {archive_path, f} =
  with_entries {archive_path = archive_path, f = fn {source, ...} => f source}

type capsule_identity =
  {name : string,
   version : string option,
   toolchain_key : string}

fun manifest_field lines key =
  let
    val prefix = key ^ "="
    fun value line =
      if String.isPrefix prefix line then SOME (String.extract (line, size prefix, NONE)) else NONE
  in
    List.mapPartial value lines
  end

fun nonempty_manifest_field lines key =
  case manifest_field lines key of
      value :: _ => if value = "" then NONE else SOME value
    | [] => NONE

(* The identity a capsule's manifest names; anything else is not a capsule. *)
fun capsule_identity archive_path text =
  let
    val lines = String.tokens (fn c => c = #"\n") text
    fun required key =
      case nonempty_manifest_field lines key of
          SOME value => value
        | NONE => raise Error ("capsule manifest in " ^ archive_path ^ " has no " ^ key)
    fun package_name () =
      let val name = required "name"
      in
        if HolbuildManifestUtil.safe_materialized_dependency_name name then name
        else raise Error ("capsule manifest in " ^ archive_path ^ " has an unsafe package name: " ^ name)
      end
  in
    case lines of
        first :: _ =>
          if first = capsule_format then
            {name = package_name (),
             version = nonempty_manifest_field lines "version",
             toolchain_key = required "toolchain_key"}
          else raise Error ("unsupported capsule format in " ^ archive_path ^ ": " ^ first)
      | [] => raise Error ("empty capsule manifest in " ^ archive_path)
  end

fun require_free_destination destination =
  if not (path_exists destination) then ()
  else if FS.isDir destination andalso
          (let val dir = FS.openDir destination
               val empty = not (Option.isSome (FS.readDir dir))
           in FS.closeDir dir; empty end)
  then ()
  else raise Error ("capsule source destination is not empty: " ^ destination)

(* Unpacks the source snapshot of a capsule into `destination`, which must be
   absent or an empty directory, and returns the identity its manifest names.
   Every member is checked before anything is written, and only the manifest
   and `source/` are unpacked, into a sibling directory that is renamed into
   place, so a failure leaves nothing at `destination`. *)
fun extract_sources {archive_path, destination} =
  let
    val names = checked_names archive_path
    val manifest_member = Path.concat(package_part, "manifest")
    val source_member = Path.concat(package_part, source_dir)
    val members =
      case (part_member names manifest_member, part_member names source_member) of
          (SOME manifest, SOME source) => [manifest, source]
        | _ => raise Error ("archive has no source snapshot: " ^ archive_path)
    val _ = require_free_destination destination
    val stage_dir = temp_dir_near destination
    fun cleanup () = remove_tree stage_dir handle _ => ()
  in
    (ensure_dir (Path.dir destination);
     ensure_dir stage_dir;
     tar_operation (fn () => HolbuildTar.extract_members
       {archive_path = archive_path, destination = stage_dir,
        members = members});
     let
       val manifest = read_text (Path.concat(stage_dir, manifest_member))
         handle IO.Io _ => raise Error ("could not read capsule manifest in " ^ archive_path)
       val identity = capsule_identity archive_path manifest
       val unpacked = Path.concat(stage_dir, source_member)
     in
       if FS.isDir unpacked then ()
       else raise Error ("capsule source is not a directory: " ^ archive_path);
       FS.rename {old = unpacked, new = destination}
         handle OS.SysErr (msg, _) =>
           raise Error ("could not install capsule source at " ^ destination ^ ": " ^ msg);
       cleanup ();
       identity
     end)
    handle e => (cleanup (); raise e)
  end

end
