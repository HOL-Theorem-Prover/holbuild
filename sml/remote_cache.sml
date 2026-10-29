structure HolbuildRemoteCache =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

type blob_entry = {sha1 : string, sha256 : string, size : string}
type blob_map = (string, blob_entry) Redblackmap.dict
datatype t = RemoteCache of {base_url : string, blobs : blob_map ref}

val metadata_header = "holbuild-remote-cache-action-v1"
val manifest_marker = "manifest-text-v1\n"

(* Large toolchain archives get a minutes-scale transfer bound without changing
   the existing theory-action policy. *)
val curl_max_time_seconds = 30
val toolchain_curl_max_time_seconds = 1800

fun trim_trailing_slashes url =
  let
    fun loop n =
      if n > 0 andalso String.sub(url, n - 1) = #"/" then loop (n - 1) else n
    val n = loop (size url)
  in
    if n = 0 then url else String.substring(url, 0, n)
  end

fun empty_blob_map () = Redblackmap.mkDict String.compare

fun remote url =
  RemoteCache {base_url = trim_trailing_slashes url, blobs = ref (empty_blob_map ())}

fun base_url (RemoteCache {base_url, ...}) = base_url
fun blob_map (RemoteCache {blobs, ...}) = blobs

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
  HolbuildTempPath.temporary ("remote-cache-" ^ label)

fun curl_config_args () =
  case HolbuildRemoteCacheConfig.curl_config () of
      SOME path => ["--config", path]
    | NONE => []

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

fun first_token text =
  case String.tokens Char.isSpace text of
      token :: _ => token
    | [] => ""

fun remove_file_before result path = (remove_file path; result)

fun run program args =
  HolbuildSpawn.run {program = program, args = args, stderr = HolbuildSpawn.Inherit}

