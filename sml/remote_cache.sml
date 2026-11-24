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

(* A node whose disk lacks a blob fetches it from the shared store, checks it
   and stores it before it sends a byte; for a heap of hundreds of MB that
   can take over a minute, and giving up meanwhile only starts the same work
   on the next node.  So a GET of a blob this large waits longer for data. *)
val large_blob_bytes = 64 * 1024 * 1024
val large_blob_stall_timeout_seconds = 120

fun empty_blob_map () = Redblackmap.mkDict String.compare

fun remote url =
  RemoteCache {urls = HolbuildRemoteCacheConfig.urls url, blobs = ref (empty_blob_map ())}

fun base_url (RemoteCache {urls, ...}) = String.concatWith "," urls

(* Authentication does not change node identity; full URLs are kept for requests.
   Preferred nodes come first, each group in rendezvous order. *)
fun ranked_urls (RemoteCache {urls, ...}) digest =
  let
    val urls = HolbuildCacheDiscovery.urls urls
    fun score url =
      let val identity = HolbuildRemoteCacheConfig.node_identity url
      in ((HolbuildHash.string_sha256 (identity ^ ":" ^ digest), identity), url) end
    fun compare (((a, u), _), ((b, v), _)) =
      case String.compare (b, a) of EQUAL => String.compare (u, v) | order => order
    val preferred = HolbuildRemoteCacheConfig.preferred_identities ()
    fun is_preferred url =
      List.exists (fn identity => identity = HolbuildRemoteCacheConfig.node_identity url) preferred
  in
    case urls of
        [_] => urls
      | _ =>
          let
            val ranked = map #2 (Redblackset.listItems (Redblackset.fromList compare (map score urls)))
            val (first, rest) = List.partition is_preferred ranked
          in first @ rest end
  end

fun request_urls cache kind digest =
  let val ranked = ranked_urls cache digest
  in map (fn url => url ^ "/" ^ kind ^ "/" ^ digest) ranked end

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

(* One thread per blob: the transfer pools already compress many blobs at
   once, and -T0 would start a thread per host core in each, whatever the
   process's CPU allowance.  Level 1 costs much less CPU than the default
   level 3 for about the same ratio on build artifacts.  Under
   HOLBUILD_CACHE_TRACE, zstd runs verbosely so its wall time and CPU load
   show how it competes with the build. *)
