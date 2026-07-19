structure HolbuildToolchainArchive =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

val archive_format = "holbuild-toolchain-archive-v1"
val action_format = "holbuild-remote-toolchain-action-v1"
val action_key_domain = "holbuild-remote-toolchain-action-key-v1"
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

fun manifest_text identity =
  archive_format ^ "\n" ^ manifest_marker ^ identity

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
  if text = manifest_text identity then ()
  else die "toolchain archive identity does not match this installation"

fun validate_extracted_manifest {staging_dir, identity} =
  let val path = Path.concat(staging_dir, internal_manifest_path)
  in
    if not (path_exists path) orelse is_dir path orelse FS.isLink path then
      die "extracted toolchain archive manifest is missing"
    else if FS.fileSize path > Position.fromInt max_manifest_size then
      die "toolchain archive manifest is too large"
    else
      (require_manifest identity (read_text path);
       remove_file path)
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
     remove_tree manifest_dir)
    handle e => (cleanup (); raise e)
  end

fun remote_action_key identity =
  HolbuildHash.string_sha256 (action_key_domain ^ "\n" ^ identity ^ "\n")

fun remote_record sha1 =
  String.concatWith "\n" [action_format, "blob-sha1=" ^ sha1] ^ "\n"

fun parse_remote_record text =
  let
    val lines = String.tokens (fn c => c = #"\n") text
    val _ =
      case lines of
          format :: _ => if format = action_format then () else die "unsupported remote toolchain action format"
        | [] => die "empty remote toolchain action"
    val sha1 = field_value "blob-sha1" lines
    val _ = if HolbuildHash.valid_sha1 sha1 then () else die "remote toolchain action has invalid SHA1"
  in
    sha1
  end

fun extract_archive {archive_path, staging_dir} =
  tar_operation
    (fn () => HolbuildTar.extract
      {archive_path = archive_path, destination = staging_dir})

fun install_archive {archive_path, identity, final_dir} =
  let
    val staging_dir = staging_path final_dir
    val extracted_marker = Path.concat(staging_dir, "build.ok")
    fun cleanup () = remove_tree staging_dir handle _ => ()
  in
    (if path_exists final_dir then die ("toolchain install path already exists: " ^ final_dir) else ();
     FS.mkDir staging_dir;
     extract_archive {archive_path = archive_path, staging_dir = staging_dir};
     if path_exists extracted_marker then die "archive contains build.ok" else ();
     validate_extracted_manifest {staging_dir = staging_dir, identity = identity};
     FS.rename {old = staging_dir, new = final_dir})
    handle e => (cleanup (); raise e)
  end

fun restore {remote, identity, final_dir} =
  case HolbuildRemoteCache.get_action remote (remote_action_key identity) of
      NONE => false
    | SOME text =>
        let
          val sha1 = parse_remote_record text
          val scratch_dir = restore_scratch_path final_dir
          val archive_path = Path.concat(scratch_dir, "archive.tar")
          fun cleanup () = remove_tree scratch_dir handle _ => ()
          fun fetch () =
            case HolbuildRemoteCache.fetch_toolchain_blob remote {hash = sha1, dst = archive_path} of
                HolbuildCacheBackend.Hit => ()
              | HolbuildCacheBackend.Miss => die "remote toolchain archive blob is missing"
              | HolbuildCacheBackend.Corrupt detail => die ("remote toolchain archive blob is corrupt: " ^ detail)
        in
          ((FS.mkDir scratch_dir;
            fetch ();
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
        val _ = upload sha1
        val action = remote_record sha1
      in
        case HolbuildRemoteCache.put_action remote HolbuildCacheBackend.PutIfAbsentOrSame
               {key = remote_action_key identity, text = action} of
            result as HolbuildCacheBackend.Published => result
          | result as HolbuildCacheBackend.AlreadyPresent => result
          | HolbuildCacheBackend.Skipped => die "remote cache skipped toolchain action publication"
          | HolbuildCacheBackend.Conflict detail => die ("remote cache rejected toolchain action: " ^ detail)
      end before cleanup ())
     handle e => (cleanup (); raise e))
  end

end
