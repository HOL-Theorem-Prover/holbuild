(* `holbuild __complete WORD...`: the candidates a shell offers for the last
   WORD of a holbuild command line, one per line.  Shell completion scripts
   run it on every keypress, so it only reads: it parses the manifests and
   lists the sources of the project and of the dependencies already on disk.
   It takes no lock, builds or fetches nothing, runs no generator and never
   fails: whatever goes wrong, it prints what it has and exits 0. *)
structure HolbuildComplete =
struct

val max_candidates = 200

(* What completes an operand or an option's value.  Files are left to the
   shell, which completes them when this offers nothing. *)
datatype names = Nothing | Commands | Targets | Theories | Heaps | Executables | Words of string list

type command = {flags : string list, valued : (string * names) list, operands : names}

(* Global options: holbuild takes them anywhere on the line. *)
val global_flags = ["--offline", "--json", "--quiet", "--verbose"]
val global_valued =
  [("--source-dir", Nothing), ("--cache-dir", Nothing), ("--remote-cache", Nothing),
   ("--verbosity", Words ["quiet", "normal", "verbose"]), ("-j", Nothing), ("--jobs", Nothing),
   ("--max-heap", Nothing), ("--prefetch-concurrency", Nothing), ("--cooperate-dir", Nothing),
   ("--machine-max-mem", Nothing), ("--child-charge", Nothing)]
(* Taken but not documented, so skipped with its value and never offered. *)
val hidden_valued = [("--holdir", Nothing)]

val remote_valued = [("--remote-exec", Nothing)]

val build_cache_flags =
  ["--fail-fast", "--force", "--force=theory", "--force=project", "--force=full", "--no-cache",
   "--allow-cache-timeout-discrepancy", "--no-stat-cache", "--skip-checkpoints",
   "--all-checkpoints", "--skip-proof-steps", "--trace-steps", "--retain-debug-artifacts",
   "--emit-output-hashes", "--warn-unreachable", "--trknl"]
val build_cache_valued =
  [("--proof-scope", Words ["root", "all"]), ("--tactic-timeout", Nothing), ("--tool-cache", Nothing)]

fun command name : command =
  case name of
      "build" =>
        {flags = ["--watch", "--dry-run", "--repl-on-failure", "--remote-only", "--detach"] @
                 build_cache_flags,
         valued = build_cache_valued @ remote_valued @ [("--priority", Nothing), ("--attach", Nothing)],
         operands = Targets}
    | "action-spec" =>
        {flags = "--upload" :: build_cache_flags, valued = build_cache_valued, operands = Targets}
    | "context" => {flags = ["--trknl"], valued = [], operands = Nothing}
    | "buildhol" => {flags = ["--trknl"], valued = [], operands = Nothing}
    | "repl" => {flags = ["--remote-only"], valued = ("--from", Theories) :: remote_valued, operands = Nothing}
    | "run" => {flags = ["--remote-only"], valued = ("--from", Theories) :: remote_valued, operands = Nothing}
    | "execution-plan" => {flags = [], valued = [], operands = Theories}
    | "check" =>
        {flags = ["--fingerprint", "--with-fingerprints", "--remote-only"], valued = remote_valued,
         operands = Theories}
    | "heap" => {flags = ["--remote-only"], valued = remote_valued, operands = Heaps}
    | "executable" => {flags = ["--remote-only"], valued = remote_valued, operands = Executables}
    | "clean" => {flags = [], valued = [], operands = Theories}
    | "export" =>
        {flags = ["--build", "--closure", "--sources-only", "--remote-only"],
         valued = [("-o", Nothing), ("--metadata-out", Nothing)] @ remote_valued, operands = Targets}
    | "import" => {flags = [], valued = [], operands = Nothing}
    | "gc" =>
        {flags = ["--clean-only", "--cache-only", "--toolchains-only"],
         valued = [("--retention-days", Nothing), ("--max-checkpoints-gb", Nothing)], operands = Nothing}
    | "cache" => {flags = [], valued = [], operands = Nothing}
    | "exec-action" =>
        {flags = ["--share-heaps"],
         valued = [("--cache-limit-gb", Nothing), ("--cache-reserve-gb", Nothing), ("--result", Nothing),
                   ("--ahead-parent", Nothing), ("--ahead-wait-seconds", Nothing)],
         operands = Nothing}
    | "run-action" =>
        {flags = ["--remote-only", "--closure", "--fetch-only", "--export-only"],
         valued = remote_valued @
                  map (fn option => (option, Nothing))
                    ["--outputs-dir", "--profile", "--script", "--support", "--load", "--output", "--option"],
         operands = Theories}
    | _ => {flags = [], valued = [], operands = Nothing}

fun lookup key pairs = Option.map #2 (List.find (fn (k, _) => k = key) pairs)

