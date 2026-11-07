structure HolbuildCommands =
struct

exception Error of string

(* EX_TEMPFAIL, the exit status of a --remote-only build that stopped where
   a local build would go on (HolbuildHolSharedCache.local_build_needed).
   Poly/ML's OS.Process.status is the exit code, but opaque. *)
val local_build_needed_status : OS.Process.status = RunCall.unsafeCast (75 : int)

(* An interrupted build exits with status 1, whatever else stopped it, so
   that nobody builds locally what its user stopped.  Set before anything
   else the interrupt does, since build threads may still fail after it. *)
val interrupted = ref false

fun err_with_debug_artifacts msg artifacts =
  (if HolbuildStatus.json_mode () then HolbuildStatus.error_with_debug_artifacts msg artifacts
   else HolbuildStatus.message_stderr ("holbuild: " ^ msg ^ "\n");
   OS.Process.exit (if !HolbuildHolSharedCache.local_build_needed andalso not (!interrupted)
                    then local_build_needed_status
                    else OS.Process.failure))

fun err msg = err_with_debug_artifacts msg HolbuildStatus.no_debug_artifacts

fun warn msg = HolbuildStatus.message_stderr ("holbuild: warning: " ^ msg ^ "\n")

fun global_help () = print
  "holbuild: experimental project-aware build frontend for HOL4\n\n\
  \Usage:\n\
  \  holbuild [GLOBAL OPTIONS] [build] [TARGET ...]\n\
  \  holbuild [GLOBAL OPTIONS] COMMAND [ARGS]\n\
  \  holbuild --version\n\n\
  \Primary command:\n\
  \  [build] [TARGET ...]        Build project targets\n\n\
  \Project interaction:\n\
  \  repl [--from THEORY] [ARG ...]  Start HOL REPL with project context\n\
  \  run [--from THEORY] [ARG ...]   Run HOL with project context\n\
  \  context [--trknl]          Show resolved project context\n\n\
  \Inspection and advanced commands:\n\
  \  execution-plan T:THM        Inspect proof-step execution plan\n\
  \  check THEORY[:THEOREM]      Check theorems for cheats, oracles and axioms\n\
  \  buildhol                    Build/reuse declared HOL and print its path\n\
  \  heap NAME                   Build a configured heap\n\
  \  executable NAME             Build a configured executable heap\n\
  \  clean THEORY...             Remove local build outputs\n\
  \  export -o FILE [TARGET ...]  Export cached build outputs\n\
  \  action-spec [TARGET ...]   Export uncached theories for remote execution\n\
  \  exec-action SPEC-SHA256    Run one exported theory action as a remote worker\n\
  \  import FILE                  Import cached build outputs\n\
  \  gc                          Remove stale project/cache state\n\n\
  \Global options:\n\
  \  --source-dir PATH\n\
  \  --cache-dir PATH\n\
  \  --remote-cache URL\n\
  \  --json\n\
  \  --quiet, --verbose, --verbosity LEVEL\n\
  \  -j N, -jN, --jobs N\n\
  \  --max-heap MB\n\
  \  --prefetch-concurrency N     Remote cache checks/prefetches at once\n\
  \                               (default: 50 or 2 * jobs, whichever is larger)\n\
  \  --cooperate-dir DIR          Share a machine memory budget with other holbuild\n\
  \                               processes using DIR (or $HOLBUILD_COOPERATE_DIR)\n\
  \  --machine-max-mem MB         Budget to record in DIR/budget if it is missing\n\
  \                               (default without it: MemTotal less a reserve)\n\
  \  --child-charge MB            Reservation per child (default: --max-heap, at\n\
  \                               most 3072; --max-heap + 1024 without\n\
  \                               MemAvailable)\n\n\
  \With --cooperate-dir, each theory, generator or heap-export child reserves\n\
  \--child-charge, and starts only while all reservations in DIR plus its own fit\n\
  \the budget, and, while other children hold reservations, MemAvailable less the\n\
  \charges of children started in the last 30 s covers its charge plus a margin.\n\
  \The reserve is a quarter of MemTotal, at least 1 GiB and at most 30 GiB; the\n\
  \margin is the reserve, or what the budget leaves out of MemTotal if that is\n\
  \less (at least 1 GiB).\n\
  \This bounds admission; it does not enforce RSS. HOL toolchain builds, check,\n\
  \run and repl reserve nothing.\n\
  \To set or resize the budget, write DIR/budget (a byte count) while holding\n\
  \DIR/lock:\n\
  \  flock DIR/lock sh -c 'echo BYTES > DIR/budget.new && mv DIR/budget.new DIR/budget'\n\
  \To return to the default, remove it: flock DIR/lock rm DIR/budget\n\
  \Waiting for DIR/lock gives up after $HOLBUILD_COOPERATE_LOCK_TIMEOUT seconds\n\
  \(default 600; 0 for no limit).\n\n\
  \Use `holbuild COMMAND --help` for command-specific help.\n"

fun build_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] [build] [OPTIONS] [TARGET ...]\n\n\
  \Build project targets. With no TARGET, build the project's default targets.\n\n\
  \Options:\n\
  \  --watch\n\
  \  --dry-run\n\
  \  --force[=theory|project|full]\n\
  \      Bypass cached outputs; valid checkpoints, including failed prefixes, may resume.\n\
  \  --no-cache\n\
  \  --allow-cache-timeout-discrepancy\n\
  \  --no-stat-cache\n\
  \  --skip-checkpoints\n\
  \  --skip-proof-steps\n\
  \  --tactic-timeout SECONDS\n\
  \  --trace-steps\n\
  \  --repl-on-failure\n\
  \  --retain-debug-artifacts\n\
  \  --emit-output-hashes\n\
  \  --warn-unreachable\n\
  \  --trknl\n\
  \  --remote-exec URL [--remote-only] [--detach | --attach BATCH-ID]\n\n\
  \With --remote-exec, theories the remote cache lacks are built by the\n\
  \coordinator's workers and restored from the remote cache, except a\n\
  \theory nothing else in the batch depends on, which builds locally when\n\
  \its local checkpoints are current, or when it is the only theory to\n\
  \build and its dependencies are built here (not with --detach; see the\n\
  \README). Needs\n\
  \--remote-cache. A closure that can't run remotely or an unreachable\n\
  \coordinator builds locally; --remote-only fails instead, with exit\n\
  \status 75. --detach submits the batch and exits; --attach follows a\n\
  \submitted batch and restores it.\n\n\
  \Global options: see `holbuild --help`.\n"

fun context_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] context [--trknl]\n\n\
  \Show resolved project context. Use --trknl to select the tracing-kernel\n\
  \context. This command resolves metadata but does not build the toolchain.\n\n\
  \Global options: see `holbuild --help`.\n"

fun repl_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] repl [--from THEORY] [--remote-exec URL [--remote-only]]\n\
  \         [ARG ...]\n\n\
  \Start HOL REPL with project context. Extra arguments are passed to HOL,\n\
  \except two kinds, wherever they appear: holbuild's global options and\n\
  \-h/--help, which holbuild takes itself, and Poly/ML runtime options\n\
  \(--gcthreads, --maxheap, -H, ...), which holbuild's own runtime consumes;\n\
  \holbuild rejects those where it can detect them (Linux).\n\n\
  \Options:\n\
  \  --from THEORY  Start from THEORY's deps_loaded build checkpoint (its\n\
  \                 ancestors loaded) and load THEORY on top when it is built\n\
  \                 for its current sources; without a current checkpoint,\n\
  \                 from [run].heap or the HOL base state. Does not build THEORY.\n\
  \                 Without --from, given .sml scripts, THEORY is inferred:\n\
  \                 of the project theories the scripts depend on, the one\n\
  \                 with the most ancestors.\n\
  \  --remote-exec URL  Build the [run].loads targets as `build --remote-exec`\n\
  \                 does, on the coordinator's workers, then start HOL locally.\n\
  \                 With --remote-only, fails instead of building locally.\n\n\
  \Global options: see `holbuild --help`.\n"

fun run_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] run [--from THEORY] [--remote-exec URL [--remote-only]]\n\
  \         [ARG ...]\n\n\
  \Run HOL with project context. Extra arguments are passed to HOL,\n\
  \except two kinds, wherever they appear: holbuild's global options and\n\
  \-h/--help, which holbuild takes itself, and Poly/ML runtime options\n\
  \(--gcthreads, --maxheap, -H, ...), which holbuild's own runtime consumes;\n\
  \holbuild rejects those where it can detect them (Linux).\n\n\
  \Options:\n\
  \  --from THEORY  Start from THEORY's deps_loaded build checkpoint (its\n\
  \                 ancestors loaded) and load THEORY on top when it is built\n\
  \                 for its current sources; without a current checkpoint,\n\
  \                 from [run].heap or the HOL base state. Does not build THEORY.\n\
  \                 Without --from, given .sml scripts, THEORY is inferred:\n\
  \                 of the project theories the scripts depend on, the one\n\
  \                 with the most ancestors.\n\
  \  --remote-exec URL  Build the [run].loads targets as `build --remote-exec`\n\
  \                 does, on the coordinator's workers, then start HOL locally.\n\
  \                 With --remote-only, fails instead of building locally.\n\n\
  \Global options: see `holbuild --help`.\n"

fun execution_plan_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] execution-plan THEORY:THEOREM\n\n\
  \Inspect the proof-step execution plan for a theorem.\n\n\
  \Global options: see `holbuild --help`.\n"

fun check_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] check THEORY[:THEOREM]\n\n\
  \Build THEORY if needed, load it in HOL and check the tags of its stored\n\
  \theorems, or of THEOREM alone. Prints one line per theorem that depends on an\n\
  \oracle other than DISK_THM (cheat, for instance) and per axiom declared in\n\
  \THEORY or its ancestors outside HOL itself, and exits non-zero if there are\n\
  \any. Otherwise prints a clean line and exits zero.\n\n\
  \The build runs without proof steps or checkpoints, so it reuses theories\n\
  \built by build --skip-proof-steps and applies no step timeout.\n\n\
  \Global options: see `holbuild --help`.\n"

fun buildhol_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] buildhol [--trknl]\n\n\
  \Build/reuse the declared HOL tree and print its path. Use --trknl to select\n\
  \the tracing kernel. A configured remote cache restores toolchains and\n\
  \publishes successful local builds automatically. A global -j N is passed to\n\
  \HOL's bin/build when the toolchain is built here.\n\n\
  \Global options: see `holbuild --help`.\n"

fun heap_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] heap NAME\n\n\
  \Build a configured heap.\n\n\
  \Global options: see `holbuild --help`.\n"

fun executable_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] executable NAME\n\n\
  \Build a configured executable heap.\n\n\
  \Global options: see `holbuild --help`.\n"

fun clean_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] clean THEORY...\n\n\
  \Remove local build outputs for theories. Subsequent builds may restore outputs\n\
  \from the global cache.\n\n\
  \Global options: see `holbuild --help`.\n"

fun gc_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] gc [OPTIONS]\n\n\
  \Remove stale project/cache state, including HOL toolchains unused for the\n\
  \retention period.\n\n\
  \Options:\n\
  \  --retention-days DAYS\n\
  \  --max-checkpoints-gb GB\n\
  \  --clean-only        project state only\n\
  \  --cache-only        global cache only; no project needed\n\
  \  --toolchains-only   installed HOL toolchains only; no project needed\n\n\
  \The --*-only options are mutually exclusive.\n\n\
  \Global options: see `holbuild --help`.\n"

fun cache_help () = print
  "`holbuild cache gc` is deprecated; use `holbuild gc --cache-only`.\n"

fun action_spec_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] action-spec [--upload] [OPTIONS] [TARGET ...]\n\n\
  \Plan TARGETs as build would and write the ActionSpec of every theory the\n\
  \remote cache can't satisfy to .holbuild/action-specs/SHA256, then print the\n\
  \action batch. With --upload, also upload the specs and their sources to the\n\
  \remote cache. Takes build's cache and proof options. Needs --remote-cache.\n\n\
  \Global options: see `holbuild --help`.\n"

fun exec_action_help () = print
  "Usage:\n\
  \  holbuild --remote-cache URL [GLOBAL OPTIONS] exec-action SPEC-SHA256\n\
  \      --cache-limit-gb N [--cache-reserve-gb N] [--share-heaps] [--result FILE]\n\n\
  \Run the ActionSpec stored in the remote cache as SPEC-SHA256 (see\n\
  \action-spec) and publish its result to the remote cache. The action runs in\n\
  \CACHE/action, with checkpoints in CACHE/checkpoints, where CACHE is the cache\n\
  \root. Writes a holbuild-action-result-v1 record to FILE, or to stdout.\n\n\
  \Exit status: 0 built or cached; 1 proof or tactic-timeout failure; 2 out of\n\
  \memory; 3 input-missing, publish, toolchain, disk or internal failure;\n\
  \4 spec rejected.\n\n\
  \--cache-limit-gb N   Before the action, evict least recently used\n\
  \                     checkpoints, toolchains and local cache entries until\n\
  \                     the cache root holds at most N GB minus the reserve.\n\
  \--cache-reserve-gb N Room to keep free under the limit (default: a tenth).\n\
  \--share-heaps        Resume from the deps-loaded heap and theorem checkpoints\n\
  \                     other workers published, and publish this run's. The\n\
  \                     host store CACHE/checkpoint-store keeps their files.\n\n\
  \Global options: see `holbuild --help`.\n"

fun export_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] export [--build] -o FILE [--metadata-out FILE] [TARGET ...]\n\n\
  \Export cached build outputs for targets. With --build, build targets first.\n\n\
  \Global options: see `holbuild --help`.\n"

fun import_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] import FILE\n\n\
  \Import cached build outputs from an hbx archive into the global cache.\n\n\
  \Global options: see `holbuild --help`.\n"

fun help_arg arg = arg = "--help" orelse arg = "-h"
fun has_help_arg args = List.exists help_arg args

val command_names =
  ["build", "context", "repl", "run", "execution-plan", "check", "buildhol", "heap", "executable",
   "clean", "export", "import", "gc", "cache", "action-spec", "exec-action"]

fun known_command command =
  List.exists (fn name => name = command) command_names orelse command = "goalfrag-plan"

fun unknown_command command =
  Error ("unknown command: " ^ command ^ HolbuildSuggest.did_you_mean command command_names)

fun command_help command =
  case command of
      "build" => build_help ()
    | "context" => context_help ()
    | "repl" => repl_help ()
    | "run" => run_help ()
    | "execution-plan" => execution_plan_help ()
    | "check" => check_help ()
    | "buildhol" => buildhol_help ()
    | "heap" => heap_help ()
    | "executable" => executable_help ()
    | "clean" => clean_help ()
    | "export" => export_help ()
    | "action-spec" => action_spec_help ()
    | "exec-action" => exec_action_help ()
    | "import" => import_help ()
    | "gc" => gc_help ()
    | "cache" => cache_help ()
    | "goalfrag-plan" => raise Error "goalfrag-plan has been removed; use execution-plan THEORY:THEOREM"
    | _ => raise unknown_command command

fun maybe_handle_command_help args =
  case args of
      [] => false
    | command :: rest =>
        if has_help_arg rest then
          if known_command command then (command_help command; true)
          else raise unknown_command command
        else false

fun nonnegative_real label text =
  case Real.fromString text of
      SOME n =>
        if n >= 0.0 then n
        else raise Error (label ^ " must be a non-negative number")
    | NONE => raise Error (label ^ " must be a non-negative number")

fun tactic_timeout_value text =
  let val seconds = nonnegative_real "--tactic-timeout" text
  in if seconds <= 0.0 then NONE else SOME seconds end

fun force_level_value text =
  case text of
      "none" => HolbuildBuildExec.ForceNone
    | "theory" => HolbuildBuildExec.ForceTargets
    | "target" => HolbuildBuildExec.ForceTargets
    | "project" => HolbuildBuildExec.ForceProject
    | "full" => HolbuildBuildExec.ForceAll
    | "all" => HolbuildBuildExec.ForceAll
    | _ => raise Error "--force must be one of: theory, project, full"

