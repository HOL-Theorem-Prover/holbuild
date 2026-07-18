structure HolbuildToolchainArchive =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

val archive_format = "holbuild-toolchain-archive-v1"
val action_format = "holbuild-remote-toolchain-action-v1"
val internal_manifest_path = ".holbuild-toolchain-archive-manifest"
val manifest_marker = "identity-text-v1\n"
val tar_block_size = 512
val max_manifest_size = 65536

datatype archive_kind =
    Regular
  | Directory
  | Symlink of string
  | Hardlink of string
  | ExtendedHeader

type archive_entry = {path : string, kind : archive_kind, mode : int, index : int}
type stored_entry = {kind : archive_kind, index : int}
type entry_map = (string, stored_entry) Redblackmap.dict

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

fun run command failure =
  if OS.Process.isSuccess (OS.Process.system command) then () else die failure

fun vector_string bytes =
  String.implode
    (List.tabulate
       (Word8Vector.length bytes,
        fn i => Char.chr (Word8.toInt (Word8Vector.sub(bytes, i)))))

fun byte_at bytes i = Word8.toInt (Word8Vector.sub(bytes, i))

fun all_zero bytes =
  let
    fun loop i =
      i >= Word8Vector.length bytes orelse
      (byte_at bytes i = 0 andalso loop (i + 1))
  in
    loop 0
  end

datatype field_grammar =
    NulPaddedText
  | TarOctal

datatype decoded_field =
    TextField of string
  | NumericField of IntInf.int

datatype octal_state =
    LeadingPadding
  | OctalDigits
  | TrailingPadding

fun raw_field bytes start length =
  String.implode
    (List.tabulate(length, fn i => Char.chr (byte_at bytes (start + i))))

fun decode_strict_field label NulPaddedText raw =
      let
        val length = size raw
        fun loop i terminated chars =
          if i >= length then TextField (String.implode (rev chars))
          else
            let val c = String.sub(raw, i)
            in
              if c = #"\000" then loop (i + 1) true chars
              else if terminated then die ("invalid " ^ label ^ " field")
              else loop (i + 1) false (c :: chars)
            end
      in
        loop 0 false []
      end
  | decode_strict_field label TarOctal raw =
      let
        val length = size raw
        fun digit c = Char.ord c - Char.ord #"0"
        fun invalid () = die ("invalid " ^ label ^ " field")
        fun loop i state value =
          if i >= length then NumericField value
          else
            let val c = String.sub(raw, i)
            in
              case state of
                  LeadingPadding =>
                    if c = #" " then loop (i + 1) LeadingPadding value
                    else if #"0" <= c andalso c <= #"7" then
                      loop (i + 1) OctalDigits (IntInf.fromInt (digit c))
                    else if c = #"\000" then loop (i + 1) TrailingPadding value
                    else invalid ()
                | OctalDigits =>
                    if #"0" <= c andalso c <= #"7" then
                      loop (i + 1) OctalDigits
                        (value * 8 + IntInf.fromInt (digit c))
                    else if c = #"\000" orelse c = #" " then
                      loop (i + 1) TrailingPadding value
                    else invalid ()
                | TrailingPadding =>
                    if c = #"\000" orelse c = #" " then
                      loop (i + 1) TrailingPadding value
                    else invalid ()
            end
      in
        loop 0 LeadingPadding 0
      end

fun field_string label bytes start length =
  case decode_strict_field ("tar " ^ label) NulPaddedText
         (raw_field bytes start length) of
      TextField value => value
    | NumericField _ => raise Fail "impossible numeric string field"

fun octal_value label bytes start length =
  case decode_strict_field ("tar " ^ label) TarOctal
         (raw_field bytes start length) of
      NumericField value =>
        (IntInf.toInt value handle Overflow => die ("tar " ^ label ^ " is too large"))
    | TextField _ => raise Fail "impossible text octal field"

