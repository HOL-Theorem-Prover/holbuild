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
      SOME url => SOME (normalize_url url)
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

(* Whether the HTTP client is usable, once it has been set up. *)
val http_ready : bool option ref = ref NONE

fun disable_remote reason =
  (TextIO.output (TextIO.stdErr, "holbuild: warning: remote cache disabled: " ^ reason ^ "\n");
   false)

fun setup_http () =
  (HolbuildHttp.setup {user = curl_config_user ()}; true)
  handle Error message => disable_remote message
       | HolbuildHttp.Error message => disable_remote message
       | Foreign.Foreign message => disable_remote ("could not load libcurl: " ^ message)

(* The remote cache URL, or NONE when none is configured or the HTTP client
   can't be set up.  The first call with a URL configured sets up the client.
   Commands make that call on the main thread before they start other
   threads (toolchain restore, then the build's prefetch and workers), as
   HolbuildHttp.setup requires. *)
fun url () =
  case configured_url () of
      NONE => NONE
    | SOME url =>
        let
          val ready =
            case !http_ready of
                SOME ready => ready
              | NONE => let val ready = setup_http () in http_ready := SOME ready; ready end
        in
          if ready then SOME url else NONE
        end

fun enabled () = Option.isSome (url ())

end
