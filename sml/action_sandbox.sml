structure HolbuildActionSandbox =
struct

exception Error of string

val private_roots : (string * string) option ref = ref NONE
val toolchain_root = ref ""
val poly_root = ref ""

fun active () = Option.isSome (!private_roots)
fun enable roots = private_roots := SOME roots
fun disable () = private_roots := NONE

fun protect_process () =
  let
    open Foreign
    val call = buildCall5 (getSymbol (loadExecutable ()) "prctl",
                          (cInt, cInt, cInt, cInt, cInt), cInt)
  in
    if call (4, 0, 0, 0, 0) = 0 then ()
    else raise Error "cannot protect exec-action process"
  end
  handle Foreign.Foreign _ => raise Error "exec-action needs Linux process protection"

fun quote s = "'" ^ String.translate (fn #"'" => "'\\''" | c => str c) s ^ "'"

fun credential_environment () =
  List.filter
    (fn entry => String.isPrefix "HOLBUILD_REMOTE_" entry orelse
                 String.isPrefix "REMOTE_EXEC_" entry)
    (Posix.ProcEnv.environ ())

fun environment_name entry = hd (String.fields (fn c => c = #"=") entry)

(* Bootstrap code is trusted, but has no reason to inherit cache credentials. *)
fun bootstrap_command script =
  if not (active ()) then script
  else
    String.concatWith " "
      (["env"] @ List.concat (map (fn entry => ["-u", quote (environment_name entry)])
                                   (credential_environment ())) @
       ["/bin/sh", "-c", quote script])

fun require_trusted_repository git =
  let
    val trusted =
      case OS.Process.getEnv "HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES" of
          SOME text => String.tokens Char.isSpace text
        | NONE => ["https://github.com/HOL-Theorem-Prover/HOL.git",
                   "https://github.com/HOL-Theorem-Prover/HOL"]
  in
    if List.exists (fn url => url = git) trusted then ()
    else raise Error ("exec-action HOL repository is not trusted by this worker: " ^ git)
  end

fun helper () = OS.Path.concat (HolbuildRuntimePaths.runtime_root (), "sml/action_sandbox.py")

fun wrap argv =
  case !private_roots of
      NONE => argv
    | SOME (root, checkpoints) =>
      let
        fun exists path = OS.FileSys.access (path, []) handle OS.SysErr _ => false
        fun full path = OS.FileSys.fullPath path
        fun fields name =
          case OS.Process.getEnv name of SOME text => String.tokens (fn c => c = #":") text | NONE => []
        val poly_prefix = !poly_root
        val readable = List.filter exists
          ([!toolchain_root, HolbuildRuntimePaths.runtime_root (), poly_prefix,
            "/usr", "/bin", "/sbin", "/lib", "/lib64", "/dev/urandom", "/dev/zero", "/proc/meminfo",
            "/etc/ld.so.cache", "/etc/ld.so.conf", "/etc/ld.so.conf.d", "/etc/localtime",
            "/etc/ssl/certs", "/etc/nsswitch.conf", "/etc/hosts", "/etc/resolv.conf", "/etc/gai.conf"] @
           fields "HOLBUILD_ACTION_READ_DIRS")
        val cache = HolbuildCacheConfig.cache_root ()
        val forbidden =
          map (fn part => OS.Path.concat (cache, part))
              ["actions", "blobs", "locks", "cooperate", "checkpoint-store"] @
          List.mapPartial
            (fn entry =>
                case String.fields (fn c => c = #"=") entry of
                    name :: rest =>
                      if String.isSuffix "CURL_CONFIG" name orelse
                         String.isPrefix "HOLBUILD_SHARED_" name orelse name = "HOLBUILD_COOPERATE_DIR"
                      then SOME (String.concatWith "=" rest) else NONE
                  | [] => NONE)
            (Posix.ProcEnv.environ ())
        fun options flag paths = List.concat (map (fn path => [flag, path]) paths)
      in
        ["python3", "-I", helper ()] @ options "--write" [full root, full checkpoints] @
        options "--read" (map full readable) @ options "--forbid" forbidden @ ["--"] @ argv
      end

end
