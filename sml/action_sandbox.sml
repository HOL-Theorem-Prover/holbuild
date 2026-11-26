structure HolbuildActionSandbox =
struct

exception Error of string
exception Rejected of string

(* The action root and checkpoint root of the exec-action running; NONE
   outside one. *)
val private_roots : (string * string) option ref = ref NONE
(* Whether the last child launch returned: a failure before then is the
   worker's, not the action's. *)
val child_completed = ref false
(* exec-action's --result file. *)
val result_file : string option ref = ref NONE
(* While set, the directories of the action root a theory child writes; the
   rest of the root, its dependencies, it only reads. *)
val action_write_dirs : string list option ref = ref NONE

fun active () = Option.isSome (!private_roots)
fun enable roots = (child_completed := false; private_roots := SOME roots)
fun disable () = private_roots := NONE

fun quote s = "'" ^ String.translate (fn #"'" => "'\\''" | c => str c) s ^ "'"

fun environment_name entry = hd (String.fields (fn c => c = #"=") entry)

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
    fun parse "*" = ("*", [])
      | parse entry =
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

(* git for the worker's own fetches: no user or system configuration,
   credentials, prompts, hooks or background maintenance, and only the named
   protocols.  HOME is never read with a null global configuration. *)
fun hardened_git {home, protocol} args =
  let
    val environment = List.filter
      (fn entry =>
          let val name = environment_name entry val lower = String.map Char.toLower name
          in List.exists (fn allowed => name = allowed)
               ["PATH", "LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE"] orelse
             List.exists (fn allowed => lower = allowed) ["http_proxy", "https_proxy", "all_proxy", "no_proxy"]
          end) (Posix.ProcEnv.environ ())
  in
    HolbuildSpawn.run
      {program = "/usr/bin/env", stderr = HolbuildSpawn.Merge,
       args = ["-i"] @ environment @
         ["HOME=" ^ home, "GIT_CONFIG_NOSYSTEM=1",
          "GIT_CONFIG_GLOBAL=/dev/null", "GIT_TERMINAL_PROMPT=0", "GIT_ASKPASS=/bin/false",
          "GIT_NO_LAZY_FETCH=1", "GIT_ALLOW_PROTOCOL=" ^ protocol,
          "git", "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0", "-c", "maintenance.auto=false"] @ args}
  end

(* A "*" entry trusts any https repository at an exact commit. *)
fun any_https_trusted git =
  String.isPrefix "https://" git andalso
  not (CharVector.exists (fn c => Char.isSpace c orelse Char.isCntrl c) git) andalso
  List.exists (fn (url, _) => url = "*") (trusted_repositories ())

fun require_trusted_branches {git, rev = revision} =
  let
    val branches =
      case List.find (fn (url, _) => url = git) (trusted_repositories ()) of
          SOME (_, refs) => refs
        | NONE => raise Rejected ("exec-action HOL repository is not trusted by this worker: " ^ git)
    val cache = HolbuildCacheConfig.cache_root ()
    val _ = HolbuildGitCache.ensure_dir cache
    val graphs = OS.Path.concat(OS.FileSys.fullPath cache, "toolchain-trust")
    val graph = OS.Path.concat(graphs, HolbuildHash.string_sha256 git)
    fun exists path = OS.FileSys.access(path, []) handle OS.SysErr _ => false
    fun run protocol args = hardened_git {home = OS.Path.concat(graph, "home"), protocol = protocol} args
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

fun require_trusted_repository {git, rev = revision} =
  let
    val _ = HolbuildGitCache.validate_rev revision
            handle HolbuildGitCache.Error msg => raise Rejected msg
  in
    if any_https_trusted git then () else require_trusted_branches {git = git, rev = revision}
  end

(* ARGV as an exec-action child runs it: with a private HOME and TMPDIR
   under the action root, HOLBUILD_ACTION_ROOT naming the root, and none of
   the worker's HOLBUILD_REMOTE_* or REMOTE_EXEC_* settings.  Elsewhere ARGV
   as it is. *)
fun child_argv argv =
  case !private_roots of
      NONE => argv
    | SOME (root, _) =>
        let
          val root = OS.FileSys.fullPath root
          val home = OS.Path.concat (root, ".holbuild/sandbox-home")
          val tmp = OS.Path.concat (home, "tmp")
          fun mkdir path = OS.FileSys.mkDir path handle OS.SysErr _ => ()
          val _ = List.app mkdir [OS.Path.concat (root, ".holbuild"), home, tmp]
          val scrubbed =
            List.filter (fn name => String.isPrefix "HOLBUILD_REMOTE_" name orelse String.isPrefix "REMOTE_EXEC_" name)
                        (map environment_name (Posix.ProcEnv.environ ()))
        in
          ["/usr/bin/env"] @ List.concat (map (fn name => ["-u", name]) scrubbed) @
          ["HOME=" ^ home, "TMPDIR=" ^ tmp, "TMP=" ^ tmp, "TEMP=" ^ tmp, "HOLBUILD_ACTION_ROOT=" ^ root] @ argv
        end

(* Shell text running SCRIPT as an exec-action child (child_argv). *)
fun child_shell script =
  if active () then String.concatWith " " (map quote (child_argv ["/bin/sh", "-c", script]))
  else script

(* Runs ARGV through EXECUTE as a child; child_completed says whether it
   returned. *)
fun launch argv execute =
  (child_completed := false;
   execute (child_argv argv) before child_completed := true)

end
