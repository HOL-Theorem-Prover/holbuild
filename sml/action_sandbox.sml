structure HolbuildActionSandbox =
struct

exception Error of string
exception Rejected of string

val private_roots : (string * string) option ref = ref NONE
val toolchain_root = ref ""
val poly_executable = ref ""
val outputs_validated = ref false

fun active () = Option.isSome (!private_roots)
fun enable roots = (outputs_validated := false; private_roots := SOME roots)
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

fun trusted_repositories () =
  let
    fun valid_ref name =
      size name > 0 andalso Char.isAlphaNum (String.sub(name, 0)) andalso
      List.all (fn c => Char.ord c < 128 andalso
                 (Char.isAlphaNum c orelse List.exists (fn x => c = x) [#".", #"_", #"/", #"-"]))
               (String.explode name) andalso
      not (List.exists (fn part => String.isSubstring part name) ["..", "//", "/."]) andalso
      not (String.isPrefix "refs/" name) andalso
      not (List.exists (fn ending => String.isSuffix ending name) ["/", ".", ".lock"])
    fun parse entry =
      case rev (String.fields (fn c => c = #"=") entry) of
          refs :: rest =>
            let
              val url = String.concatWith "=" (rev rest)
              val branches = String.fields (fn c => c = #",") refs
            in
              if (String.isPrefix "https://" url orelse String.isPrefix "/" url) andalso
                 not (String.isSubstring "\000" url) andalso List.all valid_ref branches
              then (url, branches)
              else raise Error "invalid HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES entry"
            end
        | _ => raise Error "invalid HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES entry"
  in
    case OS.Process.getEnv "HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES" of
        SOME text =>
          if null (String.tokens Char.isSpace text) then
            raise Error "HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES is empty"
          else map parse (String.tokens Char.isSpace text)
      | NONE => [("https://github.com/HOL-Theorem-Prover/HOL.git", ["develop", "master"]),
                 ("https://github.com/HOL-Theorem-Prover/HOL", ["develop", "master"])]
  end

fun require_trusted_repository {git, rev = revision} =
  let
    val _ = HolbuildGitCache.validate_rev revision
            handle HolbuildGitCache.Error msg => raise Rejected msg
    val branches =
      case List.find (fn (url, _) => url = git) (trusted_repositories ()) of
          SOME (_, refs) => refs
        | NONE => raise Rejected ("exec-action HOL repository is not trusted by this worker: " ^ git)
    val cache = HolbuildCacheConfig.cache_root ()
    val _ = HolbuildGitCache.ensure_dir cache
    val graphs = OS.Path.concat(OS.FileSys.fullPath cache, "toolchain-trust")
    val graph = OS.Path.concat(graphs, HolbuildHash.string_sha256 git)
    fun exists path = OS.FileSys.access(path, []) handle OS.SysErr _ => false
    val environment = List.filter
      (fn entry =>
          let val name = environment_name entry val lower = String.map Char.toLower name
          in List.exists (fn allowed => name = allowed)
               ["PATH", "LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE"] orelse
             List.exists (fn allowed => lower = allowed) ["http_proxy", "https_proxy", "all_proxy", "no_proxy"]
          end) (Posix.ProcEnv.environ ())
    fun run protocol args =
      HolbuildSpawn.run
        {program = "/usr/bin/env", stderr = HolbuildSpawn.Merge,
         args = ["-i"] @ environment @
           ["HOME=" ^ OS.Path.concat(graph, "home"), "GIT_CONFIG_NOSYSTEM=1",
            "GIT_CONFIG_GLOBAL=/dev/null", "GIT_TERMINAL_PROMPT=0", "GIT_ASKPASS=/bin/false",
            "GIT_NO_LAZY_FETCH=1", "GIT_ALLOW_PROTOCOL=" ^ protocol,
            "git", "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0", "-c", "maintenance.auto=false"] @ args}
    fun success (result : HolbuildSpawn.result) = #status result = Posix.Process.W_EXITED
    fun trusted () =
      exists (OS.Path.concat(graph, "HEAD")) andalso
      let val kind = run "" ["-C", graph, "cat-file", "-t", revision]
      in success kind andalso HolbuildGitCache.trim (#output kind) = "commit" andalso
         List.exists (fn branch => success (run ""
           ["-C", graph, "merge-base", "--is-ancestor", revision, "refs/heads/" ^ branch])) branches
      end
    fun refresh () =
      if trusted () then () else
      let
        val _ = HolbuildOffline.require_online "verify the HOL revision against trusted branches"
        val _ = if exists (OS.Path.concat(graph, "HEAD")) then () else
          let
            val tmp = graph ^ ".tmp-" ^ HolbuildFileLock.current_pid_text ()
            val _ = HolbuildGitCache.remove_if_exists tmp
            val initialized = run "" ["init", "--bare", "--quiet", tmp]
          in
            if success initialized then OS.FileSys.rename {old = tmp, new = graph}
            else raise Error ("cannot initialize HOL trust graph: " ^ #output initialized)
          end
        val fetched = run "https:file"
          (["-C", graph, "fetch", "--quiet", "--atomic", "--no-tags", "--no-recurse-submodules",
            "--no-write-fetch-head", "--update-head-ok"] @
           (if String.isPrefix "https://" git then ["--filter=tree:0"] else []) @ ["--", git] @
           map (fn branch => "+refs/heads/" ^ branch ^ ":refs/heads/" ^ branch) branches)
      in
        if success fetched then () else raise Error ("cannot fetch trusted HOL branches: " ^ #output fetched)
      end
  in
    if trusted () then () else
      (HolbuildGitCache.ensure_dir graphs;
       HolbuildGitCache.with_lock (graph ^ ".lock") refresh;
       if trusted () then () else
         raise Rejected ("HOL revision " ^ revision ^ " is not a commit on trusted branches: " ^
                         String.concatWith ", " branches))
  end

fun helper () = OS.Path.concat (HolbuildRuntimePaths.runtime_root (), "sml/action_sandbox.py")

fun wrap completed argv =
  case !private_roots of
      NONE => argv
    | SOME (root, checkpoints) =>
      let
        fun exists path = OS.FileSys.access (path, []) handle OS.SysErr _ => false
        fun full path = OS.FileSys.fullPath path
        fun fields name =
          case OS.Process.getEnv name of SOME text => String.tokens (fn c => c = #":") text | NONE => []
        val poly_prefix = OS.Path.dir (OS.Path.dir (!poly_executable))
        val poly_libraries = map (fn path => OS.Path.concat(poly_prefix, path))
                              ["lib", "lib64"]
        val readable = List.filter exists
          ([!toolchain_root, HolbuildRuntimePaths.runtime_root (), !poly_executable,
            "/usr", "/bin", "/sbin", "/lib", "/lib64", "/dev/urandom", "/dev/zero", "/proc/meminfo",
            "/etc/ld.so.cache", "/etc/ld.so.conf", "/etc/ld.so.conf.d", "/etc/localtime",
            "/etc/ssl/certs", "/etc/nsswitch.conf", "/etc/hosts", "/etc/resolv.conf", "/etc/gai.conf"] @
           poly_libraries @ fields "HOLBUILD_ACTION_READ_DIRS")
        val cache = full (HolbuildCacheConfig.cache_root ())
        val protected_paths =
          map (fn part => OS.Path.concat (cache, part))
              ["actions", "blobs", "locks", "cooperate", "checkpoint-store", "toolchain-trust"] @
          List.mapPartial
            (fn entry =>
                case String.fields (fn c => c = #"=") entry of
                    name :: rest =>
                      if String.isSuffix "CURL_CONFIG" name orelse
                         String.isPrefix "HOLBUILD_SHARED_" name orelse name = "HOLBUILD_COOPERATE_DIR"
                      then SOME (String.concatWith "=" rest) else NONE
                  | [] => NONE)
            (Posix.ProcEnv.environ ()) @
          (case !(HolbuildMachineMemory.settings) of SOME {dir, ...} => [dir] | NONE => [])
        val forbidden = List.mapPartial
          (fn path => if path = "" then NONE else
             SOME (OS.Path.mkAbsolute {path = path, relativeTo = OS.FileSys.getDir ()})) protected_paths
        fun options flag paths = List.concat (map (fn path => [flag, path]) paths)
      in
        ["python3", "-I", helper ()] @ options "--write" [full root, full checkpoints] @
        options "--read" (map full readable) @ options "--forbid" forbidden @
        ["--completed", completed, "--"] @ argv
      end

(* Only the trusted supervisor can write this sibling of the private roots.
   A child exit status alone cannot attest to cleanup or output validation. *)
fun launch argv execute =
  if not (active ()) then execute argv else
  let
    val _ = outputs_validated := false
    val completed = OS.Path.concat
      (OS.FileSys.fullPath (HolbuildCacheConfig.cache_root ()), "sandbox-" ^ HolbuildTempPath.suffix ())
    fun remove () = OS.FileSys.remove completed handle OS.SysErr _ => ()
    fun write text =
      let val output = TextIO.openOut completed
      in (TextIO.output(output, text); TextIO.closeOut output)
         handle e => (TextIO.closeOut output; raise e)
      end
    fun completion () =
      let val input = TextIO.openIn completed
      in (TextIO.inputAll input before TextIO.closeIn input)
         handle e => (TextIO.closeIn input; raise e)
      end
    fun await_completion deadline =
      case completion () of
          "validated\n" => true
        | "failed\n" => false
        | _ => if Time.>= (Time.now (), deadline) then false
               else (OS.Process.sleep (Time.fromReal 0.01); await_completion deadline)
    fun run () =
      let
        val _ = write "pending\n"
        val result = execute (wrap completed argv)
        (* A timeout reaps the outer shell before its watcher signals the
           supervisor. Allow the supervisor's bounded cleanup to finish. *)
        val _ = if await_completion (Time.+ (Time.now (), Time.fromSeconds 6))
                then outputs_validated := true
                else raise Error "HOL sandbox did not complete cleanup and output validation"
      in
        result
      end
  in
    (run () before remove ()) handle e => (remove (); raise e)
  end

end
