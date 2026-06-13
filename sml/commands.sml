structure HolbuildCommands =
struct

exception Error of string

fun err_with_debug_artifacts msg artifacts =
  (if HolbuildStatus.json_mode () then HolbuildStatus.error_with_debug_artifacts msg artifacts
   else HolbuildStatus.message_stderr ("holbuild: " ^ msg ^ "\n");
   OS.Process.exit OS.Process.failure)

fun err msg = err_with_debug_artifacts msg HolbuildStatus.no_debug_artifacts

fun warn msg = HolbuildStatus.message_stderr ("holbuild: warning: " ^ msg ^ "\n")

fun usage () = print
  "holbuild: experimental project-aware build frontend for HOL4\n\n\
  \Usage:\n\
  \  holbuild --version\n\
  \  holbuild [--json] [--quiet|--verbose|--verbosity LEVEL] [--source-dir PATH] [--maxheap MB] [-jN] context\n\
  \  holbuild [--json] [--quiet|--verbose|--verbosity LEVEL] [--source-dir PATH] [--maxheap MB] [-jN] execution-plan THEORY:THEOREM\n\
  \  holbuild [--json] [--quiet|--verbose|--verbosity LEVEL] [--source-dir PATH] [--maxheap MB] [-jN] build [--dry-run] [--force[=theory|project|full]] [--no-cache] [--skip-checkpoints] [--skip-proof-steps] [--tactic-timeout SECONDS] [--trace-steps] [--repl-on-failure] [--retain-debug-artifacts] [TARGET ...]\n\
  \  holbuild [--json] [--quiet|--verbose|--verbosity LEVEL] [--source-dir PATH] [--maxheap MB] [-jN] heap NAME\n\
  \  holbuild [--json] [--quiet|--verbose|--verbosity LEVEL] [--source-dir PATH] [--maxheap MB] run [ARG ...]\n\
  \  holbuild [--json] [--quiet|--verbose|--verbosity LEVEL] [--source-dir PATH] [--maxheap MB] repl [ARG ...]\n\
  \  holbuild [--source-dir PATH] buildhol\n\
  \  holbuild gc [--retention-days DAYS] [--max-checkpoints-gb GB] [--cache-dir PATH] [--clean-only|--cache-only]\n\n\
  \Projects must use schema 2 and declare dependencies.hol. Commands that need HOL\n\
  \build/reuse the declared HOL tree in the global cache. --holdir/HOLDIR are no\n\
  \longer supported.\n\
  \Project sources are found from --source-dir, HOLBUILD_SOURCE_DIR, or cwd.\n\
  \-j/--jobs controls build parallelism. Default is .holconfig.toml [build].jobs,\n\
  \or max(1, detected processor count / 2). --maxheap/--max-heap passes Poly/ML\n\
  \maximum heap size in MB to child HOL processes. --json emits newline-delimited\n\
  \JSON for build status, messages, and errors. Non-TTY normal output suppresses\n\
  \unchanged node lines; --verbose logs node starts, all finishes, and per-node\n\
  \elapsed times; --quiet suppresses per-node success lines.\n"

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
    fun loop dry force use_cache skip_checkpoints goalfrag new_ir tactic_timeout tactic_timeout_set goalfrag_plan goalfrag_trace repl_on_failure retain_debug_artifacts rest =
      case rest of
          [] => ({dry_run = dry, force = force, use_cache = use_cache,
                  skip_checkpoints = skip_checkpoints,
                  goalfrag = goalfrag, new_ir = new_ir,
                  tactic_timeout = tactic_timeout,
                  tactic_timeout_set = tactic_timeout_set,
                  goalfrag_plan = goalfrag_plan,
                  goalfrag_trace = goalfrag_trace,
                  repl_on_failure = repl_on_failure,
                  retain_debug_artifacts = retain_debug_artifacts}, [])
        | "--dry-run" :: xs =>
            loop true force use_cache skip_checkpoints goalfrag new_ir tactic_timeout tactic_timeout_set goalfrag_plan goalfrag_trace repl_on_failure retain_debug_artifacts xs
        | "--force" :: xs =>
            loop dry HolbuildBuildExec.ForceAll use_cache skip_checkpoints goalfrag new_ir tactic_timeout tactic_timeout_set goalfrag_plan goalfrag_trace repl_on_failure retain_debug_artifacts xs
        | "--force-theory" :: xs =>
            loop dry HolbuildBuildExec.ForceTargets use_cache skip_checkpoints goalfrag new_ir tactic_timeout tactic_timeout_set goalfrag_plan goalfrag_trace repl_on_failure retain_debug_artifacts xs
        | "--force-project" :: xs =>
            loop dry HolbuildBuildExec.ForceProject use_cache skip_checkpoints goalfrag new_ir tactic_timeout tactic_timeout_set goalfrag_plan goalfrag_trace repl_on_failure retain_debug_artifacts xs
        | "--force-full" :: xs =>
            loop dry HolbuildBuildExec.ForceAll use_cache skip_checkpoints goalfrag new_ir tactic_timeout tactic_timeout_set goalfrag_plan goalfrag_trace repl_on_failure retain_debug_artifacts xs
        | "--no-cache" :: xs =>
            loop dry force false skip_checkpoints goalfrag new_ir tactic_timeout tactic_timeout_set goalfrag_plan goalfrag_trace repl_on_failure retain_debug_artifacts xs
        | "--skip-checkpoints" :: xs =>
            loop dry force use_cache true goalfrag new_ir tactic_timeout tactic_timeout_set goalfrag_plan goalfrag_trace repl_on_failure retain_debug_artifacts xs
        | "--skip-proof-steps" :: xs =>
            loop dry force use_cache skip_checkpoints false false tactic_timeout tactic_timeout_set goalfrag_plan goalfrag_trace repl_on_failure retain_debug_artifacts xs
        | "--skip-goalfrag" :: xs =>
            (warn "--skip-goalfrag is deprecated; use --skip-proof-steps";
             loop dry force use_cache skip_checkpoints false false tactic_timeout tactic_timeout_set goalfrag_plan goalfrag_trace repl_on_failure retain_debug_artifacts xs)
        | "--goalfrag" :: _ =>
            raise Error "--goalfrag has been removed; proof steps are enabled by default"
        | "--new-ir" :: xs =>
            (warn "--new-ir is deprecated and has no effect; proof IR is the default";
             loop dry force use_cache skip_checkpoints goalfrag true tactic_timeout tactic_timeout_set goalfrag_plan goalfrag_trace repl_on_failure retain_debug_artifacts xs)
        | "--goalfrag-plan" :: _ => raise Error "--goalfrag-plan has been removed; use execution-plan THEORY:THEOREM"
        | "--trace-steps" :: xs =>
            loop dry force use_cache skip_checkpoints goalfrag new_ir tactic_timeout tactic_timeout_set goalfrag_plan true repl_on_failure retain_debug_artifacts xs
        | "--goalfrag-trace" :: xs =>
            (warn "--goalfrag-trace is deprecated; use --trace-steps";
             loop dry force use_cache skip_checkpoints goalfrag new_ir tactic_timeout tactic_timeout_set goalfrag_plan true repl_on_failure retain_debug_artifacts xs)
        | "--repl-on-failure" :: xs =>
            loop dry force use_cache skip_checkpoints goalfrag new_ir tactic_timeout tactic_timeout_set goalfrag_plan goalfrag_trace true retain_debug_artifacts xs
        | "--retain-debug-artifacts" :: xs =>
            loop dry force use_cache skip_checkpoints goalfrag new_ir tactic_timeout tactic_timeout_set goalfrag_plan goalfrag_trace repl_on_failure true xs
        | "--tactic-timeout" :: seconds :: xs =>
            loop dry force use_cache skip_checkpoints goalfrag new_ir (tactic_timeout_value seconds) true goalfrag_plan goalfrag_trace repl_on_failure retain_debug_artifacts xs
        | "--tactic-timeout" :: [] => raise Error "--tactic-timeout requires SECONDS"
        | x :: xs =>
            if String.isPrefix "--force=" x then
              loop dry (force_level_value (String.extract (x, size "--force=", NONE))) use_cache skip_checkpoints goalfrag new_ir tactic_timeout tactic_timeout_set goalfrag_plan goalfrag_trace repl_on_failure retain_debug_artifacts xs
            else if String.isPrefix "--tactic-timeout=" x then
              loop dry force use_cache skip_checkpoints goalfrag new_ir
                   (tactic_timeout_value (String.extract (x, size "--tactic-timeout=", NONE)))
                   true goalfrag_plan goalfrag_trace repl_on_failure retain_debug_artifacts xs
            else if String.isPrefix "--goalfrag-plan=" x then
              raise Error "--goalfrag-plan has been removed; use execution-plan THEORY:THEOREM"
            else if String.isPrefix "--trace-steps=" x then
              raise Error "--trace-steps does not take an argument"
            else if String.isPrefix "--goalfrag-trace=" x then
              raise Error "--goalfrag-trace has been replaced by --trace-steps and does not take an argument"
            else if String.isPrefix "--" x then
              raise Error ("unknown build option: " ^ x)
            else
              let val (flags, ys) = loop dry force use_cache skip_checkpoints goalfrag new_ir tactic_timeout tactic_timeout_set goalfrag_plan goalfrag_trace repl_on_failure retain_debug_artifacts xs
              in (flags, x :: ys) end
  in
    loop false HolbuildBuildExec.ForceNone true false true true NONE false NONE false false false args
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