fun zstd_compress url src dst =
  if HolbuildStatus.cache_trace_enabled () then
    let
      val result = HolbuildSpawn.run {program = "zstd", args = ["-1", "-vv", "-f", "-T1", "-o", dst, src],
                                      stderr = HolbuildSpawn.Merge}
      val ok = HolbuildSpawn.succeeded result
    in
      HolbuildStatus.cache_trace
        ("remote cache zstd " ^ redact_userinfo url ^ " " ^
         (if ok then completed_line (#output result) else "failed: " ^ #output result));
      ok
    end
  else
    HolbuildSpawn.succeeded (run "zstd" ["-1", "-q", "-f", "-T1", "-o", dst, src])

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
fun cli_status timeout options url =
  let
    val _ = HolbuildOffline.require_online "contact the remote cache"
    val result =
      run "curl" (["-q", "-sS", "-L", "--connect-timeout", Int.toString HolbuildHttp.connect_timeout_seconds,
                   "--speed-limit", "1", "--speed-time", Int.toString timeout,
                   "--max-time", Int.toString HolbuildHttp.max_transfer_seconds] @
                  curl_config_args () @ options @ ["-w", "%{http_code}", url])
  in
    case (HolbuildSpawn.succeeded result, Int.fromString (first_token (#output result))) of
        (true, SOME http_code) => HolbuildHttp.Response http_code
      | _ => HolbuildHttp.Failed "the curl command failed"
  end

fun get_status_with_headers headers {url, dst, timeout} =
  if HolbuildRemoteCacheConfig.uses_libcurl () then
    HolbuildHttp.get_with_headers {url = url, dst = dst, headers = headers, timeout = timeout}
  else
    (* --compressed advertises curl-supported response encodings, including zstd
       when this curl build has zstd support, and streams decompressed bytes to dst. *)
    cli_status timeout (["--compressed", "-o", dst] @ List.concat (map (fn h => ["-H", h]) headers)) url

fun get_status request = get_status_with_headers [] request

(* Blob downloads take the body still zstd-encoded and decode it here on
   several threads (HolbuildZstd), since libcurl decodes on the one thread
   running its transfers.  Without libcurl or libzstd, or with a body
   HolbuildZstd can't decode, the blob is fetched as get_status does.  Under
   HOLBUILD_CACHE_TRACE, a line says which way each blob was decoded. *)
val decode_threads = 4

fun trace_decode url how =
  HolbuildStatus.cache_trace ("remote cache decode " ^ redact_userinfo url ^ " " ^ how)

fun get_status_parallel_decode (request as {url, dst, timeout}) =
  if not (HolbuildRemoteCacheConfig.uses_libcurl () andalso HolbuildZstd.available ()) then
    get_status request
  else
    let
      val encoded = HolbuildTempPath.near dst ".zstd-get"
      fun remove () = FS.remove encoded handle OS.SysErr _ => ()
      val (result, encoding) =
        HolbuildHttp.get_zstd {url = url, dst = encoded, timeout = timeout}
        handle e => (remove (); raise e)
    in
      case (result, encoding) of
          (HolbuildHttp.Response 200, HolbuildHttp.Zstd) =>
            ((HolbuildZstd.decode_file {src = encoded, dst = dst, threads = decode_threads};
              remove ();
              trace_decode url ("zstd threads=" ^ Int.toString decode_threads);
              result)
             handle HolbuildZstd.Error message =>
                      (remove (); trace_decode url ("fallback: " ^ message);
                       get_status request)
                  | e => (remove (); raise e))
        | (HolbuildHttp.Response 200, HolbuildHttp.Identity) =>
            (FS.rename {old = encoded, new = dst}; trace_decode url "identity"; result)
        | (HolbuildHttp.Response 200, HolbuildHttp.OtherEncoding) =>
            (remove (); trace_decode url "fallback: another encoding";
             get_status request)
        | _ => (remove (); result)
    end

fun head_status url =
  if HolbuildRemoteCacheConfig.uses_libcurl () then
    HolbuildHttp.head {url = url, timeout = stall_timeout_seconds}
  else
    cli_status stall_timeout_seconds ["-I", "--ignore-content-length", "-o", "/dev/null"] url

fun put_status_within timeout headers {url, src} =
  if HolbuildRemoteCacheConfig.uses_libcurl () then
    HolbuildHttp.put {url = url, src = src, headers = headers, timeout = timeout}
  else
    cli_status timeout (List.concat (map (fn header => ["-H", header]) headers) @ ["-T", src, "-o", "/dev/null"]) url

fun put_status headers request = put_status_within stall_timeout_seconds headers request

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

(* Reads made inside `required f`, on its thread, are for entries that must be
   there, such as an action's inputs or what a write just put: they ask every
   node before a miss, as the entry may be on another node only, and a node
   that failed may be the one holding it, so a read that found it nowhere but
   saw a node fail gives that failure, not a 404.  Any other read ends at the
   first 404 and takes a 404 beside a failure as a miss, so that a lookup
   before building or publishing doesn't stop on one dead node.  Per thread, as the hydrate path between the
   caller and the read doesn't carry the caller's intent. *)
val required_tag : bool Universal.tag = Universal.tag ()

fun reads_required () = Option.getOpt (Thread.getLocal required_tag, false)

fun required f =
  let
    val outer = reads_required ()
    fun restore () = Thread.setLocal (required_tag, outer)
  in
    Thread.setLocal (required_tag, true);
    (f () before restore ()) handle e => (restore (); raise e)
  end

(* Reads of action entries made inside `revalidating f`, on its thread, ask
   the cache to check its copy with its origin first (Cache-Control:
   no-cache).  An action key doesn't fix its bytes, so a cache in front of a
   shared store (a per-host bazel-remote over S3, say) can keep serving an
   entry the store has since replaced; a caller that found an entry that
   doesn't fit its parents asks for the store's.  Per thread, like
   `required`. *)
val revalidating_tag : bool Universal.tag = Universal.tag ()

fun reads_revalidate () = Option.getOpt (Thread.getLocal revalidating_tag, false)

fun revalidating f =
  let
    val outer = reads_revalidate ()
    fun restore () = Thread.setLocal (revalidating_tag, outer)
  in
    Thread.setLocal (revalidating_tag, true);
    (f () before restore ()) handle e => (restore (); raise e)
  end

(* A read's probes past its first nodes run on the caller's thread and on
   helper threads, at most probe_helpers of them in the whole process, so
   callers that run many lookups at once don't multiply threads,
   connections or curl processes. *)
val probe_helpers = 16
val free_helpers = ref probe_helpers
val helpers_mutex = Mutex.mutex ()

fun with_mutex mutex f =
  (Mutex.lock mutex; f () before Mutex.unlock mutex)
  handle e => (Mutex.unlock mutex; raise e)

(* The result of probe on each of urls, in order.  The caller probes too, so
   with every helper busy this is a plain serial walk. *)
fun probe_all probe urls =
  let
    val nodes = Vector.fromList urls
    val count = Vector.length nodes
    val results = Array.array (count, HolbuildHttp.Failed "not probed")
    val mutex = Mutex.mutex ()
    val finished = ConditionVar.conditionVar ()
    val next = ref 0
    val running = ref 0
    fun take () =
      with_mutex mutex (fn () => if !next < count then SOME (!next before next := !next + 1) else NONE)
    fun work () =
      case take () of
          NONE => ()
        | SOME i =>
            (Array.update (results, i, probe (Vector.sub (nodes, i))
                                         handle e => HolbuildHttp.Failed (General.exnMessage e));
             work ())
    fun release slots = with_mutex helpers_mutex (fn () => free_helpers := !free_helpers + slots)
    fun stopped () = with_mutex mutex (fn () => (running := !running - 1; ConditionVar.broadcast finished))
    fun helper () = (work (); release 1; stopped ())
    fun start 0 = ()
      | start slots =
          (with_mutex mutex (fn () => running := !running + 1);
           ignore (Thread.fork (helper, []));
           start (slots - 1))
          handle _ => (release slots; stopped ())
    val slots = with_mutex helpers_mutex (fn () =>
      let val slots = Int.min (count - 1, !free_helpers)
      in free_helpers := !free_helpers - slots; slots end)
    fun wait () = if !running > 0 then (ConditionVar.wait (finished, mutex); wait ()) else ()
  in
    start slots;
    work ();
    with_mutex mutex wait;
    Array.foldr (op ::) [] results
  end

(* The breaker observes the whole request: a dead primary must not disable a healthy backup.
   A write goes past the first two nodes only while none of them answered at all
   (a member whose name doesn't resolve yet, say), and stops at the first answer.
   Every node serves what the shared backing store holds, and a node writes an
   entry there shortly after it answers the PUT, so until then only the
   writer's node holds it.  A read goes past a node that failed and ends at
   the first 404: it misses only an entry another node took moments ago, which
   a build or a submission then makes again.  A required read (`required`),
   of an entry that must be there, and a read that passed over a weaker copy
   below, which looks on for a stronger one, instead reach every node before a
   miss: they ask their nodes in turn until two of them answer 404, which finds
   what a writer ranking the nodes the same way wrote, then probe all the rest
   at once and go on through their answers in rank order; a GET asks a node
   whose probe found the entry for its body.
   A read whose 200 body fails `usable` counts as that node's 404, so a replica
   holding a weaker copy does not hide a better one on another node.
   A required read that saw a node fail ends with that failure rather than a
   404.
   A build's cache of one node gets the second attempt on that node: a 429
   or 5xx answer to its first request is asked again once.  No answer at all
   is not, so an unreachable cache still costs a build one attempt per
   request until the breaker trips.  exec-action (fail_closed) instead waits
   on such a cache on retrying_one_node's schedule, below. *)
fun routed_status_using usable method probe urls path request =
  let
    val read = method = "GET" orelse method = "HEAD"
    fun unanswered (HolbuildHttp.Failed _) = true
      | unanswered (HolbuildHttp.Response _) = false
    fun ask node () = traced method node path (fn () => request node)
    fun probed node result () =
      if method = "GET" andalso result = HolbuildHttp.Response 200 then ask node () else result
    fun probe_rest rest =
      let val nodes = map #1 rest
      in
        ListPair.mapEq (fn (node, result) => (node, probed node result))
          (nodes, probe_all (fn node => traced "HEAD" node "" (fn () => probe node)) nodes)
      end
    val required = read andalso reads_required ()
    fun outcome missing failed last =
      case (missing, failed) of
          (SOME found, SOME failure) => if required then failure else found
        | _ => Option.getOpt (missing, last)
    fun loop [] _ _ _ _ missing failed last = outcome missing failed last
      | loop ((node, answer) :: rest) count misses silent passed missing failed last =
          if not read andalso count >= 2 andalso not silent then
            outcome missing failed last
          else
            let
              val result = answer ()
              val rejected = read andalso result = HolbuildHttp.Response 200 andalso not (usable path)
              val _ =
                if rejected then
                  HolbuildStatus.cache_trace ("remote cache " ^ method ^ " " ^ redact_userinfo node ^
                                              ": entry passed over")
                else ()
              val miss = read andalso result = HolbuildHttp.Response 404
              val passed = passed orelse rejected
              val result = if rejected then HolbuildHttp.Response 404 else result
              val misses = if miss then misses + 1 else misses
              val missing = if read andalso result = HolbuildHttp.Response 404 then SOME (node, result) else missing
              val rest =
                if count = 0 andalso null rest andalso not (!fail_closed) andalso transient result andalso
                   not (unanswered result) then
                  [(node, ask node)]
                else rest
              val failed = if transient result then SOME (node, result) else failed
            in
              if miss andalso not required andalso not passed then outcome missing failed (node, result)
              else if transient result orelse (read andalso result = HolbuildHttp.Response 404) then
                loop (if miss andalso misses = 2 andalso not (null rest) then probe_rest rest else rest)
                     (count + 1) misses (silent andalso unanswered result) passed missing failed (node, result)
              else (node, result)
            end
  in
    loop (map (fn node => (node, ask node)) urls) 0 0 true false NONE NONE
         (hd urls, HolbuildHttp.Failed "no cache response")
  end

fun routed_status method urls path request = routed_status_using (fn _ => true) method request urls path request

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

(* exec-action's cache of one node, as each fleet host's own: a request it
   leaves without a usable answer (none at all, 429 or 5xx), as while that
   node's daemon restarts, is asked again after each of these waits that
   still ends within their sum, 90 s, of the first attempt; only then does
   it fail.  A ring's other nodes stand in instead, and a build goes on
   without the cache.  Tests shorten them with
   HOLBUILD_TEST_CACHE_RETRY_DELAYS, comma-separated seconds. *)
fun one_node_retry_delays () =
  case OS.Process.getEnv "HOLBUILD_TEST_CACHE_RETRY_DELAYS" of
      SOME text => List.mapPartial Int.fromString (String.tokens (fn c => c = #",") text)
    | NONE => [1, 2, 4, 8, 15, 15, 15, 15, 15]

fun whole_seconds n = Time.fromSeconds (Int.toLarge n)

(* Cleared by exec-action's interrupt: a request then fails at its next
   unavailable answer, and a wait under way ends within a second. *)
val retry_one_node = ref true

fun wait_seconds n =
  if n <= 0 orelse not (!retry_one_node) then ()
  else (OS.Process.sleep (whole_seconds 1); wait_seconds (n - 1))

(* A caller with a deadline of its own (the theory-module requests) runs F
   under it: a retry then starts only if it could still end by DEADLINE
   after a full stall_timeout_seconds.  Per thread, like `required`. *)
val retry_deadline_tag : Time.time option Universal.tag = Universal.tag ()

fun retry_deadline () = Option.join (Thread.getLocal retry_deadline_tag)

fun retrying_within deadline f =
  let
    val outer = retry_deadline ()
    fun restore () = Thread.setLocal (retry_deadline_tag, outer)
  in
    Thread.setLocal (retry_deadline_tag, SOME deadline);
    (f () before restore ()) handle e => (restore (); raise e)
  end

fun retrying_one_node method urls attempt =
  case urls of
      [_] =>
        if not (!fail_closed) then attempt ()
        else
          let
            val delays = one_node_retry_delays ()
            val window = Time.+ (Time.now (), whole_seconds (foldl op+ 0 delays))
            val own = retry_deadline ()
            fun fits delay =
              let val start = Time.+ (Time.now (), whole_seconds delay)
              in
                Time.<= (start, window) andalso
                (case own of
                     SOME deadline => Time.<= (Time.+ (start, whole_seconds stall_timeout_seconds), deadline)
                   | NONE => true)
              end
            fun loop delays =
              let val (url, result) = attempt ()
              in
                case delays of
                    delay :: rest =>
                      if transient result andalso !retry_one_node andalso fits delay then
                        (TextIO.output (TextIO.stdErr,
                           "holbuild: remote cache " ^ method ^ " " ^ redact_userinfo url ^ " " ^
                           (case result of
                                HolbuildHttp.Failed message => "got no answer: " ^ message
                              | HolbuildHttp.Response code => "answered HTTP " ^ Int.toString code) ^
                           "; retrying in " ^ Int.toString delay ^ " s\n");
                         TextIO.flushOut TextIO.stdErr;
                         wait_seconds delay;
                         if !retry_one_node then loop rest else (url, result))
                      else (url, result)
                  | [] => (url, result)
              end
          in
            loop delays
          end
    | _ => attempt ()

fun send_urls_using usable method urls path request =
  send_result method (hd urls) (fn () =>
    retrying_one_node method urls (fn () => routed_status_using usable method head_status urls path request))

fun send_urls method urls path request = send_urls_using (fn _ => true) method urls path request

fun curl_get_urls_by get usable {urls, dst, timeout} =
  (case send_urls_using usable "GET" urls dst (fn url => get {url = url, dst = dst, timeout = timeout}) of
        NONE => HolbuildCacheBackend.Miss
      | SOME (url, HolbuildHttp.Failed message) =>
          HolbuildCacheBackend.Corrupt ("GET " ^ redact_userinfo url ^ " failed: " ^ message)
      | SOME (_, HolbuildHttp.Response 200) => HolbuildCacheBackend.Hit
      | SOME (_, HolbuildHttp.Response 404) => HolbuildCacheBackend.Miss
      | SOME (url, HolbuildHttp.Response code) =>
          HolbuildCacheBackend.Corrupt ("HTTP " ^ Int.toString code ^ " from " ^ redact_userinfo url))
  handle e as Unavailable _ => raise e
       | e => (HolbuildCacheBackend.Corrupt (General.exnMessage e))

fun curl_get_urls_using usable {urls, dst} =
  curl_get_urls_by get_status usable {urls = urls, dst = dst, timeout = stall_timeout_seconds}

fun curl_get_urls request = curl_get_urls_using (fn _ => true) request

fun curl_get {url, dst} = curl_get_urls {urls = [url], dst = dst}

fun successful_put_code code =
  code = 200 orelse code = 201 orelse code = 204

(* The result, and the node that answered last, if any. *)
fun curl_put_urls_at headers {urls, src} =
  (case send_urls "PUT" urls src (fn url => put_status headers {url = url, src = src}) of
        NONE => (NONE, HolbuildCacheBackend.Skipped)
      | SOME (url, HolbuildHttp.Failed message) =>
          (SOME url, HolbuildCacheBackend.Conflict ("PUT " ^ redact_userinfo url ^ " failed: " ^ message))
      | SOME (url, HolbuildHttp.Response code) =>
          (SOME url,
           if successful_put_code code then HolbuildCacheBackend.Published
           else HolbuildCacheBackend.Conflict ("HTTP " ^ Int.toString code ^ " from " ^ redact_userinfo url)))
  handle e as Unavailable _ => raise e
       | e => (NONE, HolbuildCacheBackend.Conflict (General.exnMessage e))

fun curl_put_urls headers request = #2 (curl_put_urls_at headers request)

(* Whether a PUT's Conflict, as curl_put_urls_at words it, is one a later try
   may not meet: no answer, or a 429 or 5xx answer. *)
fun transient_put_failure message =
  (String.isPrefix "PUT " message andalso String.isSubstring " failed: " message) orelse
  (case String.tokens (fn c => c = #" ") message of
       "HTTP" :: code :: "from" :: _ =>
         (case Int.fromString code of
              SOME code => transient (HolbuildHttp.Response code)
            | NONE => false)
     | _ => false)

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

(* The stall budget of a GET of a blob, by the size an action entry that
   lists it gave; a blob no entry read here lists gets the usual one. *)
fun blob_stall_timeout cache sha256 =
  case Option.mapPartial (Position.fromString o #size) (lookup_blob cache sha256) of
      SOME size =>
        if size >= Position.fromInt large_blob_bytes then large_blob_stall_timeout_seconds
        else stall_timeout_seconds
    | NONE => stall_timeout_seconds

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

(* An action's metadata, without recording its blobs as present: a caller
   that may not use the manifest records them with remember_action.  The
   lookup passes over a node whose manifest fails `usable`, as for a 404. *)
fun fetch_action_using usable cache key =
  let
    val tmp = temp_path "action"
    fun cleanup () = remove_file tmp
    fun usable_body path = usable (#manifest (metadata_manifest (read_text path))) handle _ => true
    val get =
      if reads_revalidate () then get_status_with_headers ["Cache-Control: no-cache"] else get_status
  in
    case curl_get_urls_by get usable_body {urls = action_urls cache key, dst = tmp, timeout = stall_timeout_seconds} of
        HolbuildCacheBackend.Hit =>
          let val action = metadata_manifest (read_text tmp)
          in
            cleanup ();
            SOME action
          end
      | HolbuildCacheBackend.Miss => (cleanup (); NONE)
      | HolbuildCacheBackend.Corrupt message =>
          (cleanup (); warn_restore_once message; NONE)
  end
  handle e as Unavailable _ => raise e
       | _ => NONE

fun remember_action cache {blobs, manifest} =
  (List.app (remember_blob cache) blobs; manifest)

fun fetch_action cache key = fetch_action_using (fn _ => true) cache key

fun get_action_using usable cache key = Option.map (remember_action cache) (fetch_action_using usable cache key)

fun get_action cache key = get_action_using (fn _ => true) cache key

(* The entry for KEY, as get_action finds it, and, with none, whether a
   node answered that it holds none (a 404), not with an error or an
   unusable entry. *)
fun probe_action cache key =
  let
    val tmp = temp_path "action"
    fun found () = SOME (remember_action cache (metadata_manifest (read_text tmp))) handle _ => NONE
    val get =
      if reads_revalidate () then get_status_with_headers ["Cache-Control: no-cache"] else get_status
    val result =
      case send_urls "GET" (action_urls cache key) tmp
             (fn url => get {url = url, dst = tmp, timeout = stall_timeout_seconds}) of
          SOME (_, HolbuildHttp.Response 200) => {found = found (), missing = false}
        | SOME (_, HolbuildHttp.Response 404) => {found = NONE, missing = true}
        | _ => {found = NONE, missing = false}
  in
    remove_file tmp; result
  end
  handle e as Unavailable _ => raise e
       | _ => {found = NONE, missing = false}

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

(* Repair only resident entries the caller identifies as weaker compatible
   copies. Optional replica maintenance must not trip the primary's breaker. *)
fun repair_action_replicas cache {key, text, attempts, should_replace} =
  if tripped () then ()
  else
    let
      val download = temp_path "action-repair-get"
      val upload = temp_path "action-repair-put"
      fun cleanup () = (remove_file download; remove_file upload)
      fun repair url =
        let
          fun warning detail =
            warn_restore_once ("could not reconcile cache replica " ^ redact_userinfo url ^ ": " ^ detail)
          fun request method path call = traced method url path call
          fun loop remaining =
            case request "GET" download (fn () => get_status {url = url, dst = download, timeout = stall_timeout_seconds}) of
                HolbuildHttp.Response 404 => ()
              | HolbuildHttp.Response 200 =>
                  if not (should_replace (#manifest (metadata_manifest (read_text download)))) then ()
                  else if remaining = 0 then warning "weaker timeout contract remains after repair"
                  else
                    (case request "PUT" upload (fn () => put_status [] {url = url, src = upload}) of
                         HolbuildHttp.Response code =>
                           if successful_put_code code then loop (remaining - 1)
                           else if remaining > 1 then loop (remaining - 1)
                           else warning ("HTTP " ^ Int.toString code ^ " during repair")
                       | HolbuildHttp.Failed message =>
                           if remaining > 1 then loop (remaining - 1) else warning message)
              | result =>
                  HolbuildStatus.cache_trace
                    ("cache replica repair skipped: " ^ redact_userinfo url ^
                     (case result of HolbuildHttp.Failed message => ": " ^ message
                                   | HolbuildHttp.Response code => ": HTTP " ^ Int.toString code))
        in
          loop attempts handle Error detail => warning detail
                             | IO.Io {name, function, ...} => warning (function ^ ": " ^ name)
                             | OS.SysErr (detail, _) => warning detail
        end
    in
      (write_text upload (action_metadata cache key text);
       List.app repair (action_urls cache key);
       cleanup ())
      handle Error detail => (cleanup (); warn_restore_once detail)
           | IO.Io {name, function, ...} => (cleanup (); warn_restore_once (function ^ ": " ^ name))
           | OS.SysErr (detail, _) => (cleanup (); warn_restore_once detail)
    end

fun publish_action_metadata_at cache key metadata =
  let
    val tmp = temp_path "action-put"
    val urls = action_urls cache key
    fun cleanup () = remove_file tmp
    fun publish () =
      ((write_text tmp metadata; curl_put_urls_at [] {urls = urls, src = tmp} before cleanup ())
       handle e => (cleanup (); raise e))
  in
    publish ()
  end

fun publish_action_metadata cache key metadata = #2 (publish_action_metadata_at cache key metadata)

(* Checked first, as the blobs an action lists go unpublished while the
   remote cache is disabled. *)
fun publish_action cache {key, text} =
  if disabled () then HolbuildCacheBackend.Skipped
  else publish_action_metadata cache key (action_metadata cache key text)
  handle e as Unavailable _ => raise e
       | e => HolbuildCacheBackend.Conflict (General.exnMessage e)

(* A node answers a read of an entry it holds on its own disk without asking
   the shared backing store, so a node holding the entry being replaced would
   go on serving the old one.  Once a node took the new entry, every other node
   is sent it too.  These writes are best effort: a node that fails one is only
   traced and doesn't trip the breaker, so each is given only
   replica_stall_seconds, and none is sent once refresh_replicas is cleared,
   as by an interrupted action, which has a few seconds left. *)
val replica_stall_seconds = 2
val refresh_replicas = ref true
fun refresh_action_replicas cache key metadata taken =
  case List.filter (fn url => SOME url <> taken) (action_urls cache key) of
      [] => ()
    | urls =>
        if tripped () orelse not (!refresh_replicas) then ()
        else
          let
            val tmp = temp_path "action-replica-put"
            fun put url = traced "PUT" url tmp (fn () => put_status_within replica_stall_seconds [] {url = url, src = tmp})
            fun skipped detail url =
              HolbuildStatus.cache_trace ("cache replica refresh skipped: " ^ redact_userinfo url ^ ": " ^ detail)
            fun report (url, HolbuildHttp.Response code) =
                  if successful_put_code code then () else skipped ("HTTP " ^ Int.toString code) url
              | report (url, HolbuildHttp.Failed message) = skipped message url
          in
            (write_text tmp metadata;
             ListPair.app report (urls, probe_all put urls);
             remove_file tmp)
            handle e => (remove_file tmp;
                         HolbuildStatus.cache_trace ("cache replica refresh failed: " ^ General.exnMessage e))
          end

(* The HTTP write is unconditional.  Callers must authorize replacement from
   action-kind-specific semantics before using this operation. *)
fun replace_action_unconditionally cache request = publish_action cache request

(* For an entry that is replaced in place as it changes (a checkpoint index,
   say), which a reader takes from whichever node it asks: replaced as above,
   then sent to every node.  Not for entries whose replicas are ranked by
   strength (theory actions), which repair_action_replicas handles. *)
fun replace_action_everywhere cache {key, text} =
  if disabled () then HolbuildCacheBackend.Skipped
  else
    let val metadata = action_metadata cache key text
    in
      case publish_action_metadata_at cache key metadata of
          (taken, HolbuildCacheBackend.Published) =>
            (refresh_action_replicas cache key metadata taken; HolbuildCacheBackend.Published)
        | (_, result) => result
    end
    handle e as Unavailable _ => raise e
         | e => HolbuildCacheBackend.Conflict (General.exnMessage e)

(* put_action, which puts the entry, once no node holds one, only if FITS
   () then (else Skipped). *)
fun put_action_if fits cache policy {key, text} =
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
        | NONE => if fits () then publish_action_metadata cache key metadata else HolbuildCacheBackend.Skipped
    end
  handle e as Unavailable _ => raise e
       | e => HolbuildCacheBackend.Conflict (General.exnMessage e)

fun put_action cache policy entry = put_action_if (fn () => true) cache policy entry

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

(* blob_present, by a GET: a node can answer HEAD for a blob its store lost. *)
fun blob_served cache sha256 =
  let
    val tmp = temp_path "blob-check"
    val result =
      send_urls "GET" (cas_urls cache sha256) tmp
        (fn url => get_status {url = url, dst = tmp, timeout = blob_stall_timeout cache sha256})
      handle e => (remove_file tmp; raise e)
  in
    remove_file tmp;
    case result of
        SOME (_, HolbuildHttp.Response 404) => false
      | _ => true
  end
  handle e as Unavailable _ => raise e
       | _ => true

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
          val result = curl_get_urls_by get_status (fn _ => true)
                         {urls = cas_urls cache sha256, dst = dst,
                          timeout = blob_stall_timeout cache sha256}
        in
          case result of
              HolbuildCacheBackend.Hit => verify_downloaded_blob dst entry
            | HolbuildCacheBackend.Corrupt message =>
                (warn_restore_once message; result)
            | other => other
        end
        handle e as Unavailable _ => raise e
             | e => HolbuildCacheBackend.Corrupt (General.exnMessage e)

(* Fetches a blob by its SHA-256 alone, without needing an action entry that
   lists it, as a remote worker fetches its spec and sources; a GET fails
   once it has moved no data for TIMEOUT seconds. *)
fun fetch_unlisted_blob_within timeout cache {hash, dst} =
  (case curl_get_urls_by get_status_parallel_decode (fn _ => true)
                         {urls = cas_urls cache hash, dst = dst, timeout = timeout} of
       HolbuildCacheBackend.Hit =>
         if HolbuildHash.file_sha256 dst = hash then HolbuildCacheBackend.Hit
         else HolbuildCacheBackend.Corrupt ("downloaded blob SHA256 mismatch: " ^ hash)
     | other => other)
  handle e as Unavailable _ => raise e
       | e => HolbuildCacheBackend.Corrupt (General.exnMessage e)

fun fetch_unlisted_blob cache (request as {hash, ...}) =
  fetch_unlisted_blob_within (blob_stall_timeout cache hash) cache request

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
