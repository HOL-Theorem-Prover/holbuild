structure HolbuildRemoteCacheConfig =
struct

exception Error of string

val override_url : string option ref = ref NONE
val local_url : string option ref = ref NONE
val local_curl_config : string option ref = ref NONE
(* How many threads copy remote theory entries ahead of the build; NONE
   means twice the build's jobs. *)
val prefetch_concurrency : int option ref = ref NONE

fun nonempty label text =
  if text = "" then raise Error (label ^ " must not be empty") else text

fun normalize_url url = nonempty "remote cache URL" url
fun normalize_curl_config path = nonempty "remote cache curl config" path

fun set_url url = override_url := SOME (normalize_url url)
fun set_local_url NONE = local_url := NONE
  | set_local_url (SOME url) = local_url := SOME (normalize_url url)
fun set_local_curl_config NONE = local_curl_config := NONE
  | set_local_curl_config (SOME path) = local_curl_config := SOME (normalize_curl_config path)

fun set_prefetch_concurrency n = prefetch_concurrency := SOME n

fun env_url () =
  case OS.Process.getEnv "HOLBUILD_REMOTE_CACHE_URL" of
      SOME "" => NONE
    | SOME url => SOME (normalize_url url)
    | NONE => NONE

fun configured_url () =
  case !override_url of
      SOME url => SOME url
    | NONE =>
        case env_url () of
            SOME url => SOME url
          | NONE => !local_url

fun curl_config () =
  case OS.Process.getEnv "HOLBUILD_REMOTE_CACHE_CURL_CONFIG" of
      SOME path => SOME (normalize_curl_config path)
    | NONE => !local_curl_config

(* The `user` value of a curl config file, the only option holbuild's
   libcurl client reads from it.  Follows curl's syntax: `#` comment lines,
   `name value`, `name = value`, `name: value` and `--name value`, values in
   double quotes with backslash escapes.  Any other option raises Error
   naming it. *)
fun parse_curl_config_user text =
  let
    fun is_separator c = Char.isSpace c orelse c = #"=" orelse c = #":"
    val drop_spaces = Substring.dropl Char.isSpace
    fun unescape c =
      case c of #"t" => #"\t" | #"n" => #"\n" | #"r" => #"\r" | #"v" => #"\v" | c => c
    fun quoted chars acc =
      case chars of
          [] => raise Error "unterminated quoted value"
        | #"\"" :: _ => String.implode (rev acc)
        | #"\\" :: c :: rest => quoted rest (unescape c :: acc)
        | c :: rest => quoted rest (c :: acc)
    fun value s =
      let
        val s = drop_spaces s
        val s = drop_spaces (if Substring.isPrefix "=" s orelse Substring.isPrefix ":" s
                             then Substring.triml 1 s else s)
      in
        case Substring.getc s of
            SOME (#"\"", rest) => quoted (Substring.explode rest) []
          | _ => Substring.string (Substring.takel (not o Char.isSpace) s)
      end
    fun option (line, user) =
      let
        val s = drop_spaces (Substring.full line)
        val (name, rest) = Substring.splitl (not o is_separator) s
        val name = Substring.string name
        val bare = if String.isPrefix "--" name then String.extract (name, 2, NONE) else name
      in
        if Substring.isEmpty s orelse Substring.isPrefix "#" s then user
        else if bare = "user" then SOME (value rest)
        else raise Error ("unsupported option " ^ name ^ " (holbuild's libcurl client reads only user)")
      end
  in
    List.foldl option NONE (String.fields (fn c => c = #"\n") text)
  end

fun curl_config_user () =
  case curl_config () of
      NONE => NONE
    | SOME path =>
        parse_curl_config_user (HolbuildHash.read_all path)
        handle Error message => raise Error ("curl config " ^ path ^ ": " ^ message)
             | IO.Io {cause, ...} =>
                 raise Error ("could not read curl config " ^ path ^ ": " ^ General.exnMessage cause)

(* Whether requests go through libcurl: SOME once setup_client has decided,
   when a URL is configured.  Otherwise they go through the curl command,
   which reads the whole curl config file itself. *)
val libcurl_ready : bool option ref = ref NONE

fun fall_back reason =
  (TextIO.output (TextIO.stdErr, "holbuild: remote cache: using the curl command, since " ^ reason ^ "\n");
   false)

fun setup_libcurl () =
  (HolbuildHttp.setup {user = curl_config_user ()}; true)
  handle Error message => fall_back message
       | HolbuildHttp.Error message => fall_back message
       | Foreign.Foreign message => fall_back ("libcurl could not be loaded: " ^ message)

(* Chooses the HTTP client once the URL and curl config are final.  Must run
   on the main thread before any other thread starts, since
   HolbuildHttp.setup must. *)
fun setup_client () =
  case (!libcurl_ready, configured_url ()) of
      (NONE, SOME _) => libcurl_ready := SOME (setup_libcurl ())
    | _ => ()

fun uses_libcurl () = !libcurl_ready = SOME true

(* The remote cache URL, or NONE when none is configured. *)
val url = configured_url

fun enabled () = Option.isSome (url ())

end
