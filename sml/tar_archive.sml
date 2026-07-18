structure HolbuildTar =
struct

structure Path = OS.Path

exception Error of string

val block_size = 512
val max_extended_header_size = 65536

datatype entry_kind =
    Regular
  | Directory
  | Symlink of string
  | Hardlink of string

type archive_entry = {path : string, kind : entry_kind, mode : int, index : int}
type stored_entry = {kind : entry_kind, index : int}
type entry_map = (string, stored_entry) Redblackmap.dict
type content_request = {path : string, max_size : int, description : string}

datatype header_kind =
    ArchiveMember of entry_kind
  | ExtendedHeader

fun die msg = raise Error msg
fun quote text = HolbuildHash.quote text

fun run command failure =
  if OS.Process.isSuccess (OS.Process.system command) then () else die failure

fun source_arguments (directory, members) =
  " -C " ^ quote directory ^
  String.concat (map (fn member => " " ^ quote member) members)

fun exclude_argument pattern = " " ^ quote ("--exclude=" ^ pattern)

fun create {archive_path, sources, excludes, hard_dereference} =
  let
    val command =
      "tar --format=pax --pax-option=delete=atime,delete=ctime " ^
      "--sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner" ^
      (if hard_dereference then " --hard-dereference" else "") ^
      String.concat (map exclude_argument excludes) ^
      " -cf " ^ quote archive_path ^
      String.concat (map source_arguments sources)
  in
    run command ("could not create tar archive: " ^ archive_path)
  end

fun extract {archive_path, destination} =
  run
    ("umask 000; tar -xf " ^ quote archive_path ^ " -C " ^ quote destination ^
     " --no-same-owner --no-same-permissions --delay-directory-restore")
    ("could not extract tar archive: " ^ archive_path)

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
  | NulFreeText
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
  | decode_strict_field label NulFreeText raw =
      let
        val length = size raw
        fun loop i =
          if i >= length then TextField raw
          else if String.sub(raw, i) = #"\000" then
            die ("invalid " ^ label ^ " field: NUL is not allowed")
          else loop (i + 1)
      in
        loop 0
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

fun pax_path_value label value =
  case decode_strict_field ("PAX " ^ label) NulFreeText value of
      TextField valid => valid
    | NumericField _ => raise Fail "impossible numeric PAX path field"

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
    fun loop i sum = if i >= block_size then sum else loop (i + 1) (sum + value i)
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
    val absolute = size raw > 0 andalso String.sub(raw, 0) = #"/"
    val path = strip_trailing_slash raw
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
             [] => die "archive link escapes the extraction root"
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

fun absolute_link_target destination target =
  let
    val normalized = "/" ^ String.concatWith "/" (reduce_components [] (components target))
    val root = trim_trailing_slashes destination
    val _ =
      if path_within root normalized then ()
      else die ("archive symlink escapes the extraction root: " ^ target)
  in
    if normalized = root then ""
    else String.extract(normalized, size root + 1, NONE)
  end

fun relative_link_target member target =
  let
    val parent =
      List.filter (fn component => component <> "." andalso component <> "")
        (components (Path.dir member))
  in
    String.concatWith "/" (reduce_components parent (components target))
  end

fun resolved_symlink_target destination member target =
  if target = "" then die ("archive symlink has empty target: " ^ member)
  else if String.sub(target, 0) = #"/" then absolute_link_target destination target
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

fun kind_name kind =
  case kind of
      Regular => "regular file"
    | Directory => "directory"
    | Symlink _ => "symlink"
    | Hardlink _ => "hardlink"

fun require_root_directory path kind =
  if path = "" andalso
     (case kind of ArchiveMember Directory => false | ExtendedHeader => false | _ => true) then
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
          #"0" => ArchiveMember Regular
        | #"5" => ArchiveMember Directory
        | #"2" => ArchiveMember (Symlink link)
        | #"1" => ArchiveMember (Hardlink link)
        | #"x" => ExtendedHeader
        | #"3" => die ("archive contains character device: " ^ path)
        | #"4" => die ("archive contains block device: " ^ path)
        | #"6" => die ("archive contains FIFO: " ^ path)
        | _ => die ("archive contains unsupported tar entry type at: " ^ path)
    val _ = if mode <= 511 then () else die ("archive member has unsafe mode: " ^ path)
    val _ =
      case kind of
          ArchiveMember Regular => ()
        | ExtendedHeader => ()
        | _ => if size = 0 then () else die ("non-regular archive member has data: " ^ path)
    val _ = require_root_directory path kind
  in
    {path = path, kind = kind, mode = mode, size = size}
  end