fun default_build_targets project index targets =
  if null targets then HolbuildSourceIndex.default_targets index project else targets

fun source_key source =
  #package source ^ "\000" ^ #relative_path source ^ "\000" ^ #logical_name source

fun key_member key keys = List.exists (fn k => k = key) keys

fun rooted_package_names project =
  map HolbuildProject.package_name
    (List.filter (fn package => not (null (HolbuildProject.package_roots package)))
                 (HolbuildProject.packages project))

fun root_warning_source rooted_packages built_keys source =
  #kind source = HolbuildSourceIndex.TheoryScript andalso
  key_member (#package source) rooted_packages andalso
  not (key_member (source_key source) built_keys)

fun warn_unreachable_root_scripts project index plan =
  let
    val rooted_packages = rooted_package_names project
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

fun parse_goalfrag_selector selector =
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

fun bool_field "1" = true
  | bool_field "0" = false
  | bool_field s = raise Error ("bad proof-ir boolean field: " ^ s)

fun phase_field "start" = HolbuildProofIr.BranchStart
  | phase_field "suffix" = HolbuildProofIr.BranchSuffix
  | phase_field "close" = HolbuildProofIr.BranchClose
  | phase_field s = raise Error ("bad proof-ir branch phase: " ^ s)

fun int_field s =
  case Int.fromString s of SOME n => n | NONE => raise Error ("bad proof-ir integer field: " ^ s)

fun parse_proof_step fields =
  case fields of
      ["proof-step", "tactic", a, b, label, program] =>
        HolbuildProofIr.StepTactic {start_pos = int_field a, end_pos = int_field b, label = label, program = program}
    | ["proof-step", "list", a, b, label, program] =>
        HolbuildProofIr.StepList {start_pos = int_field a, end_pos = int_field b, label = label, program = program}
    | "proof-step" :: "choice" :: a :: b :: label :: program :: alternatives =>
        HolbuildProofIr.StepChoice {start_pos = int_field a, end_pos = int_field b, label = label, program = program, alternatives = alternatives}
    | "proof-step" :: "list-choice" :: a :: b :: label :: program :: alternatives =>
        HolbuildProofIr.StepListChoice {start_pos = int_field a, end_pos = int_field b, label = label, program = program, alternatives = alternatives}
    | ["proof-step", "then1", a, b, label, list_suffix, first_label, first_program, second_program] =>
        HolbuildProofIr.StepThen1 {start_pos = int_field a, end_pos = int_field b, label = label,
                                   list_suffix = bool_field list_suffix, first_label = first_label,
                                   first_program = first_program, second_program = second_program}
    | ["proof-step", "gentle-then1", a, b, label, list_suffix, first_program, second_program] =>
        HolbuildProofIr.StepGentleThen1 {start_pos = int_field a, end_pos = int_field b, label = label,
                                         list_suffix = bool_field list_suffix,
                                         first_program = first_program, second_program = second_program}
    | ["proof-step", "branch", a, b, label, program, phase] =>
        HolbuildProofIr.StepBranch {start_pos = int_field a, end_pos = int_field b, label = label, program = program,
                                    phase = phase_field phase}
    | ["proof-step", "branch-list", a, b, label, program] =>
        HolbuildProofIr.StepBranchList {start_pos = int_field a, end_pos = int_field b, label = label, program = program}
    | ["proof-step", "plain", a, b, label, program] =>
        HolbuildProofIr.StepPlain {start_pos = int_field a, end_pos = int_field b, label = label, program = program}
    | _ => raise Error ("bad proof-ir step response")

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
               | ["end-proof-ir", "0"] => loop more false [] (SOME (rev acc))
               | fields as "proof-step" :: _ =>
                   if active then loop more active (parse_proof_step fields :: acc) found
                   else loop more active acc found
               | _ => loop more active acc found)
  in
    case loop lines false [] NONE of
        SOME steps => steps
      | NONE => raise Error ("proof-IR plan missing for execution-plan theorem: " ^ name)
  end

