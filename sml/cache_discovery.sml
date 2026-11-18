structure HolbuildCacheDiscovery =
struct

exception Error of string

val refresh_seconds = 30
val stale_seconds = 60
val mutex = Mutex.mutex ()
val refreshing = ref false
val attempted = ref Time.zeroTime
val succeeded = ref Time.zeroTime
val members : string list ref = ref []
val scope = ref ""
fun env name =
  case OS.Process.getEnv name of SOME "" => NONE | value => value

fun endpoint () = env "HOLBUILD_REMOTE_CACHE_DISCOVERY_URL"
fun enabled () = Option.isSome (endpoint ()) andalso not (HolbuildOffline.enabled ())

fun userinfo url =
  let
    val identity = HolbuildRemoteCacheConfig.node_identity url
    val (scheme, _) = Substring.position "://" (Substring.full url)
    val start = Substring.size scheme + 3
  in String.substring (url, start, size url - size identity) end

fun with_userinfo auth url =
  if auth = "" then url
  else
    let val (scheme, rest) = Substring.position "://" (Substring.full url)
    in Substring.string scheme ^ "://" ^ auth ^ Substring.string (Substring.triml 3 rest) end

(* The API can select local configured identities, never supply credentials or a new credential recipient. *)
fun parse defaults allowed text =
  let
    val identity = HolbuildRemoteCacheConfig.node_identity
    val lines = String.tokens (fn c => c = #"\n" orelse c = #"\r") text
    val urls = case lines of
        "holbuild-cache-members-v1" :: urls => urls
      | _ => raise Error "bad cache membership header"
    fun resolve url =
      if identity url <> url then raise Error "cache membership contained credentials"
      else case List.find (fn known => identity known = url) allowed of
          SOME known => known
        | NONE => raise Error "cache membership contained an unconfigured endpoint"
    val nodes = map resolve urls
    val _ = if List.all (fn url => List.exists (fn node => identity node = identity url) nodes) defaults then ()
            else raise Error "cache membership omitted a permanent endpoint"
  in HolbuildRemoteCacheConfig.urls (String.concatWith "," nodes) end

(* With credentials, inline or from a curl config, every endpoint discovery may select must be HTTPS. *)
fun check_plain_http defaults url =
  let
    val credentials = List.exists (fn node => userinfo node <> "") defaults orelse
      Option.isSome (HolbuildRemoteCacheConfig.curl_config ())
  in
    if credentials andalso not (String.isPrefix "https://" (String.map Char.toLower url))
    then raise Error ("cache credentials must not reach plain-HTTP endpoint " ^ HolbuildRemoteCacheConfig.node_identity url)
    else url
  end

fun allowed defaults =
  let
    val auth = userinfo (hd defaults)
    val extra = case env "HOLBUILD_REMOTE_CACHE_ALLOWED_URLS" of
        NONE => []
      | SOME text => map (fn url => if userinfo url = "" then with_userinfo auth url else url)
          (HolbuildRemoteCacheConfig.urls text)
  in map (check_plain_http defaults) (HolbuildRemoteCacheConfig.urls (String.concatWith "," (defaults @ extra))) end

fun config_args () =
  case env "HOLBUILD_REMOTE_CACHE_DISCOVERY_CURL_CONFIG" of
      SOME path => ["--config", path]
    | NONE => (case env "HOLBUILD_REMOTE_EXEC_CURL_CONFIG" of SOME path => ["--config", path] | NONE => [])

(* An IP literal needs no lookup; IPv6 literals are bracketed. *)
fun resolves url =
  let
    val (_, rest) = Substring.position "://" (Substring.full (HolbuildRemoteCacheConfig.node_identity url))
    val authority = Substring.takel (fn c => c <> #"/" andalso c <> #"?" andalso c <> #"#") (Substring.triml 3 rest)
    val host = Substring.string (Substring.takel (fn c => c <> #":") authority)
  in
    Substring.isPrefix "[" authority orelse
    (Option.isSome (NetHostDB.getByName host) handle OS.SysErr _ => false)
  end

(* A member published before its name resolves here (a resolver can cache the
   empty name's NXDOMAIN for minutes) is left out until a later refresh finds it.
   The permanent endpoints are always kept. *)
fun fetch url defaults =
  let
    val identity = HolbuildRemoteCacheConfig.node_identity
    fun permanent node = List.exists (fn default => identity default = identity node) defaults
    val result = HolbuildSpawn.run {
      program = "curl", stderr = HolbuildSpawn.Discard,
      args = ["-q", "-fsSg", "--connect-timeout", "2", "--max-time", "5", "--max-filesize", "16384"] @
        config_args () @ [url]}
  in
    if HolbuildSpawn.succeeded result then
      SOME (List.filter (fn node => permanent node orelse resolves node)
        (parse defaults (allowed defaults) (#output result)))
    else NONE
  end

(* Only the refresher waits for HTTP. Other cache threads keep using the most recent complete ring. *)
fun urls defaults =
  if not (enabled ()) then defaults
  else
    let
      val now = Time.now ()
      val _ = Mutex.lock mutex
      val requested_scope = String.concatWith "," defaults
      val _ = if !scope <> requested_scope andalso not (!refreshing) then
          (scope := requested_scope; attempted := Time.zeroTime; succeeded := Time.zeroTime; members := [])
        else ()
      val same_scope = !scope = requested_scope
      val update = same_scope andalso not (!refreshing) andalso
        Time.>= (Time.- (now, !attempted), Time.fromSeconds refresh_seconds)
      val _ = if update then (refreshing := true; attempted := now) else ()
      val _ = Mutex.unlock mutex
      fun release () = (Mutex.lock mutex; refreshing := false; Mutex.unlock mutex)
      val fetched = (if update then
          (case endpoint () of SOME url => fetch url defaults | NONE => NONE)
          handle Error _ => NONE | OS.SysErr _ => NONE | IO.Io _ => NONE
        else NONE) handle e => (if update then release () else (); raise e)
      val published = Time.now ()
      val _ = Mutex.lock mutex
      val _ = if update then
          ((case fetched of SOME nodes => (members := nodes; succeeded := published)
            | NONE => ()); refreshing := false)
        else ()
      val result = if not same_scope orelse null (!members) orelse
                     Time.>= (Time.- (published, !succeeded), Time.fromSeconds stale_seconds)
                   then defaults else !members
      val _ = Mutex.unlock mutex
    in result end

end