fun input_exact input length label =
  let val bytes = BinIO.inputN(input, length)
  in
    if Word8Vector.length bytes = length then bytes
    else die ("truncated tar archive " ^ label)
  end

fun skip_bytes input length =
  if length <= 0 then ()
  else
    let val chunk = Int.min(length, 65536)
    in
      ignore (input_exact input chunk "payload");
      skip_bytes input (length - chunk)
    end

fun payload_padding size =
  if size mod block_size = 0 then 0 else block_size - (size mod block_size)

fun read_remaining_zeros input =
  let val bytes = BinIO.inputN(input, 65536)
  in
    if Word8Vector.length bytes = 0 then ()
    else if all_zero bytes then read_remaining_zeros input
    else die "tar archive has data after its end marker"
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
            else {path = SOME (pax_path_value "path" value), linkpath = linkpath}
        | "linkpath" =>
            if Option.isSome linkpath then die "PAX header repeats linkpath"
            else {path = path, linkpath = SOME (pax_path_value "linkpath" value)}
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

fun read_member_payload input capture path kind size =
  case capture of
      NONE => (skip_bytes input size; NONE)
    | SOME ({path = wanted, max_size, description} : content_request) =>
        if path <> wanted then (skip_bytes input size; NONE)
        else
          (case kind of
               Regular =>
                 if size > max_size then die (description ^ " is too large")
                 else SOME (vector_string (input_exact input size description))
             | _ => die (description ^ " is not a regular file"))

fun scan_archive {archive_path, capture} =
  let
    val input = BinIO.openIn archive_path
    val entries = ref (Redblackmap.mkDict String.compare : entry_map)
    val entry_list = ref ([] : archive_entry list)
    val entry_count = ref 0
    val content = ref (NONE : string option)
    val pending_pax = ref (NONE : {path : string option, linkpath : string option} option)
    fun close () = BinIO.closeIn input handle _ => ()
    fun record_content NONE = ()
      | record_content (SOME text) =
          if Option.isSome (!content) then die "archive repeats requested content"
          else content := SOME text
    fun read_extended_header size =
      if size > max_extended_header_size then die "tar extended header is too large"
      else vector_string (input_exact input size "extended header")
    fun normal_entry raw_path raw_kind mode size =
      let
        val overrides = !pending_pax
        val path =
          case overrides of
              NONE => raw_path
            | SOME {path, ...} => apply_pax_path raw_path path
        val kind =
          case overrides of
              NONE => raw_kind
            | SOME {linkpath, ...} => apply_pax_link raw_kind linkpath
        val _ = require_root_directory path (ArchiveMember kind)
        val _ = pending_pax := NONE
        val _ = add_entry entries entry_list entry_count path kind mode
        val payload = read_member_payload input capture path kind size
      in
        record_content payload;
        skip_bytes input (payload_padding size)
      end
    fun extended_header size =
      let
        val _ = if Option.isSome (!pending_pax) then die "archive has consecutive PAX headers" else ()
        val text = read_extended_header size
      in
        skip_bytes input (payload_padding size);
        pending_pax := SOME (pax_fields text)
      end
    fun finish () =
      if Option.isSome (!pending_pax) then die "archive ends after a PAX header" else ()
    fun loop () =
      let val header = input_exact input block_size "header"
      in
        if all_zero header then
          let val second = input_exact input block_size "end marker"
          in
            if all_zero second then (finish (); read_remaining_zeros input)
            else die "tar archive has a malformed end marker"
          end
        else
          let val {path, kind, mode, size} = require_supported_header header
          in
            (case kind of
                 ExtendedHeader => extended_header size
               | ArchiveMember member_kind => normal_entry path member_kind mode size);
            loop ()
          end
      end
    val result =
      ((loop ();
        {entry_map = !entries, members = rev (!entry_list), content = !content})
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

fun require_link_target entries destination {path, kind, index, ...} =
  let
    fun existing_target target =
      if target = "" then SOME {kind = Directory, index = ~1}
      else Redblackmap.peek(entries, target)
    fun safe_symlink target =
      let val resolved = resolved_symlink_target destination path target
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
              if target_index < index then ()
              else die ("archive hardlink target does not precede link: " ^ path)
          | _ => die ("archive hardlink target is not a regular file: " ^ path)
      end
  in
    case kind of
        Symlink target => safe_symlink target
      | Hardlink target => safe_hardlink target
      | _ => ()
  end

fun inspect {archive_path, destination, capture} =
  let
    val {entry_map, members, content} =
      scan_archive {archive_path = archive_path, capture = capture}
    val _ = List.app (require_directory_ancestors entry_map) members
    val _ = List.app (require_link_target entry_map destination) members
  in
    {members = members, content = content}
  end

end
