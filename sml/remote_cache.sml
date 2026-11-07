structure HolbuildRemoteCache =
struct

structure Path = OS.Path
structure FS = OS.FileSys

exception Error of string

(* The remote cache gave no usable answer: no answer at all, 429, 5xx, or
   the breaker below holds requests back.  Raised only when fail_closed. *)
exception Unavailable of string

(* Set by exec-action, whose result counts only once the remote cache holds
   it: a request the cache doesn't answer raises Unavailable rather than
   reading as a miss, a skipped write or a conflict.  A build leaves it off
   and goes on without the remote cache. *)
val fail_closed = ref false

type blob_entry = {sha256 : string, size : string}
type blob_map = (string, blob_entry) Redblackmap.dict
datatype t = RemoteCache of {urls : string list, blobs : blob_map ref}

val metadata_header = "holbuild-remote-cache-action-v2"
val manifest_marker = "manifest-text-v1\n"

(* A request fails once it has moved no data for this long; one that keeps
   moving data, such as a heap upload sharing a busy server, goes on up to
   HolbuildHttp.max_transfer_seconds. *)
val stall_timeout_seconds = 30

fun empty_blob_map () = Redblackmap.mkDict String.compare

fun remote url =
  RemoteCache {urls = HolbuildRemoteCacheConfig.urls url, blobs = ref (empty_blob_map ())}

fun base_url (RemoteCache {urls, ...}) = String.concatWith "," urls

(* Authentication does not change node identity; full URLs are kept for requests. *)
fun ranked_urls (RemoteCache {urls, ...}) digest =
  let
    fun score url =
      let val identity = HolbuildRemoteCacheConfig.node_identity url
      in ((HolbuildHash.string_sha256 (identity ^ ":" ^ digest), identity), url) end
    fun compare (((a, u), _), ((b, v), _)) =
      case String.compare (b, a) of EQUAL => String.compare (u, v) | order => order
  in
    case urls of
        [_] => urls
      | _ => map #2 (Redblackset.listItems (Redblackset.fromList compare (map score urls)))
  end

fun request_urls cache kind digest =
  let val ranked = ranked_urls cache digest
  in map (fn url => url ^ "/" ^ kind ^ "/" ^ digest)
       (List.take (ranked, Int.min (2, length ranked)))
  end

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

