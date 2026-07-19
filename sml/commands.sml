structure HolbuildCommands =
struct

exception Error of string

fun err_with_debug_artifacts msg artifacts =
  (if HolbuildStatus.json_mode () then HolbuildStatus.error_with_debug_artifacts msg artifacts
   else HolbuildStatus.message_stderr ("holbuild: " ^ msg ^ "\n");
   OS.Process.exit OS.Process.failure)

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
  \  repl [ARG ...]              Start HOL REPL with project context\n\
  \  run [ARG ...]               Run HOL with project context\n\
  \  context [--trknl]          Show resolved project context\n\n\
  \Inspection and advanced commands:\n\
  \  execution-plan T:THM        Inspect proof-step execution plan\n\
  \  buildhol                    Build/reuse declared HOL and print its path\n\
  \  heap NAME                   Build a configured heap\n\
  \  executable NAME             Build a configured executable heap\n\
  \  clean THEORY...             Remove local build outputs\n\
  \  export -o FILE [TARGET ...]  Export cached build outputs\n\
  \  import FILE                  Import cached build outputs\n\
  \  gc                          Remove stale project/cache state\n\n\
  \Global options:\n\
  \  --source-dir PATH\n\
  \  --cache-dir PATH\n\
  \  --remote-cache URL\n\
  \  --json\n\
  \  --quiet, --verbose, --verbosity LEVEL\n\
  \  -j N, -jN, --jobs N\n\
  \  --maxheap MB, --max-heap MB\n\n\
  \Use `holbuild COMMAND --help` for command-specific help.\n"

fun build_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] [build] [OPTIONS] [TARGET ...]\n\n\
  \Build project targets. With no TARGET, build the project's default targets.\n\n\
  \Options:\n\
  \  --watch\n\
  \  --dry-run\n\
  \  --force[=theory|project|full]\n\
  \  --no-cache\n\
  \  --no-stat-cache\n\
  \  --skip-checkpoints\n\
  \  --skip-proof-steps\n\
  \  --tactic-timeout SECONDS\n\
  \  --trace-steps\n\
  \  --repl-on-failure\n\
  \  --retain-debug-artifacts\n\
  \  --emit-output-hashes\n\
  \  --warn-unreachable\n\
  \  --trknl\n\n\
  \Global options: see `holbuild --help`.\n"

fun context_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] context [--trknl]\n\n\
  \Show resolved project context. Use --trknl to select the tracing-kernel\n\
  \context. This command resolves metadata but does not build the toolchain.\n\n\
  \Global options: see `holbuild --help`.\n"

fun repl_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] repl [ARG ...]\n\n\
  \Start HOL REPL with project context. Extra arguments are passed to HOL.\n\n\
  \Global options: see `holbuild --help`.\n"

fun run_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] run [ARG ...]\n\n\
  \Run HOL with project context. Extra arguments are passed to HOL.\n\n\
  \Global options: see `holbuild --help`.\n"

fun execution_plan_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] execution-plan THEORY:THEOREM\n\n\
  \Inspect the proof-step execution plan for a theorem.\n\n\
  \Global options: see `holbuild --help`.\n"

fun buildhol_help () = print
  "Usage:\n\
  \  holbuild [GLOBAL OPTIONS] buildhol [--trknl]\n\n\
  \Build/reuse the declared HOL tree and print its path. Use --trknl to select\n\
  \the tracing kernel. A configured remote cache restores toolchains and\n\
  \publishes successful local builds automatically.\n\n\
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
  \Remove stale project/cache state.\n\n\
  \Options:\n\
  \  --retention-days DAYS\n\
  \  --max-checkpoints-gb GB\n\
  \  --clean-only\n\
  \  --cache-only\n\n\
  \Global options: see `holbuild --help`.\n"

fun cache_help () = print
  "`holbuild cache gc` is deprecated; use `holbuild gc --cache-only`.\n"

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

fun known_command command =
  command = "build" orelse command = "context" orelse command = "repl" orelse
  command = "run" orelse command = "execution-plan" orelse command = "buildhol" orelse
  command = "heap" orelse command = "executable" orelse command = "clean" orelse command = "export" orelse
  command = "import" orelse command = "gc" orelse command = "cache" orelse
  command = "goalfrag-plan"