fun split_flags args =
  let
    fun extract_flag flag rest =
      let
        fun loop found acc xs =
          case xs of
              [] => (found, rev acc)
            | y :: ys =>
                if y = flag then loop true acc ys
                else loop found (y :: acc) ys
      in
        loop false [] rest
      end
    val (emit_output_hashes, args_without_emit_output_hashes) =
      extract_flag "--emit-output-hashes" args
    val (allow_cache_timeout_discrepancy, build_args) =
      extract_flag "--allow-cache-timeout-discrepancy" args_without_emit_output_hashes
    fun loop dry watch force use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable rest =
      case rest of
          [] => ({dry_run = dry, watch = watch, force = force, use_cache = use_cache,
                  verify_cache = verify_cache,
                  no_stat_cache = no_stat_cache,
                  skip_checkpoints = skip_checkpoints,
                  proof_steps = proof_steps, new_ir = new_ir,
                  tactic_timeout = tactic_timeout,
                  tactic_timeout_set = tactic_timeout_set,
                  execution_plan = execution_plan,
                  trace_steps = trace_steps,
                  repl_on_failure = repl_on_failure,
                  retain_debug_artifacts = retain_debug_artifacts,
                  warn_unreachable = warn_unreachable,
                  emit_output_hashes = emit_output_hashes,
                  allow_cache_timeout_discrepancy = allow_cache_timeout_discrepancy}, [])
        | "--dry-run" :: xs =>
            loop true watch force use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs
        | "--watch" :: xs =>
            loop dry true force use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs
        | "--force" :: xs =>
            loop dry watch HolbuildBuildExec.ForceAll use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs
        | "--force-theory" :: xs =>
            loop dry watch HolbuildBuildExec.ForceTargets use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs
        | "--force-project" :: xs =>
            loop dry watch HolbuildBuildExec.ForceProject use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs
        | "--force-full" :: xs =>
            loop dry watch HolbuildBuildExec.ForceAll use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs
        | "--no-cache" :: xs =>
            loop dry watch force false verify_cache no_stat_cache skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs
        | "--no-stat-cache" :: xs =>
            loop dry watch force use_cache verify_cache true skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs
        | "--skip-checkpoints" :: xs =>
            loop dry watch force use_cache verify_cache no_stat_cache true proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs
        | "--skip-proof-steps" :: xs =>
            loop dry watch force use_cache verify_cache no_stat_cache skip_checkpoints false false tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs
        | "--skip-goalfrag" :: xs =>
            (warn "--skip-goalfrag is deprecated; use --skip-proof-steps";
             loop dry watch force use_cache verify_cache no_stat_cache skip_checkpoints false false tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs)
        | "--goalfrag" :: _ =>
            raise Error "--goalfrag has been removed; proof steps are enabled by default"
        | "--new-ir" :: xs =>
            (warn "--new-ir is deprecated and has no effect; proof IR is the default";
             loop dry watch force use_cache verify_cache no_stat_cache skip_checkpoints proof_steps true tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs)
        | "--goalfrag-plan" :: _ => raise Error "--goalfrag-plan has been removed; use execution-plan THEORY:THEOREM"
        | "--trace-steps" :: xs =>
            loop dry watch force use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan true repl_on_failure retain_debug_artifacts warn_unreachable xs
        | "--goalfrag-trace" :: xs =>
            (warn "--goalfrag-trace is deprecated; use --trace-steps";
             loop dry watch force use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan true repl_on_failure retain_debug_artifacts warn_unreachable xs)
        | "--repl-on-failure" :: xs =>
            loop dry watch force use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan trace_steps true retain_debug_artifacts warn_unreachable xs
        | "--retain-debug-artifacts" :: xs =>
            loop dry watch force use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure true warn_unreachable xs
        | "--warn-unreachable" :: xs =>
            loop dry watch force use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts true xs
         | "--trknl" :: xs =>
             loop dry watch force use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs
        | "--tactic-timeout" :: seconds :: xs =>
            loop dry watch force use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir (tactic_timeout_value seconds) true execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs
        | "--tactic-timeout" :: [] => raise Error "--tactic-timeout requires SECONDS"
        | x :: xs =>
            if String.isPrefix "--force=" x then
              loop dry watch (force_level_value (String.extract (x, size "--force=", NONE))) use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs
            else if String.isPrefix "--tactic-timeout=" x then
              loop dry watch force use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir
                   (tactic_timeout_value (String.extract (x, size "--tactic-timeout=", NONE)))
                   true execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs
            else if String.isPrefix "--goalfrag-plan=" x then
              raise Error "--goalfrag-plan has been removed; use execution-plan THEORY:THEOREM"
            else if String.isPrefix "--trace-steps=" x then
              raise Error "--trace-steps does not take an argument"
            else if String.isPrefix "--goalfrag-trace=" x then
              raise Error "--goalfrag-trace has been replaced by --trace-steps and does not take an argument"
            else if String.isPrefix "--" x then
              raise Error ("unknown build option: " ^ x)
            else
              let val (flags, ys) = loop dry watch force use_cache verify_cache no_stat_cache skip_checkpoints proof_steps new_ir tactic_timeout tactic_timeout_set execution_plan trace_steps repl_on_failure retain_debug_artifacts warn_unreachable xs
              in (flags, x :: ys) end
  in
    loop false false HolbuildBuildExec.ForceNone true true false false true true NONE false NONE false false false false build_args
  end

fun default_build_request targets =
  ({dry_run = false, watch = false, force = HolbuildBuildExec.ForceNone,
    use_cache = true, verify_cache = true, no_stat_cache = false,
    skip_checkpoints = false, proof_steps = true, new_ir = true,
    tactic_timeout = NONE, tactic_timeout_set = false, execution_plan = NONE,
    trace_steps = false, repl_on_failure = false, retain_debug_artifacts = false,
    warn_unreachable = false, emit_output_hashes = false,
    allow_cache_timeout_discrepancy = false},
   targets)

(* check builds plain: step timeouts are build's check, and a timeout-free
   request reuses any built or cached theory, including ones from build
   --skip-proof-steps --skip-checkpoints. It saves no checkpoints. *)
fun plain_build_request targets =
  ({dry_run = false, watch = false, force = HolbuildBuildExec.ForceNone,
    use_cache = true, verify_cache = true, no_stat_cache = false,
    skip_checkpoints = true, proof_steps = false, new_ir = false,
    tactic_timeout = NONE, tactic_timeout_set = false, execution_plan = NONE,
    trace_steps = false, repl_on_failure = false, retain_debug_artifacts = false,
    warn_unreachable = false, emit_output_hashes = false,
    allow_cache_timeout_discrepancy = false},
   targets)

fun has_suffix suffix s =
  let
    val n = size s
    val m = size suffix
  in
    n >= m andalso String.substring(s, n - m, m) = suffix
  end

fun reject_object_target target =
  if has_suffix ".uo" target orelse has_suffix ".ui" target orelse
     has_suffix ".dat" target orelse has_suffix ".art" target then
    raise Error ("build targets are logical names, not object files: " ^ target)
  else ()

fun reject_object_targets targets = List.app reject_object_target targets

fun resolved_packages resolution project =
  HolbuildProjectGraph.packages
    (HolbuildProjectGraph.resolve {project = project, resolution = resolution})

fun project_has_default_targets resolution project =
  List.exists HolbuildSourceIndex.package_has_default_targets
    (resolved_packages resolution project)

fun default_build_targets resolution project index targets =
  if null targets then HolbuildSourceIndex.default_targets_with resolution index project
  else
    (reject_object_targets targets;
     HolbuildSourceIndex.expand_group_tokens index (HolbuildProject.project_package project)
       (HolbuildSourceIndex.resolve_path_targets index targets))

fun build_target_plan resolution components holdir project index requested_targets targets =
  if null requested_targets andalso null targets andalso not (project_has_default_targets resolution project) then
    HolbuildBuildPlan.plan_targets components holdir index (HolbuildSourceIndex.root_package_targets index project)
  else
    HolbuildBuildPlan.plan_targets components holdir index targets

fun source_key source =
  #package source ^ "\000" ^ #relative_path source ^ "\000" ^ #logical_name source

fun key_member key keys = List.exists (fn k => k = key) keys

fun rooted_package_names resolution project =
  let
    fun has_rooted_targets package =
      not (null (HolbuildProject.package_roots package)) orelse
      not (null (HolbuildProject.package_root_groups package))
  in
    map HolbuildProject.package_name
      (List.filter has_rooted_targets (resolved_packages resolution project))
  end