(* Options before any command word are build's: holbuild runs `build` then. *)
fun valued_option command_opt word =
  case lookup word (global_valued @ hidden_valued) of
      SOME names => SOME names
    | NONE => lookup word (#valued (command (Option.getOpt (command_opt, "build"))))

(* The command the finished words select (a first operand that is no command
   is a build target), what the last of them leaves to complete if it is an
   option that takes a value, and a --source-dir they give. *)
fun scan words =
  let
    fun loop command pending source_dir [] = (command, pending, source_dir)
      | loop command (SOME option) source_dir (word :: rest) =
          loop command NONE (if option = "--source-dir" then SOME word else source_dir) rest
      | loop command NONE source_dir (word :: rest) =
          if String.isPrefix "-" word then
            (case valued_option command word of
                 SOME _ => loop command (SOME word) source_dir rest
               | NONE =>
                   loop command NONE
                     (if String.isPrefix "--source-dir=" word
                      then SOME (String.extract (word, size "--source-dir=", NONE))
                      else source_dir)
                     rest)
          else
            case command of
                SOME _ => loop command NONE source_dir rest
              | NONE =>
                  loop (SOME (if List.exists (fn name => name = word) HolbuildNames.command_names
                              then word else "build"))
                       NONE source_dir rest
  in
    loop NONE NONE NONE words
  end

(* The dependencies whose sources are already on disk, and theirs in turn;
   the HOL toolchain and packages taken from it are left out. *)
fun dependency_packages (project : HolbuildProject.t) =
  let
    val artifact_parent = #graph_artifact_root project
    fun from_hol parent (HolbuildProject.Dependency {source = HolbuildProject.FromSource {from, ...}, ...}) =
          List.exists
            (fn dep as HolbuildProject.Dependency {name, ...} =>
                name = from andalso HolbuildProject.hol_toolchain_dependency dep)
            (#dependencies parent)
      | from_hol _ _ = false
    fun on_disk parent dep =
      not (HolbuildProject.hol_toolchain_dependency dep orelse from_hol parent dep) andalso
      (case HolbuildProject.dependency_local_path parent dep of
           SOME path => (OS.FileSys.isDir path handle OS.SysErr _ => false)
         | NONE => false)
    fun add parent (dep as HolbuildProject.Dependency {name, ...}, (seen, packages)) =
      if List.exists (fn n => n = name) seen orelse not (on_disk parent dep) then (seen, packages)
      else
        case SOME (HolbuildProject.local_dependency_package artifact_parent parent dep)
             handle _ => NONE of
            SOME (package, dep_project) => walk dep_project (name :: seen, package :: packages)
          | NONE => (name :: seen, packages)
    and walk parent state = List.foldl (add parent) state (#dependencies parent)
  in
    rev (#2 (walk project ([], [])))
  end

fun project_names project names =
  let
    val root = HolbuildProject.project_package project
    fun sources () =
      List.concat
        (map (fn package => HolbuildSourceIndex.discover_package [] package handle _ => [])
             (root :: dependency_packages project))
  in
    case names of
        Targets => HolbuildNames.group_tokens root @ HolbuildNames.target_names (sources ())
      | Theories => HolbuildNames.theory_names (sources ())
      | Heaps => HolbuildNames.heap_names "heap" (#heaps project)
      | Executables => HolbuildNames.heap_names "executable" (#heaps project)
      | _ => []
  end

fun names_for names =
  case names of
      Nothing => []
    | Words words => words
    | Commands => HolbuildNames.command_names
    | _ => project_names (HolbuildProject.discover ()) names handle _ => []

fun options command_opt =
  global_flags @ map #1 global_valued @ ["--help"] @
  (case command_opt of
       SOME name => #flags (command name) @ map #1 (#valued (command name))
     | NONE => ["--version"])

fun candidates words =
  let
    val (finished, current) =
      case rev words of
          [] => ([], "")
        | last :: earlier => (rev earlier, last)
    val (command_opt, pending, source_dir) = scan finished
    val _ = Option.app HolbuildProject.set_source_dir source_dir
    val names =
      case pending of
          SOME option => names_for (Option.getOpt (valued_option command_opt option, Nothing))
        | NONE =>
            if String.isPrefix "-" current then
              (* `--option=VALUE` completes the value after the `=`. *)
              let
                val (option, value) = Substring.position "=" (Substring.full current)
                val option = Substring.string option
              in
                case if Substring.isEmpty value then NONE else valued_option command_opt option of
                    SOME names => map (fn name => option ^ "=" ^ name) (names_for names)
                  | NONE => options command_opt
              end
            else
              case command_opt of
                  NONE => names_for Commands @ names_for Targets
                | SOME name => names_for (#operands (command name))
    val matching =
      Redblackset.listItems
        (Redblackset.addList (Redblackset.empty String.compare,
                              List.filter (String.isPrefix current) names))
  in
    List.take (matching, Int.min (max_candidates, length matching))
  end
  handle _ => []

(* Nothing this runs may write to the terminal the shell is editing in. *)
fun silence_stderr () =
  let val null = Posix.FileSys.openf ("/dev/null", Posix.FileSys.O_WRONLY, Posix.FileSys.O.flags [])
  in Posix.IO.dup2 {old = null, new = Posix.FileSys.stderr}; Posix.IO.close null end
  handle _ => ()

fun main words =
  (silence_stderr ();
   HolbuildOffline.enable ();
   (List.app (fn name => print (name ^ "\n")) (candidates words);
    TextIO.flushOut TextIO.stdOut)
   handle _ => ();
   OS.Process.exit OS.Process.success)

end