fun tar_checksum bytes =
  let
    fun value i = if 148 <= i andalso i < 156 then 32 else byte_at bytes i
    fun loop i sum = if i >= tar_block_size then sum else loop (i + 1) (sum + value i)
  in
    loop 0 0
  end

fun strip_trailing_slash path =
  if size path > 0 andalso String.sub(path, size path - 1) = #"/" then
    strip_trailing_slash (String.substring(path, 0, size path - 1))
  else path

fun has_empty_component path =
  let
    fun loop i =
      i + 1 < size path andalso
      ((String.sub(path, i) = #"/" andalso String.sub(path, i + 1) = #"/") orelse loop (i + 1))
  in
    loop 0
  end

fun member_path raw =
  let
    val path = strip_trailing_slash raw
    val absolute = size path > 0 andalso String.sub(path, 0) = #"/"
    val _ = if absolute then die ("archive member has absolute path: " ^ raw) else ()
    val _ = if has_empty_component path then die ("archive member has empty path component: " ^ raw) else ()
    val components = String.tokens (fn c => c = #"/") path
    val _ =
      if List.exists (fn component => component = "..") components then
        die ("archive member traverses its parent: " ^ raw)
      else ()
    val clean = List.filter (fn component => component <> "." andalso component <> "") components
  in
    String.concatWith "/" clean
  end

fun components path = String.tokens (fn c => c = #"/") path

fun reduce_components initial additions =
  let
    fun step (component, stack) =
      if component = "" orelse component = "." then stack
      else if component = ".." then
        (case stack of
             [] => die "archive link escapes the toolchain entry"
           | _ :: rest => rest)
      else component :: stack
  in
    rev (List.foldl step (rev initial) additions)
  end

fun trim_trailing_slashes path =
  if size path > 1 andalso String.sub(path, size path - 1) = #"/" then
    trim_trailing_slashes (String.substring(path, 0, size path - 1))
  else path

fun path_within root path =
  path = root orelse
  (size path > size root andalso String.isPrefix (root ^ "/") path)

fun absolute_link_target final target =
  let
    val normalized = "/" ^ String.concatWith "/" (reduce_components [] (components target))
    val root = trim_trailing_slashes final
    val _ = if path_within root normalized then () else die ("archive symlink escapes the toolchain entry: " ^ target)
  in
    if normalized = root then ""
    else String.extract(normalized, size root + 1, NONE)
  end

fun relative_link_target member target =
  let
    val parent = components (Path.dir member)
  in
    String.concatWith "/" (reduce_components parent (components target))
  end

fun resolved_symlink_target final member target =
  if target = "" then die ("archive symlink has empty target: " ^ member)
  else if String.sub(target, 0) = #"/" then absolute_link_target final target
  else relative_link_target member target

fun ancestors path =
  let
    fun loop _ [] = []
      | loop _ [_] = []
      | loop prefix (component :: rest) =
          let val next = if prefix = "" then component else prefix ^ "/" ^ component
          in next :: loop next rest end
  in
    loop "" (components path)
  end

fun volatile_lock_path path =
  let
    fun loop (".hol" :: "locks" :: _) = true
      | loop (_ :: rest) = loop rest
      | loop [] = false
  in
    loop (components path)
  end

fun kind_name kind =
  case kind of
      Regular => "regular file"
    | Directory => "directory"
    | Symlink _ => "symlink"
    | Hardlink _ => "hardlink"
    | ExtendedHeader => "PAX extended header"

fun require_root_directory path kind =
  if path = "" andalso
     (case kind of Directory => false | ExtendedHeader => false | _ => true) then
    die "archive root is not a directory"
  else ()

fun require_supported_header header =
  let
    val magic = field_string "magic" header 257 6
    val stored = octal_value "checksum" header 148 8
    val actual = tar_checksum header
    val _ = if String.isPrefix "ustar" magic then () else die "archive is not ustar"
    val _ = if stored = actual then () else die "archive tar header checksum mismatch"
    val name = field_string "name" header 0 100
    val prefix = field_string "prefix" header 345 155
    val raw_path = if prefix = "" then name else prefix ^ "/" ^ name
    val path = member_path raw_path
    val mode = octal_value "mode" header 100 8
    val size = octal_value "size" header 124 12
    val type_byte = byte_at header 156
    val type_flag = if type_byte = 0 then #"0" else Char.chr type_byte
    val link = field_string "link name" header 157 100
    val kind =
      case type_flag of
          #"0" => Regular
        | #"5" => Directory
        | #"2" => Symlink link
        | #"1" => Hardlink link
        | #"x" => ExtendedHeader
        | #"3" => die ("archive contains character device: " ^ path)
        | #"4" => die ("archive contains block device: " ^ path)
        | #"6" => die ("archive contains FIFO: " ^ path)
        | _ => die ("archive contains unsupported tar entry type at: " ^ path)
    val _ = if mode <= 511 then () else die ("archive member has unsafe mode: " ^ path)
    val _ =
      case kind of
          Regular => ()
        | ExtendedHeader => ()
        | _ => if size = 0 then () else die ("non-regular archive member has data: " ^ path)
    val _ = if kind_name kind = "PAX extended header" orelse path <> "build.ok" then () else die "archive contains build.ok"
    val _ = if kind_name kind = "PAX extended header" orelse not (volatile_lock_path path) then () else die ("archive contains volatile .hol/locks path: " ^ path)
    val _ = require_root_directory path kind
  in
    {path = path, kind = kind, mode = mode, size = size}
  end

fun input_exact input length label =
  let val bytes = BinIO.inputN(input, length)
  in
    if Word8Vector.length bytes = length then bytes
    else die ("truncated toolchain archive " ^ label)
  end

fun skip_bytes input length =
  if length <= 0 then ()
  else
    let
      val chunk = Int.min(length, 65536)
      val bytes = input_exact input chunk "payload"
    in
      if Word8Vector.length bytes = chunk then skip_bytes input (length - chunk) else ()
    end

fun payload_padding size =
  if size mod tar_block_size = 0 then 0 else tar_block_size - (size mod tar_block_size)

fun read_remaining_zeros input =
  let val bytes = BinIO.inputN(input, 65536)
  in
    if Word8Vector.length bytes = 0 then ()
    else if all_zero bytes then read_remaining_zeros input
    else die "toolchain archive has data after its end marker"
  end

fun add_entry entries entry_list entry_count path kind mode =
  if path = "" then ()
  else
    case Redblackmap.peek(!entries, path) of
        SOME _ => die ("archive contains duplicate path: " ^ path)
      | NONE =>
          let
            val index = !entry_count
            val entry = {path = path, kind = kind, mode = mode, index = index}
          in
            entry_count := index + 1;
            entries := Redblackmap.insert(!entries, path, {kind = kind, index = index});
            entry_list := entry :: !entry_list
          end

fun pax_fields text =
  let
    val total = size text
    fun find_char wanted i limit =
      if i >= limit then NONE
      else if String.sub(text, i) = wanted then SOME i
      else find_char wanted (i + 1) limit
    fun add_field (key, value, {path, linkpath}) =
      case key of
          "path" =>
            if Option.isSome path then die "PAX header repeats path"
            else {path = SOME value, linkpath = linkpath}
        | "linkpath" =>
            if Option.isSome linkpath then die "PAX header repeats linkpath"
            else {path = path, linkpath = SOME value}
        | _ => die ("archive contains unsupported PAX field: " ^ key)
    fun loop offset fields =
      if offset = total then fields
      else
        case find_char #" " offset total of
            NONE => die "archive has malformed PAX record length"
          | SOME separator =>
              let
                val length_text = String.substring(text, offset, separator - offset)
                val record_length =
                  case Int.fromString length_text of
                      SOME value => value
                    | NONE => die "archive has invalid PAX record length"
                val record_end = offset + record_length
                val _ =
                  if record_length > 0 andalso record_end <= total andalso
                     String.sub(text, record_end - 1) = #"\n" then ()
                  else die "archive has truncated PAX record"
                val body_start = separator + 1
                val body_length = record_end - body_start - 1
                val body = String.substring(text, body_start, body_length)
                fun find_equals i =
                  if i >= size body then NONE
                  else if String.sub(body, i) = #"=" then SOME i
                  else find_equals (i + 1)
                val equals =
                  case find_equals 0 of
                      SOME value => value
                    | NONE => die "archive has malformed PAX field"
                val key = String.substring(body, 0, equals)
                val value = String.extract(body, equals + 1, NONE)
              in
                loop record_end (add_field (key, value, fields))
              end
  in
    loop 0 {path = NONE, linkpath = NONE}
  end

fun apply_pax_path path NONE = path
  | apply_pax_path _ (SOME override) = member_path override

fun apply_pax_link kind NONE = kind
  | apply_pax_link (Symlink _) (SOME target) = Symlink target
  | apply_pax_link (Hardlink _) (SOME target) = Hardlink target
  | apply_pax_link _ (SOME _) = die "PAX linkpath applies to a non-link archive member"

fun scan_archive path =
  let
    val input = BinIO.openIn path
    val entries = ref (Redblackmap.mkDict String.compare : entry_map)
    val entry_list = ref ([] : archive_entry list)
    val entry_count = ref 0
    val manifest = ref (NONE : string option)
    val pending_pax = ref (NONE : {path : string option, linkpath : string option} option)
    fun close () = BinIO.closeIn input handle _ => ()
    fun record_manifest member size bytes =
      if member <> internal_manifest_path then ()
      else if Option.isSome (!manifest) then die "archive contains duplicate internal manifest"
      else if size > max_manifest_size then die "toolchain archive manifest is too large"
      else manifest := SOME (vector_string bytes)
    fun finish () =
      if Option.isSome (!pending_pax) then die "archive ends after a PAX header"
      else ()
    fun normal_entry member kind mode size payload =
      let
        val overrides = !pending_pax
        val member' =
          case overrides of
              NONE => member
            | SOME {path, ...} => apply_pax_path member path
        val kind' =
          case overrides of
              NONE => kind
            | SOME {linkpath, ...} => apply_pax_link kind linkpath
        val _ = require_root_directory member' kind'
        val _ = pending_pax := NONE
        val _ = if member' = "build.ok" then die "archive contains build.ok" else ()
        val _ = if volatile_lock_path member' then die ("archive contains volatile .hol/locks path: " ^ member') else ()
        val _ = add_entry entries entry_list entry_count member' kind' mode
      in
        record_manifest member' size payload
      end
    fun loop () =
      let val header = input_exact input tar_block_size "header"
      in
        if all_zero header then
          let val second = input_exact input tar_block_size "end marker"
          in
            if all_zero second then (finish (); read_remaining_zeros input)
            else die "toolchain archive has a malformed end marker"
          end
        else
          let
            val {path = member, kind, mode, size} = require_supported_header header
            val needs_payload =
              member = internal_manifest_path orelse
              (case kind of ExtendedHeader => true | _ => false)
            val _ =
              if needs_payload andalso size > max_manifest_size then
                die "toolchain archive metadata is too large"
              else ()
            val payload =
              if needs_payload then input_exact input size "metadata"
              else (skip_bytes input size; Word8Vector.fromList [])
            val _ = skip_bytes input (payload_padding size)
            val _ =
              case kind of
                  ExtendedHeader =>
                    if Option.isSome (!pending_pax) then die "archive has consecutive PAX headers"
                    else pending_pax := SOME (pax_fields (vector_string payload))
                | _ => normal_entry member kind mode size payload
          in
            loop ()
          end
      end
    val result =
      ((loop ();
        {entries = !entries, entry_list = rev (!entry_list), manifest = !manifest})
       before close ())
      handle e => (close (); raise e)
  in
    result
  end

fun require_directory_ancestors entries {path, ...} =
  let
    fun check ancestor =
      case Redblackmap.peek(entries, ancestor) of
          NONE => ()
        | SOME {kind = Directory, ...} => ()
        | SOME {kind, ...} => die ("archive " ^ kind_name kind ^ " is a parent of: " ^ path)
  in
    List.app check (ancestors path)
  end

fun require_link_target entries final {path, kind, index, ...} =
  let
    fun existing_target target =
      if target = "" then SOME {kind = Directory, index = ~1}
      else Redblackmap.peek(entries, target)
    fun safe_symlink target =
      let val resolved = resolved_symlink_target final path target
      in
        case existing_target resolved of
            SOME {kind = Regular, ...} => ()
          | SOME {kind = Directory, ...} => ()
          | SOME _ => die ("archive symlink target is not a regular file or directory: " ^ path)
          | NONE => die ("archive symlink target is missing: " ^ path)
      end
    fun safe_hardlink target =
      let val resolved = member_path target
      in
        case Redblackmap.peek(entries, resolved) of
            SOME {kind = Regular, index = target_index} =>
              if target_index < index then () else die ("archive hardlink target does not precede link: " ^ path)
          | _ => die ("archive hardlink target is not a regular file: " ^ path)
      end
  in
    case kind of
        Symlink target => safe_symlink target
      | Hardlink target => safe_hardlink target
      | _ => ()
  end

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
    val {entries, entry_list, manifest} = scan_archive archive_path
    val _ = List.app (require_directory_ancestors entries) entry_list
    val _ = List.app (require_link_target entries final_dir) entry_list
  in
    case manifest of
        SOME text => require_manifest identity text
      | NONE => die "toolchain archive is missing its internal manifest"
  end

fun temp_path label =
  Path.concat(Path.dir (FS.tmpName ()), "holbuild-toolchain-" ^ label ^ "-" ^ Path.file (FS.tmpName ()))

fun stage_prefix final_dir = "." ^ Path.file final_dir ^ ".restore-"

fun staging_path final_dir =
  Path.concat(Path.dir final_dir,
              stage_prefix final_dir ^ HolbuildFileLock.current_pid_text () ^ "-" ^ Path.file (FS.tmpName ()))

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
     run
       ("tar --format=pax --pax-option=delete=atime,delete=ctime --sort=name --mtime=@0 " ^
        "--owner=0 --group=0 --numeric-owner --hard-dereference --exclude='./build.ok' " ^
        "--exclude='*/.hol/locks' --exclude='*/.hol/locks/*' " ^
        "-cf " ^ quote archive_path ^ " -C " ^ quote manifest_dir ^ " " ^ quote internal_manifest_path ^
        " -C " ^ quote entry_dir ^ " .")
       "could not create toolchain archive";
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
  run
    ("umask 000; tar -xf " ^ quote archive_path ^ " -C " ^ quote staging_dir ^
     " --no-same-owner --no-same-permissions --delay-directory-restore")
    "could not extract toolchain archive"

fun install_archive {archive_path, identity, final_dir} =
  let
    val staging_dir = staging_path final_dir
    val extracted_manifest = Path.concat(staging_dir, internal_manifest_path)
    fun cleanup () = remove_tree staging_dir handle _ => ()
  in
    (if path_exists final_dir then die ("toolchain install path already exists: " ^ final_dir) else ();
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
          val archive_path = temp_path "download"
          fun cleanup () = remove_file archive_path
          fun fetch () =
            case HolbuildRemoteCache.fetch_toolchain_blob remote {hash = #sha1 expected, dst = archive_path} of
                HolbuildCacheBackend.Hit => ()
              | HolbuildCacheBackend.Miss => die "remote toolchain archive blob is missing"
              | HolbuildCacheBackend.Corrupt detail => die ("remote toolchain archive blob is corrupt: " ^ detail)
        in
          ((fetch ();
            verify_archive_file archive_path expected;
            inspect_archive {archive_path = archive_path, identity = identity, final_dir = final_dir};
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
