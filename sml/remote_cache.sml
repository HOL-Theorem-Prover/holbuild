structure HolbuildRemoteCache =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

type blob_entry = {sha1 : string, sha256 : string, size : string}
datatype t = RemoteCache of {base_url : string, blobs : blob_entry list ref}

val metadata_header = "holbuild-remote-cache-action-v1"
val manifest_marker = "manifest-text-v1\n"

(* Initial remote-cache transport keeps curl policy deliberately simple.  The
   30s transfer timeout is hardcoded for now; make it configurable if real
   deployments need different WAN/large-blob behavior. *)
val curl_max_time_seconds = "30"

fun trim_trailing_slashes url =
  let
    fun loop n =
      if n > 0 andalso String.sub(url, n - 1) = #"/" then loop (n - 1) else n
    val n = loop (size url)
  in
    if n = 0 then url else String.substring(url, 0, n)
  end

fun remote url = RemoteCache {base_url = trim_trailing_slashes url, blobs = ref []}

fun base_url (RemoteCache {base_url, ...}) = base_url
fun blob_map (RemoteCache {blobs, ...}) = blobs

fun quote s = HolbuildHash.quote s

fun path_exists path = FS.access(path, []) handle OS.SysErr _ => false

fun ensure_dir path =
  if path = "" orelse path = "." then ()
  else if path_exists path then ()
  else (ensure_dir (Path.dir path); FS.mkDir path handle OS.SysErr _ => ())

fun ensure_parent path = ensure_dir (Path.dir path)
fun remove_file path = FS.remove path handle OS.SysErr _ => ()

fun read_text path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end

fun write_text path text =
  let
    val _ = ensure_parent path
    val output = TextIO.openOut path
      handle e => raise Error ("could not write " ^ path ^ ": " ^ General.exnMessage e)
    fun close () = TextIO.closeOut output handle _ => ()
  in
    (TextIO.output(output, text); TextIO.closeOut output)
    handle e => (close (); raise e)
  end

fun temp_path label =
  Path.concat(Path.dir (FS.tmpName ()), "holbuild-remote-cache-" ^ label ^ "-" ^ Path.file (FS.tmpName ()))

fun curl_config_arg () =
  case OS.Process.getEnv "HOLBUILD_REMOTE_CACHE_CURL_CONFIG" of
      SOME path => " --config " ^ quote path
    | NONE => ""

fun redact_userinfo url =
  let
    val marker = "://"
    val marker_len = size marker
    val url_len = size url
    fun marker_at i = i + marker_len <= url_len andalso String.substring(url, i, marker_len) = marker
    fun find_marker i =
      if i + marker_len > url_len then NONE
      else if marker_at i then SOME i else find_marker (i + 1)
    fun slash_or_end i =
      if i >= url_len orelse String.sub(url, i) = #"/" then i else slash_or_end (i + 1)
    fun at_before limit i =
      if i >= limit then NONE
      else if String.sub(url, i) = #"@" then SOME i else at_before limit (i + 1)
  in
    case find_marker 0 of
        NONE => url
      | SOME scheme_end =>
          let
            val auth_start = scheme_end + marker_len
            val path_start = slash_or_end auth_start
          in
            case at_before path_start auth_start of
                NONE => url
              | SOME at => String.substring(url, 0, auth_start) ^ "<redacted>@" ^ String.extract(url, at + 1, NONE)
          end
  end

fun read_first_token path =
  case String.tokens Char.isSpace (read_text path) of
      token :: _ => token
    | [] => ""

fun remove_file_before result path = (remove_file path; result)

fun command_success command = OS.Process.isSuccess (OS.Process.system command)

fun zstd_compress src dst =
  command_success ("zstd -q -f -T0 -o " ^ quote dst ^ " " ^ quote src)

fun zstd_content_headers size =
  " -H 'Content-Encoding: zstd' -H " ^ quote ("X-Digest-SizeBytes: " ^ size)

