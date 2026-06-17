structure HolbuildCacheConfig =
struct

structure Path = OS.Path

exception Error of string

val cache_root_override = ref (NONE : string option)

fun set_cache_root path = cache_root_override := SOME path

fun cache_root () =
  case !cache_root_override of
      SOME path => path
    | NONE =>
      case OS.Process.getEnv "HOLBUILD_CACHE" of
          SOME path => path
        | NONE =>
          case OS.Process.getEnv "XDG_CACHE_HOME" of
              SOME base => Path.concat(base, "holbuild")
            | NONE =>
              case OS.Process.getEnv "HOME" of
                  SOME home => Path.concat(Path.concat(home, ".cache"), "holbuild")
                | NONE => raise Error "set HOME, XDG_CACHE_HOME, or HOLBUILD_CACHE"

fun cache_root_option () = SOME (cache_root ()) handle Error _ => NONE

end