fun command_help command =
  case command of
      "build" => build_help ()
    | "context" => context_help ()
    | "repl" => repl_help ()
    | "run" => run_help ()
    | "execution-plan" => execution_plan_help ()
    | "buildhol" => buildhol_help ()
    | "heap" => heap_help ()
    | "executable" => executable_help ()
    | "clean" => clean_help ()
    | "export" => export_help ()
    | "import" => import_help ()
    | "gc" => gc_help ()
    | "cache" => cache_help ()
    | "goalfrag-plan" => raise Error "goalfrag-plan has been removed; use execution-plan THEORY:THEOREM"
    | _ => raise Error ("unknown command: " ^ command)

fun maybe_handle_command_help args =
  case args of
      [] => false
    | command :: rest =>
        if has_help_arg rest then
          if known_command command then (command_help command; true)
          else raise Error ("unknown command: " ^ command)
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
    fun extract_emit_output_hashes rest =
      let
        fun loop emit acc xs =
          case xs of
              [] => (emit, rev acc)
            | "--emit-output-hashes" :: ys => loop true acc ys
            | y :: ys => loop emit (y :: acc) ys
      in
        loop false [] rest
      end
    val (emit_output_hashes, build_args) = extract_emit_output_hashes args
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
                  emit_output_hashes = emit_output_hashes}, [])
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
  else HolbuildSourceIndex.expand_group_tokens index (HolbuildProject.project_package project) targets

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

