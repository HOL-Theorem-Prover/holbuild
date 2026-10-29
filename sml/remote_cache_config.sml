structure HolbuildRemoteCacheConfig =
struct

exception Error of string

val override_url : string option ref = ref NONE
val local_url : string option ref = ref NONE
val local_curl_config : string option ref = ref NONE

fun nonempty label text =
  if text = "" then raise Error (label ^ " must not be empty") else text

fun normalize_url url = nonempty "remote cache URL" url
fun normalize_curl_config path = nonempty "remote cache curl config" path

fun set_url url = override_url := SOME (normalize_url url)
fun set_local_url NONE = local_url := NONE
  | set_local_url (SOME url) = local_url := SOME (normalize_url url)
fun set_local_curl_config NONE = local_curl_config := NONE
  | set_local_curl_config (SOME path) = local_curl_config := SOME (normalize_curl_config path)

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

fun curl_config_user () =
  case curl_config () of
      NONE => NONE
    | SOME path =>
        let val input = TextIO.openIn path
        in
          HolbuildHttp.curl_config_user (TextIO.inputAll input before TextIO.closeIn input)
          handle HolbuildHttp.Error message => raise Error ("curl config " ^ path ^ ": " ^ message)
        end
        handle IO.Io {cause, ...} =>
          raise Error ("could not read curl config " ^ path ^ ": " ^ General.exnMessage cause)

(* Whether requests go through libcurl, once that has been decided.  When
   libcurl can't be used, they go through the curl command, which reads the
   whole curl config file itself. *)
val libcurl_ready : bool option ref = ref NONE

fun fall_back reason =
  (TextIO.output (TextIO.stdErr, "holbuild: remote cache: using the curl command, since " ^ reason ^ "\n");
   false)

fun setup_libcurl () =
  (HolbuildHttp.setup {user = curl_config_user ()}; true)
  handle Error message => fall_back message
       | HolbuildHttp.Error message => fall_back message
       | Foreign.Foreign message => fall_back ("libcurl could not be loaded: " ^ message)

(* Decides the HTTP client on the first call.  HolbuildHttp.setup must run on
   the main thread before any other thread starts; url () makes this first
   call, and commands look up the URL on the main thread before they start
   other threads (toolchain restore, then the build's prefetch and workers). *)
fun uses_libcurl () =
  case !libcurl_ready of
      SOME ready => ready
    | NONE => let val ready = setup_libcurl () in libcurl_ready := SOME ready; ready end

(* The remote cache URL, or NONE when none is configured. *)
fun url () =
  case configured_url () of
      NONE => NONE
    | SOME url => (ignore (uses_libcurl ()); SOME url)

fun enabled () = Option.isSome (url ())

end