fun root_warning_source rooted_packages built_keys source =
  #kind source = HolbuildSourceIndex.TheoryScript andalso
  key_member (#package source) rooted_packages andalso
  not (key_member (source_key source) built_keys)

fun warn_unreachable_root_scripts resolution project index plan =
  let
    val rooted_packages = rooted_package_names resolution project
    val built_keys = map (source_key o HolbuildBuildPlan.source_of) (HolbuildBuildPlan.selected_nodes plan)
    val unreachable = List.filter (root_warning_source rooted_packages built_keys) index
    fun describe source = #package source ^ ":" ^ #relative_path source ^ " (" ^ #logical_name source ^ ")"
    val limit = 20
    fun take (0, _) = []
      | take (_, []) = []
      | take (n, x :: xs) = x :: take (n - 1, xs)
  in
    case unreachable of
        [] => ()
      | _ =>
        (warn (Int.toString (length unreachable) ^
               " discoverable theory script(s) are not reachable from build.roots");
         List.app (fn source => warn ("  unreachable: " ^ describe source))
                  (take (limit, unreachable));
         if length unreachable > limit then
           warn ("  ... " ^ Int.toString (length unreachable - limit) ^ " more")
         else ())
  end

fun read_text path =
  let val ins = TextIO.openIn path
  in TextIO.inputAll ins before TextIO.closeIn ins end

fun theory_source source = #kind source = HolbuildSourceIndex.TheoryScript

fun describe_source source =
  #package source ^ ":" ^ #relative_path source ^ " (" ^ #logical_name source ^ ")"

fun parse_execution_plan_selector selector =
  case String.fields (fn c => c = #":") selector of
      [theory, theorem] =>
        if theory = "" orelse theorem = "" then
          raise Error "execution-plan requires THEORY:THEOREM"
        else {theory = theory, theorem = theorem}
    | _ => raise Error "execution-plan requires THEORY:THEOREM"

type execution_plan_unit = {kind : string, name : string, tactic_start : int,
                            tactic_end : int, tactic_text : string}

fun theorem_match theorem source =
  let
    val text = read_text (#source_path source)
    val boundaries = HolbuildBuildExec.discover_theorem_boundaries (#source_path source) text
    val theorem_units =
      map (fn ({name, tactic_start, tactic_end, tactic_text, ...} : HolbuildTheoryCheckpoints.boundary) =>
             {kind = "theorem", name = name, tactic_start = tactic_start,
              tactic_end = tactic_end, tactic_text = tactic_text}) boundaries
    val theorem_matches =
      List.filter (fn ({name, ...} : execution_plan_unit) => name = theorem) theorem_units
    fun termination_match () =
      let
        val terminations =
          HolbuildBuildExec.discover_termination_diagnostics_strict (#source_path source) text
        val termination_units =
          map (fn ({name, tactic_start, tactic_end, tactic_text, ...} : HolbuildTheoryCheckpoints.termination) =>
                 {kind = "termination", name = name, tactic_start = tactic_start,
                  tactic_end = tactic_end, tactic_text = tactic_text}) terminations
      in
        case List.filter (fn ({name, ...} : execution_plan_unit) => name = theorem)
                         termination_units of
            [] => NONE
          | [unit] => SOME (source, unit)
          | _ => raise Error ("duplicate termination proof in " ^ describe_source source ^ ": " ^ theorem)
      end
  in
    case theorem_matches of
        [] => termination_match ()
      | [unit] => SOME (source, unit)
      | _ => raise Error ("duplicate theorem in " ^ describe_source source ^ ": " ^ theorem)
  end

(* The theorem and termination names theorem_match accepts for source. *)
fun proof_unit_names source =
  let
    val path = #source_path source
    val text = read_text path
  in
    map (fn ({name, ...} : HolbuildTheoryCheckpoints.boundary) => name)
        (HolbuildBuildExec.discover_theorem_boundaries path text) @
    map (fn ({name, ...} : HolbuildTheoryCheckpoints.termination) => name)
        (HolbuildBuildExec.discover_termination_diagnostics_strict path text)
  end

fun write_text_file path text =
  let val out = TextIO.openOut path
  in TextIO.output(out, text); TextIO.closeOut out end

fun run_analyser_for_proof_ir_text {name, tactic_start, tactic_end, tactic_text} =
  case HolbuildDependencies.current_analyser_path () of
      NONE => raise Error "internal error: HOL analyser is not configured"
    | SOME analyser =>
        let
          val req = OS.FileSys.tmpName ()
          val resp = OS.FileSys.tmpName ()
          val request = String.concatWith "\n"
            [HolbuildAnalysisProtocol.join ["version", HolbuildAnalysisProtocol.protocol_version],
             HolbuildAnalysisProtocol.join ["command", "proof-ir-plan"],
             HolbuildAnalysisProtocol.join ["theorem", "0", name, Int.toString tactic_start, Int.toString tactic_end, tactic_text],
             HolbuildAnalysisProtocol.join ["end"]] ^ "\n"
          val _ = write_text_file req request
          val status = OS.Process.system (HolbuildHash.quote analyser ^ " " ^
                                          String.concatWith " " (HolbuildDependencies.analyser_min_heap_args ()) ^
                                          " --request " ^ HolbuildHash.quote req ^
                                          " --response " ^ HolbuildHash.quote resp)
          val _ = OS.FileSys.remove req handle OS.SysErr _ => ()
          val text = if OS.Process.isSuccess status then read_text resp
                     else (OS.FileSys.remove resp handle OS.SysErr _ => ();
                           raise Error "holbuild-hol-analyser failed")
          val _ = OS.FileSys.remove resp handle OS.SysErr _ => ()
        in text end

fun int_field s =
  case Int.fromString s of SOME n => n | NONE => raise Error ("bad proof-ir integer field: " ^ s)

fun parse_selector ["first"] = HolbuildProofIr.SelectFirst
  | parse_selector ["matching-first", pats] = HolbuildProofIr.SelectMatchingFirst pats
  | parse_selector ["matching-all", pats] = HolbuildProofIr.SelectMatchingAll pats
  | parse_selector _ = raise Error "bad proof-ir selector"

fun parse_mode "solve" = HolbuildProofIr.SelectSolve
  | parse_mode "keep" = HolbuildProofIr.SelectKeep
  | parse_mode s = raise Error ("bad proof-ir select mode: " ^ s)

fun parse_proof_steps fieldss =
  let
    fun parse_body stops rest acc =
      case rest of
          [] => if List.exists (fn s => s = "end") stops then raise Error "unterminated proof-ir block" else (rev acc, [])
        | fields :: more =>
            (case fields of
                 ["proof-step", "end"] =>
                   if List.exists (fn s => s = "end") stops then
                     if List.exists (fn s => s = "case" orelse s = "alternative") stops then (rev acc, rest)
                     else (rev acc, more)
                   else raise Error "proof-ir end outside block"
               | ["proof-step", "case", _] =>
                   if List.exists (fn s => s = "case") stops then (rev acc, rest)
                   else raise Error "proof-ir case outside cases"
               | ["proof-step", "alternative", _] =>
                   if List.exists (fn s => s = "alternative") stops then (rev acc, rest)
                   else raise Error "proof-ir alternative outside choice"
               | ["proof-step", "step", a, b, label, program] =>
                   parse_body stops more (HolbuildProofIr.StepTactic {start_pos = int_field a, end_pos = int_field b, label = label, program = program} :: acc)
               | ["proof-step", "list-step", a, b, label, program] =>
                   parse_body stops more (HolbuildProofIr.StepList {start_pos = int_field a, end_pos = int_field b, label = label, program = program} :: acc)
               | ["proof-step", "each", a, b] =>
                   let val (body, rest') = parse_body ["end"] more []
                   in parse_body stops rest' (HolbuildProofIr.StepEach {start_pos = int_field a, end_pos = int_field b, body = body} :: acc) end
               | "proof-step" :: "select" :: a :: b :: restfields =>
                   let
                     val (sel_fields, mode_text) =
                       case restfields of
                           [sel, mode] => ([sel], mode)
                         | [sel, pats, mode] => ([sel, pats], mode)
                         | _ => raise Error "bad proof-ir select response"
                     val (body, rest') = parse_body ["end"] more []
                   in parse_body stops rest' (HolbuildProofIr.StepSelect {start_pos = int_field a, end_pos = int_field b, selector = parse_selector sel_fields, mode = parse_mode mode_text, body = body} :: acc) end
               | ["proof-step", "cases", a, b] =>
                   let
                     fun parse_cases n rest cases =
                       (case rest of
                            ["proof-step", "end"] :: more' => (rev cases, more')
                          | ["proof-step", "case", k] :: more' =>
                              if int_field k <> n then raise Error "proof-ir case ordering error"
                              else let val (body, rest'') = parse_body ["case", "end"] more' []
                                   in parse_cases (n + 1) rest'' (body :: cases) end
                          | _ => raise Error "bad proof-ir cases block")
                     val (cases, rest') = parse_cases 1 more []
                   in parse_body stops rest' (HolbuildProofIr.StepCases {start_pos = int_field a, end_pos = int_field b, cases = cases} :: acc) end
               | ["proof-step", "choice", a, b, label] =>
                   let
                     fun parse_alts n rest alts =
                       (case rest of
                            ["proof-step", "end"] :: more' => (rev alts, more')
                          | ["proof-step", "alternative", k] :: more' =>
                              if int_field k <> n then raise Error "proof-ir alternative ordering error"
                              else let val (body, rest'') = parse_body ["alternative", "end"] more' []
                                   in parse_alts (n + 1) rest'' (body :: alts) end
                          | _ => raise Error "bad proof-ir choice block")
                     val (alts, rest') = parse_alts 1 more []
                   in parse_body stops rest' (HolbuildProofIr.StepChoice {start_pos = int_field a, end_pos = int_field b, label = label, alternatives = alts} :: acc) end
               | ["proof-step", "repeat", a, b] =>
                   let val (body, rest') = parse_body ["end"] more []
                   in parse_body stops rest' (HolbuildProofIr.StepRepeat {start_pos = int_field a, end_pos = int_field b, body = body} :: acc) end
               | ["proof-step", "try", a, b] =>
                   let val (body, rest') = parse_body ["end"] more []
                   in parse_body stops rest' (HolbuildProofIr.StepTry {start_pos = int_field a, end_pos = int_field b, body = body} :: acc) end
               | _ => raise Error "bad proof-ir step response")
    val (steps, rest) = parse_body [] fieldss []
  in
    case rest of [] => steps | _ => raise Error "unexpected proof-ir parser residue"
  end

fun analyser_proof_ir_plan_for_unit (unit : execution_plan_unit) =
  let
    val {name, tactic_start, tactic_end, tactic_text, ...} = unit
    val lines = String.tokens (fn c => c = #"\n")
      (run_analyser_for_proof_ir_text {name = name, tactic_start = tactic_start,
                                       tactic_end = tactic_end, tactic_text = tactic_text})
    fun loop rest active acc found =
      case rest of
          [] => found
        | line :: more =>
            (case HolbuildAnalysisProtocol.split line of
                 ["begin-proof-ir", "0", _, _, _, _] => loop more true [] found
               | ["end-proof-ir", "0"] => loop more false [] (SOME (parse_proof_steps (rev acc)))
               | fields as "proof-step" :: _ =>
                   if active then loop more active (fields :: acc) found
                   else loop more active acc found
               | _ => loop more active acc found)
  in
    case loop lines false [] NONE of
        SOME steps => steps
      | NONE => raise Error ("proof-IR plan missing for execution-plan proof unit: " ^ name)
  end

fun print_static_execution_plan project new_ir source theorem unit_opt =
  (print (let
            val unit = case unit_opt of SOME value => value | NONE => raise Error "internal error: missing proof-IR unit"
            val plan = analyser_proof_ir_plan_for_unit unit
          in
            "holbuild proof-ir plan " ^
            (if #kind unit = "theorem" then "" else #kind unit ^ " ") ^
            #logical_name source ^ ":" ^ theorem ^ " source=" ^ #relative_path source ^
            " (" ^ Int.toString (HolbuildProofIr.display_step_count plan) ^ " steps)\n" ^
            HolbuildProofIr.format_plan_lines plan
          end);
   TextIO.flushOut TextIO.stdOut)

fun find_theory_source command index theory =
  case List.filter (fn source => theory_source source andalso #logical_name source = theory) index of
      [source] => source
    | [] =>
        raise Error ("theory not found for " ^ command ^ ": " ^ theory ^
                     HolbuildSuggest.did_you_mean theory
                       (map #logical_name (List.filter theory_source index)))
    | matches =>
        raise Error ("ambiguous theory for " ^ command ^ ": " ^ theory ^ " in " ^
                     String.concatWith ", " (map describe_source matches))

fun find_theorem_in_source theorem source =
  case theorem_match theorem source of
      SOME (_, unit) => unit
    | NONE =>
        raise Error ("proof unit not found for execution-plan: " ^ #logical_name source ^ ":" ^ theorem ^
                     HolbuildSuggest.did_you_mean theorem (proof_unit_names source))

fun print_execution_plan_selector new_ir project selector =
  let
    val {theory, theorem} = parse_execution_plan_selector selector
    val graph = HolbuildProjectGraph.resolve
                  {project = project,
                   resolution = HolbuildProject.standard_resolution}
    val preparation = HolbuildPackagePrepare.prepare graph
    val discovery = HolbuildSourceIndex.discover_prepared_with_inventories [] preparation
    val components = HolbuildComponentProvider.load HolbuildComponentProvider.LiveProvider
                       {preparation = preparation, discovery = discovery}
    val index = HolbuildComponentProvider.sources components
    val source = find_theory_source "execution-plan" index theory
  in
    print_static_execution_plan project new_ir source theorem (SOME (find_theorem_in_source theorem source))
  end

fun positive_int label text =
  case Int.fromString text of
      SOME n => if n >= 1 then n else raise Error (label ^ " must be a positive integer")
    | NONE => raise Error (label ^ " must be a positive integer")

fun verbosity_value text =
  case text of
      "quiet" => HolbuildStatus.Quiet
    | "normal" => HolbuildStatus.Normal
    | "verbose" => HolbuildStatus.Verbose
    | _ => raise Error "--verbosity must be one of: quiet, normal, verbose"

fun parse_global_options args =
  let
    fun loop prefetch_concurrency holdir source_dir cache_dir remote_cache jobs maxheap json verbosity rest =
      case rest of
          [] => ({holdir = holdir, source_dir = source_dir, cache_dir = cache_dir, remote_cache = remote_cache, jobs = jobs, maxheap = maxheap, prefetch_concurrency = prefetch_concurrency, json = json, verbosity = verbosity}, [])
        | "--json" :: xs => loop prefetch_concurrency holdir source_dir cache_dir remote_cache jobs maxheap true verbosity xs
        | "--quiet" :: xs => loop prefetch_concurrency holdir source_dir cache_dir remote_cache jobs maxheap json HolbuildStatus.Quiet xs
        | "--verbose" :: xs => loop prefetch_concurrency holdir source_dir cache_dir remote_cache jobs maxheap json HolbuildStatus.Verbose xs
        | "--verbosity" :: level :: xs => loop prefetch_concurrency holdir source_dir cache_dir remote_cache jobs maxheap json (verbosity_value level) xs
        | "--holdir" :: path :: xs => loop prefetch_concurrency (SOME path) source_dir cache_dir remote_cache jobs maxheap json verbosity xs
        | "--source-dir" :: path :: xs => loop prefetch_concurrency holdir (SOME path) cache_dir remote_cache jobs maxheap json verbosity xs
        | "--cache-dir" :: path :: xs => loop prefetch_concurrency holdir source_dir (SOME path) remote_cache jobs maxheap json verbosity xs
        | "--remote-cache" :: url :: xs => loop prefetch_concurrency holdir source_dir cache_dir (SOME url) jobs maxheap json verbosity xs
        | "--jobs" :: n :: xs => loop prefetch_concurrency holdir source_dir cache_dir remote_cache (SOME (positive_int "--jobs" n)) maxheap json verbosity xs
        | "-j" :: n :: xs => loop prefetch_concurrency holdir source_dir cache_dir remote_cache (SOME (positive_int "-j" n)) maxheap json verbosity xs
        | "--max-heap" :: n :: xs => loop prefetch_concurrency holdir source_dir cache_dir remote_cache jobs (SOME (positive_int "--max-heap" n)) json verbosity xs
        | "--prefetch-concurrency" :: n :: xs => loop (SOME (positive_int "--prefetch-concurrency" n)) holdir source_dir cache_dir remote_cache jobs maxheap json verbosity xs
        | "--verbosity" :: [] => raise Error "--verbosity requires LEVEL"
        | "--holdir" :: [] => raise Error "--holdir requires PATH"
        | "--source-dir" :: [] => raise Error "--source-dir requires PATH"
        | "--cache-dir" :: [] => raise Error "--cache-dir requires PATH"
        | "--remote-cache" :: [] => raise Error "--remote-cache requires URL"
        | "--jobs" :: [] => raise Error "--jobs requires N"
        | "-j" :: [] => raise Error "-j requires N"
        | "--max-heap" :: [] => raise Error "--max-heap requires MB"
        | "--prefetch-concurrency" :: [] => raise Error "--prefetch-concurrency requires N"
        | arg :: xs =>
            if String.isPrefix "--verbosity=" arg then
              loop prefetch_concurrency holdir source_dir cache_dir remote_cache jobs maxheap json (verbosity_value (String.extract (arg, size "--verbosity=", NONE))) xs
            else if String.isPrefix "--holdir=" arg then
              loop prefetch_concurrency (SOME (String.extract (arg, size "--holdir=", NONE))) source_dir cache_dir remote_cache jobs maxheap json verbosity xs
            else if String.isPrefix "--source-dir=" arg then
              loop prefetch_concurrency holdir (SOME (String.extract (arg, size "--source-dir=", NONE))) cache_dir remote_cache jobs maxheap json verbosity xs
            else if String.isPrefix "--cache-dir=" arg then
              loop prefetch_concurrency holdir source_dir (SOME (String.extract (arg, size "--cache-dir=", NONE))) remote_cache jobs maxheap json verbosity xs
            else if String.isPrefix "--remote-cache=" arg then
              loop prefetch_concurrency holdir source_dir cache_dir (SOME (String.extract (arg, size "--remote-cache=", NONE))) jobs maxheap json verbosity xs
            else if String.isPrefix "--jobs=" arg then
              loop prefetch_concurrency holdir source_dir cache_dir remote_cache (SOME (positive_int "--jobs" (String.extract (arg, size "--jobs=", NONE)))) maxheap json verbosity xs
            else if String.isPrefix "--max-heap=" arg then
              loop prefetch_concurrency holdir source_dir cache_dir remote_cache jobs (SOME (positive_int "--max-heap" (String.extract (arg, size "--max-heap=", NONE)))) json verbosity xs
            else if String.isPrefix "--prefetch-concurrency=" arg then
              loop (SOME (positive_int "--prefetch-concurrency" (String.extract (arg, size "--prefetch-concurrency=", NONE)))) holdir source_dir cache_dir remote_cache jobs maxheap json verbosity xs
            else if String.isPrefix "-j" arg andalso size arg > 2 then
              loop prefetch_concurrency holdir source_dir cache_dir remote_cache (SOME (positive_int "-j" (String.extract (arg, 2, NONE)))) maxheap json verbosity xs
            else
              let val (opts, args') = loop prefetch_concurrency holdir source_dir cache_dir remote_cache jobs maxheap json verbosity xs in (opts, arg :: args') end
  in
    loop NONE NONE NONE NONE NONE NONE NONE false HolbuildStatus.Normal args
  end

(* --cooperate-dir, --machine-max-mem and --child-charge, removed from args. *)
fun parse_cooperation_options args =
  let
    fun loop dir mem charge [] = (dir, mem, charge, [])
      | loop _ _ _ ("--cooperate-dir" :: "" :: _) = raise Error "--cooperate-dir requires DIR"
      | loop _ mem charge ("--cooperate-dir" :: path :: xs) = loop (SOME path) mem charge xs
      | loop _ _ _ ["--cooperate-dir"] = raise Error "--cooperate-dir requires DIR"
      | loop dir _ charge ("--machine-max-mem" :: n :: xs) = loop dir (SOME (positive_int "--machine-max-mem" n)) charge xs
      | loop _ _ _ ["--machine-max-mem"] = raise Error "--machine-max-mem requires MB"
      | loop dir mem _ ("--child-charge" :: n :: xs) = loop dir mem (SOME (positive_int "--child-charge" n)) xs
      | loop _ _ _ ["--child-charge"] = raise Error "--child-charge requires MB"
      | loop dir mem charge (arg :: xs) =
          if String.isPrefix "--cooperate-dir=" arg then
            loop dir mem charge ("--cooperate-dir" :: String.extract (arg, size "--cooperate-dir=", NONE) :: xs)
          else if String.isPrefix "--machine-max-mem=" arg then
            loop dir (SOME (positive_int "--machine-max-mem" (String.extract (arg, size "--machine-max-mem=", NONE)))) charge xs
          else if String.isPrefix "--child-charge=" arg then
            loop dir mem (SOME (positive_int "--child-charge" (String.extract (arg, size "--child-charge=", NONE)))) xs
          else
            let val (dir', mem', charge', rest) = loop dir mem charge xs in (dir', mem', charge', arg :: rest) end
  in
    loop NONE NONE NONE args
  end

fun configure_cooperation dir budget_mb charge_mb maxheap =
  let
    val dir =
      case dir of
          SOME _ => dir
        | NONE =>
            (case OS.Process.getEnv "HOLBUILD_COOPERATE_DIR" of
                 SOME "" => NONE
               | env => env)
  in
    case (dir, budget_mb, charge_mb) of
        (SOME dir, _, _) =>
          let
            val default = HolbuildMachineMemory.default_charge_mb
            (* The flat default leans on the MemAvailable check; without it a
               child is charged all it may reach, as before that check. *)
            fun default_charge () =
              if HolbuildMachineMemory.has_mem_available () then
                Int.min (Option.getOpt (maxheap, default), default)
              else
                case maxheap of
                    SOME mb => mb + 1024
                  | NONE => raise Error ("--cooperate-dir requires --max-heap MB or --child-charge MB " ^
                                         "where MemAvailable cannot be read")
          in
            HolbuildMachineMemory.configure
              {dir = dir, budget_mb = budget_mb,
               charge_mb = case charge_mb of SOME mb => mb | NONE => default_charge ()}
          end
      | (NONE, SOME _, _) => raise Error "--machine-max-mem requires --cooperate-dir DIR"
      | (NONE, NONE, SOME _) => raise Error "--child-charge requires --cooperate-dir DIR"
      | (NONE, NONE, NONE) => ()
  end

fun with_input path f =
  let val ins = TextIO.openIn path
  in (f ins before TextIO.closeIn ins)
     handle e => (TextIO.closeIn ins; raise e)
  end

fun detected_processors () =
  let
    fun count ins n =
      case TextIO.inputLine ins of
          NONE => n
        | SOME line =>
            if String.isPrefix "processor" line then count ins (n + 1)
            else count ins n
    val n = with_input "/proc/cpuinfo" (fn ins => count ins 0)
  in
    if n > 0 then n else 2
  end
  handle _ => 2

fun default_jobs () = Int.max (1, detected_processors () div 2)

fun effective_jobs (project : HolbuildProject.t) cli_jobs =
  case cli_jobs of
      SOME jobs => jobs
    | NONE => Option.getOpt (#local_build_jobs project, default_jobs ())

fun apply_project_local_remote_cache_config (project : HolbuildProject.t) =
  (HolbuildRemoteCacheConfig.set_local_url (HolbuildProject.remote_cache_url project);
   HolbuildRemoteCacheConfig.set_local_curl_config (HolbuildProject.remote_cache_curl_config project);
   (* The remote cache settings are final here, and no other thread has
      started yet. *)
   HolbuildRemoteCacheConfig.setup_client ();
   project)

fun load_project () =
  apply_project_local_remote_cache_config (HolbuildProject.discover ())
  handle HolbuildProject.Error msg => raise Error msg

fun context (tc : HolbuildToolchain.t) args =
  let
    val _ =
      case args of
          [] => ()
        | ["--trknl"] => ()
        | _ => raise Error "usage: holbuild context [--trknl]"
    val project = load_project ()
    val resolution = {kernel_variant = #kernel_variant tc}
    val _ = HolbuildProjectGraph.resolve
              {project = project, resolution = resolution}
  in
    HolbuildProject.describe_with resolution project
  end

fun timed_phase name f = HolbuildToolchain.time_phase name f

fun configure_analyser_for_toolchain ({holdir, ...} : HolbuildToolchain.t) =
  if holdir = "" then HolbuildDependencies.clear_analyser_path ()
  else HolbuildDependencies.set_analyser_path (HolbuildHolSharedCache.analyser_path_for_holdir holdir)

fun begin_stat_cache _ _ =
  (* A portable stat record cannot establish file content identity, so this
     cache has no safe hit path.  Keep it disabled until a sound criterion is
     available; direct hashing avoids its stats, locks, and cache-file I/O. *)
  (HolbuildStatCache.clear_current_instance (); NONE)

fun emit_stat_cache_stats instance_opt =
  let
    val {hits, recomputes} =
      case instance_opt of
          SOME instance => HolbuildStatCache.stats instance
        | NONE => {hits = 0, recomputes = 0}
  in
    HolbuildToolchain.record_phase_detail 1 "build.stat_cache" (Time.fromMilliseconds 0)
      ["enabled=" ^ Bool.toString (Option.isSome instance_opt),
       "hits=" ^ Int.toString hits,
       "recomputes=" ^ Int.toString recomputes]
  end

fun finish_stat_cache instance_opt =
  (emit_stat_cache_stats instance_opt;
   (case instance_opt of
        SOME instance => (HolbuildStatCache.flush instance handle _ => ())
      | NONE => ());
   HolbuildStatCache.clear_current_instance ())

fun resolution_for_toolchain (tc : HolbuildToolchain.t) =
  {kernel_variant = #kernel_variant tc}

fun prepare_source_index phase_prefix resolution project =
  let
    val graph = timed_phase (phase_prefix ^ ".graph.resolve")
                  (fn () => HolbuildProjectGraph.resolve
                    {project = project, resolution = resolution})
    val scans = timed_phase (phase_prefix ^ ".policies.prevalidate")
                  (fn () => HolbuildSourceIndex.prevalidate_graph graph)
    val preparation = timed_phase (phase_prefix ^ ".generators.prepare")
                        (fn () => HolbuildPackagePrepare.prepare graph)
    val discovery = timed_phase (phase_prefix ^ ".inventory.construct")
                      (fn () => HolbuildSourceIndex.discover_prepared_with_inventories scans preparation)
    val components = timed_phase (phase_prefix ^ ".components.load")
                       (fn () => HolbuildComponentProvider.load
                         HolbuildComponentProvider.LiveProvider
                         {preparation = preparation, discovery = discovery})
  in
    {index = HolbuildComponentProvider.sources components,
     components = components}
  end

(* A theory script may write SML sources as extra outputs, as EmitML code does.
   A plan made before the theory runs has no node for such a source while it is
   missing, so the sources that use it build without it, and it hashes a stale
   one.  Builds the planned theories that declare such outputs, and returns
   true when the caller must plan again over the sources they wrote. *)
fun build_generated_source_owners build components holdir index plan =
  case HolbuildBuildPlan.generated_source_owners plan of
      [] => false
    | owners => (build (HolbuildBuildPlan.plan_targets components holdir index owners); true)

(* What a planned build does: build its targets, or export their uncached
   theories for remote execution. *)
datatype build_mode =
    BuildTargets
  | ExportActionSpecs of {upload : bool}
  | RemoteExec of {url : string, remote_only : bool, detach : bool, attach : string option}

fun build_once_with_prepared_mode mode tc cli_jobs prepared ({dry_run, watch, force, use_cache, verify_cache, no_stat_cache, skip_checkpoints, proof_steps, new_ir, tactic_timeout, tactic_timeout_set, execution_plan, trace_steps, repl_on_failure, retain_debug_artifacts, warn_unreachable, emit_output_hashes, allow_cache_timeout_discrepancy}, targets) =
  let
    val project =
      case prepared of
          SOME {project, ...} => project
        | NONE => timed_phase "project.discover" load_project
    val resolution = resolution_for_toolchain tc
    val trknl = HolbuildToolchain.kernel_variant_tracing (#kernel_variant tc)
    (* Tracing builds collect proof traces, so by default they skip the proof
       development artifacts, as --skip-checkpoints --skip-proof-steps would.
       An explicit debugging flag turns back on what it needs. *)
    val debug_proof_steps = trace_steps orelse tactic_timeout_set orelse repl_on_failure
    val (skip_checkpoints, proof_steps, new_ir) =
      if trknl then
        (skip_checkpoints orelse not repl_on_failure,
         proof_steps andalso debug_proof_steps,
         new_ir andalso debug_proof_steps)
      else (skip_checkpoints, proof_steps, new_ir)
    val _ = HolbuildStatus.set_retain_debug_artifacts retain_debug_artifacts
    val jobs = if repl_on_failure then 1 else effective_jobs project cli_jobs
    val _ = HolbuildDependencies.set_analyser_jobs jobs
    val _ =
      if HolbuildStatus.json_mode () andalso dry_run then
        raise Error "--json does not support build --dry-run yet"
      else if HolbuildStatus.json_mode () andalso trace_steps then
        raise Error "--json does not support --trace-steps until structured proof-step trace events exist"
      else if dry_run andalso trace_steps then
        raise Error "--trace-steps requires build execution; use --force to inspect up-to-date targets"
      else if dry_run andalso repl_on_failure then
        raise Error "--repl-on-failure requires build execution"
      else if HolbuildStatus.json_mode () andalso repl_on_failure then
        raise Error "--json does not support --repl-on-failure"
      else if skip_checkpoints andalso repl_on_failure then
        raise Error "--repl-on-failure requires checkpoints; remove --skip-checkpoints"
      else if not proof_steps andalso new_ir then
        raise Error "proof steps are required for proof IR; remove --skip-proof-steps"
      else if not proof_steps andalso tactic_timeout_set then
        raise Error "--tactic-timeout requires proof steps; remove --skip-proof-steps"
      else if not proof_steps andalso trace_steps then
        raise Error "--trace-steps requires proof steps; remove --skip-proof-steps"
      else if not proof_steps andalso repl_on_failure then
        raise Error "--repl-on-failure requires proof steps; remove --skip-proof-steps"
      else ()
    val stat_cache = begin_stat_cache project no_stat_cache
    fun default_tactic_timeout () =
      case #build_tactic_timeout project of
          NONE => SOME 2.5
        | SOME timeout => timeout
    fun build_options_for index entry_plan plan force_targets =
      {use_cache = use_cache,
       verify_cache = verify_cache,
       force = force,
       force_targets = force_targets,
       skip_checkpoints = skip_checkpoints,
       proof_steps = proof_steps,
       new_ir = new_ir,
       node_tactic_timeouts =
         let
           (* Resolve all manifest entries even when CLI policy wins, so invalid
              configuration is never hidden by an invocation override. *)
           val node_local = HolbuildTacticTimeoutPolicy.theory_timeouts project index plan
         in
           if not proof_steps then []
           else if tactic_timeout_set then
             HolbuildTacticTimeoutPolicy.plan_timeouts project plan tactic_timeout
           else
             let
               val selected =
                 HolbuildTacticTimeoutPolicy.combine_timeouts
                   (HolbuildTacticTimeoutPolicy.plan_timeouts project plan
                      (default_tactic_timeout ()))
                   (HolbuildTacticTimeoutPolicy.entry_timeouts project index plan
                      (default_tactic_timeout ()))
               val explicit =
                 case entry_plan of
                     NONE => []
                   | SOME explicit_plan =>
                       HolbuildTacticTimeoutPolicy.entry_timeouts project index explicit_plan
                         (default_tactic_timeout ())
             in
               HolbuildTacticTimeoutPolicy.replace_timeouts
                 (HolbuildTacticTimeoutPolicy.combine_timeouts selected explicit)
                 node_local
             end
         end,
       execution_plan = execution_plan,
       trace_steps = trace_steps,
       repl_on_failure = repl_on_failure,
       emit_output_hashes = emit_output_hashes,
       allow_cache_timeout_discrepancy = allow_cache_timeout_discrepancy,
       trknl = trknl,
       restore_only = (case mode of RemoteExec {remote_only, ...} => remote_only | _ => false)}
    fun prepared_sources () =
      case prepared of
          SOME {index, components, ...} => {index = index, components = components}
        | NONE => prepare_source_index "build" resolution project
    type planned =
      {index : HolbuildSourceIndex.t, targets : string list, entry_plan : HolbuildBuildPlan.t option,
       plan : HolbuildBuildPlan.t, toolchain_key : string,
       components : HolbuildComponentProvider.project_components option}
    fun entry_targets index =
      if proof_steps then map #2 (HolbuildTacticTimeoutPolicy.explicit_entries project index) else []
    fun prepare_plan {index, components} =
      let
        val requested_targets = targets
        val targets = timed_phase "targets.default" (fn () => default_build_targets resolution project index requested_targets)
        val _ = reject_object_targets targets
        val plan = timed_phase "build.plan" (fn () => build_target_plan resolution components (#holdir tc) project index requested_targets targets)
        val entry_plan =
          case entry_targets index of
              [] => NONE
            | entry_targets =>
                SOME (timed_phase "entry_timeout.plan"
                        (fn () => HolbuildBuildPlan.plan_targets components (#holdir tc) index entry_targets))
        val toolchain_key = timed_phase "toolchain.key" (fn () => HolbuildToolchain.toolchain_key tc)
      in
        {index = index, targets = targets, entry_plan = entry_plan, plan = plan,
         toolchain_key = toolchain_key, components = SOME components}
      end
    fun action_toolchain_key toolchain_key = HolbuildToolchain.action_toolchain_key tc (fn _ => toolchain_key)
    fun with_options (planned as {index, targets, entry_plan, plan, ...}) =
      (planned, build_options_for index entry_plan plan targets)
    (* The input keys of a plan, which the plan keeps for execution.  Only
       for plans whose theories that write SML sources are up to date: until
       those run, an extra input naming such a source may not exist. *)
    fun input_keys ({plan, toolchain_key, ...} : planned, options) =
      HolbuildBuildPlan.input_keys (HolbuildBuildExec.build_config_lines_for_node options project)
        (action_toolchain_key toolchain_key) plan
    fun warn_unreachable_for ({index, plan, ...} : planned) =
      if warn_unreachable andalso null targets then
        warn_unreachable_root_scripts resolution project index plan
      else ()
    (* The first theory that writes SML sources and is not up to date, whose
       sources a plan cannot yet hold as they will be.  KEYS are computed
       only once every such theory's outputs exist, since an extra input
       may name one. *)
    fun stale_source_owner ({plan, toolchain_key, ...} : planned, options) keys =
      let
        val owners = HolbuildBuildPlan.generated_source_owner_nodes plan
        fun outputs_exist owner =
          List.all (fn declaration => OS.FileSys.access (HolbuildBuildPlan.extra_output_path owner declaration, []))
            (#extra_outputs (HolbuildBuildPlan.dependencies plan owner))
      in
        case List.find (not o outputs_exist) owners of
            SOME owner => SOME owner
          | NONE =>
              List.find (not o HolbuildBuildExec.node_is_up_to_date options project plan (keys ()) toolchain_key)
                owners
      end
    (* Plans from the record when it holds; AFTER_OWNERS plans again, in
       full, once the theories that write SML sources have run. *)
    fun plan_with_record after_owners =
      let
        val start_ns = Time.toNanoseconds (Time.now ())
        val record_mode = HolbuildPlanRecord.mode ()
        val graph = timed_phase "build.graph.resolve"
                      (fn () => HolbuildProjectGraph.resolve {project = project, resolution = resolution})
        val record_dir = HolbuildPlanRecord.record_dir project
        val fingerprint = HolbuildPlanRecord.fingerprint
                            {project = project, graph = graph, holdir = #holdir tc, kernel_variant = #kernel_variant tc}
        fun say text = if HolbuildStatus.verbose_mode () then HolbuildStatus.message_stderr ("holbuild: plan: " ^ text ^ "\n") else ()
        val attempt =
          case record_mode of
              HolbuildPlanRecord.Off => HolbuildPlanRecord.Fallback "plan record is off"
            | _ =>
              if after_owners then HolbuildPlanRecord.Fallback "theories that write SML sources ran"
              else timed_phase "plan.record" (fn () =>
                     HolbuildPlanRecord.restore {dir = record_dir, graph = graph, tc = tc, fingerprint = fingerprint, start_ns = start_ns})
        fun context {members, dirs, stamps, index, targets, toolchain_key} : HolbuildPlanRecord.context =
          {fingerprint = fingerprint, start_ns = start_ns,
           toolchain = {hol = HolbuildToolchain.hol tc, state = HolbuildToolchain.base_state tc, key = toolchain_key},
           action_toolchain_key = action_toolchain_key toolchain_key,
           graph = graph, members = members, dirs = dirs, stamps = stamps, index = index, targets = targets}
        fun write context prior plan keys =
          case timed_phase "plan.record.write"
                 (fn () => HolbuildPlanRecord.write record_dir context prior plan keys) of
              HolbuildPlanRecord.Written => ()
            | HolbuildPlanRecord.NotWritten reason => say ("plan record not written: " ^ reason)
        (* Check mode plans in full only to compare, and keeps the record
           the restored plan wrote, so the suite reads such records back. *)
        fun full {reason, record} =
          let
            val _ = say ("full (" ^ reason ^ ")")
            val members = HolbuildPlanRecord.member_kinds graph
            val planned as ({index, targets, plan, toolchain_key, ...}, _) =
              with_options (prepare_plan (prepare_source_index "build" resolution project))
            fun record_plan () =
              case stale_source_owner planned (fn () => input_keys planned) of
                  SOME owner =>
                    say ("plan record not written: " ^ HolbuildBuildPlan.logical_name owner ^
                         " writes SML sources and is not up to date")
              | NONE =>
                  write (context {members = members,
                                  dirs = HolbuildPlanRecord.watched_dirs graph (rev (!HolbuildSourceIndex.observed_dirs)),
                                  stamps = Binarymap.mkDict String.compare, index = index,
                                  targets = targets, toolchain_key = toolchain_key})
                    NONE plan (input_keys planned)
            val _ =
              if not record then ()
              else if List.exists (not o null o HolbuildProject.package_generators) (HolbuildProjectGraph.packages graph)
              then say "plan record not written: the project has generators"
              else record_plan ()
          in
            planned
          end
        fun restored {index, targets, plan, toolchain_key, changed, record, stamps, rehashed} =
          let
            (* With every root that has its own tactic timeout selected, the
               plan holds each such root's closure, which is all the entry
               plan would add. *)
            val entry_plan =
              case entry_targets index of
                  [] => NONE
                | entry_targets =>
                    if List.all (fn target => List.exists (fn node => HolbuildBuildPlan.logical_name node = target)
                                                          (HolbuildBuildPlan.selected_nodes plan))
                                entry_targets
                    then SOME plan
                    else raise HolbuildPlanRecord.Fall "a root with its own tactic timeout is not selected"
            val planned =
              with_options {index = index, targets = targets, entry_plan = entry_plan, plan = plan,
                            toolchain_key = toolchain_key, components = NONE}
            val keys = input_keys planned
            (* The record's generated sources hold only while their writers
               would not run again. *)
            val _ =
              case stale_source_owner planned (fn () => keys) of
                  SOME owner =>
                    raise HolbuildPlanRecord.Fall (HolbuildBuildPlan.logical_name owner ^
                                                   " writes SML sources and is not up to date")
                | NONE => ()
            val changed_keys = HolbuildPlanRecord.changed_keys record plan keys
            val _ = say ("from record (" ^ Int.toString rehashed ^ " files rehashed, " ^
                         Int.toString changed_keys ^ " keys changed)")
            val _ =
              if changed orelse changed_keys > 0 then
                write (context {members = #members record,
                                dirs = map (fn {path, entries, ...} =>
                                              (path, Binarymap.peek(stamps, path), entries)) (#dirs record),
                                stamps = stamps, index = index, targets = targets,
                                toolchain_key = toolchain_key})
                  (SOME record) plan keys
              else ()
          in
            (* Check mode builds from the record too, once full planning agrees. *)
            case record_mode of
                HolbuildPlanRecord.Check =>
                  let val from_full = full {reason = "checking the plan record", record = false}
                  in HolbuildPlanRecord.compare ((#1 planned, keys), (#1 from_full, input_keys from_full)) end
              | _ => ();
            planned
          end
      in
        case attempt of
            HolbuildPlanRecord.Fallback reason => full {reason = reason, record = record_mode <> HolbuildPlanRecord.Off}
          | HolbuildPlanRecord.Restored restored_plan =>
              restored restored_plan
              handle HolbuildPlanRecord.Fall reason => full {reason = reason, record = true}
      end
    (* Plans the build, from the plan record when it applies. *)
    fun plan_build () =
      let
        val planned as (sources, _) =
          case prepared of
              SOME _ => with_options (prepare_plan (prepared_sources ()))
            | NONE => if watch then with_options (prepare_plan (prepared_sources ())) else plan_with_record false
      in
        warn_unreachable_for sources;
        planned
      end
    fun describe_dry_run () =
      let val ({plan, toolchain_key, ...}, build_options) = plan_build ()
      in
        timed_phase "dry_run.describe"
          (fn () => HolbuildBuildPlan.describe (HolbuildBuildExec.build_config_lines_for_node build_options project)
                      (action_toolchain_key toolchain_key) plan)
      end
    fun execute_build () =
      let
        fun execute (options, plan, toolchain_key) =
          timed_phase "build.execute"
            (fn () => HolbuildBuildExec.build options tc project plan toolchain_key jobs)
        val ({index, entry_plan, plan, toolchain_key, components, ...}, options) = plan_build ()
        fun build_owners owner_plan =
          execute (build_options_for index entry_plan owner_plan [], owner_plan, toolchain_key)
        fun replan () =
          if Option.isSome prepared orelse watch
          then with_options (prepare_plan (prepare_source_index "build" resolution project))
          else plan_with_record true
      in
        case components of
            (* A plan from the record holds the generated sources as their
               up-to-date writers left them. *)
            NONE => execute (options, plan, toolchain_key)
          | SOME components =>
              if build_generated_source_owners build_owners components (#holdir tc) index plan then
                let val (planned as {plan, toolchain_key, ...}, options) = replan ()
                in warn_unreachable_for planned; execute (options, plan, toolchain_key) end
              else execute (options, plan, toolchain_key)
      end
    fun export_action_specs upload () =
      let val ({plan, toolchain_key, ...}, build_options) = plan_build ()
      in
        timed_phase "action_spec.export"
          (fn () => print (HolbuildBuildExec.export_action_specs build_options tc project plan toolchain_key jobs
                             {upload = upload, local_resumable = false, remote_only = false}))
      end
    (* Theories the remote cache lacks go to the coordinator as a batch; once
       it finishes, the ordinary build restores them from the remote cache. *)
    fun remote_build {url, remote_only, detach, attach} =
      let
        val _ =
          if Option.isSome (HolbuildRemoteCacheConfig.url ()) then ()
          else raise Error "--remote-exec needs a remote cache: pass --remote-cache URL"
        val ({plan, toolchain_key, ...}, build_options) = plan_build ()
        fun export upload =
          timed_phase "action_spec.export"
            (fn () => HolbuildBuildExec.export_action_specs build_options tc project plan toolchain_key jobs
                        {upload = upload, local_resumable = not detach, remote_only = remote_only})
        fun batch_keys batch =
          List.mapPartial (fn line => case String.tokens Char.isSpace line of
                                          "action" :: key :: _ => SOME key
                                        | _ => NONE)
                          (String.tokens (fn c => c = #"\n") batch)
        fun build_locally () =
          timed_phase "build.execute"
            (fn () => HolbuildBuildExec.build build_options tc project plan toolchain_key jobs)
        (* Under --remote-only the build options only restore (restore_only);
           a detached build has nothing to fall back to. *)
        fun fall_back reason =
          if detach then raise Error ("remote execution: " ^ reason)
          else if remote_only then
            (HolbuildHolSharedCache.local_build_needed := true;
             raise Error ("remote execution: " ^ reason))
          else (HolbuildBuildExec.warn ("remote execution: " ^ reason ^ "; building locally");
                build_locally ())
        fun finished {built, total} =
          if total = 0 then "the coordinator reported no theories"
          else "remote workers finished " ^ Int.toString built ^ " of " ^ Int.toString total ^ " theories"
        (* A batch the build stops following is cancelled (a finished one is
           left as it is), before it builds locally or, under --remote-only,
           fails for its caller to build locally. *)
        fun abandon batch_id reason =
          if HolbuildRemoteExec.cancel url batch_id then fall_back (reason ^ ", cancelled the batch")
          else fall_back reason
        (* Builds theory `logical` and what it needs, and nothing else. *)
        fun build_theory_locally logical =
          let
            val {index, components} = prepare_source_index "build" resolution project
            val theory_plan = HolbuildBuildPlan.plan_targets components (#holdir tc) index [logical]
            val entry_plan =
              case entry_targets index of
                  [] => NONE
                | entry_targets => SOME (HolbuildBuildPlan.plan_targets components (#holdir tc) index entry_targets)
          in
            timed_phase "build.execute"
              (fn () => HolbuildBuildExec.build (build_options_for index entry_plan theory_plan targets)
                          tc project theory_plan toolchain_key jobs)
          end
        (* A batch that failed because a proof did: a local build would fail
           the same way, so the build restores what the cache holds, reports
           the failure from the worker's build log and stops, building nothing
           locally.  Without the log, it builds the failed theory locally
           for its diagnostic. *)
        fun proof_failed reason ({input_key, kind, log_sha256} : HolbuildRemoteExec.proof_failure) =
          let
            val no_log = "could not fetch the failed theory's build log"
          in
            HolbuildStatus.message_stderr ("holbuild: remote execution: " ^ reason ^ "\n");
            HolbuildBuildExec.build (HolbuildBuildExec.restore_only_options build_options)
              tc project plan toolchain_key jobs
            handle HolbuildBuildExec.Error _ => ()
                 | HolbuildBuildExec.ErrorWithDebugArtifacts _ => ();
            (* The restore stops at a theory the cache lacks, the failed one if
               no other, which isn't why this build fails. *)
            HolbuildHolSharedCache.local_build_needed := false;
            case HolbuildBuildExec.node_with_input_key build_options tc project plan toolchain_key input_key of
                NONE => fall_back no_log
              | SOME node =>
                  case HolbuildBuildExec.remote_proof_failure build_options tc project plan toolchain_key node
                         {kind = kind, log_sha256 = log_sha256} of
                      SOME error => raise error
                    | NONE =>
                        if remote_only then fall_back no_log
                        else (HolbuildBuildExec.warn ("remote execution: " ^ no_log ^ "; building " ^
                                                      HolbuildBuildPlan.logical_name node ^ " locally");
                              build_theory_locally (HolbuildBuildPlan.logical_name node))
          end
        (* A batch that abandon would cancel is cancelled on an interrupt too.
           While it runs, the entries of the theories it finishes, and of a
           submitted batch the theories outside it that the remote cache
           already holds, are copied into the local cache, for the build
           that follows to restore.  An attached batch's theories are
           unknown, so none of the others are copied before it ends. *)
        fun follow in_batch batch_id =
          let
            val {add, stop} =
              HolbuildBuildExec.start_remote_exec_prefetch build_options tc project plan toolchain_key jobs in_batch
            fun follow_batch () =
              (HolbuildRemoteExec.follow url batch_id add before stop ())
              handle e => (stop (); raise e)
          in
            HolbuildRemoteExec.while_followed url batch_id follow_batch
          end
        fun finish in_batch batch_id =
          case follow in_batch batch_id of
              (HolbuildRemoteExec.Done, progress) =>
                (HolbuildStatus.message_stderr ("holbuild: remote execution: " ^ finished progress ^ "\n");
                 build_locally ())
            | (HolbuildRemoteExec.Failed (reason, NONE), progress) =>
                fall_back ("batch " ^ batch_id ^ " " ^ reason ^ "; " ^ finished progress)
            | (HolbuildRemoteExec.Failed (reason, SOME failure), progress) =>
                proof_failed ("batch " ^ batch_id ^ " " ^ reason ^ "; " ^ finished progress) failure
            | (HolbuildRemoteExec.Cancelled, progress) =>
                let val reason = "batch " ^ batch_id ^ " cancelled; " ^ finished progress
                in
                  (* Whoever cancelled it stopped this work, so a --remote-only
                     build doesn't ask for it to be built locally instead. *)
                  if remote_only then raise Error ("remote execution: " ^ reason) else fall_back reason
                end
            | (HolbuildRemoteExec.Unfollowable reason, progress) =>
                abandon batch_id ("batch " ^ batch_id ^ " " ^ reason ^ "; " ^ finished progress)
            | (HolbuildRemoteExec.Unreachable reason, progress) =>
                if remote_only
                then fall_back (reason ^ "; " ^ finished progress ^ "; reattach with --attach " ^ batch_id)
                else abandon batch_id (reason ^ "; " ^ finished progress)
        fun submit batch =
          if null (batch_keys batch) then
            (HolbuildStatus.message_stderr "holbuild: remote execution: nothing to build remotely\n";
             build_locally ())
          else
            case HolbuildRemoteExec.submit url batch of
                HolbuildRemoteExec.Refused reason => fall_back reason
              | HolbuildRemoteExec.Ok batch_id =>
                  (HolbuildStatus.message_stderr ("holbuild: remote batch " ^ batch_id ^ "\n");
                   if detach then () else finish (SOME (batch_keys batch)) batch_id)
        (* A theory that writes SML sources runs before the rest of the build
           is planned (execute_build), which neither a batch nor the restore
           build of this plan does.  Under --remote-only, execute_build only
           restores (restore_only). *)
        val writes_sources = not (null (HolbuildBuildPlan.generated_source_owners plan))
        val reason = "theories that write SML sources build before the rest is planned"
      in
        if writes_sources andalso detach then raise Error ("remote execution: " ^ reason)
        else if writes_sources andalso remote_only then
          (HolbuildStatus.message_stderr ("holbuild: remote execution: " ^ reason ^ "; restoring from the cache\n");
           Option.app (fn batch_id => ignore (HolbuildRemoteExec.cancel url batch_id)) attach;
           execute_build ())
        else if writes_sources then
          (HolbuildBuildExec.warn ("remote execution: " ^ reason ^ "; building locally");
           Option.app (fn batch_id => ignore (HolbuildRemoteExec.cancel url batch_id)) attach;
           execute_build ())
        else
          case attach of
              SOME batch_id => finish NONE batch_id
            | NONE =>
                (case HolbuildRemoteExec.Ok (export true)
                      handle HolbuildBuildExec.Error reason => HolbuildRemoteExec.Refused reason of
                     HolbuildRemoteExec.Ok batch => submit batch
                   | HolbuildRemoteExec.Refused reason => fall_back reason)
      end
    fun run_with_stat_cache f =
      (f (); finish_stat_cache stat_cache)
      handle e => (finish_stat_cache stat_cache; raise e)
  in
    case mode of
        ExportActionSpecs {upload} =>
          HolbuildBuildExec.with_project_lock project "action-spec"
            (fn () => run_with_stat_cache (export_action_specs upload))
      | BuildTargets =>
          if dry_run then run_with_stat_cache describe_dry_run
          else HolbuildBuildExec.with_project_lock project "build" (fn () => run_with_stat_cache execute_build)
      | RemoteExec remote =>
          HolbuildBuildExec.with_project_lock project "build"
            (fn () => run_with_stat_cache (fn () => remote_build remote))
  end

fun build_once_with_prepared tc = build_once_with_prepared_mode BuildTargets tc

fun build_once tc cli_jobs parsed = build_once_with_prepared tc cli_jobs NONE parsed

fun action_spec_command tc cli_jobs args =
  let
    val upload = List.exists (fn arg => arg = "--upload") args
    val parsed as ({dry_run, watch, trace_steps, repl_on_failure, execution_plan, ...}, _) =
      split_flags (List.filter (fn arg => arg <> "--upload") args)
    val _ =
      if dry_run orelse watch orelse trace_steps orelse repl_on_failure orelse Option.isSome execution_plan then
        raise Error "action-spec does not run builds: remove --dry-run, --watch, --trace-steps and --repl-on-failure"
      else ()
  in
    build_once_with_prepared_mode (ExportActionSpecs {upload = upload}) tc cli_jobs NONE parsed
  end

fun build_iteration_error_message exn =
  case exn of
      Error msg => SOME msg
    | HolbuildProcessGroup.Error msg => SOME msg
    | HolbuildToolchain.Error msg => SOME msg
    | HolbuildProject.Error msg => SOME msg
    | HolbuildGenerators.Error msg => SOME msg
    | HolbuildGenerators.ErrorWithDebugArtifacts (msg, _) => SOME msg
    | HolbuildPackagePrepare.Error msg => SOME msg
    | HolbuildPackagePrepare.ErrorWithDebugArtifacts (msg, _) => SOME msg
    | HolbuildPackageComponent.Error msg => SOME msg
    | HolbuildComponentProvider.Error msg => SOME msg
    | HolbuildSourceIndex.Error msg => SOME msg
    | HolbuildSourceIndex.ErrorWithDebugArtifacts (msg, _) => SOME msg
    | HolbuildDependencies.Error msg => SOME msg
    | HolbuildBuildPlan.Error msg => SOME msg
    | HolbuildBuildPlan.UnknownTarget unknown => SOME (HolbuildBuildPlan.unknown_target_message unknown)
    | HolbuildBuildExec.Error msg => SOME msg
    | HolbuildBuildExec.ErrorWithDebugArtifacts (msg, _) => SOME msg
    | HolbuildHolSharedCache.Error msg => SOME msg
    | HolbuildCache.Error msg => SOME msg
    | HolbuildCacheConfig.Error msg => SOME msg
    | HolbuildWatch.Error msg => SOME msg
    | _ => NONE

fun current_watch_state resolution previous_paths =
  let
    val project = timed_phase "watch.project.discover" load_project
    val {index, components} = prepare_source_index "watch" resolution project
    val watch_set = HolbuildWatch.watch_paths_with resolution project index
  in
    {prepared = SOME {project = project, index = index,
                      components = components, paths = #paths watch_set},
     watch_set = watch_set}
  end
  handle exn =>
    case (build_iteration_error_message exn, previous_paths) of
        (SOME msg, SOME watch_set) =>
          (warn ("could not recompute watch set: " ^ msg);
           {prepared = NONE, watch_set = watch_set})
      | (SOME msg, NONE) => raise Error ("could not compute watch set: " ^ msg)
      | (NONE, _) => raise exn

fun build_watch tc cli_jobs parsed =
  let
    val resolution = resolution_for_toolchain tc
    val _ = HolbuildWatch.ensure_inotifywait ()
    fun attempt prepared =
      (build_once_with_prepared tc cli_jobs prepared parsed; ())
      handle exn =>
        case build_iteration_error_message exn of
            SOME msg => warn ("build failed: " ^ msg)
          | NONE => raise exn
    fun loop previous_paths =
      let
        val {prepared, watch_set = previous} = current_watch_state resolution previous_paths
        val _ = attempt prepared
        (* Recompute the watch set after the build so inputs created during the
           build are watched immediately, not only after the next change. *)
        val {prepared = _, watch_set} = current_watch_state resolution (SOME previous)
        val _ = warn ("watching " ^ Int.toString (length (#paths watch_set)) ^
                      " project path(s); waiting for changes")
        val _ = HolbuildWatch.wait_for_change watch_set
      in
        loop (SOME watch_set)
      end
  in
    loop NONE
  end

(* Takes build's remote-execution options out of its arguments. *)
fun split_remote_exec_flags args =
  let
    fun loop (url, remote_only, detach, attach) acc xs =
      case xs of
          [] => ({url = url, remote_only = remote_only, detach = detach, attach = attach}, rev acc)
        | "--remote-exec" :: value :: rest =>
            if String.isPrefix "-" value then raise Error "--remote-exec requires URL"
            else loop (SOME value, remote_only, detach, attach) acc rest
        | ["--remote-exec"] => raise Error "--remote-exec requires URL"
        | "--remote-only" :: rest => loop (url, true, detach, attach) acc rest
        | "--detach" :: rest => loop (url, remote_only, true, attach) acc rest
        | "--attach" :: value :: rest =>
            if String.isPrefix "-" value then raise Error "--attach requires BATCH-ID"
            else loop (url, remote_only, detach, SOME value) acc rest
        | ["--attach"] => raise Error "--attach requires BATCH-ID"
        | x :: rest => loop (url, remote_only, detach, attach) (x :: acc) rest
  in
    loop (NONE, false, false, NONE) [] args
  end

fun build tc cli_jobs args =
  let
    val ({url, remote_only, detach, attach}, args) = split_remote_exec_flags args
    val parsed as ({dry_run, watch, repl_on_failure, trace_steps, execution_plan, ...}, _) = split_flags args
    val _ =
      if watch andalso HolbuildStatus.json_mode () then
        raise Error "--json does not support build --watch yet"
      else if watch andalso dry_run then
        raise Error "--watch does not support --dry-run"
      else if watch andalso repl_on_failure then
        raise Error "--watch does not support --repl-on-failure"
      else if not (Option.isSome url) andalso (remote_only orelse detach orelse Option.isSome attach) then
        raise Error "--remote-only, --detach and --attach need --remote-exec URL"
      else if Option.isSome url andalso
              (watch orelse dry_run orelse trace_steps orelse repl_on_failure orelse Option.isSome execution_plan) then
        raise Error "--remote-exec does not support --watch, --dry-run, --trace-steps, --execution-plan or --repl-on-failure"
      else if Option.isSome url andalso HolbuildStatus.json_mode () then
        raise Error "--json does not support --remote-exec yet"
      else if detach andalso Option.isSome attach then
        raise Error "--detach and --attach exclude each other"
      else ()
  in
    case url of
        SOME url =>
          build_once_with_prepared_mode
            (RemoteExec {url = url, remote_only = remote_only, detach = detach, attach = attach})
            tc cli_jobs NONE parsed
      | NONE =>
          if watch then build_watch tc cli_jobs parsed
          else build_once tc cli_jobs parsed
  end

fun chomp text =
  let
    fun loop n =
      if n > 0 andalso
         (String.sub(text, n - 1) = #"\n" orelse String.sub(text, n - 1) = #"\r") then
        loop (n - 1)
      else String.substring(text, 0, n)
  in
    loop (size text)
  end

fun command_output command =
  let
    val output = OS.FileSys.tmpName ()
    val status = OS.Process.system (command ^ " > " ^ HolbuildHash.quote output ^ " 2>/dev/null")
    val text = if OS.Process.isSuccess status then chomp (read_text output) else ""
    val _ = OS.FileSys.remove output handle OS.SysErr _ => ()
  in
    if text = "" then NONE else SOME text
  end
  handle _ => NONE

fun git_output root args =
  command_output ("git -C " ^ HolbuildHash.quote root ^ " " ^ args)

fun current_utc_timestamp () =
  Date.fmt "%Y-%m-%dT%H:%M:%SZ" (Date.fromTimeUniv (Time.now ()))

fun hol_dependency_metadata project =
  case HolbuildProject.resolved_hol_dependency project of
      SOME (HolbuildProject.Dependency {source = HolbuildProject.GitSource {git, rev}, ...}) =>
        {hol_repo = SOME git, hol_rev = SOME rev}
    | _ => {hol_repo = NONE, hol_rev = NONE}

fun hbx_export_metadata project =
  let
    val {hol_repo, hol_rev} = hol_dependency_metadata project
  in
    {created_at = SOME (current_utc_timestamp ()),
     source_repo = git_output (#root project) "config --get remote.origin.url",
     source_rev = git_output (#root project) "rev-parse HEAD",
     hol_repo = hol_repo,
     hol_rev = hol_rev} : HolbuildCacheArchive.metadata
  end

datatype export_args = ExportArgs of {build_first : bool, output : string, metadata_out : string option, targets : string list}

fun parse_export_args args =
  let
    fun done build_first output metadata_out targets =
      case output of
          SOME path => ExportArgs {build_first = build_first, output = path, metadata_out = metadata_out, targets = rev targets}
        | NONE => raise Error "usage: holbuild export [--build] -o FILE [--metadata-out FILE] [TARGET ...]"
    fun loop build_first output metadata_out targets rest =
      case rest of
          [] => done build_first output metadata_out targets
        | "--build" :: xs => loop true output metadata_out targets xs
        | "-o" :: path :: xs => loop build_first (SOME path) metadata_out targets xs
        | "--output" :: path :: xs => loop build_first (SOME path) metadata_out targets xs
        | "--metadata-out" :: path :: xs => loop build_first output (SOME path) targets xs
        | "-o" :: [] => raise Error "export -o requires FILE"
        | "--output" :: [] => raise Error "export --output requires FILE"
        | "--metadata-out" :: [] => raise Error "export --metadata-out requires FILE"
        | arg :: xs =>
            if String.isPrefix "--output=" arg then
              loop build_first (SOME (String.extract(arg, size "--output=", NONE))) metadata_out targets xs
            else if String.isPrefix "--metadata-out=" arg then
              loop build_first output (SOME (String.extract(arg, size "--metadata-out=", NONE))) targets xs
            else if String.isPrefix "--" arg then
              raise Error ("unknown export option: " ^ arg)
            else loop build_first output metadata_out (arg :: targets) xs
  in
    loop false NONE NONE [] args
  end

fun root_package_name project =
  HolbuildProject.package_name (HolbuildProject.project_package project)

fun default_build_options trknl project index entry_plan plan =
  let
    fun default_tactic_timeout () =
      case #build_tactic_timeout project of
          NONE => SOME 2.5
        | SOME timeout => timeout
  in
    {use_cache = true,
     verify_cache = true,
     force = HolbuildBuildExec.ForceNone,
     force_targets = [],
     skip_checkpoints = false,
     proof_steps = true,
     new_ir = true,
     node_tactic_timeouts =
       HolbuildTacticTimeoutPolicy.replace_timeouts
         (HolbuildTacticTimeoutPolicy.combine_timeouts
            (HolbuildTacticTimeoutPolicy.combine_timeouts
               (HolbuildTacticTimeoutPolicy.plan_timeouts project plan
                  (default_tactic_timeout ()))
               (HolbuildTacticTimeoutPolicy.entry_timeouts project index plan
                  (default_tactic_timeout ())))
            (case entry_plan of
                 NONE => []
               | SOME explicit_plan =>
                   HolbuildTacticTimeoutPolicy.entry_timeouts project index explicit_plan
                     (default_tactic_timeout ())))
         (HolbuildTacticTimeoutPolicy.theory_timeouts project index plan),
     execution_plan = NONE,
     trace_steps = false,
     repl_on_failure = false,
     emit_output_hashes = false,
     allow_cache_timeout_discrepancy = false,
     trknl = trknl,
     restore_only = false}
  end

(* Input keys a plain `holbuild build` uses for PLAN's nodes; they name the
   cache entries and checkpoints that build leaves behind. *)
fun default_build_input_keys tc project index components plan =
  let
    val explicit_entry_targets =
      map #2 (HolbuildTacticTimeoutPolicy.explicit_entries project index)
    val entry_plan =
      if null explicit_entry_targets then NONE
      else SOME (timed_phase "entry_timeout.plan"
                   (fn () => HolbuildBuildPlan.plan_targets components (#holdir tc) index explicit_entry_targets))
    val action_toolchain_key = HolbuildToolchain.action_toolchain_key tc HolbuildToolchain.toolchain_key
    val options = default_build_options (HolbuildToolchain.kernel_variant_tracing (#kernel_variant tc)) project index entry_plan plan
  in
    HolbuildBuildPlan.input_keys (HolbuildBuildExec.build_config_lines_for_node options project) action_toolchain_key plan
  end

(* Heaps and executables build their ancestors plain: proof steps and their
   tactic timeouts are checked by build, and a timeout-free request can reuse
   any cached theory, including ones from build --skip-proof-steps. *)
fun heap_build_options trknl =
  {use_cache = true,
   verify_cache = true,
   force = HolbuildBuildExec.ForceNone,
   force_targets = [],
   skip_checkpoints = false,
   proof_steps = false,
   new_ir = false,
   node_tactic_timeouts = [],
   execution_plan = NONE,
   trace_steps = false,
   repl_on_failure = false,
   emit_output_hashes = false,
   allow_cache_timeout_discrepancy = false,
   trknl = trknl,
   restore_only = false}

fun theory_node node =
  #kind (HolbuildBuildPlan.source_of node) = HolbuildSourceIndex.TheoryScript

fun cache_key_usable root key =
  case HolbuildCache.get_action root key of
      SOME text => HolbuildBuildExec.cache_entry_usable root key text
    | NONE => false

fun portable_cache_key_for_node root keys node =
  let
    val logical = HolbuildBuildPlan.logical_name node
    val cache_key = HolbuildBuildPlan.input_key_for keys node
  in
    if cache_key_usable root cache_key then cache_key
    else
      raise Error ("target " ^ logical ^
                   " is not built in the cache; run `holbuild build " ^
                   logical ^ "` first, or use `holbuild export --build`")
  end

fun export_entry_for_node project root keys node =
  let
    val cache_key = portable_cache_key_for_node root keys node
    val source = HolbuildBuildPlan.source_of node
    val package = HolbuildBuildPlan.package node
  in
    {key = cache_key,
     package = package,
     logical = HolbuildBuildPlan.logical_name node,
     source_path = #relative_path source,
     root = package = root_package_name project}
  end

fun export_entries project plan keys =
  let
    val root = HolbuildCache.cache_root ()
    val theory_nodes = List.filter theory_node (HolbuildBuildPlan.selected_nodes plan)
    val _ = if null theory_nodes then raise Error "export found no theory build outputs in the selected targets" else ()
  in
    map (export_entry_for_node project root keys) theory_nodes
  end
  handle HolbuildBuildExec.Error msg => raise Error msg

fun fs_cache_source cache : HolbuildCacheTransfer.source =
  {get_action = HolbuildFSCacheBackend.get_action cache,
   fetch_blob = HolbuildFSCacheBackend.fetch_blob cache}

fun file_size_string path = Position.toString (OS.FileSys.fileSize path)

fun json_escape text =
  let
    fun escape_char c =
      case c of
          #"\\" => "\\\\"
        | #"\"" => "\\\""
        | #"\n" => "\\n"
        | #"\r" => "\\r"
        | #"\t" => "\\t"
        | _ => if Char.ord c < 32 then "" else str c
  in
    "\"" ^ String.translate escape_char text ^ "\""
  end

fun json_string_field name value = json_escape name ^ ": " ^ json_escape value
fun json_int_field name value = json_escape name ^ ": " ^ Int.toString value
fun json_raw_field name value = json_escape name ^ ": " ^ value
fun json_array_field name values =
  json_escape name ^ ": [" ^ String.concatWith ", " (map json_escape values) ^ "]"

fun optional_json_string_field name value =
  case value of
      SOME text => [json_string_field name text]
    | NONE => []

fun export_metadata_json {archive_path, targets, action_count, metadata} =
  let
    val sha256 = HolbuildHash.file_sha256 archive_path
    val {created_at, source_repo, source_rev, hol_repo, hol_rev} : HolbuildCacheArchive.metadata = metadata
    val fields =
      [json_string_field "format" "holbuild-hbx-metadata-v1",
       json_string_field "archive_format" HolbuildCacheArchive.format,
       json_string_field "archive" (OS.Path.file archive_path),
       json_string_field "sha256" sha256,
       json_raw_field "size" (file_size_string archive_path),
       json_array_field "targets" targets,
       json_int_field "action_count" action_count,
       json_string_field "holbuild_version" HolbuildVersion.version] @
      optional_json_string_field "created_at" created_at @
      optional_json_string_field "source_repo" source_repo @
      optional_json_string_field "source_rev" source_rev @
      optional_json_string_field "hol_repo" hol_repo @
      optional_json_string_field "hol_rev" hol_rev
  in
    "{\n  " ^ String.concatWith ",\n  " fields ^ "\n}\n"
  end

fun write_export_metadata {path, archive_path, targets, action_count, metadata} =
  write_text_file path (export_metadata_json {archive_path = archive_path,
                                              targets = targets,
                                              action_count = action_count,
                                              metadata = metadata})

fun export_archive tc jobs args =
  let
    val ExportArgs {build_first, output, metadata_out, targets = requested_targets} = parse_export_args args
    val _ = if build_first then build tc jobs requested_targets else ()
    val project = timed_phase "project.discover" load_project
    val resolution = resolution_for_toolchain tc
    val {index, components} = prepare_source_index "export" resolution project
    val targets = timed_phase "targets.default" (fn () => default_build_targets resolution project index requested_targets)
    val _ = reject_object_targets targets
    val plan = timed_phase "build.plan" (fn () => build_target_plan resolution components (#holdir tc) project index requested_targets targets)
    val keys = default_build_input_keys tc project index components plan
    val entries = export_entries project plan keys
    val cache = HolbuildFSCacheBackend.default () handle HolbuildFSCacheBackend.Error msg => raise Error msg
    val metadata = hbx_export_metadata project
  in
    HolbuildCacheArchive.create_export {archive_path = output,
                                        source = fs_cache_source cache,
                                        entries = entries,
                                        targets = targets,
                                        metadata = metadata};
    Option.app (fn path => write_export_metadata {path = path,
                                                  archive_path = output,
                                                  targets = targets,
                                                  action_count = length entries,
                                                  metadata = metadata}) metadata_out;
    print ("exported " ^ Int.toString (length entries) ^ " cache action(s) to " ^ output ^ "\n")
  end

fun fs_cache_destination cache : HolbuildCacheTransfer.destination =
  {put_action = HolbuildFSCacheBackend.put_action cache,
   publish_blob = HolbuildFSCacheBackend.publish_blob cache}

fun import_archive args =
  case args of
      [archive_path] =>
        let
          val destination = HolbuildFSCacheBackend.default () handle HolbuildFSCacheBackend.Error msg => raise Error msg
          val _ = HolbuildFSCacheBackend.ensure_layout destination
          val result_count = ref 0
          fun validate_action source key =
            case #get_action source key of
                SOME text =>
                  ignore (HolbuildBuildExec.cache_manifest_blobs_from_lines key
                            (HolbuildBuildExec.cache_manifest_lines text))
              | NONE => raise Error ("archive action missing: " ^ key)
          fun copy {source, keys} =
            let
              val _ = List.app (validate_action source) keys
              val results = HolbuildCacheTransfer.copy_entries
                              {source = source,
                               destination = fs_cache_destination destination,
                               tmp_dir = HolbuildFSCacheBackend.tmp_dir destination}
                              keys
            in
              result_count := length results
            end
        in
          HolbuildCacheArchive.with_entries {archive_path = archive_path, f = copy};
          print ("imported " ^ Int.toString (!result_count) ^ " cache action(s) from " ^ archive_path ^ "\n")
        end
    | _ => raise Error "usage: holbuild import FILE"


fun clean_targets args =
  let
    val project = timed_phase "project.discover" load_project
    val _ = if null args then raise Error "usage: holbuild clean THEORY..." else ()
    val _ = reject_object_targets args
    fun execute_clean () =
      let
        val {index, components} = prepare_source_index "clean"
                                  HolbuildProject.standard_resolution project
        val args = HolbuildSourceIndex.resolve_path_targets index args
        val plan = timed_phase "build.plan"
                     (fn () => HolbuildBuildPlan.plan_targets components "" index args)
        fun target_nodes target =
          case HolbuildBuildPlan.lookup plan target of
              [] => raise Error ("unknown clean target: " ^ target)
            | matches => matches
        fun require_theory node =
          case #kind (HolbuildBuildPlan.source_of node) of
              HolbuildSourceIndex.TheoryScript => node
            | _ => raise Error ("clean only supports theory targets: " ^ HolbuildBuildPlan.logical_name node)
        val nodes = List.concat (map target_nodes args)
        val theory_nodes = map require_theory nodes
        val _ = List.app (HolbuildBuildExec.clean_theory_node project plan) theory_nodes
        val _ = List.app (fn node => print ("cleaned " ^ HolbuildBuildPlan.logical_name node ^ "\n")) theory_nodes
        val _ = print "note: subsequent builds may restore cleaned targets from the global cache; use `holbuild build --no-cache TARGET...` to force a local rebuild\n"
      in
        ()
      end
  in
    HolbuildBuildExec.with_project_lock project "clean" execute_clean
  end

fun heap_kind_name HolbuildProject.HeapImage = "heap"
  | heap_kind_name (HolbuildProject.ExecutableImage _) = "executable"

fun heap_kind_matches "heap" HolbuildProject.HeapImage = true
  | heap_kind_matches "executable" (HolbuildProject.ExecutableImage _) = true
  | heap_kind_matches _ _ = false

fun heap_named project command target =
  let
    fun matches (HolbuildProject.Heap {name, ...}) = name = target
  in
    case List.find matches (#heaps project) of
        SOME (heap as HolbuildProject.Heap {kind, ...}) =>
        if heap_kind_matches command kind then heap
        else raise Error (target ^ " is a " ^ heap_kind_name kind ^ " target, not a " ^ command ^ " target")
      | NONE =>
          raise Error ("unknown " ^ command ^ " target: " ^ target ^
                       HolbuildSuggest.did_you_mean target
                         (List.mapPartial
                            (fn HolbuildProject.Heap {name, kind, ...} =>
                                if heap_kind_matches command kind then SOME name else NONE)
                            (#heaps project)))
  end

fun build_heap_kind tc cli_jobs command target =
  let
    val project = timed_phase "project.discover" load_project
    val jobs = effective_jobs project cli_jobs
    val _ = HolbuildDependencies.set_analyser_jobs jobs
    fun execute_heap () =
      let
        val HolbuildProject.Heap {output, objects, kind, ...} = heap_named project command target
        fun plan_heap () =
          let
            val {index, components} = prepare_source_index "heap"
                                      (resolution_for_toolchain tc) project
            val objects = HolbuildSourceIndex.expand_group_tokens index (HolbuildProject.project_package project) objects
            val _ = if null objects then raise Error (command ^ " target has no objects: " ^ target) else ()
            val plan = timed_phase "build.plan" (fn () => HolbuildBuildPlan.plan_targets components (#holdir tc) index objects)
            (* Unused without proof steps, but resolved so invalid configuration is
               reported here as it is by build. *)
            val _ = HolbuildTacticTimeoutPolicy.theory_timeouts project index plan
          in
            {index = index, components = components, plan = plan}
          end
        val toolchain_key = timed_phase "toolchain.key" (fn () => HolbuildToolchain.toolchain_key tc)
        val output_path = HolbuildProject.abs_under (#root project) output
        fun build_plan plan =
          HolbuildBuildExec.build (heap_build_options (HolbuildToolchain.kernel_variant_tracing (#kernel_variant tc)))
                                 tc project plan toolchain_key jobs
        val {index, components, plan} = plan_heap ()
        val plan =
          if build_generated_source_owners build_plan components (#holdir tc) index plan then #plan (plan_heap ())
          else plan
      in
        build_plan plan;
        HolbuildBuildExec.export_heap tc project plan output_path kind
      end
  in
    HolbuildBuildExec.with_project_lock project (command ^ " " ^ target) execute_heap
  end

fun build_heap tc cli_jobs target = build_heap_kind tc cli_jobs "heap" target
fun build_executable tc cli_jobs target = build_heap_kind tc cli_jobs "executable" target

(* `--from THEORY`, `--remote-exec URL` and `--remote-only` lead the HOL
   arguments; everything after them is passed to HOL unchanged. *)
fun split_run_options args =
  let
    fun select NONE theory =
          if theory = "" then raise Error "--from requires THEORY" else SOME theory
      | select (SOME _) _ = raise Error "--from given more than once"
    fun loop (from, url, remote_only) rest =
      case rest of
          "--from" :: theory :: xs =>
            if String.isPrefix "-" theory then raise Error "--from requires THEORY"
            else loop (select from theory, url, remote_only) xs
        | ["--from"] => raise Error "--from requires THEORY"
        | "--remote-exec" :: value :: xs =>
            if String.isPrefix "-" value then raise Error "--remote-exec requires URL"
            else loop (from, SOME value, remote_only) xs
        | ["--remote-exec"] => raise Error "--remote-exec requires URL"
        | "--remote-only" :: xs => loop (from, url, true) xs
        | arg :: xs =>
            if String.isPrefix "--from=" arg then
              loop (select from (String.extract (arg, size "--from=", NONE)), url, remote_only) xs
            else ({from = from, url = url, remote_only = remote_only}, rest)
        | [] => ({from = from, url = url, remote_only = remote_only}, [])
  in
    loop (NONE, NONE, false) args
  end

(* A .sig/.sml pair shares a logical name; a theory's name is unique. *)
fun from_theory_node plan theory =
  let
    val nodes = HolbuildBuildPlan.lookup plan theory
  in
    case (List.filter theory_node nodes, nodes) of
        (node :: _, _) => node
      | ([], node :: _) =>
          raise Error ("--from requires a theory target, not " ^ HolbuildBuildPlan.logical_name node)
      | ([], []) => raise Error ("--from " ^ theory ^ ": unknown build target: " ^ theory)
  end

fun from_theory_state tc project theory =
  let
    val {index, components} = prepare_source_index "run.from" (resolution_for_toolchain tc) project
    val target = hd (HolbuildSourceIndex.resolve_path_targets index [theory])
                 handle HolbuildSourceIndex.Error msg => raise Error ("--from " ^ theory ^ ": " ^ msg)
    val plan = timed_phase "run.from.plan"
                 (fn () => HolbuildBuildPlan.plan_targets components (#holdir tc) index [target])
                 handle HolbuildBuildPlan.Error msg => raise Error ("--from " ^ theory ^ ": " ^ msg)
                      | HolbuildBuildPlan.UnknownTarget unknown =>
                          raise Error ("--from " ^ theory ^ ": " ^ HolbuildBuildPlan.unknown_target_message unknown)
    val node = from_theory_node plan target
    val keys = default_build_input_keys tc project index components plan
  in
    HolbuildBuildExec.run_from_state tc project plan keys node
  end

(* The state HOL starts from, the lines the run context runs first, and the
   modules it loads before [run].loads. *)
type run_start = {holstate : string, context_lines : string list, loads : string list}

fun checkpoint_start path loads =
  {holstate = path, context_lines = HolbuildBuildExec.child_policy_reset_lines, loads = loads}

(* Where run and repl start: an explicit --from theory, the theory inferred
   from the script files HOL is given, or the fallback state (check). *)
datatype run_from = FromTheory of string | FromScripts of string list | NoFrom

(* The arguments HOL loads as scripts. *)
fun script_args args =
  List.filter
    (fn arg => String.isSuffix ".sml" arg andalso
               (OS.FileSys.access (arg, [OS.FileSys.A_READ]) handle OS.SysErr _ => false))
    args

(* Of the root-package theories SCRIPTS depend on, found by the dependency
   analysis build applies to sources, the one with the most ancestors.  When
   one of them has all the others as ancestors, that is the one. *)
fun infer_from_theory tc project scripts =
  let
    val _ = configure_analyser_for_toolchain tc
    val {index, components} = prepare_source_index "run.infer" (resolution_for_toolchain tc) project
    val root = root_package_name project
    fun referenced script =
      let val {loads, holdep_mentions, ...} = HolbuildDependencies.extract script
      in loads @ holdep_mentions end
    fun root_source name =
      List.exists (fn (source : HolbuildSourceIndex.source) =>
                     #logical_name source = name andalso #package source = root)
                  index
    val targets =
      List.foldr (fn (name, kept) => if List.exists (fn k => k = name) kept then kept else name :: kept)
        [] (List.filter root_source (List.concat (map referenced scripts)))
  in
    if null targets then NONE
    else
      let
        val plan = timed_phase "run.infer.plan"
                     (fn () => HolbuildBuildPlan.plan_targets components (#holdir tc) index targets)
        val theories =
          List.filter (fn node => theory_node node andalso HolbuildBuildPlan.package node = root)
            (HolbuildBuildPlan.selected_nodes plan)
        fun ancestors node =
          length (List.filter theory_node (HolbuildBuildPlan.transitive_project_deps plan node))
        fun deeper (node, NONE) = SOME node
          | deeper (node, SOME best) = SOME (if ancestors node > ancestors best then node else best)
      in
        Option.map HolbuildBuildPlan.logical_name (List.foldl deeper NONE theories)
      end
  end

(* A usable --from checkpoint takes precedence over [run].heap; without one,
   run starts from [run].heap when RUN_HEAP and it is configured, and from the
   base state otherwise. *)
fun run_start tc project run_heap from : run_start =
  let
    val (fallback, fallback_name) =
      case (run_heap, HolbuildProject.abs_run_heap project) of
          (true, SOME heap) => (heap, "[run].heap " ^ heap)
        | _ => (HolbuildToolchain.base_state tc, "the HOL base state")
    val fallback_start = {holstate = fallback, context_lines = [], loads = []}
    fun start label theory =
      let
        fun note text = HolbuildStatus.message_stderr ("holbuild: " ^ label ^ ": " ^ text ^ "\n")
      in
        case from_theory_state tc project theory of
            HolbuildBuildExec.DepsLoadedState {path, load = SOME stem} =>
              (note ("starting from its deps_loaded checkpoint and loading " ^ OS.Path.file stem);
               checkpoint_start path [stem])
          | HolbuildBuildExec.DepsLoadedState {path, load = NONE} =>
              (note ("it is not built for its current source; starting from its deps_loaded " ^
                     "checkpoint, which has only its ancestors loaded");
               checkpoint_start path [])
          | HolbuildBuildExec.NoRunFromState reason =>
              (note (reason ^ "; starting from " ^ fallback_name); fallback_start)
      end
  in
    case from of
        NoFrom => fallback_start
      | FromTheory theory => start ("--from " ^ theory) theory
      | FromScripts scripts =>
          (* Nobody asked for a theory, so a script or project the analysis or
             checkpoint lookup cannot handle starts HOL as it would without
             inference. *)
          (case infer_from_theory tc project scripts of
               NONE => fallback_start
             | SOME theory => start ("--from " ^ theory ^ " (inferred from the scripts' dependencies)") theory)
          handle exn =>
            case build_iteration_error_message exn of
                SOME msg =>
                  (HolbuildStatus.message_stderr
                     ("holbuild: could not infer --from from the scripts' dependencies: " ^ msg ^
                      "; starting from " ^ fallback_name ^ "\n");
                   fallback_start)
              | NONE => raise exn
  end

fun hol_run_argv tc holstate subcommand context user_args =
  HolbuildToolchain.hol_subcommand_argv tc subcommand @ ["--holstate", holstate, context] @ user_args

(* With run_heap false, HOL starts from the toolchain's base state even when
   [run].heap is configured. build_request builds the [run].loads targets, in
   build_mode (locally, or on remote workers). *)
fun run_hol_status runner tc cli_jobs build_mode build_request run_heap from subcommand user_args =
  let
    val configured_project = timed_phase "project.discover" load_project
    val run_loads = #run_loads configured_project
    val _ =
      if null run_loads then ()
      else build_once_with_prepared_mode build_mode tc cli_jobs NONE (build_request run_loads)
    val project =
      if null run_loads then configured_project
      else timed_phase "run.project.rediscover" load_project
    val {holstate, context_lines, loads} = run_start tc project run_heap from
    val packages = resolved_packages (resolution_for_toolchain tc) project
    fun invoke context =
      runner (hol_run_argv tc holstate subcommand context user_args)
  in
    HolbuildToolchain.with_run_context project packages context_lines loads invoke
  end

fun run_hol_with runner tc cli_jobs subcommand args =
  let
    val ({from, url, remote_only}, user_args) = split_run_options args
    val build_mode =
      case url of
          SOME url => RemoteExec {url = url, remote_only = remote_only, detach = false, attach = NONE}
        | NONE =>
            if remote_only then raise Error "--remote-only needs --remote-exec URL"
            else BuildTargets
    val run_from =
      case from of
          SOME theory => FromTheory theory
        | NONE =>
            (case script_args user_args of
                 [] => NoFrom
               | scripts => FromScripts scripts)
  in
    if HolbuildToolchain.success (run_hol_status runner tc cli_jobs build_mode default_build_request true run_from subcommand user_args) then ()
    else raise Error ("hol " ^ subcommand ^ " failed")
  end

fun run_hol tc cli_jobs subcommand user_args =
  run_hol_with HolbuildToolchain.run tc cli_jobs subcommand user_args

fun repl_hol tc cli_jobs user_args =
  run_hol_with HolbuildToolchain.run_interactive tc cli_jobs "repl" user_args

fun parse_check_selector selector =
  case String.fields (fn c => c = #":") selector of
      [theory] =>
        if theory = "" then raise Error "check requires THEORY or THEORY:THEOREM"
        else {theory = theory, theorem = NONE}
    | [theory, theorem] =>
        if theory = "" orelse theorem = "" then
          raise Error "check requires THEORY or THEORY:THEOREM"
        else {theory = theory, theorem = SOME theorem}
    | _ => raise Error "check requires THEORY or THEORY:THEOREM"

(* The theory names HOL itself does not declare: those of the root package
   and its dependency packages.  Axioms in these theories are findings. *)
fun project_theory_names tc project index =
  let
    val graph = HolbuildProjectGraph.resolve
                  {project = project, resolution = resolution_for_toolchain tc}
    val hol = HolbuildProjectGraph.hol graph
    fun project_theory source =
      theory_source source andalso #package_id (#node source) <> hol
  in
    map (HolbuildBuildExec.theory_name_from_logical o #logical_name)
        (List.filter project_theory index)
  end

(* An SML script for `hol run` that loads the theory and prints the
   findings.  Theorems loaded from disk keep their oracles but not the axioms
   they depend on, so axioms are found by scanning the ancestry instead. *)
fun check_script {logical_name, theorem, project_theories} =
  let
    val sml_string = HolbuildToolchain.sml_string
    val theory = HolbuildBuildExec.theory_name_from_logical logical_name
    val selected =
      case theorem of
          NONE => "NONE"
        | SOME name => "SOME " ^ sml_string name
  in
    String.concatWith "\n"
      [HolbuildToolchain.run_load_line logical_name,
       "local",
       "  val theory = " ^ sml_string theory,
       "  val selected : string option = " ^ selected,
       "  val project_theories = " ^ HolbuildToolchain.sml_list project_theories,
       "  fun out s = (TextIO.output(TextIO.stdOut, s ^ \"\\n\"); TextIO.flushOut TextIO.stdOut)",
       "  fun fail s = (TextIO.output(TextIO.stdErr, \"holbuild: \" ^ s ^ \"\\n\");",
       "                TextIO.flushOut TextIO.stdErr; OS.Process.exit OS.Process.failure)",
       "  fun qualified thy name = thy ^ \"Theory.\" ^ name",
       "  fun by_name ((a, _), (b, _)) = String.compare(a, b)",
       "  val stored = Listsort.sort by_name (DB.thms theory)",
       "  val checked =",
       "    case selected of",
       "        NONE => stored",
       "      | SOME name =>",
       "          (case List.filter (fn (n, _) => n = name) stored of",
       "               [] => fail (\"theorem not found: \" ^ qualified theory name)",
       "             | found => found)",
       "  fun theorem_oracles (name, th) =",
       "    case List.filter (fn s => s <> \"DISK_THM\") (#1 (Tag.dest_tag (Thm.tag th))) of",
       "        [] => []",
       "      | oracles => [qualified theory name ^ \": \" ^ String.concatWith \", \" oracles]",
       "  fun project_theory thy = List.exists (fn t => t = thy) project_theories",
       "  fun theory_axioms thy =",
       "    map (fn (name, _) => qualified thy name ^ \": axiom\")",
       "        (Listsort.sort by_name (DB.axioms thy))",
       "  val findings =",
       "    List.concat (map theorem_oracles checked) @",
       "    List.concat (map theory_axioms",
       "                   (List.filter project_theory (theory :: Theory.ancestry theory)))",
       "  fun count n noun = Int.toString n ^ \" \" ^ noun ^ (if n = 1 then \"\" else \"s\")",
       "  val subject =",
       "    case selected of NONE => theory ^ \"Theory\" | SOME name => qualified theory name",
       "in",
       "  val _ = List.app out findings",
       "  val _ =",
       "    if null findings then",
       "      out (subject ^ \": clean (\" ^ count (length checked) \"theorem\" ^ \")\")",
       "    else",
       "      (out (subject ^ \": \" ^ count (length findings) \"finding\");",
       "       OS.Process.exit OS.Process.failure)",
       "end;",
       ""]
  end

fun check_selector tc cli_jobs selector =
  let
    val {theory, theorem} = parse_check_selector selector
    val project = timed_phase "project.discover" load_project
    val {index, ...} = prepare_source_index "check" (resolution_for_toolchain tc) project
    val source = find_theory_source "check" index theory
    val _ = build_once tc cli_jobs (plain_build_request [#logical_name source])
    val script_path = HolbuildToolchain.invocation_sml_file project "holbuild-check"
    val _ = write_text_file script_path
              (check_script {logical_name = #logical_name source, theorem = theorem,
                             project_theories = project_theory_names tc project index})
    fun cleanup () = OS.FileSys.remove script_path handle OS.SysErr _ => ()
    val status =
      (* A run heap may hold an older copy of the theory, which load would keep. *)
      run_hol_status HolbuildToolchain.run tc cli_jobs BuildTargets plain_build_request false NoFrom "run" [script_path]
      handle e => (cleanup (); raise e)
  in
    cleanup ();
    if HolbuildToolchain.success status then () else OS.Process.exit OS.Process.failure
  end

fun check_command tc cli_jobs args =
  case args of
      [selector] => check_selector tc cli_jobs selector
    | _ => raise Error "usage: holbuild check THEORY[:THEOREM]"

fun removed_legacy_plan_command _ _ =
  raise Error "goalfrag-plan has been removed; use execution-plan THEORY:THEOREM"

fun execution_plan_command tc args =
  (configure_analyser_for_toolchain tc;
   case args of
       [selector] => print_execution_plan_selector true (load_project ()) selector
     | _ => raise Error "usage: holbuild execution-plan THEORY:THEOREM")

fun reject_json command =
  if HolbuildStatus.json_mode () then
    raise Error ("--json does not support " ^ command ^ " yet")
  else ()

fun dispatch tc jobs args =
  case args of
      [] => build tc jobs []
    | "context" :: rest => (reject_json "context"; context tc rest)
    | "execution-plan" :: rest => (reject_json "execution-plan"; execution_plan_command tc rest)
    | "check" :: rest => (reject_json "check"; check_command tc jobs rest)
    | "goalfrag-plan" :: rest => removed_legacy_plan_command tc rest
    | "build" :: rest => build tc jobs rest
    | "clean" :: rest => (reject_json "clean"; clean_targets rest)
    | "heap" :: [target] => (reject_json "heap"; build_heap tc jobs target)
    | "heap" :: _ => raise Error "usage: holbuild heap NAME"
    | "executable" :: [target] => (reject_json "executable"; build_executable tc jobs target)
    | "executable" :: _ => raise Error "usage: holbuild executable NAME"
    | "run" :: rest => (reject_json "run"; run_hol tc jobs "run" rest)
    | "repl" :: rest => (reject_json "repl"; repl_hol tc jobs rest)
    | "export" :: rest => (reject_json "export"; export_archive tc jobs rest)
    | "action-spec" :: rest => (reject_json "action-spec"; action_spec_command tc jobs rest)
    | "import" :: rest => (reject_json "import"; import_archive rest)
    | cmd :: _ =>
        if known_command cmd then raise Error ("unknown command: " ^ cmd)
        else
          (* A first word that is no target may be a mistyped command. *)
          build tc jobs args
          handle HolbuildBuildPlan.UnknownTarget (target, candidates) =>
            raise HolbuildBuildPlan.UnknownTarget
                    (target, if target = cmd then command_names @ candidates else candidates)

datatype gc_scope = GcProjectAndCache | GcProjectOnly | GcCacheOnly | GcToolchainsOnly

fun gc_scope_flag scope =
  case scope of
      GcProjectAndCache => ""
    | GcProjectOnly => "--clean-only"
    | GcCacheOnly => "--cache-only"
    | GcToolchainsOnly => "--toolchains-only"

fun select_gc_scope scope selected =
  if scope = GcProjectAndCache orelse scope = selected then selected
  else raise Error (gc_scope_flag scope ^ " and " ^ gc_scope_flag selected ^ " are mutually exclusive")

fun parse_gc_args args =
  let
    fun loop days max_checkpoints_gb scope rest =
      case rest of
          [] => (days, max_checkpoints_gb, scope)
        | "--retention-days" :: n :: xs => loop (HolbuildCache.parse_days n) max_checkpoints_gb scope xs
        | "--days" :: n :: xs => loop (HolbuildCache.parse_days n) max_checkpoints_gb scope xs
        | "--max-checkpoints-gb" :: n :: xs =>
            (case Int.fromString n of
                 SOME gb => if gb >= 0 then loop days (SOME gb) scope xs
                            else raise Error "--max-checkpoints-gb must be non-negative"
               | NONE => raise Error "--max-checkpoints-gb requires an integer")
        | "--max-checkpoints-gb" :: [] => raise Error "--max-checkpoints-gb requires GB"
        | "--clean-only" :: xs => loop days max_checkpoints_gb (select_gc_scope scope GcProjectOnly) xs
        | "--cache-only" :: xs => loop days max_checkpoints_gb (select_gc_scope scope GcCacheOnly) xs
        | "--toolchains-only" :: xs => loop days max_checkpoints_gb (select_gc_scope scope GcToolchainsOnly) xs
        | arg :: _ => raise Error ("unknown gc option: " ^ arg)
  in
    loop HolbuildCache.default_retention_days NONE GcProjectAndCache args
  end

fun run_project_gc (days, max_checkpoints_gb_option) =
  let
    val project = load_project ()
    val max_checkpoints_gb = Option.getOpt(max_checkpoints_gb_option, HolbuildBuildExec.project_checkpoint_limit_gb project)
    fun clean_project () = HolbuildBuildExec.clean_project project days max_checkpoints_gb
  in
    HolbuildBuildExec.with_project_lock project "gc" clean_project
  end

fun gc args =
  let
    val (days, max_checkpoints_gb, scope) = parse_gc_args args
    fun cache_gc () = HolbuildCache.gc_root (HolbuildCache.cache_root ()) days
  in
    case scope of
        GcProjectAndCache => (run_project_gc (days, max_checkpoints_gb); cache_gc ())
      | GcProjectOnly => run_project_gc (days, max_checkpoints_gb)
      | GcCacheOnly => cache_gc ()
      | GcToolchainsOnly => HolbuildCache.gc_toolchains_root (HolbuildCache.cache_root ()) days
  end

fun reject_holdir holdir =
  case holdir of
      SOME _ => raise Error "--holdir is no longer supported; declare dependencies.hol"
    | NONE => ()

fun project_hol_holdir kernel_variant jobs project =
  let val resolution = {kernel_variant = kernel_variant}
  in
    (ignore (HolbuildProjectGraph.resolve {project = project, resolution = resolution});
     case HolbuildProject.resolved_hol_dependency_with resolution project of
         SOME (HolbuildProject.Dependency {source = HolbuildProject.GitSource {git, rev}, ...}) =>
           HolbuildHolSharedCache.ensure_built_with_kernel jobs
             {git = git, rev = rev, kernel_variant = kernel_variant}
       | _ => raise Error "schema 2 project has no dependencies.hol")
  end

fun effective_toolchain_for kernel_variant holdir maxheap jobs =
  let
    val project = load_project ()
    val _ = reject_holdir holdir
  in
    {holdir = project_hol_holdir kernel_variant jobs project, maxheap = maxheap,
     kernel_variant = kernel_variant}
  end

fun effective_toolchain holdir maxheap jobs =
  effective_toolchain_for HolbuildHolToolchainConfig.StandardKernel holdir maxheap jobs

fun tracing_toolchain holdir maxheap jobs =
  effective_toolchain_for HolbuildHolToolchainConfig.TracingKernel holdir maxheap jobs

fun context_toolchain_for kernel_variant holdir maxheap =
  let
    val _ = load_project ()
    val _ = reject_holdir holdir
  in
    {holdir = "", maxheap = maxheap, kernel_variant = kernel_variant}
  end

fun parse_context_args args =
  case args of
      [] => HolbuildHolToolchainConfig.StandardKernel
    | ["--trknl"] => HolbuildHolToolchainConfig.TracingKernel
    | _ => raise Error "usage: holbuild context [--trknl]"

fun parse_buildhol_args args =
  case args of
      [] => HolbuildHolToolchainConfig.StandardKernel
    | ["--trknl"] => HolbuildHolToolchainConfig.TracingKernel
    | _ => raise Error "usage: holbuild buildhol [--trknl]"

fun buildhol holdir maxheap jobs args =
  let
    val kernel_variant = parse_buildhol_args args
    val project = load_project ()
    val _ = reject_holdir holdir
    val holdir = project_hol_holdir kernel_variant jobs project
  in
    print (holdir ^ "\n")
  end

fun exec_action_command maxheap jobs args =
  let
    fun gb label text =
      case Int.fromString text of
          SOME n => if n >= 0 then IntInf.fromInt n * 1073741824
                    else raise Error (label ^ " must be a non-negative integer")
        | NONE => raise Error (label ^ " must be a non-negative integer")
    fun parse (opts as {spec, result, limit, reserve, share}) rest =
      case rest of
          [] => opts
        | "--result" :: file :: xs => parse {spec = spec, result = SOME file, limit = limit, reserve = reserve, share = share} xs
        | "--cache-limit-gb" :: n :: xs =>
            parse {spec = spec, result = result, limit = SOME (gb "--cache-limit-gb" n), reserve = reserve, share = share} xs
        | "--cache-reserve-gb" :: n :: xs =>
            parse {spec = spec, result = result, limit = limit, reserve = SOME (gb "--cache-reserve-gb" n), share = share} xs
        | "--share-heaps" :: xs => parse {spec = spec, result = result, limit = limit, reserve = reserve, share = true} xs
        | ["--result"] => raise Error "--result requires FILE"
        | ["--cache-limit-gb"] => raise Error "--cache-limit-gb requires N"
        | ["--cache-reserve-gb"] => raise Error "--cache-reserve-gb requires N"
        | arg :: xs =>
            if String.isPrefix "-" arg then raise Error ("unknown exec-action option: " ^ arg)
            else
              case spec of
                  NONE => parse {spec = SOME arg, result = result, limit = limit, reserve = reserve, share = share} xs
                | SOME _ => raise Error "exec-action takes one SPEC-SHA256"
    val {spec, result, limit, reserve, share} =
      parse {spec = NONE, result = NONE, limit = NONE, reserve = NONE, share = false} args
    val spec = case spec of SOME s => s | NONE => raise Error "exec-action requires SPEC-SHA256"
    val cache_cap =
      case limit of
          SOME limit => {limit_bytes = limit, reserve_bytes = Option.getOpt (reserve, limit div 10)}
        | NONE => raise Error "exec-action requires --cache-limit-gb N"
    fun toolchain {git, rev, kernel = _} =
      let
        (* Every worker must run the published archive's bytes, so a build
           whose own publish lost is replaced by the stored archive. *)
        val _ = HolbuildHolSharedCache.adopt_published_archive := true
        val kernel_variant = HolbuildHolToolchainConfig.StandardKernel
        val holdir = HolbuildHolSharedCache.ensure_built_with_kernel jobs
                       {git = git, rev = rev, kernel_variant = kernel_variant}
        val tc = {holdir = holdir, maxheap = maxheap, kernel_variant = kernel_variant}
      in
        configure_analyser_for_toolchain tc; tc
      end
    (* An error outside the action itself (no remote cache, the action lock,
       writing the record) is an infrastructure failure, never a final one. *)
    val code =
      (HolbuildRemoteCacheConfig.setup_client ();
       HolbuildBuildExec.exec_action
         {spec_sha256 = spec, result_file = result, cache_cap = cache_cap, share_heaps = share,
          toolchain = toolchain})
      handle e =>
        (HolbuildStatus.message_stderr
           ("holbuild: exec-action failed: " ^
            Option.getOpt (build_iteration_error_message e, General.exnMessage e) ^ "\n");
         3)
  in
    TextIO.flushOut TextIO.stdOut;
    TextIO.flushOut TextIO.stdErr;
    Posix.Process.exit (Word8.fromInt code)
  end

fun removed_legacy_proof_step_build_arg arg =
  arg = "--goalfrag" orelse arg = "--goalfrag-plan" orelse String.isPrefix "--goalfrag-plan=" arg

fun trace_steps_build_arg arg = arg = "--trace-steps" orelse arg = "--goalfrag-trace"

fun dispatch_with_options {holdir, source_dir, cache_dir, remote_cache, jobs, maxheap, prefetch_concurrency, json, verbosity} args =
  (HolbuildStatus.set_json_mode json;
   HolbuildStatus.set_verbosity verbosity;
   HolbuildStatus.set_retain_debug_artifacts false;
   Option.app HolbuildProject.set_source_dir source_dir;
   Option.app HolbuildCacheConfig.set_cache_root cache_dir;
   Option.app HolbuildRemoteCacheConfig.set_url remote_cache;
   Option.app HolbuildRemoteCacheConfig.set_prefetch_concurrency prefetch_concurrency;
   if args = ["--help"] orelse args = ["-h"] then global_help ()
   else if maybe_handle_command_help args then () else
   (* A build, explicit or implicit, under --remote-only must not build HOL. *)
   (HolbuildHolSharedCache.restore_only := List.exists (fn arg => arg = "--remote-only") args;
   case args of
       "gc" :: rest => (reject_json "gc"; gc rest)
     | "cache" :: rest => (reject_json "cache"; HolbuildCache.dispatch rest)
     | "import" :: rest => (reject_json "import"; import_archive rest)
     | "buildhol" :: rest => buildhol holdir maxheap jobs rest
     | "exec-action" :: rest =>
         (reject_json "exec-action"; reject_holdir holdir;
          exec_action_command maxheap jobs rest)
     | "goalfrag-plan" :: _ => raise Error "goalfrag-plan has been removed; use execution-plan THEORY:THEOREM"
     | [] => dispatch (effective_toolchain holdir maxheap jobs) jobs args
     | "build" :: rest =>
         if List.exists removed_legacy_proof_step_build_arg rest then
           (case List.find removed_legacy_proof_step_build_arg rest of
                SOME "--goalfrag" => raise Error "--goalfrag has been removed; proof steps are enabled by default"
              | SOME _ => raise Error "--goalfrag-plan has been removed; use execution-plan THEORY:THEOREM"
              | NONE => dispatch (effective_toolchain holdir maxheap jobs) jobs args)
         else if json andalso List.exists trace_steps_build_arg rest then
           raise Error "--json does not support --trace-steps until structured proof-step trace events exist"
         else if List.exists (fn arg => arg = "--trknl") rest then
           dispatch (tracing_toolchain holdir maxheap jobs) jobs args
         else dispatch (effective_toolchain holdir maxheap jobs) jobs args
     | "context" :: rest =>
         dispatch (context_toolchain_for (parse_context_args rest) holdir maxheap) jobs args
     | _ =>
         if List.exists (fn arg => arg = "--trknl") args then
           dispatch (tracing_toolchain holdir maxheap jobs) jobs args
         else dispatch (effective_toolchain holdir maxheap jobs) jobs args))

fun is_broken_pipe (IO.Io {cause = OS.SysErr (msg, _), ...}) = msg = "Broken pipe"
  | is_broken_pipe _ = false

fun install_signal_handlers () =
  let
    fun handler _ =
      (interrupted := true;
       HolbuildToolchain.cleanup_active_children ();
       HolbuildRemoteExec.cancel_followed ();
       err "interrupted")
    val _ = Signal.signal (Posix.Signal.int, Signal.SIG_HANDLE handler)
    val _ = Signal.signal (Posix.Signal.term, Signal.SIG_HANDLE handler)
  in
    ()
  end

(* The process's own command line, without argv[0], or [] where /proc is
   unavailable. Each argument ends in a NUL, so the last field is empty. *)
fun process_arguments () =
  (case String.fields (fn c => c = #"\000") (with_input "/proc/self/cmdline" TextIO.inputAll) of
       [] => []
     | _ :: args => (case rev args of "" :: rest => rev rest | _ => args))
  handle IO.Io _ => []

(* The Poly/ML runtime removes its own options (--maxheap, --gcthreads, -H,
   ...) and their values from the command line before CommandLine.arguments,
   so they set holbuild's own runtime and never reach HOL. The process's own
   arguments, readable where /proc exists, still hold them: those that
   CommandLine.arguments lacks and that start with "-", as every runtime
   option does, are such options. Others (an option's value; the program
   path, when a dynamic loader started holbuild) are skipped. *)
fun runtime_options args =
  let
    fun consumed [] _ = []
      | consumed (x :: xs) (y :: ys) = if x = y then consumed xs ys else missing x xs (y :: ys)
      | consumed (x :: xs) [] = missing x xs []
    and missing x xs ys = if String.isPrefix "-" x then x :: consumed xs ys else consumed xs ys
  in
    consumed (process_arguments ()) args
  end

(* --maxheap would cap holbuild's own heap, never HOL's, so it is always an
   error. Other runtime options may tune holbuild's own runtime on purpose,
   except with run and repl, whose extra arguments are meant for HOL. *)
fun reject_runtime_options options args =
  let
    val consumed = " is consumed by holbuild's Poly/ML runtime and does not reach child HOL processes"
  in
    case (List.find (String.isPrefix "--maxheap") options, options, args) of
        (SOME arg, _, _) => raise Error (arg ^ consumed ^ "; use --max-heap MB")
      | (NONE, arg :: _, command :: _) =>
          if command = "run" orelse command = "repl" then raise Error (arg ^ consumed) else ()
      | _ => ()
  end

fun main raw_args =
  (let
     val _ = install_signal_handlers ()
     val _ = HolbuildStatus.set_json_mode (List.exists (fn s => s = "--json") raw_args)
     val runtime_options = runtime_options raw_args
     val _ =
       if raw_args = ["--version"] then
         (print ("holbuild " ^ HolbuildVersion.version ^ "\n"); OS.Process.exit OS.Process.success)
       else if raw_args = ["--help"] orelse raw_args = ["-h"]
       then (global_help (); OS.Process.exit OS.Process.success)
       else ()
     val (cooperate_dir, machine_max_mem, child_charge, raw_args) = parse_cooperation_options raw_args
     val (options, args) = parse_global_options raw_args
     val _ = reject_runtime_options runtime_options args
   in
     configure_cooperation cooperate_dir machine_max_mem child_charge (#maxheap options);
     dispatch_with_options options args
   end)
  handle Thread.Interrupt => (interrupted := true; HolbuildToolchain.cleanup_active_children (); err "interrupted")
       | Error msg => err msg
       | HolbuildToolchain.Error msg => err msg
       | HolbuildProject.Error msg => err msg
       | HolbuildProjectGraph.Error msg => err msg
       | HolbuildGenerators.Error msg => err msg
       | HolbuildGenerators.ErrorWithDebugArtifacts (msg, artifacts) => err_with_debug_artifacts msg artifacts
       | HolbuildPackagePrepare.Error msg => err msg
       | HolbuildPackagePrepare.ErrorWithDebugArtifacts (msg, artifacts) => err_with_debug_artifacts msg artifacts
       | HolbuildPackageComponent.Error msg => err msg
       | HolbuildComponentProvider.Error msg => err msg
       | HolbuildSourceIndex.Error msg => err msg
       | HolbuildSourceIndex.ErrorWithDebugArtifacts (msg, artifacts) => err_with_debug_artifacts msg artifacts
       | HolbuildDependencies.Error msg => err msg
       | HolbuildBuildPlan.Error msg => err msg
       | HolbuildPlanRecord.Error msg => err msg
       | HolbuildBuildPlan.UnknownTarget unknown => err (HolbuildBuildPlan.unknown_target_message unknown)
       | HolbuildBuildExec.Error msg => err msg
       | HolbuildBuildExec.ErrorWithDebugArtifacts (msg, artifacts) => err_with_debug_artifacts msg artifacts
       | HolbuildHolSharedCache.Error msg => err msg
       | HolbuildProcessGroup.Error msg => err msg
       | HolbuildCache.Error msg => err msg
       | HolbuildCacheArchive.Error msg => err msg
       | HolbuildCacheTransfer.Error msg => err msg
       | HolbuildCacheConfig.Error msg => err msg
       | HolbuildRemoteCacheConfig.Error msg => err msg
       | HolbuildWatch.Error msg => err msg
       | e => if is_broken_pipe e then
                OS.Process.exit (if HolbuildStatus.json_mode () then OS.Process.failure else OS.Process.success)
              else err (General.exnMessage e)

end