fun theorem_match theorem source =
  let
    val text = read_text (#source_path source)
    val boundaries = HolbuildBuildExec.discover_theorem_boundaries (#source_path source) text
  in
    case List.filter (fn boundary => #name boundary = theorem) boundaries of
        [] => NONE
      | [boundary] => SOME (source, boundary)
      | _ => raise Error ("duplicate theorem in " ^ describe_source source ^ ": " ^ theorem)
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
          val status = OS.Process.system (HolbuildHash.quote analyser ^ " --request " ^ HolbuildHash.quote req ^
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

fun analyser_proof_ir_plan_for_boundary (boundary : HolbuildTheoryCheckpoints.boundary) =
  let
    val {name, tactic_start, tactic_end, tactic_text, ...} = boundary
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
      | NONE => raise Error ("proof-IR plan missing for execution-plan theorem: " ^ name)
  end

fun print_static_execution_plan project new_ir source theorem boundary_opt =
  (print (let val plan = analyser_proof_ir_plan_for_boundary (case boundary_opt of SOME b => b | NONE => raise Error "internal error: missing proof-IR boundary")
          in
            "holbuild proof-ir plan " ^ #logical_name source ^ ":" ^ theorem ^ " source=" ^ #relative_path source ^
            " (" ^ Int.toString (HolbuildProofIr.display_step_count plan) ^ " steps)\n" ^
            HolbuildProofIr.format_plan_lines plan
          end);
   TextIO.flushOut TextIO.stdOut)

fun find_theory_source index theory =
  case List.filter (fn source => theory_source source andalso #logical_name source = theory) index of
      [source] => source
    | [] => raise Error ("theory not found for execution-plan: " ^ theory)
    | matches =>
        raise Error ("ambiguous theory for execution-plan: " ^ theory ^ " in " ^                     String.concatWith ", " (map describe_source matches))

fun find_theorem_in_source theorem source =
  case theorem_match theorem source of
      SOME (_, boundary) => boundary
    | NONE => raise Error ("theorem not found for execution-plan: " ^ #logical_name source ^ ":" ^ theorem)

fun print_execution_plan_selector new_ir project selector =
  let
    val {theory, theorem} = parse_execution_plan_selector selector
    val graph = HolbuildProjectGraph.resolve
                  {project = project,
                   resolution = HolbuildProject.standard_resolution}
    val preparation = HolbuildPackagePrepare.prepare graph
    val discovery = HolbuildSourceIndex.discover_prepared_with_inventories preparation
    val components = HolbuildComponentProvider.load HolbuildComponentProvider.LiveProvider
                       {preparation = preparation, discovery = discovery}
    val index = HolbuildComponentProvider.sources components
    val source = find_theory_source index theory
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
    fun loop holdir source_dir cache_dir remote_cache jobs maxheap json verbosity rest =
      case rest of
          [] => ({holdir = holdir, source_dir = source_dir, cache_dir = cache_dir, remote_cache = remote_cache, jobs = jobs, maxheap = maxheap, json = json, verbosity = verbosity}, [])
        | "--json" :: xs => loop holdir source_dir cache_dir remote_cache jobs maxheap true verbosity xs
        | "--quiet" :: xs => loop holdir source_dir cache_dir remote_cache jobs maxheap json HolbuildStatus.Quiet xs
        | "--verbose" :: xs => loop holdir source_dir cache_dir remote_cache jobs maxheap json HolbuildStatus.Verbose xs
        | "--verbosity" :: level :: xs => loop holdir source_dir cache_dir remote_cache jobs maxheap json (verbosity_value level) xs
        | "--holdir" :: path :: xs => loop (SOME path) source_dir cache_dir remote_cache jobs maxheap json verbosity xs
        | "--source-dir" :: path :: xs => loop holdir (SOME path) cache_dir remote_cache jobs maxheap json verbosity xs
        | "--cache-dir" :: path :: xs => loop holdir source_dir (SOME path) remote_cache jobs maxheap json verbosity xs
        | "--remote-cache" :: url :: xs => loop holdir source_dir cache_dir (SOME url) jobs maxheap json verbosity xs
        | "--jobs" :: n :: xs => loop holdir source_dir cache_dir remote_cache (SOME (positive_int "--jobs" n)) maxheap json verbosity xs
        | "-j" :: n :: xs => loop holdir source_dir cache_dir remote_cache (SOME (positive_int "-j" n)) maxheap json verbosity xs
        | "--maxheap" :: n :: xs => loop holdir source_dir cache_dir remote_cache jobs (SOME (positive_int "--maxheap" n)) json verbosity xs
        | "--max-heap" :: n :: xs => loop holdir source_dir cache_dir remote_cache jobs (SOME (positive_int "--max-heap" n)) json verbosity xs
        | "--verbosity" :: [] => raise Error "--verbosity requires LEVEL"
        | "--holdir" :: [] => raise Error "--holdir requires PATH"
        | "--source-dir" :: [] => raise Error "--source-dir requires PATH"
        | "--cache-dir" :: [] => raise Error "--cache-dir requires PATH"
        | "--remote-cache" :: [] => raise Error "--remote-cache requires URL"
        | "--jobs" :: [] => raise Error "--jobs requires N"
        | "-j" :: [] => raise Error "-j requires N"
        | "--maxheap" :: [] => raise Error "--maxheap requires MB"
        | "--max-heap" :: [] => raise Error "--max-heap requires MB"
        | arg :: xs =>
            if String.isPrefix "--verbosity=" arg then
              loop holdir source_dir cache_dir remote_cache jobs maxheap json (verbosity_value (String.extract (arg, size "--verbosity=", NONE))) xs
            else if String.isPrefix "--holdir=" arg then
              loop (SOME (String.extract (arg, size "--holdir=", NONE))) source_dir cache_dir remote_cache jobs maxheap json verbosity xs
            else if String.isPrefix "--source-dir=" arg then
              loop holdir (SOME (String.extract (arg, size "--source-dir=", NONE))) cache_dir remote_cache jobs maxheap json verbosity xs
            else if String.isPrefix "--cache-dir=" arg then
              loop holdir source_dir (SOME (String.extract (arg, size "--cache-dir=", NONE))) remote_cache jobs maxheap json verbosity xs
            else if String.isPrefix "--remote-cache=" arg then
              loop holdir source_dir cache_dir (SOME (String.extract (arg, size "--remote-cache=", NONE))) jobs maxheap json verbosity xs
            else if String.isPrefix "--jobs=" arg then
              loop holdir source_dir cache_dir remote_cache (SOME (positive_int "--jobs" (String.extract (arg, size "--jobs=", NONE)))) maxheap json verbosity xs
            else if String.isPrefix "--maxheap=" arg then
              loop holdir source_dir cache_dir remote_cache jobs (SOME (positive_int "--maxheap" (String.extract (arg, size "--maxheap=", NONE)))) json verbosity xs
            else if String.isPrefix "--max-heap=" arg then
              loop holdir source_dir cache_dir remote_cache jobs (SOME (positive_int "--max-heap" (String.extract (arg, size "--max-heap=", NONE)))) json verbosity xs
            else if String.isPrefix "-j" arg andalso size arg > 2 then
              loop holdir source_dir cache_dir remote_cache (SOME (positive_int "-j" (String.extract (arg, 2, NONE)))) maxheap json verbosity xs
            else
              let val (opts, args') = loop holdir source_dir cache_dir remote_cache jobs maxheap json verbosity xs in (opts, arg :: args') end
  in
    loop NONE NONE NONE NONE NONE NONE false HolbuildStatus.Normal args
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
    val _ = timed_phase (phase_prefix ^ ".policies.prevalidate")
              (fn () => HolbuildSourceIndex.prevalidate_graph graph)
    val preparation = timed_phase (phase_prefix ^ ".generators.prepare")
                        (fn () => HolbuildPackagePrepare.prepare graph)
    val discovery = timed_phase (phase_prefix ^ ".inventory.construct")
                      (fn () => HolbuildSourceIndex.discover_prepared_with_inventories preparation)
    val components = timed_phase (phase_prefix ^ ".components.load")
                       (fn () => HolbuildComponentProvider.load
                         HolbuildComponentProvider.LiveProvider
                         {preparation = preparation, discovery = discovery})
  in
    {index = HolbuildComponentProvider.sources components,
     components = components}
  end

fun build_once_with_prepared tc cli_jobs prepared ({dry_run, watch, force, use_cache, verify_cache, no_stat_cache, skip_checkpoints, proof_steps, new_ir, tactic_timeout, tactic_timeout_set, execution_plan, trace_steps, repl_on_failure, retain_debug_artifacts, warn_unreachable, emit_output_hashes}, targets) =
  let
    val project =
      case prepared of
          SOME {project, ...} => project
        | NONE => timed_phase "project.discover" load_project
    val resolution = resolution_for_toolchain tc
    val _ = HolbuildStatus.set_retain_debug_artifacts retain_debug_artifacts
    val jobs = if repl_on_failure then 1 else effective_jobs project cli_jobs
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
        | some => some
    fun build_options_for index entry_plan plan force_targets =
      {use_cache = use_cache,
       verify_cache = verify_cache,
       force = force,
       force_targets = force_targets,
       skip_checkpoints = skip_checkpoints,
       proof_steps = proof_steps,
       new_ir = new_ir,
       node_tactic_timeouts =
         if tactic_timeout_set then HolbuildTacticTimeoutPolicy.plan_timeouts project plan tactic_timeout
         else HolbuildTacticTimeoutPolicy.entry_timeouts project index entry_plan (default_tactic_timeout ()),
       execution_plan = execution_plan,
       trace_steps = trace_steps,
       repl_on_failure = repl_on_failure,
       emit_output_hashes = emit_output_hashes,
       trknl = HolbuildToolchain.kernel_variant_tracing (#kernel_variant tc)}
    fun prepare_plan () =
      let
        val {index, components} =
          case prepared of
              SOME {index, components, ...} =>
                {index = index, components = components}
            | NONE => prepare_source_index "build" resolution project
        val requested_targets = targets
        val targets = timed_phase "targets.default" (fn () => default_build_targets resolution project index requested_targets)
        val _ = reject_object_targets targets
        val plan = timed_phase "build.plan" (fn () => build_target_plan resolution components (#holdir tc) project index requested_targets targets)
        val entry_targets = map #2 (HolbuildTacticTimeoutPolicy.declared_entries project index)
        val entry_plan = timed_phase "entry_timeout.plan" (fn () => HolbuildBuildPlan.plan_targets components (#holdir tc) index entry_targets)
        val _ = if warn_unreachable andalso null requested_targets then
                  warn_unreachable_root_scripts resolution project index plan
                else ()
        val toolchain_key = timed_phase "toolchain.key" (fn () => HolbuildToolchain.toolchain_key tc)
      in
        (index, targets, entry_plan, plan, toolchain_key)
      end
    fun describe_dry_run () =
      let val (index, force_targets, entry_plan, plan, toolchain_key) = prepare_plan ()
          val build_options = build_options_for index entry_plan plan force_targets
      in
        timed_phase "dry_run.describe"
          (fn () => HolbuildBuildPlan.describe (HolbuildBuildExec.build_config_lines_for_node build_options project) toolchain_key plan)
      end
    fun execute_build () =
      let val (index, force_targets, entry_plan, plan, toolchain_key) = prepare_plan ()
          val build_options = build_options_for index entry_plan plan force_targets
      in
        timed_phase "build.execute"
          (fn () => HolbuildBuildExec.build build_options tc project plan toolchain_key jobs)
      end
    fun run_with_stat_cache f =
      (f (); finish_stat_cache stat_cache)
      handle e => (finish_stat_cache stat_cache; raise e)
  in
    if dry_run then run_with_stat_cache describe_dry_run
    else HolbuildBuildExec.with_project_lock project "build" (fn () => run_with_stat_cache execute_build)
  end

fun build_once tc cli_jobs parsed = build_once_with_prepared tc cli_jobs NONE parsed

fun build_iteration_error_message exn =
  case exn of
      Error msg => SOME msg
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
    val paths = HolbuildWatch.watch_paths_with resolution project index
  in
    {prepared = SOME {project = project, index = index,
                      components = components, paths = paths}, paths = paths}
  end
  handle exn =>
    case (build_iteration_error_message exn, previous_paths) of
        (SOME msg, SOME paths) =>
          (warn ("could not recompute watch set: " ^ msg);
           {prepared = NONE, paths = paths})
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
        val {prepared, paths = before_paths} = current_watch_state resolution previous_paths
        val _ = attempt prepared
        (* Recompute the watch set after the build so inputs created during the
           build are watched immediately, not only after the next change. *)
        val {prepared = _, paths} = current_watch_state resolution (SOME before_paths)
        val _ = warn ("watching " ^ Int.toString (length paths) ^ " project path(s); waiting for changes")
        val _ = HolbuildWatch.wait_for_change paths
      in
        loop (SOME paths)
      end
  in
    loop NONE
  end

fun build tc cli_jobs args =
  let
    val parsed as ({dry_run, watch, repl_on_failure, ...}, _) = split_flags args
    val _ =
      if watch andalso HolbuildStatus.json_mode () then
        raise Error "--json does not support build --watch yet"
      else if watch andalso dry_run then
        raise Error "--watch does not support --dry-run"
      else if watch andalso repl_on_failure then
        raise Error "--watch does not support --repl-on-failure"
      else ()
  in
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

fun export_build_options trknl project index entry_plan plan =
  let
    fun default_tactic_timeout () =
      case #build_tactic_timeout project of
          NONE => SOME 2.5
        | some => some
  in
    {use_cache = true,
     verify_cache = true,
     force = HolbuildBuildExec.ForceNone,
     force_targets = [],
     skip_checkpoints = false,
     proof_steps = true,
     new_ir = true,
     node_tactic_timeouts = HolbuildTacticTimeoutPolicy.entry_timeouts project index entry_plan (default_tactic_timeout ()),
     execution_plan = NONE,
     trace_steps = false,
     repl_on_failure = false,
     emit_output_hashes = false,
      trknl = trknl}
  end

fun theory_node node =
  #kind (HolbuildBuildPlan.source_of node) = HolbuildSourceIndex.TheoryScript

fun cache_key_usable root key =
  case HolbuildCache.get_action root key of
      SOME text => HolbuildBuildExec.cache_entry_usable root key text
    | NONE => false

fun any_usable_cache_key root keys = List.exists (cache_key_usable root) keys

fun portable_cache_key_for_node project plan root keys node =
  let
    val logical = HolbuildBuildPlan.logical_name node
    val input_key = HolbuildBuildPlan.input_key_for keys node
    val cache_keys = HolbuildBuildExec.theory_cache_keys project plan node input_key
  in
    case cache_keys of
        [] => raise Error ("internal error: no cache keys for " ^ logical)
      | portable_key :: path_dependent_keys =>
          if cache_key_usable root portable_key then portable_key
          else if any_usable_cache_key root path_dependent_keys then
            raise Error ("target " ^ logical ^ " only has a path-dependent cache entry; portable export requires rebuilding it without transient stage paths")
          else
            raise Error ("target " ^ logical ^
                         " is not built in the cache; run `holbuild build " ^
                         logical ^ "` first, or use `holbuild export --build`")
  end

fun export_entry_for_node project plan root keys node =
  let
    val cache_key = portable_cache_key_for_node project plan root keys node
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
    map (export_entry_for_node project plan root keys) theory_nodes
  end
  handle HolbuildBuildExec.Error msg => raise Error msg

fun fs_cache_source cache : HolbuildCacheTransfer.source =
  {get_action = HolbuildFSCacheBackend.get_action cache,
   fetch_blob = HolbuildFSCacheBackend.fetch_blob cache}

fun first_token text =
  case String.tokens Char.isSpace text of
      token :: _ => SOME token
    | [] => NONE

fun file_sha256 path =
  case command_output ("sha256sum " ^ HolbuildHash.quote path) of
      SOME text => first_token text
    | NONE => NONE

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
    val sha256 =
      case file_sha256 archive_path of
          SOME hash => hash
        | NONE => raise Error ("could not compute sha256 for " ^ archive_path)
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
    val entry_targets = map #2 (HolbuildTacticTimeoutPolicy.declared_entries project index)
    val entry_plan = timed_phase "entry_timeout.plan" (fn () => HolbuildBuildPlan.plan_targets components (#holdir tc) index entry_targets)
    val toolchain_key = timed_phase "toolchain.key" (fn () => HolbuildToolchain.toolchain_key tc)
    val options = export_build_options (HolbuildToolchain.kernel_variant_tracing (#kernel_variant tc)) project index entry_plan plan
    val keys = HolbuildBuildPlan.input_keys (HolbuildBuildExec.build_config_lines_for_node options project) toolchain_key plan
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
        val _ = List.app (HolbuildBuildExec.clean_theory_node project) theory_nodes
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
      | NONE => raise Error ("unknown " ^ command ^ " target: " ^ target)
  end

fun build_heap_kind tc cli_jobs command target =
  let
    val project = timed_phase "project.discover" load_project
    val jobs = effective_jobs project cli_jobs
    fun execute_heap () =
      let
        val HolbuildProject.Heap {output, objects, kind, ...} = heap_named project command target
        val {index, components} = prepare_source_index "heap"
                                  (resolution_for_toolchain tc) project
        val objects = HolbuildSourceIndex.expand_group_tokens index (HolbuildProject.project_package project) objects
        val _ = if null objects then raise Error (command ^ " target has no objects: " ^ target) else ()
        val plan = timed_phase "build.plan" (fn () => HolbuildBuildPlan.plan_targets components (#holdir tc) index objects)
        val toolchain_key = timed_phase "toolchain.key" (fn () => HolbuildToolchain.toolchain_key tc)
        val output_path = HolbuildProject.abs_under (#root project) output
      in
        HolbuildBuildExec.build {use_cache = true, verify_cache = true, force = HolbuildBuildExec.ForceNone, force_targets = [], skip_checkpoints = false, proof_steps = true, new_ir = true, node_tactic_timeouts = HolbuildTacticTimeoutPolicy.entry_timeouts project index plan (SOME 2.5), execution_plan = NONE, trace_steps = false, repl_on_failure = false, emit_output_hashes = false, trknl = HolbuildToolchain.kernel_variant_tracing (#kernel_variant tc)}
                               tc project plan toolchain_key jobs;
        HolbuildBuildExec.export_heap tc project plan output_path kind
      end
  in
    HolbuildBuildExec.with_project_lock project (command ^ " " ^ target) execute_heap
  end

fun build_heap tc cli_jobs target = build_heap_kind tc cli_jobs "heap" target
fun build_executable tc cli_jobs target = build_heap_kind tc cli_jobs "executable" target

fun hol_args_for_project tc project subcommand user_args =
  let
    val packages = resolved_packages (resolution_for_toolchain tc) project
    val context = HolbuildToolchain.write_run_context project packages
    val heap_args =
      case HolbuildProject.abs_run_heap project of
          NONE => ["--holstate", HolbuildToolchain.base_state tc]
        | SOME heap => ["--holstate", heap]
  in
    HolbuildToolchain.hol_subcommand_argv tc subcommand @ heap_args @ [context] @ user_args
  end

fun run_hol_with runner tc subcommand user_args =
  let
    val project = timed_phase "project.discover" load_project
    val argv = hol_args_for_project tc project subcommand user_args
    val status = runner argv
  in
    if HolbuildToolchain.success status then ()
    else raise Error ("hol " ^ subcommand ^ " failed")
  end

fun run_hol tc subcommand user_args =
  run_hol_with HolbuildToolchain.run tc subcommand user_args

fun repl_hol tc user_args =
  run_hol_with HolbuildToolchain.run_interactive tc "repl" user_args

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
    | "goalfrag-plan" :: rest => removed_legacy_plan_command tc rest
    | "build" :: rest => build tc jobs rest
    | "clean" :: rest => (reject_json "clean"; clean_targets rest)
    | "heap" :: [target] => (reject_json "heap"; build_heap tc jobs target)
    | "heap" :: _ => raise Error "usage: holbuild heap NAME"
    | "executable" :: [target] => (reject_json "executable"; build_executable tc jobs target)
    | "executable" :: _ => raise Error "usage: holbuild executable NAME"
    | "run" :: rest => (reject_json "run"; run_hol tc "run" rest)
    | "repl" :: rest => (reject_json "repl"; repl_hol tc rest)
    | "export" :: rest => (reject_json "export"; export_archive tc jobs rest)
    | "import" :: rest => (reject_json "import"; import_archive rest)
    | cmd :: _ => if known_command cmd then raise Error ("unknown command: " ^ cmd)
                  else build tc jobs args

fun parse_gc_args args =
  let
    fun result days max_checkpoints_gb clean_only cache_only =
      case (clean_only, cache_only) of
          (true, true) => raise Error "--clean-only and --cache-only are mutually exclusive"
        | (true, false) => (days, max_checkpoints_gb, true, false)
        | (false, true) => (days, max_checkpoints_gb, false, true)
        | (false, false) => (days, max_checkpoints_gb, true, true)
    fun loop days max_checkpoints_gb clean_only cache_only rest =
      case rest of
          [] => result days max_checkpoints_gb clean_only cache_only
        | "--retention-days" :: n :: xs => loop (HolbuildCache.parse_days n) max_checkpoints_gb clean_only cache_only xs
        | "--days" :: n :: xs => loop (HolbuildCache.parse_days n) max_checkpoints_gb clean_only cache_only xs
        | "--max-checkpoints-gb" :: n :: xs =>
            (case Int.fromString n of
                 SOME gb => if gb >= 0 then loop days (SOME gb) clean_only cache_only xs
                            else raise Error "--max-checkpoints-gb must be non-negative"
               | NONE => raise Error "--max-checkpoints-gb requires an integer")
        | "--max-checkpoints-gb" :: [] => raise Error "--max-checkpoints-gb requires GB"
        | "--clean-only" :: xs => loop days max_checkpoints_gb true cache_only xs
        | "--cache-only" :: xs => loop days max_checkpoints_gb clean_only true xs
        | arg :: _ => raise Error ("unknown gc option: " ^ arg)
  in
    loop HolbuildCache.default_retention_days NONE false false args
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
    val (days, max_checkpoints_gb, clean_project, clean_cache) = parse_gc_args args
    val _ = if clean_project then run_project_gc (days, max_checkpoints_gb) else ()
    val _ = if clean_cache then HolbuildCache.gc_root (HolbuildCache.cache_root ()) days else ()
  in
    ()
  end

fun reject_holdir holdir =
  case holdir of
      SOME _ => raise Error "--holdir is no longer supported; declare dependencies.hol"
    | NONE => ()

fun project_hol_holdir kernel_variant project =
  let val resolution = {kernel_variant = kernel_variant}
  in
    (ignore (HolbuildProjectGraph.resolve {project = project, resolution = resolution});
     case HolbuildProject.resolved_hol_dependency_with resolution project of
         SOME (HolbuildProject.Dependency {source = HolbuildProject.GitSource {git, rev}, ...}) =>
           HolbuildHolSharedCache.ensure_built_with_kernel
             {git = git, rev = rev, kernel_variant = kernel_variant}
       | _ => raise Error "schema 2 project has no dependencies.hol")
  end

fun effective_toolchain_for kernel_variant holdir maxheap =
  let
    val project = load_project ()
    val _ = reject_holdir holdir
  in
    {holdir = project_hol_holdir kernel_variant project, maxheap = maxheap,
     kernel_variant = kernel_variant}
  end

fun effective_toolchain holdir maxheap =
  effective_toolchain_for HolbuildHolToolchainConfig.StandardKernel holdir maxheap

fun tracing_toolchain holdir maxheap =
  effective_toolchain_for HolbuildHolToolchainConfig.TracingKernel holdir maxheap

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

fun buildhol holdir maxheap args =
  let
    val kernel_variant = parse_buildhol_args args
    val project = load_project ()
    val _ = reject_holdir holdir
    val holdir = project_hol_holdir kernel_variant project
  in
    print (holdir ^ "\n")
  end

fun removed_legacy_proof_step_build_arg arg =
  arg = "--goalfrag" orelse arg = "--goalfrag-plan" orelse String.isPrefix "--goalfrag-plan=" arg

fun trace_steps_build_arg arg = arg = "--trace-steps" orelse arg = "--goalfrag-trace"

fun dispatch_with_options {holdir, source_dir, cache_dir, remote_cache, jobs, maxheap, json, verbosity} args =
  (HolbuildStatus.set_json_mode json;
   HolbuildStatus.set_verbosity verbosity;
   HolbuildStatus.set_retain_debug_artifacts false;
   Option.app HolbuildProject.set_source_dir source_dir;
   Option.app HolbuildCacheConfig.set_cache_root cache_dir;
   Option.app HolbuildRemoteCacheConfig.set_url remote_cache;
   if args = ["--help"] orelse args = ["-h"] then global_help ()
   else if maybe_handle_command_help args then () else
   case args of
       "gc" :: rest => (reject_json "gc"; gc rest)
     | "cache" :: rest => (reject_json "cache"; HolbuildCache.dispatch rest)
     | "import" :: rest => (reject_json "import"; import_archive rest)
     | "buildhol" :: rest => buildhol holdir maxheap rest
     | "goalfrag-plan" :: _ => raise Error "goalfrag-plan has been removed; use execution-plan THEORY:THEOREM"
     | [] => dispatch (effective_toolchain holdir maxheap) jobs args
     | "build" :: rest =>
         if List.exists removed_legacy_proof_step_build_arg rest then
           (case List.find removed_legacy_proof_step_build_arg rest of
                SOME "--goalfrag" => raise Error "--goalfrag has been removed; proof steps are enabled by default"
              | SOME _ => raise Error "--goalfrag-plan has been removed; use execution-plan THEORY:THEOREM"
              | NONE => dispatch (effective_toolchain holdir maxheap) jobs args)
         else if json andalso List.exists trace_steps_build_arg rest then
           raise Error "--json does not support --trace-steps until structured proof-step trace events exist"
         else if List.exists (fn arg => arg = "--trknl") rest then
           dispatch (tracing_toolchain holdir maxheap) jobs args
         else dispatch (effective_toolchain holdir maxheap) jobs args
     | "context" :: rest =>
         dispatch (context_toolchain_for (parse_context_args rest) holdir maxheap) jobs args
     | _ =>
         if List.exists (fn arg => arg = "--trknl") args then
           dispatch (tracing_toolchain holdir maxheap) jobs args
         else dispatch (effective_toolchain holdir maxheap) jobs args)

fun is_broken_pipe (IO.Io {cause = OS.SysErr (msg, _), ...}) = msg = "Broken pipe"
  | is_broken_pipe _ = false

fun install_signal_handlers () =
  let
    fun handler _ = (HolbuildToolchain.cleanup_active_children (); err "interrupted")
    val _ = Signal.signal (Posix.Signal.int, Signal.SIG_HANDLE handler)
    val _ = Signal.signal (Posix.Signal.term, Signal.SIG_HANDLE handler)
  in
    ()
  end

fun main raw_args =
  (let
     val _ = install_signal_handlers ()
     val _ = HolbuildStatus.set_json_mode (List.exists (fn s => s = "--json") raw_args)
     val _ =
       if raw_args = ["--version"] then
         (print ("holbuild " ^ HolbuildVersion.version ^ "\n"); OS.Process.exit OS.Process.success)
       else if raw_args = ["--help"] orelse raw_args = ["-h"]
       then (global_help (); OS.Process.exit OS.Process.success)
       else ()
     val (options, args) = parse_global_options raw_args
   in
     dispatch_with_options options args
   end)
  handle Thread.Interrupt => (HolbuildToolchain.cleanup_active_children (); err "interrupted")
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
       | HolbuildBuildExec.Error msg => err msg
       | HolbuildBuildExec.ErrorWithDebugArtifacts (msg, artifacts) => err_with_debug_artifacts msg artifacts
       | HolbuildHolSharedCache.Error msg => err msg
       | HolbuildCache.Error msg => err msg
       | HolbuildCacheArchive.Error msg => err msg
       | HolbuildCacheTransfer.Error msg => err msg
       | HolbuildCacheConfig.Error msg => err msg
       | HolbuildRemoteCacheConfig.Error msg => err msg
       | HolbuildWatch.Error msg => err msg
       | e => if is_broken_pipe e then OS.Process.exit OS.Process.success
              else err (General.exnMessage e)

end