fun print_static_goalfrag_plan project new_ir source theorem boundary_opt =
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

fun print_goalfrag_plan_selector new_ir project selector =
  let
    val {theory, theorem} = parse_goalfrag_selector selector
    val index = HolbuildSourceIndex.discover project
    val source = find_theory_source index theory
  in
    print_static_goalfrag_plan project new_ir source theorem (SOME (find_theorem_in_source theorem source))
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
    fun loop holdir source_dir jobs maxheap json verbosity rest =
      case rest of
          [] => ({holdir = holdir, source_dir = source_dir, jobs = jobs, maxheap = maxheap, json = json, verbosity = verbosity}, [])
        | "--json" :: xs => loop holdir source_dir jobs maxheap true verbosity xs
        | "--quiet" :: xs => loop holdir source_dir jobs maxheap json HolbuildStatus.Quiet xs
        | "--verbose" :: xs => loop holdir source_dir jobs maxheap json HolbuildStatus.Verbose xs
        | "--verbosity" :: level :: xs => loop holdir source_dir jobs maxheap json (verbosity_value level) xs
        | "--holdir" :: path :: xs => loop (SOME path) source_dir jobs maxheap json verbosity xs
        | "--source-dir" :: path :: xs => loop holdir (SOME path) jobs maxheap json verbosity xs
        | "--jobs" :: n :: xs => loop holdir source_dir (SOME (positive_int "--jobs" n)) maxheap json verbosity xs
        | "-j" :: n :: xs => loop holdir source_dir (SOME (positive_int "-j" n)) maxheap json verbosity xs
        | "--maxheap" :: n :: xs => loop holdir source_dir jobs (SOME (positive_int "--maxheap" n)) json verbosity xs
        | "--max-heap" :: n :: xs => loop holdir source_dir jobs (SOME (positive_int "--max-heap" n)) json verbosity xs
        | "--verbosity" :: [] => raise Error "--verbosity requires LEVEL"
        | "--holdir" :: [] => raise Error "--holdir requires PATH"
        | "--source-dir" :: [] => raise Error "--source-dir requires PATH"
        | "--jobs" :: [] => raise Error "--jobs requires N"
        | "-j" :: [] => raise Error "-j requires N"
        | "--maxheap" :: [] => raise Error "--maxheap requires MB"
        | "--max-heap" :: [] => raise Error "--max-heap requires MB"
        | arg :: xs =>
            if String.isPrefix "--verbosity=" arg then
              loop holdir source_dir jobs maxheap json (verbosity_value (String.extract (arg, size "--verbosity=", NONE))) xs
            else if String.isPrefix "--holdir=" arg then
              loop (SOME (String.extract (arg, size "--holdir=", NONE))) source_dir jobs maxheap json verbosity xs
            else if String.isPrefix "--source-dir=" arg then
              loop holdir (SOME (String.extract (arg, size "--source-dir=", NONE))) jobs maxheap json verbosity xs
            else if String.isPrefix "--jobs=" arg then
              loop holdir source_dir (SOME (positive_int "--jobs" (String.extract (arg, size "--jobs=", NONE)))) maxheap json verbosity xs
            else if String.isPrefix "--maxheap=" arg then
              loop holdir source_dir jobs (SOME (positive_int "--maxheap" (String.extract (arg, size "--maxheap=", NONE)))) json verbosity xs
            else if String.isPrefix "--max-heap=" arg then
              loop holdir source_dir jobs (SOME (positive_int "--max-heap" (String.extract (arg, size "--max-heap=", NONE)))) json verbosity xs
            else if String.isPrefix "-j" arg andalso size arg > 2 then
              loop holdir source_dir (SOME (positive_int "-j" (String.extract (arg, 2, NONE)))) maxheap json verbosity xs
            else
              let val (opts, args') = loop holdir source_dir jobs maxheap json verbosity xs in (opts, arg :: args') end
  in
    loop NONE NONE NONE NONE false HolbuildStatus.Normal args
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