fun curl_get {url, dst} =
  let
    val code = temp_path "code"
    val display_url = redact_userinfo url
    (* --compressed advertises curl-supported response encodings, including zstd
       when this curl build has zstd support, and writes decompressed bytes to dst. *)
    val command = "curl -q -sS -L --compressed --max-time " ^ curl_max_time_seconds ^ curl_config_arg () ^ " -o " ^ quote dst ^
                  " -w '%{http_code}' " ^ quote url ^ " > " ^ quote code
    val status = OS.Process.system command
    val http_code = if path_exists code then read_first_token code else "000"
    val _ = remove_file code
  in
    if not (OS.Process.isSuccess status) then HolbuildCacheBackend.Corrupt ("curl GET failed: " ^ display_url)
    else if http_code = "200" then HolbuildCacheBackend.Hit
    else if http_code = "404" then HolbuildCacheBackend.Miss
    else HolbuildCacheBackend.Corrupt ("HTTP " ^ http_code ^ " from " ^ display_url)
  end
  handle e => (HolbuildCacheBackend.Corrupt (General.exnMessage e))

fun successful_put_code code =
  code = "200" orelse code = "201" orelse code = "204"

fun curl_put_with_headers headers {url, src} =
  let
    val code = temp_path "code"
    val body = temp_path "body"
    val display_url = redact_userinfo url
    val command = "curl -q -sS -L --max-time " ^ curl_max_time_seconds ^ curl_config_arg () ^ headers ^ " -T " ^ quote src ^
                  " -o " ^ quote body ^ " -w '%{http_code}' " ^ quote url ^
                  " > " ^ quote code
    val status = OS.Process.system command
    val http_code = if path_exists code then read_first_token code else "000"
    val _ = remove_file code
    val _ = remove_file body
  in
    if not (OS.Process.isSuccess status) then HolbuildCacheBackend.Conflict ("curl PUT failed: " ^ display_url)
    else if successful_put_code http_code then HolbuildCacheBackend.Published
    else HolbuildCacheBackend.Conflict ("HTTP " ^ http_code ^ " from " ^ display_url)
  end
  handle e => (HolbuildCacheBackend.Conflict (General.exnMessage e))

fun curl_put request = curl_put_with_headers "" request

fun curl_put_zstd {url, src, size} =
  let val compressed = temp_path "zstd-put"
  in
    if zstd_compress src compressed then
      curl_put_with_headers (zstd_content_headers size) {url = url, src = compressed}
      before remove_file compressed
    else
      remove_file_before (curl_put {url = url, src = src}) compressed
  end
  handle e => HolbuildCacheBackend.Conflict (General.exnMessage e)

fun action_url cache key = base_url cache ^ "/ac/" ^ key
fun cas_url cache sha256 = base_url cache ^ "/cas/" ^ sha256

fun lookup_blob cache sha1 =
  List.find (fn {sha1 = existing, ...} => existing = sha1) (!(blob_map cache))

fun remember_blob cache entry =
  let
    val blobs = blob_map cache
    val {sha1, ...} = entry
  in
    blobs := entry :: List.filter (fn {sha1 = existing, ...} => existing <> sha1) (!blobs)
  end

fun split_at_marker text =
  let
    val marker_len = size manifest_marker
    val text_len = size text
    fun loop i =
      if i + marker_len > text_len then NONE
      else if String.substring(text, i, marker_len) = manifest_marker then
        SOME (String.substring(text, 0, i), String.extract(text, i + marker_len, NONE))
      else loop (i + 1)
  in
    loop 0
  end

fun parse_blob_line line =
  case String.tokens Char.isSpace line of
      ["blob", sha1, sha256, size] =>
        if HolbuildHash.valid_sha1 sha1 andalso HolbuildHash.valid_sha256 sha256 then
          SOME {sha1 = sha1, sha256 = sha256, size = size}
        else NONE
    | _ => NONE

fun line_value name line =
  case String.tokens Char.isSpace line of
      [field, value] => if field = name then SOME value else NONE
    | _ => NONE

fun first_value name lines =
  case List.mapPartial (line_value name) lines of
      value :: _ => SOME value
    | [] => NONE

fun require_manifest_checksum lines manifest =
  case first_value "manifest-sha256" lines of
      SOME expected =>
        if HolbuildHash.valid_sha256 expected andalso HolbuildHash.string_sha256 manifest = expected then ()
        else raise Error "remote action metadata manifest SHA256 mismatch"
    | NONE => raise Error "remote action metadata missing manifest SHA256"

fun require_manifest_size lines manifest =
  case first_value "manifest-size" lines of
      SOME expected =>
        if expected = Int.toString (size manifest) then ()
        else raise Error "remote action metadata manifest size mismatch"
    | NONE => raise Error "remote action metadata missing manifest size"