val redact_userinfo = HolbuildRemoteCacheConfig.replace_userinfo "<redacted>@"

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
fun cli_status options url =
  let
    val _ = HolbuildOffline.require_online "contact the remote cache"
    val result =
      run "curl" (["-q", "-sS", "-L", "--connect-timeout", Int.toString HolbuildHttp.connect_timeout_seconds,
                   "--speed-limit", "1", "--speed-time", Int.toString stall_timeout_seconds,
                   "--max-time", Int.toString HolbuildHttp.max_transfer_seconds] @
                  curl_config_args () @ options @ ["-w", "%{http_code}", url])
  in
    case (HolbuildSpawn.succeeded result, Int.fromString (first_token (#output result))) of
        (true, SOME http_code) => HolbuildHttp.Response http_code
      | _ => HolbuildHttp.Failed "the curl command failed"
  end

fun get_status {url, dst} =
  if HolbuildRemoteCacheConfig.uses_libcurl () then
    HolbuildHttp.get {url = url, dst = dst, timeout = stall_timeout_seconds}
  else
    (* --compressed advertises curl-supported response encodings, including zstd
       when this curl build has zstd support, and streams decompressed bytes to dst. *)
    cli_status ["--compressed", "-o", dst] url

fun head_status url =
  if HolbuildRemoteCacheConfig.uses_libcurl () then
    HolbuildHttp.head {url = url, timeout = stall_timeout_seconds}
  else
    cli_status ["-I", "-o", "/dev/null"] url

fun put_status headers {url, src} =
  if HolbuildRemoteCacheConfig.uses_libcurl () then
    HolbuildHttp.put {url = url, src = src, headers = headers, timeout = stall_timeout_seconds}
  else
    cli_status (List.concat (map (fn header => ["-H", header]) headers) @ ["-T", src, "-o", "/dev/null"]) url

(* No HTTP response counts as a transport failure; any HTTP status resets
   the count. After tripping, only one request probes each cooldown. *)
val max_consecutive_transport_failures = 3
val transport_cooldown = Time.fromSeconds 60
val transport_failures = ref 0
val retry_after = ref Time.zeroTime
val probe_in_flight = ref false
val transport_generation = ref 0
val transport_mutex = Mutex.mutex ()

(* A check never reserves the probe: publication checks this before send. *)
fun disabled_unlocked () =
  !transport_failures >= max_consecutive_transport_failures andalso
  (!probe_in_flight orelse Time.< (Time.now (), !retry_after))

val disabled_message = "the remote cache is disabled after repeated failures"

(* Every caller skips a write when this holds; with fail_closed it raises. *)
fun disabled () =
  let
    val _ = Mutex.lock transport_mutex
    val result = disabled_unlocked ()
    val _ = Mutex.unlock transport_mutex
  in
    if result andalso !fail_closed then raise Unavailable disabled_message else result
  end

(* Advisory requests leave recovery probes to send. *)
fun tripped () =
  (Mutex.lock transport_mutex;
   !transport_failures >= max_consecutive_transport_failures
   before Mutex.unlock transport_mutex)

fun begin_request () =
  let
    val _ = Mutex.lock transport_mutex
    val admission =
      if disabled_unlocked () then NONE
      else
        let
          val probe = !transport_failures >= max_consecutive_transport_failures
          val _ = if probe then probe_in_flight := true else ()
        in SOME (!transport_generation, probe) end
  in admission before Mutex.unlock transport_mutex end

fun record_transport_outcome (generation, probe) result =
  let
    val _ = Mutex.lock transport_mutex
    val current = generation = !transport_generation
    val _ =
      if not current then ()
      else
        case result of
            HolbuildHttp.Failed _ =>
              if probe then () else transport_failures := !transport_failures + 1
          | HolbuildHttp.Response _ => transport_failures := 0
    val tripped = current andalso
      !transport_failures >= max_consecutive_transport_failures
    val recovered = current andalso probe andalso not tripped
    val _ = if current then probe_in_flight := false else ()
    (* Ignore completions from requests admitted before this trip. *)
    val _ = if tripped then
      (retry_after := Time.+ (Time.now (), transport_cooldown);
       transport_generation := !transport_generation + 1)
      else ()
    val _ = Mutex.unlock transport_mutex
  in
    case (tripped, recovered, result) of
        (true, _, HolbuildHttp.Failed message) =>
          (TextIO.output (TextIO.stdErr,
             "holbuild: warning: remote cache disabled for 60 seconds after " ^
             (if probe then "a recovery probe failed"
              else Int.toString max_consecutive_transport_failures ^
                   " requests in a row failed") ^
             "; the last: " ^ message ^ "\n");
           TextIO.flushOut TextIO.stdErr)
      | (_, true, _) =>
          (TextIO.output (TextIO.stdErr, "holbuild: remote cache available again\n");
           TextIO.flushOut TextIO.stdErr)
      | _ => ()
  end

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

fun require_answer method url result =
  let val request = method ^ " " ^ redact_userinfo url
  in
    case result of
        HolbuildHttp.Failed message =>
          raise Unavailable ("no answer from the remote cache to " ^ request ^ ": " ^ message)
      | HolbuildHttp.Response code =>
          if code = 429 orelse code >= 500 then
            raise Unavailable ("remote cache server error: HTTP " ^ Int.toString code ^ " for " ^ request)
          else ()
  end

fun transient (HolbuildHttp.Failed _) = true
  | transient (HolbuildHttp.Response code) = code = 429 orelse (code >= 500 andalso code < 600)

(* The breaker observes the whole request: a dead primary must not disable a healthy backup. *)
fun routed_status method urls path request =
  let
    val primary = hd urls
    val result = traced method primary path (fn () => request primary)
    val retry = transient result orelse
      ((method = "GET" orelse method = "HEAD") andalso result = HolbuildHttp.Response 404)
  in
    case tl urls of
        backup :: _ =>
          if retry then
            let val next = traced method backup path (fn () => request backup)
            in
              if result = HolbuildHttp.Response 404 andalso transient next then (primary, result)
              else (backup, next)
            end
          else (primary, result)
      | [] => (primary, result)
  end

(* NONE when the remote cache is disabled, without a request.  With
   fail_closed, raises Unavailable instead, and for no answer, 429 or 5xx. *)
fun send_result method url request =
  case begin_request () of
      NONE =>
        if !fail_closed then
          raise Unavailable (disabled_message ^ "; not sent: " ^ method ^ " " ^ redact_userinfo url)
        else NONE
    | SOME admission =>
        let
          val (answered_url, result) = request ()
            handle e =>
              ((if #2 admission then
                  record_transport_outcome admission (HolbuildHttp.Failed (General.exnMessage e))
                else ());
               raise e)
        in
          record_transport_outcome admission result;
          if !fail_closed then require_answer method answered_url result else ();
          SOME (answered_url, result)
        end

fun send method url path request =
  Option.map #2 (send_result method url (fn () => (url, traced method url path request)))

fun send_urls method urls path request =
  send_result method (hd urls) (fn () => routed_status method urls path request)

fun curl_get_urls {urls, dst} =
  (case send_urls "GET" urls dst (fn url => get_status {url = url, dst = dst}) of
        NONE => HolbuildCacheBackend.Miss
      | SOME (url, HolbuildHttp.Failed message) =>
          HolbuildCacheBackend.Corrupt ("GET " ^ redact_userinfo url ^ " failed: " ^ message)
      | SOME (_, HolbuildHttp.Response 200) => HolbuildCacheBackend.Hit
      | SOME (_, HolbuildHttp.Response 404) => HolbuildCacheBackend.Miss
      | SOME (url, HolbuildHttp.Response code) =>
          HolbuildCacheBackend.Corrupt ("HTTP " ^ Int.toString code ^ " from " ^ redact_userinfo url))
  handle e as Unavailable _ => raise e
       | e => (HolbuildCacheBackend.Corrupt (General.exnMessage e))

fun curl_get {url, dst} = curl_get_urls {urls = [url], dst = dst}

fun successful_put_code code =
  code = 200 orelse code = 201 orelse code = 204

fun curl_put_urls headers {urls, src} =
  (case send_urls "PUT" urls src (fn url => put_status headers {url = url, src = src}) of
        NONE => HolbuildCacheBackend.Skipped
      | SOME (url, HolbuildHttp.Failed message) =>
          HolbuildCacheBackend.Conflict ("PUT " ^ redact_userinfo url ^ " failed: " ^ message)
      | SOME (url, HolbuildHttp.Response code) =>
          if successful_put_code code then HolbuildCacheBackend.Published
          else HolbuildCacheBackend.Conflict ("HTTP " ^ Int.toString code ^ " from " ^ redact_userinfo url))
  handle e as Unavailable _ => raise e
       | e => (HolbuildCacheBackend.Conflict (General.exnMessage e))

fun curl_put_with_headers headers {url, src} = curl_put_urls headers {urls = [url], src = src}

fun curl_put request = curl_put_with_headers [] request

fun curl_put_zstd {urls, src, size} =
  let
    val compressed = temp_path "zstd-put"
    fun put () =
      if zstd_compress (hd urls) src compressed then
        curl_put_urls (zstd_content_headers size)
          {urls = urls, src = compressed}
      else
        curl_put_urls [] {urls = urls, src = src}
  in
    if disabled () then HolbuildCacheBackend.Skipped
    else
      (* Unavailable passes through the PUT; the copy goes either way. *)
      remove_file_before (put () handle e => (remove_file compressed; raise e)) compressed
  end
  handle e as Unavailable _ => raise e
       | e => HolbuildCacheBackend.Conflict (General.exnMessage e)

fun remote_action_key key =
  HolbuildHash.string_sha256 ("holbuild-remote-ac-v1\n" ^ key ^ "\n")

fun action_urls cache key = request_urls cache "ac" (remote_action_key key)
fun cas_urls cache sha256 = request_urls cache "cas" sha256

fun lookup_blob cache sha256 =
  Redblackmap.peek (!(blob_map cache), sha256)

(* A worker's transfer threads share one handle. *)
val blobs_mutex = Mutex.mutex ()

fun remember_blob cache entry =
  let
    val blobs = blob_map cache
    val {sha256, ...} = entry
  in
    Mutex.lock blobs_mutex;
    blobs := Redblackmap.insert (!blobs, sha256, entry);
    Mutex.unlock blobs_mutex
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
      ["blob", sha256, size] =>
        if HolbuildHash.valid_sha256 sha256 then
          SOME {sha256 = sha256, size = size}
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
     map (fn {sha256, size} => "blob " ^ sha256 ^ " " ^ size) blobs @
     [manifest_marker ^ manifest])

fun get_action cache key =
  let
    val tmp = temp_path "action"
    fun cleanup () = remove_file tmp
  in
    case curl_get_urls {urls = action_urls cache key, dst = tmp} of
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
  handle e as Unavailable _ => raise e
       | _ => NONE

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
    val urls = action_urls cache key
    fun cleanup () = remove_file tmp
    fun publish () =
      ((write_text tmp metadata; curl_put_urls [] {urls = urls, src = tmp} before cleanup ())
       handle e => (cleanup (); raise e))
  in
    publish ()
  end

(* Checked first, as the blobs an action lists go unpublished while the
   remote cache is disabled. *)
fun publish_action cache {key, text} =
  if disabled () then HolbuildCacheBackend.Skipped
  else publish_action_metadata cache key (action_metadata cache key text)
  handle e as Unavailable _ => raise e
       | e => HolbuildCacheBackend.Conflict (General.exnMessage e)

(* The HTTP write is unconditional.  Callers must authorize replacement from
   action-kind-specific semantics before using this operation. *)
fun replace_action_unconditionally cache request = publish_action cache request

fun put_action cache policy {key, text} =
  if disabled () then HolbuildCacheBackend.Skipped
  else
    let
      val urls = action_urls cache key
      val metadata = action_metadata cache key text
    in
      case get_action cache key of
          SOME existing =>
            (case policy of
                 HolbuildCacheBackend.PutIfAbsent => HolbuildCacheBackend.Conflict (hd urls)
               | HolbuildCacheBackend.PutIfAbsentOrSame =>
                   if existing = text then HolbuildCacheBackend.AlreadyPresent
                   else HolbuildCacheBackend.Conflict (hd urls))
        | NONE => publish_action_metadata cache key metadata
    end
  handle e as Unavailable _ => raise e
       | e => HolbuildCacheBackend.Conflict (General.exnMessage e)

fun has_blob cache sha256 = Option.isSome (lookup_blob cache sha256)

(* Whether the remote cache answers for the blob.  An action entry can
   outlive its blobs (an object store expires each object on its own), so
   an entry whose blobs are gone isn't usable.  Only a 404 says the blob is
   gone; no answer, or another status, says nothing about it. *)
fun blob_present cache sha256 =
  let val urls = cas_urls cache sha256
  in
    case send_urls "HEAD" urls "" head_status of
        SOME (_, HolbuildHttp.Response 404) => false
      | _ => true
  end
  handle e as Unavailable _ => raise e
       | _ => true

(* An optional upload probe must not disable PUTs when a server drops HEADs.
   Leave the breaker to the normal cache requests, and skip only confirmed hits. *)
fun blob_confirmed_present cache sha256 =
  if tripped () then false
  else
    let val urls = cas_urls cache sha256
    in #2 (routed_status "HEAD" urls "" head_status) = HolbuildHttp.Response 200 end
    handle _ => false

fun verify_downloaded_blob path ({sha256, size} : blob_entry) =
  if Position.toString (FS.fileSize path) <> size then
    HolbuildCacheBackend.Corrupt ("downloaded blob size mismatch: " ^ sha256)
  else if HolbuildHash.file_sha256 path <> sha256 then
    HolbuildCacheBackend.Corrupt ("downloaded blob SHA256 mismatch: " ^ sha256)
  else
    HolbuildCacheBackend.Hit

fun fetch_blob cache {hash, dst} =
  case lookup_blob cache hash of
      NONE => HolbuildCacheBackend.Miss
    | SOME entry =>
        let
          val {sha256, ...} = entry
          val result = curl_get_urls {urls = cas_urls cache sha256, dst = dst}
        in
          case result of
              HolbuildCacheBackend.Hit => verify_downloaded_blob dst entry
            | HolbuildCacheBackend.Corrupt message =>
                (warn_restore_once message; result)
            | other => other
        end
        handle e as Unavailable _ => raise e
             | e => HolbuildCacheBackend.Corrupt (General.exnMessage e)

(* Fetches a blob by its SHA-256 alone, without an action entry that lists
   it, as a remote worker fetches its spec and sources. *)
fun fetch_unlisted_blob cache {hash, dst} =
  (case curl_get_urls {urls = cas_urls cache hash, dst = dst} of
       HolbuildCacheBackend.Hit =>
         if HolbuildHash.file_sha256 dst = hash then HolbuildCacheBackend.Hit
         else HolbuildCacheBackend.Corrupt ("downloaded blob SHA256 mismatch: " ^ hash)
     | other => other)
  handle e as Unavailable _ => raise e
       | e => HolbuildCacheBackend.Corrupt (General.exnMessage e)

fun put_blob cache {hash, src} =
  let
    val size = Position.toString (FS.fileSize src)
    val result =
      curl_put_zstd {urls = cas_urls cache hash, src = src, size = size}
  in
    case result of
        HolbuildCacheBackend.Published => (remember_blob cache {sha256 = hash, size = size}; result)
      | HolbuildCacheBackend.AlreadyPresent => (remember_blob cache {sha256 = hash, size = size}; result)
      | other => other
  end
  handle e as Unavailable _ => raise e
       | e => HolbuildCacheBackend.Conflict (General.exnMessage e)

fun publish_blob cache {hash, src} =
  let val sha256 = HolbuildHash.file_sha256 src
  in
    if sha256 = hash then put_blob cache {hash = hash, src = src}
    else HolbuildCacheBackend.Conflict ("blob SHA256 mismatch: expected " ^ hash ^ " got " ^ sha256)
  end
  handle e as Unavailable _ => raise e
       | e => HolbuildCacheBackend.Conflict (General.exnMessage e)

(* For a src the caller hashed in this process and has not changed since:
   the upload skips hashing it again. *)
val publish_hashed_blob = put_blob

end