fun load_project () =
  HolbuildProject.discover ()
  handle HolbuildProject.Error msg => raise Error msg

fun context () = HolbuildProject.describe (load_project ())

fun timed_phase name f = HolbuildToolchain.time_phase name f

fun configure_analyser_for_toolchain ({holdir, ...} : HolbuildToolchain.t) =
  if holdir = "" then HolbuildDependencies.clear_analyser_path ()
  else HolbuildDependencies.set_analyser_path (HolbuildHolSharedCache.analyser_path_for_holdir holdir)

fun build tc cli_jobs args =
  let
    val project = timed_phase "project.discover" load_project
    val ({dry_run, force, use_cache, skip_checkpoints, goalfrag, new_ir, tactic_timeout, tactic_timeout_set, goalfrag_plan, goalfrag_trace, repl_on_failure, retain_debug_artifacts}, targets) = split_flags args
    val _ = HolbuildStatus.set_retain_debug_artifacts retain_debug_artifacts
    val jobs = if repl_on_failure then 1 else effective_jobs project cli_jobs
    val _ =
      if HolbuildStatus.json_mode () andalso dry_run then
        raise Error "--json does not support build --dry-run yet"
      else if HolbuildStatus.json_mode () andalso goalfrag_trace then
        raise Error "--json does not support --trace-steps until structured proof-step trace events exist"
      else if dry_run andalso goalfrag_trace then
        raise Error "--trace-steps requires build execution; use --force to inspect up-to-date targets"
      else if dry_run andalso repl_on_failure then
        raise Error "--repl-on-failure requires build execution"
      else if HolbuildStatus.json_mode () andalso repl_on_failure then
        raise Error "--json does not support --repl-on-failure"
      else if skip_checkpoints andalso repl_on_failure then
        raise Error "--repl-on-failure requires checkpoints; remove --skip-checkpoints"
      else if not goalfrag andalso new_ir then
        raise Error "proof steps are required for proof IR; remove --skip-proof-steps"
      else if not goalfrag andalso tactic_timeout_set then
        raise Error "--tactic-timeout requires proof steps; remove --skip-proof-steps"
      else if not goalfrag andalso goalfrag_trace then
        raise Error "--trace-steps requires proof steps; remove --skip-proof-steps"
      else if not goalfrag andalso repl_on_failure then
        raise Error "--repl-on-failure requires proof steps; remove --skip-proof-steps"
      else ()
    fun default_tactic_timeout () =
      case #build_tactic_timeout project of
          NONE => SOME 2.5
        | some => some
    fun build_options_for index entry_plan plan force_targets =
      {use_cache = use_cache,
       force = force,
       force_targets = force_targets,
       skip_checkpoints = skip_checkpoints,
       goalfrag = goalfrag,
       new_ir = new_ir,
       node_tactic_timeouts =
         if tactic_timeout_set then HolbuildTacticTimeoutPolicy.plan_timeouts project plan tactic_timeout
         else HolbuildTacticTimeoutPolicy.entry_timeouts project index entry_plan (default_tactic_timeout ()),
       goalfrag_plan = goalfrag_plan,
       goalfrag_trace = goalfrag_trace,
       repl_on_failure = repl_on_failure}
    fun prepare_plan () =
      let
        val index = timed_phase "source.discover" (fn () => HolbuildSourceIndex.discover project)
        val requested_targets = targets
        val targets = timed_phase "targets.default" (fn () => default_build_targets project index requested_targets)
        val _ = reject_object_targets targets
        val plan = timed_phase "build.plan" (fn () => HolbuildBuildPlan.plan (#holdir tc) index targets)
        val entry_targets = map #2 (HolbuildTacticTimeoutPolicy.declared_entries project index)
        val entry_plan = timed_phase "entry_timeout.plan" (fn () => HolbuildBuildPlan.plan (#holdir tc) index entry_targets)
        val _ = if null requested_targets andalso not (null targets) then
                  warn_unreachable_root_scripts project index plan
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
  in
    if dry_run then describe_dry_run ()
    else HolbuildBuildExec.with_project_lock project "build" execute_build
  end

fun heap_named project target =
  let
    fun matches (HolbuildProject.Heap {name, ...}) = name = target
  in
    case List.find matches (#heaps project) of
        SOME heap => heap
      | NONE => raise Error ("unknown heap target: " ^ target)
  end

fun build_heap tc cli_jobs target =
  let
    val project = timed_phase "project.discover" load_project
    val jobs = effective_jobs project cli_jobs
    fun execute_heap () =
      let
        val HolbuildProject.Heap {output, objects, ...} = heap_named project target
        val _ = if null objects then raise Error ("heap target has no objects: " ^ target) else ()
        val index = timed_phase "source.discover" (fn () => HolbuildSourceIndex.discover project)
        val plan = timed_phase "build.plan" (fn () => HolbuildBuildPlan.plan (#holdir tc) index objects)
        val toolchain_key = timed_phase "toolchain.key" (fn () => HolbuildToolchain.toolchain_key tc)
        val output_path = HolbuildProject.abs_under (#root project) output
      in
        HolbuildBuildExec.build {use_cache = true, force = HolbuildBuildExec.ForceNone, force_targets = [], skip_checkpoints = false, goalfrag = true, new_ir = true, node_tactic_timeouts = HolbuildTacticTimeoutPolicy.entry_timeouts project index plan (SOME 2.5), goalfrag_plan = NONE, goalfrag_trace = false, repl_on_failure = false}
                               tc project plan toolchain_key jobs;
        HolbuildBuildExec.export_heap tc project plan output_path
      end
  in
    HolbuildBuildExec.with_project_lock project ("heap " ^ target) execute_heap
  end

fun hol_args_for_project tc project subcommand user_args =
  let
    val context = HolbuildToolchain.write_run_context project
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

fun goalfrag_plan_command _ _ =
  raise Error "goalfrag-plan has been removed; use execution-plan THEORY:THEOREM"

fun execution_plan_command tc args =
  (configure_analyser_for_toolchain tc;
   case args of
       [selector] => print_goalfrag_plan_selector true (load_project ()) selector
     | _ => raise Error "usage: holbuild execution-plan THEORY:THEOREM")

fun reject_json command =
  if HolbuildStatus.json_mode () then
    raise Error ("--json does not support " ^ command ^ " yet")
  else ()

fun dispatch tc jobs args =
  case args of
      [] => (reject_json "context"; context ())
    | "context" :: [] => (reject_json "context"; context ())
    | "execution-plan" :: rest => (reject_json "execution-plan"; execution_plan_command tc rest)
    | "goalfrag-plan" :: rest => goalfrag_plan_command tc rest
    | "build" :: rest => build tc jobs rest
    | "heap" :: [target] => (reject_json "heap"; build_heap tc jobs target)
    | "heap" :: _ => raise Error "usage: holbuild heap NAME"
    | "run" :: rest => (reject_json "run"; run_hol tc "run" rest)
    | "repl" :: rest => (reject_json "repl"; repl_hol tc rest)
    | cmd :: _ => raise Error ("unknown command: " ^ cmd)

fun parse_gc_args args =
  let
    fun result root days max_checkpoints_gb clean_only cache_only =
      case (clean_only, cache_only) of
          (true, true) => raise Error "--clean-only and --cache-only are mutually exclusive"
        | (true, false) => (root, days, max_checkpoints_gb, true, false)
        | (false, true) => (root, days, max_checkpoints_gb, false, true)
        | (false, false) => (root, days, max_checkpoints_gb, true, true)
    fun loop root days max_checkpoints_gb clean_only cache_only rest =
      case rest of
          [] => result root days max_checkpoints_gb clean_only cache_only
        | "--cache-dir" :: path :: xs => loop (SOME path) days max_checkpoints_gb clean_only cache_only xs
        | "--retention-days" :: n :: xs => loop root (HolbuildCache.parse_days n) max_checkpoints_gb clean_only cache_only xs
        | "--days" :: n :: xs => loop root (HolbuildCache.parse_days n) max_checkpoints_gb clean_only cache_only xs
        | "--max-checkpoints-gb" :: n :: xs =>
            (case Int.fromString n of
                 SOME gb => if gb >= 0 then loop root days gb clean_only cache_only xs
                            else raise Error "--max-checkpoints-gb must be non-negative"
               | NONE => raise Error "--max-checkpoints-gb requires an integer")
        | "--max-checkpoints-gb" :: [] => raise Error "--max-checkpoints-gb requires GB"
        | "--clean-only" :: xs => loop root days max_checkpoints_gb true cache_only xs
        | "--cache-only" :: xs => loop root days max_checkpoints_gb clean_only true xs
        | arg :: _ => raise Error ("unknown gc option: " ^ arg)
  in
    loop NONE HolbuildCache.default_retention_days HolbuildBuildExec.default_max_checkpoints_gb false false args
  end

fun run_project_gc (days, max_checkpoints_gb) =
  let
    val project = load_project ()
    fun clean_project () = HolbuildBuildExec.clean_project project days max_checkpoints_gb
  in
    HolbuildBuildExec.with_project_lock project "gc" clean_project
  end

fun gc args =
  let
    val (cache_root, days, max_checkpoints_gb, clean_project, clean_cache) = parse_gc_args args
    val _ = if clean_project then run_project_gc (days, max_checkpoints_gb) else ()
    val _ = if clean_cache then HolbuildCache.gc_root (Option.getOpt(cache_root, HolbuildCache.cache_root ())) days else ()
  in
    ()
  end

fun reject_holdir holdir =
  case holdir of
      SOME _ => raise Error "--holdir is no longer supported; declare dependencies.hol"
    | NONE => ()

fun require_schema2 project =
  if HolbuildProject.schema project = 2 then ()
  else raise Error "only holproject schema 2 is supported"

fun project_hol_holdir project =
  (HolbuildProject.packages project;
   case HolbuildProject.resolved_hol_dependency project of
       SOME (HolbuildProject.Dependency {source = HolbuildProject.GitSource {git, rev}, ...}) =>
         HolbuildHolSharedCache.ensure_built {git = git, rev = rev}
     | _ => raise Error "schema 2 project has no dependencies.hol")

fun effective_toolchain holdir maxheap =
  let
    val project = load_project ()
    val _ = reject_holdir holdir
    val _ = require_schema2 project
  in
    {holdir = project_hol_holdir project, maxheap = maxheap}
  end

fun context_toolchain holdir maxheap =
  let
    val project = load_project ()
    val _ = reject_holdir holdir
    val _ = require_schema2 project
  in
    {holdir = "", maxheap = maxheap}
  end

fun buildhol holdir maxheap =
  let
    val project = load_project ()
    val _ = reject_holdir holdir
    val _ = require_schema2 project
    val holdir = project_hol_holdir project
  in
    print (holdir ^ "\n")
  end

fun removed_goalfrag_build_arg arg =
  arg = "--goalfrag" orelse arg = "--goalfrag-plan" orelse String.isPrefix "--goalfrag-plan=" arg

fun trace_steps_build_arg arg = arg = "--trace-steps" orelse arg = "--goalfrag-trace"

fun dispatch_with_options {holdir, source_dir, jobs, maxheap, json, verbosity} args =
  (HolbuildStatus.set_json_mode json;
   HolbuildStatus.set_verbosity verbosity;
   HolbuildStatus.set_retain_debug_artifacts false;
   Option.app HolbuildProject.set_source_dir source_dir;
   case args of
       "gc" :: rest => (reject_json "gc"; gc rest)
     | "cache" :: rest => (reject_json "cache"; HolbuildCache.dispatch rest)
     | "buildhol" :: [] => buildhol holdir maxheap
     | "goalfrag-plan" :: _ => raise Error "goalfrag-plan has been removed; use execution-plan THEORY:THEOREM"
     | "build" :: rest =>
         if List.exists removed_goalfrag_build_arg rest then
           (case List.find removed_goalfrag_build_arg rest of
                SOME "--goalfrag" => raise Error "--goalfrag has been removed; proof steps are enabled by default"
              | SOME _ => raise Error "--goalfrag-plan has been removed; use execution-plan THEORY:THEOREM"
              | NONE => dispatch (effective_toolchain holdir maxheap) jobs args)
         else if json andalso List.exists trace_steps_build_arg rest then
           raise Error "--json does not support --trace-steps until structured proof-step trace events exist"
         else dispatch (effective_toolchain holdir maxheap) jobs args
     | [] => dispatch (context_toolchain holdir maxheap) jobs args
     | "context" :: _ => dispatch (context_toolchain holdir maxheap) jobs args
     | _ => dispatch (effective_toolchain holdir maxheap) jobs args)

fun is_broken_pipe (IO.Io {cause = OS.SysErr (msg, _), ...}) = msg = "Broken pipe"
  | is_broken_pipe _ = false

fun main raw_args =
  (let
     val _ = HolbuildStatus.set_json_mode (List.exists (fn s => s = "--json") raw_args)
     val _ =
       if raw_args = ["--version"] then
         (print ("holbuild " ^ HolbuildVersion.version ^ "\n"); OS.Process.exit OS.Process.success)
       else if List.exists (fn s => s = "--help" orelse s = "-h" orelse s = "help") raw_args
       then (usage (); OS.Process.exit OS.Process.success)
       else ()
     val (options, args) = parse_global_options raw_args
   in
     dispatch_with_options options args
   end)
  handle Thread.Interrupt => (HolbuildToolchain.cleanup_active_children (); err "interrupted")
       | Error msg => err msg
       | HolbuildToolchain.Error msg => err msg
       | HolbuildProject.Error msg => err msg
       | HolbuildGenerators.Error msg => err msg
       | HolbuildGenerators.ErrorWithDebugArtifacts (msg, artifacts) => err_with_debug_artifacts msg artifacts
       | HolbuildSourceIndex.Error msg => err msg
       | HolbuildSourceIndex.ErrorWithDebugArtifacts (msg, artifacts) => err_with_debug_artifacts msg artifacts
       | HolbuildDependencies.Error msg => err msg
       | HolbuildBuildPlan.Error msg => err msg
       | HolbuildBuildExec.Error msg => err msg
       | HolbuildBuildExec.ErrorWithDebugArtifacts (msg, artifacts) => err_with_debug_artifacts msg artifacts
       | HolbuildHolSharedCache.Error msg => err msg
       | HolbuildCache.Error msg => err msg
       | e => if is_broken_pipe e then OS.Process.exit OS.Process.success
              else err (General.exnMessage e)

end
