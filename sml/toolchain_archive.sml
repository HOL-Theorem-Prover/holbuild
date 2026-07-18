structure HolbuildToolchainArchive =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

val archive_format = "holbuild-toolchain-archive-v1"
val action_format = "holbuild-remote-toolchain-action-v1"
val internal_manifest_path = ".holbuild-toolchain-archive-manifest"
val manifest_marker = "identity-text-v1\n"
val max_manifest_size = 65536

fun die msg = raise Error msg
fun quote text = HolbuildHash.quote text
fun path_exists path = FS.access(path, []) handle OS.SysErr _ => false
fun is_dir path = FS.isDir path handle OS.SysErr _ => false

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if path_exists path then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun remove_file path = FS.remove path handle OS.SysErr _ => ()

fun remove_tree path =
  if path = "" orelse path = "." orelse path = "/" then
    die ("refusing to remove unsafe toolchain archive path: " ^ path)
  else
    ignore (OS.Process.system ("rm -rf " ^ quote path))

fun read_text path =
  let
    val input = TextIO.openIn path
    fun close () = TextIO.closeIn input handle _ => ()
  in
    (TextIO.inputAll input before close ()) handle e => (close (); raise e)
  end

fun write_text path text =
  let
    val output = TextIO.openOut path
    fun close () = TextIO.closeOut output handle _ => ()
  in
    (TextIO.output(output, text); close ()) handle e => (close (); raise e)
  end

fun tar_operation operation =
  operation () handle HolbuildTar.Error msg => die msg