fun completed_line text =
  case List.find (String.isSubstring "Completed in") (String.fields (fn c => c = #"\n") text) of
      SOME line => Substring.string (#2 (Substring.position "Completed in" (Substring.full line)))
    | NONE => "no zstd completion line"

(* Under HOLBUILD_CACHE_TRACE, zstd runs verbosely so its wall time and CPU
   load show how much the -T0 threads compete with the build. *)
fun zstd_compress url src dst =
  if HolbuildStatus.cache_trace_enabled () then
    let
      val result = HolbuildSpawn.run {program = "zstd", args = ["-vv", "-f", "-T0", "-o", dst, src],
                                      stderr = HolbuildSpawn.Merge}
      val ok = HolbuildSpawn.succeeded result
    in
      HolbuildStatus.cache_trace
        ("remote cache zstd " ^ redact_userinfo url ^ " " ^
         (if ok then completed_line (#output result) else "failed: " ^ #output result));
      ok
    end
  else
    HolbuildSpawn.succeeded (run "zstd" ["-q", "-f", "-T0", "-o", dst, src])

fun zstd_content_headers size =
  ["Content-Encoding: zstd", "X-Digest-SizeBytes: " ^ size]

val restore_warning_emitted = ref false
val restore_warning_mutex = Mutex.mutex ()

fun warn_restore_once message =
  let
    val _ = Mutex.lock restore_warning_mutex
    val emit = not (!restore_warning_emitted)
    val _ = restore_warning_emitted := true
    val _ = Mutex.unlock restore_warning_mutex
  in
    if emit then
      (TextIO.output (TextIO.stdErr, "holbuild: warning: remote cache restore failed: " ^ message ^ "\n");
       TextIO.flushOut TextIO.stdErr)
    else ()
  end

(* Requests go through libcurl when HolbuildRemoteCacheConfig could set it
   up, and otherwise through the curl command, which prints its own error
   message. *)
fun cli_status timeout_seconds options url =
  let
    val result =
      run "curl" (["-q", "-sS", "-L", "--connect-timeout", Int.toString HolbuildHttp.connect_timeout_seconds,
                   "--max-time", Int.toString timeout_seconds] @
                  curl_config_args () @ options @ ["-w", "%{http_code}", url])
  in
    case (HolbuildSpawn.succeeded result, Int.fromString (first_token (#output result))) of
        (true, SOME http_code) => HolbuildHttp.Response http_code
      | _ => HolbuildHttp.Failed "the curl command failed"
  end

fun get_status timeout_seconds {url, dst} =
  if HolbuildRemoteCacheConfig.uses_libcurl () then
    HolbuildHttp.get {url = url, dst = dst, timeout = timeout_seconds}
  else
    (* --compressed advertises curl-supported response encodings, including zstd
       when this curl build has zstd support, and streams decompressed bytes to dst. *)
    cli_status timeout_seconds ["--compressed", "-o", dst] url

fun put_status timeout_seconds headers {url, src} =
  if HolbuildRemoteCacheConfig.uses_libcurl () then
    HolbuildHttp.put {url = url, src = src, headers = headers, timeout = timeout_seconds}
  else
    cli_status timeout_seconds
               (List.concat (map (fn header => ["-H", header]) headers) @ ["-T", src, "-o", "/dev/null"]) url

(* Under HOLBUILD_CACHE_TRACE, one line per request: its wall time, then the
   HTTP status and the size of the file received or sent. *)
fun traced method url path request =
  if not (HolbuildStatus.cache_trace_enabled ()) then request ()
  else
    let
      val timer = Timer.startRealTimer ()
      val result = request ()
      val wall = LargeInt.toString (Time.toMilliseconds (Timer.checkRealTimer timer))
      val outcome =
        case result of
            HolbuildHttp.Failed message => "failed: " ^ message
          | HolbuildHttp.Response code =>
              Int.toString code ^ " bytes=" ^
              (if path_exists path then Position.toString (FS.fileSize path) else "0")
    in
      HolbuildStatus.cache_trace
        ("remote cache " ^ method ^ " " ^ redact_userinfo url ^ " wall=" ^ wall ^ "ms " ^ outcome);
      result
    end

fun curl_get_with_timeout timeout_seconds (request as {url, dst}) =
  let val display_url = redact_userinfo url
  in
    case traced "GET" url dst (fn () => get_status timeout_seconds request) of
        HolbuildHttp.Failed message =>
          HolbuildCacheBackend.Corrupt ("GET " ^ display_url ^ " failed: " ^ message)
      | HolbuildHttp.Response 200 => HolbuildCacheBackend.Hit
      | HolbuildHttp.Response 404 => HolbuildCacheBackend.Miss
      | HolbuildHttp.Response code =>
          HolbuildCacheBackend.Corrupt ("HTTP " ^ Int.toString code ^ " from " ^ display_url)
  end
  handle e => (HolbuildCacheBackend.Corrupt (General.exnMessage e))

fun curl_get request = curl_get_with_timeout curl_max_time_seconds request

fun successful_put_code code =
  code = 200 orelse code = 201 orelse code = 204

fun curl_put_with_headers_timeout timeout_seconds headers (request as {url, src}) =
  let val display_url = redact_userinfo url
  in
    case traced "PUT" url src (fn () => put_status timeout_seconds headers request) of
        HolbuildHttp.Failed message =>
          HolbuildCacheBackend.Conflict ("PUT " ^ display_url ^ " failed: " ^ message)
      | HolbuildHttp.Response code =>
          if successful_put_code code then HolbuildCacheBackend.Published
          else HolbuildCacheBackend.Conflict ("HTTP " ^ Int.toString code ^ " from " ^ display_url)
  end
  handle e => (HolbuildCacheBackend.Conflict (General.exnMessage e))

fun curl_put_with_headers headers request =
  curl_put_with_headers_timeout curl_max_time_seconds headers request

fun curl_put request = curl_put_with_headers [] request

fun curl_put_zstd_with_timeout timeout_seconds {url, src, size} =
  let val compressed = temp_path "zstd-put"
  in
    if zstd_compress url src compressed then
      curl_put_with_headers_timeout timeout_seconds (zstd_content_headers size)
        {url = url, src = compressed}
      before remove_file compressed
    else
      remove_file_before
        (curl_put_with_headers_timeout timeout_seconds [] {url = url, src = src})
        compressed
  end
  handle e => HolbuildCacheBackend.Conflict (General.exnMessage e)

fun curl_put_zstd request =
  curl_put_zstd_with_timeout curl_max_time_seconds request

fun remote_action_key key =
  HolbuildHash.string_sha256 ("holbuild-remote-ac-v1\n" ^ key ^ "\n")

fun action_url cache key = base_url cache ^ "/ac/" ^ remote_action_key key
fun cas_url cache sha256 = base_url cache ^ "/cas/" ^ sha256

fun lookup_blob cache sha1 =
  Redblackmap.peek (!(blob_map cache), sha1)

fun remember_blob cache entry =
  let
    val blobs = blob_map cache
    val {sha1, ...} = entry
  in
    blobs := Redblackmap.insert (!blobs, sha1, entry)
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
      | HolbuildCacheBackend.Corrupt message =>
          (cleanup (); warn_restore_once message; NONE)
  end
  handle _ => NONE

fun action_metadata cache key text =
  let
    val refs = HolbuildCacheTransfer.unique_blobs text
    val known_blobs = List.mapPartial (lookup_blob cache) refs
    val _ =
      if length refs = length known_blobs then ()
      else raise Error ("remote action is missing published blob metadata for " ^ key)
  in
    metadata_text text known_blobs
  end

fun publish_action_metadata cache key metadata =
  let
    val tmp = temp_path "action-put"
    val url = action_url cache key
    fun cleanup () = remove_file tmp
    fun publish () =
      ((write_text tmp metadata; curl_put {url = url, src = tmp} before cleanup ())
       handle e => (cleanup (); raise e))
  in
    publish ()
  end

fun publish_action cache {key, text} =
  publish_action_metadata cache key (action_metadata cache key text)
  handle e => HolbuildCacheBackend.Conflict (General.exnMessage e)

(* The HTTP write is unconditional.  Callers must authorize replacement from
   action-kind-specific semantics before using this operation. *)
fun replace_action_unconditionally cache request = publish_action cache request

fun put_action cache policy {key, text} =
  let
    val url = action_url cache key
    val metadata = action_metadata cache key text
  in
    case get_action cache key of
        SOME existing =>
          (case policy of
               HolbuildCacheBackend.PutIfAbsent => HolbuildCacheBackend.Conflict url
             | HolbuildCacheBackend.PutIfAbsentOrSame =>
                 if existing = text then HolbuildCacheBackend.AlreadyPresent
                 else HolbuildCacheBackend.Conflict url)
      | NONE => publish_action_metadata cache key metadata
  end
  handle e => HolbuildCacheBackend.Conflict (General.exnMessage e)

fun has_blob cache sha1 = Option.isSome (lookup_blob cache sha1)

fun verify_downloaded_blob path ({sha1, sha256, size} : blob_entry) =
  if Position.toString (FS.fileSize path) <> size then
    HolbuildCacheBackend.Corrupt ("downloaded blob size mismatch: " ^ sha1)
  else if HolbuildHash.file_sha1 path <> sha1 then
    HolbuildCacheBackend.Corrupt ("downloaded blob SHA1 mismatch: " ^ sha1)
  else if HolbuildHash.file_sha256 path <> sha256 then
    HolbuildCacheBackend.Corrupt ("downloaded blob SHA256 mismatch: " ^ sha256)
  else
    HolbuildCacheBackend.Hit

fun fetch_blob_with_timeout timeout_seconds cache {hash, dst} =
  case lookup_blob cache hash of
      NONE => HolbuildCacheBackend.Miss
    | SOME entry =>
        let
          val {sha256, ...} = entry
          val result = curl_get_with_timeout timeout_seconds {url = cas_url cache sha256, dst = dst}
        in
          case result of
              HolbuildCacheBackend.Hit => verify_downloaded_blob dst entry
            | HolbuildCacheBackend.Corrupt message =>
                (warn_restore_once message; result)
            | other => other
        end
        handle e => HolbuildCacheBackend.Corrupt (General.exnMessage e)

fun fetch_blob cache request =
  fetch_blob_with_timeout curl_max_time_seconds cache request

fun fetch_toolchain_blob cache request =
  fetch_blob_with_timeout toolchain_curl_max_time_seconds cache request

fun publish_blob_with_timeout timeout_seconds cache {hash, src} =
  let
    val sha1 = HolbuildHash.file_sha1 src
    val sha256 = HolbuildHash.file_sha256 src
    val size = Position.toString (FS.fileSize src)
    val _ =
      if sha1 = hash then ()
      else raise Error ("blob SHA1 mismatch: expected " ^ hash ^ " got " ^ sha1)
    val result =
      curl_put_zstd_with_timeout timeout_seconds
        {url = cas_url cache sha256, src = src, size = size}
  in
    case result of
        HolbuildCacheBackend.Published => (remember_blob cache {sha1 = hash, sha256 = sha256, size = size}; result)
      | HolbuildCacheBackend.AlreadyPresent => (remember_blob cache {sha1 = hash, sha256 = sha256, size = size}; result)
      | other => other
  end
  handle e => HolbuildCacheBackend.Conflict (General.exnMessage e)

fun publish_blob cache request =
  publish_blob_with_timeout curl_max_time_seconds cache request

fun publish_toolchain_blob cache request =
  publish_blob_with_timeout toolchain_curl_max_time_seconds cache request

end