fun metadata_manifest text =
  case split_at_marker text of
      SOME (header_text, manifest) =>
        let
          val lines = String.tokens (fn c => c = #"\n") header_text
          val _ =
            case lines of
                first :: _ => if first = metadata_header then () else raise Error "remote action metadata has unsupported header"
              | [] => raise Error "remote action metadata is empty"
          val _ = require_manifest_checksum lines manifest
          val _ = require_manifest_size lines manifest
        in
          {blobs = List.mapPartial parse_blob_line lines, manifest = manifest}
        end
    | NONE => raise Error "remote action metadata missing manifest marker"

fun metadata_text manifest blobs =
  String.concatWith "\n"
    ([metadata_header,
      "manifest-sha256 " ^ HolbuildHash.string_sha256 manifest,
      "manifest-size " ^ Int.toString (size manifest)] @
     map (fn {sha1, sha256, size} => "blob " ^ sha1 ^ " " ^ sha256 ^ " " ^ size) blobs @
     [manifest_marker ^ manifest])

fun get_action cache key =
  let
    val tmp = temp_path "action"
    fun cleanup () = remove_file tmp
  in
    case curl_get {url = action_url cache key, dst = tmp} of
        HolbuildCacheBackend.Hit =>
          let
            val {blobs, manifest} = metadata_manifest (read_text tmp)
            val _ = List.app (remember_blob cache) blobs
          in
            cleanup ();
            SOME manifest
          end
      | HolbuildCacheBackend.Miss => (cleanup (); NONE)
      | HolbuildCacheBackend.Corrupt _ => (cleanup (); NONE)
  end
  handle _ => NONE

fun put_action cache policy {key, text} =
  let
    val refs = HolbuildCacheTransfer.unique_blobs text
    val known_blobs = List.mapPartial (lookup_blob cache) refs
    val _ =
      if length refs = length known_blobs then ()
      else raise Error ("remote action is missing published blob metadata for " ^ key)
    val metadata = metadata_text text known_blobs
    val tmp = temp_path "action-put"
    fun cleanup () = remove_file tmp
    fun publish () = (write_text tmp metadata; curl_put {url = action_url cache key, src = tmp} before cleanup ())
  in
    case get_action cache key of
        SOME existing =>
          (case policy of
               HolbuildCacheBackend.PutIfAbsent => HolbuildCacheBackend.Conflict (action_url cache key)
             | HolbuildCacheBackend.PutIfAbsentOrSame =>
                 if existing = text then HolbuildCacheBackend.AlreadyPresent
                 else HolbuildCacheBackend.Conflict (action_url cache key))
      | NONE => publish ()
  end
  handle e => HolbuildCacheBackend.Conflict (General.exnMessage e)

fun has_blob cache sha1 = Option.isSome (lookup_blob cache sha1)

fun fetch_blob cache {hash, dst} =
  case lookup_blob cache hash of
      NONE => HolbuildCacheBackend.Miss
    | SOME {sha256, ...} =>
        let val result = curl_get {url = cas_url cache sha256, dst = dst}
        in
          case result of
              HolbuildCacheBackend.Hit =>
                if HolbuildHash.file_sha1 dst = hash then HolbuildCacheBackend.Hit
                else HolbuildCacheBackend.Corrupt ("downloaded blob SHA1 mismatch: " ^ hash)
            | other => other
        end
        handle e => HolbuildCacheBackend.Corrupt (General.exnMessage e)

fun publish_blob cache {hash, src} =
  let
    val sha1 = HolbuildHash.file_sha1 src
    val sha256 = HolbuildHash.file_sha256 src
    val size = Position.toString (FS.fileSize src)
    val _ =
      if sha1 = hash then ()
      else raise Error ("blob SHA1 mismatch: expected " ^ hash ^ " got " ^ sha1)
    val result = curl_put_zstd {url = cas_url cache sha256, src = src, size = size}
  in
    case result of
        HolbuildCacheBackend.Published => (remember_blob cache {sha1 = hash, sha256 = sha256, size = size}; result)
      | HolbuildCacheBackend.AlreadyPresent => (remember_blob cache {sha1 = hash, sha256 = sha256, size = size}; result)
      | other => other
  end
  handle e => HolbuildCacheBackend.Conflict (General.exnMessage e)

end