fun components path = String.tokens (fn c => c = #"/") path

fun volatile_lock_path path =
  let
    fun loop (".hol" :: "locks" :: _) = true
      | loop (_ :: rest) = loop rest
      | loop [] = false
  in
    loop (components path)
  end

fun require_toolchain_member {path, ...} =
  if path = "build.ok" then die "archive contains build.ok"
  else if volatile_lock_path path then
    die ("archive contains volatile .hol/locks path: " ^ path)
  else ()

fun split_at_marker text =
  let
    val marker_length = size manifest_marker
    val text_length = size text
    fun loop i =
      if i + marker_length > text_length then NONE
      else if String.substring(text, i, marker_length) = manifest_marker then
        SOME (String.substring(text, 0, i), String.extract(text, i + marker_length, NONE))
      else loop (i + 1)
  in
    loop 0
  end

fun manifest_text identity =
  String.concatWith "\n"
    [archive_format,
     "identity-sha256 " ^ HolbuildHash.string_sha256 identity,
     "identity-size " ^ Int.toString (size identity),
     manifest_marker ^ identity]

fun field_value name lines =
  let
    val prefix = name ^ "="
    val values =
      List.mapPartial
        (fn line => if String.isPrefix prefix line then SOME (String.extract(line, size prefix, NONE)) else NONE)
        lines
  in
    case values of
        [value] => value
      | [] => die ("remote toolchain action is missing " ^ name)
      | _ => die ("remote toolchain action repeats " ^ name)
  end

fun require_manifest identity text =
  case split_at_marker text of
      NONE => die "toolchain archive manifest is missing identity"
    | SOME (header, actual_identity) =>
        let
          val lines = String.tokens (fn c => c = #"\n") header
          val _ =
            case lines of
                format :: _ => if format = archive_format then () else die "unsupported toolchain archive format"
              | [] => die "empty toolchain archive manifest"
          fun line_value name =
            let
              val prefix = name ^ " "
              val matches = List.mapPartial (fn line => if String.isPrefix prefix line then SOME (String.extract(line, size prefix, NONE)) else NONE) lines
            in
              case matches of [value] => value | _ => die ("toolchain archive manifest has invalid " ^ name)
            end
          val expected_hash = line_value "identity-sha256"
          val expected_size = line_value "identity-size"
          val _ = if expected_hash = HolbuildHash.string_sha256 actual_identity then () else die "toolchain archive identity checksum mismatch"
          val _ = if expected_size = Int.toString (size actual_identity) then () else die "toolchain archive identity size mismatch"
          val _ = if actual_identity = identity then () else die "toolchain archive identity does not match this installation"
        in
          ()
        end

fun inspect_archive {archive_path, identity, final_dir} =
  let
    val {members, content} =
      tar_operation
        (fn () => HolbuildTar.inspect
          {archive_path = archive_path,
           destination = final_dir,
           capture = SOME
             {path = internal_manifest_path,
              max_size = max_manifest_size,
              description = "toolchain archive manifest"}})
    val _ = List.app require_toolchain_member members
  in
    case content of
        SOME text => require_manifest identity text
      | NONE => die "toolchain archive is missing its internal manifest"
  end

fun fresh_temp_name () =
  let val placeholder = FS.tmpName ()
  in
    remove_file placeholder;
    placeholder
  end

fun temp_path label =
  let val unique = fresh_temp_name ()
  in
    Path.concat(Path.dir unique,
                "holbuild-toolchain-" ^ label ^ "-" ^ Path.file unique)
  end

fun stage_prefix final_dir = "." ^ Path.file final_dir ^ ".restore-"

fun staging_path final_dir =
  Path.concat(Path.dir final_dir,
              stage_prefix final_dir ^ HolbuildFileLock.current_pid_text () ^
              "-" ^ Path.file (fresh_temp_name ()))

fun restore_scratch_path final_dir = staging_path final_dir ^ ".scratch"

fun children dir =
  let
    val stream = FS.openDir dir
    fun close () = FS.closeDir stream handle _ => ()
    fun loop paths =
      case FS.readDir stream of
          NONE => rev paths before close ()
        | SOME name => loop (Path.concat(dir, name) :: paths)
  in
    loop [] handle e => (close (); raise e)
  end

fun cleanup_staging final_dir =
  let
    val parent = Path.dir final_dir
    val prefix = stage_prefix final_dir
    fun stale path = String.isPrefix prefix (Path.file path)
  in
    if is_dir parent then List.app remove_tree (List.filter stale (children parent)) else ()
  end

fun create_archive {entry_dir, identity, archive_path} =
  let
    val manifest_dir = temp_path "manifest"
    val manifest_path = Path.concat(manifest_dir, internal_manifest_path)
    val collision = Path.concat(entry_dir, internal_manifest_path)
    fun cleanup () = (remove_file archive_path; remove_tree manifest_dir handle _ => ())
    val _ = if path_exists collision then die ("toolchain entry contains reserved archive path: " ^ collision) else ()
  in
    (FS.mkDir manifest_dir;
     write_text manifest_path (manifest_text identity);
     tar_operation
       (fn () => HolbuildTar.create
         {archive_path = archive_path,
          sources =
            [(manifest_dir, [internal_manifest_path]),
             (entry_dir, ["."])],
          excludes = ["./build.ok", "*/.hol/locks", "*/.hol/locks/*"],
          hard_dereference = true});
     inspect_archive {archive_path = archive_path, identity = identity, final_dir = entry_dir};
     remove_tree manifest_dir)
    handle e => (cleanup (); raise e)
  end

fun remote_record identity {sha1, sha256, size} =
  String.concatWith "\n"
    [action_format,
     "identity-sha256=" ^ HolbuildHash.string_sha256 identity,
     "blob-sha1=" ^ sha1,
     "archive-sha256=" ^ sha256,
     "archive-size=" ^ size] ^ "\n"

fun parse_remote_record identity text =
  let
    val lines = String.tokens (fn c => c = #"\n") text
    val _ =
      case lines of
          format :: _ => if format = action_format then () else die "unsupported remote toolchain action format"
        | [] => die "empty remote toolchain action"
    val identity_sha256 = field_value "identity-sha256" lines
    val sha1 = field_value "blob-sha1" lines
    val sha256 = field_value "archive-sha256" lines
    val size = field_value "archive-size" lines
    val _ = if identity_sha256 = HolbuildHash.string_sha256 identity then () else die "remote toolchain action identity mismatch"
    val _ = if HolbuildHash.valid_sha1 sha1 then () else die "remote toolchain action has invalid SHA1"
    val _ = if HolbuildHash.valid_sha256 sha256 then () else die "remote toolchain action has invalid SHA256"
    val _ = case Position.fromString size of SOME _ => () | NONE => die "remote toolchain action has invalid archive size"
  in
    {sha1 = sha1, sha256 = sha256, size = size}
  end

fun verify_archive_file path {sha1, sha256, size} =
  let
    val actual_size = Position.toString (FS.fileSize path)
    val actual_sha1 = HolbuildHash.file_sha1 path
    val actual_sha256 = HolbuildHash.file_sha256 path
  in
    if actual_size <> size then die "downloaded toolchain archive size mismatch"
    else if actual_sha1 <> sha1 then die "downloaded toolchain archive SHA1 mismatch"
    else if actual_sha256 <> sha256 then die "downloaded toolchain archive SHA256 mismatch"
    else ()
  end

fun extract_archive {archive_path, staging_dir} =
  tar_operation
    (fn () => HolbuildTar.extract
      {archive_path = archive_path, destination = staging_dir})

fun install_archive {archive_path, identity, final_dir} =
  let
    val staging_dir = staging_path final_dir
    val extracted_manifest = Path.concat(staging_dir, internal_manifest_path)
    fun cleanup () = remove_tree staging_dir handle _ => ()
  in
    (if path_exists final_dir then die ("toolchain install path already exists: " ^ final_dir) else ();
     inspect_archive {archive_path = archive_path, identity = identity, final_dir = final_dir};
     FS.mkDir staging_dir;
     extract_archive {archive_path = archive_path, staging_dir = staging_dir};
     inspect_archive {archive_path = archive_path, identity = identity, final_dir = final_dir};
     if path_exists extracted_manifest andalso not (is_dir extracted_manifest) then remove_file extracted_manifest
     else die "extracted toolchain archive manifest is missing";
     FS.rename {old = staging_dir, new = final_dir})
    handle e => (cleanup (); raise e)
  end

fun restore {remote, identity, final_dir} =
  case HolbuildRemoteCache.get_toolchain_action remote identity of
      NONE => false
    | SOME text =>
        let
          val expected = parse_remote_record identity text
          val scratch_dir = restore_scratch_path final_dir
          val archive_path = Path.concat(scratch_dir, "archive.tar")
          fun cleanup () = remove_tree scratch_dir handle _ => ()
          fun fetch () =
            case HolbuildRemoteCache.fetch_toolchain_blob remote {hash = #sha1 expected, dst = archive_path} of
                HolbuildCacheBackend.Hit => ()
              | HolbuildCacheBackend.Miss => die "remote toolchain archive blob is missing"
              | HolbuildCacheBackend.Corrupt detail => die ("remote toolchain archive blob is corrupt: " ^ detail)
        in
          ((FS.mkDir scratch_dir;
            fetch ();
            verify_archive_file archive_path expected;
            install_archive {archive_path = archive_path, identity = identity, final_dir = final_dir};
            cleanup ();
            true)
           handle e => (cleanup (); raise e))
        end

fun publish {remote, identity, entry_dir} =
  let
    val archive_path = temp_path "publish"
    fun cleanup () = remove_file archive_path
    fun upload sha1 =
      case HolbuildRemoteCache.publish_toolchain_blob remote {hash = sha1, src = archive_path} of
          result as HolbuildCacheBackend.Published => result
        | result as HolbuildCacheBackend.AlreadyPresent => result
        | HolbuildCacheBackend.Skipped => die "remote cache skipped toolchain archive publication"
        | HolbuildCacheBackend.Conflict detail => die ("remote cache rejected toolchain archive: " ^ detail)
  in
    ((create_archive {entry_dir = entry_dir, identity = identity, archive_path = archive_path};
      let
        val sha1 = HolbuildHash.file_sha1 archive_path
        val sha256 = HolbuildHash.file_sha256 archive_path
        val size = Position.toString (FS.fileSize archive_path)
        val _ = upload sha1
        val action = remote_record identity {sha1 = sha1, sha256 = sha256, size = size}
      in
        case HolbuildRemoteCache.put_toolchain_action remote HolbuildCacheBackend.PutIfAbsentOrSame
               {identity = identity, text = action} of
            result as HolbuildCacheBackend.Published => result
          | result as HolbuildCacheBackend.AlreadyPresent => result
          | HolbuildCacheBackend.Skipped => die "remote cache skipped toolchain action publication"
          | HolbuildCacheBackend.Conflict detail => die ("remote cache rejected toolchain action: " ^ detail)
      end before cleanup ())
     handle e => (cleanup (); raise e))
  end

end
