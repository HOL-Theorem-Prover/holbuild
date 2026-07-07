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

fun url () =
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

fun enabled () = Option.isSome (url ())

end
