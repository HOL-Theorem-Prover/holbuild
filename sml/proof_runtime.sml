structure HolbuildProofRuntime =
struct

type config = {checkpoint_enabled : bool,
               tactic_timeout : real option,
               timeout_marker : string option,
               plan_theorem : string option,
               trace_all : bool,
               plan_only_marker : string option}

val checkpoint_enabled_ref = ref false
val tactic_timeout_ref = ref (NONE : real option)
val tactic_timeout_marker_ref = ref (NONE : string option)
val plan_theorem_ref = ref (NONE : string option)
val trace_all_ref = ref false
val plan_only_marker_ref = ref (NONE : string option)
val plan_active_ref = ref false
val trace_active_ref = ref false
val trace_current_theorem_ref = ref ""
val theorem_info_ref = ref NONE : (string * string * string * string * string * string * string * string * string * bool * int) option ref
val context_info_ref = ref NONE : (string * string * int) option ref
val failed_prefix_resume_active_ref = ref false
val proving_with_proof_ir_ref = ref false
val active_tactic_text_ref = ref ""
val active_plan_ref = ref (NONE : HolbuildProofIr.step list option)
val successful_step_count_ref = ref 0
val successful_prefix_end_ref = ref 0
val current_path_ref = ref ([] : HolbuildProofIr.proof_path)
val successful_path_ref = ref ([] : HolbuildProofIr.proof_path)
val dynamic_events_ref = ref ([] : HolbuildProofIr.dynamic_event list)
val failed_step_end_ref = ref NONE : int option ref
val failed_step_span_ref = ref NONE : (int * int) option ref
val failed_plan_position_ref = ref NONE : (int * string * string) option ref
val suppress_expected_failure_diagnostics_ref = ref false
val compiled_tactic_ref = ref Tactical.ALL_TAC
val compiled_list_tactic_ref = ref Tactical.ALL_LT
val proof_history_ref = ref (NONE : goalStack.gstk History.history option)
val branch_tail_count_ref = ref ([] : int list)
val reverse_group_lengths_ref = ref (NONE : int list option)

fun env_bool name =
  case OS.Process.getEnv name of
      SOME "1" => SOME true
    | SOME "true" => SOME true
    | SOME "yes" => SOME true
    | SOME "0" => SOME false
    | SOME "false" => SOME false
    | SOME "no" => SOME false
    | _ => NONE

fun seconds (a, b) = Time.toReal (Time.-(b, a))
fun fmt_ms t = Real.fmt (StringCvt.FIX (SOME 3)) (1000.0 * t)

fun write_timeout_marker label seconds =
  case !tactic_timeout_marker_ref of
      NONE => ()
    | SOME path =>
        let val out = TextIO.openOut path
        in TextIO.output(out, String.concat [label, "\t", Real.toString seconds, "\n"]);
           TextIO.closeOut out
        end

fun timeout_message label seconds =
  String.concat ["holbuild tactic timeout after ", Real.toString seconds, "s: ", label]

fun with_tactic_timeout label f x =
  case !tactic_timeout_ref of
      NONE => f x
    | SOME seconds =>
        (smlTimeout.timeout seconds f x
         handle smlTimeout.FunctionTimeout =>
           (write_timeout_marker label seconds;
            raise Fail (timeout_message label seconds)))

fun save_checkpoint label default_share path ok_text depth =
  if not (!checkpoint_enabled_ref) then ()
  else
    HolbuildCheckpointSaveRuntime.save_checkpoint
      {label = label, default_share = default_share, path = path,
       ok_text = ok_text, depth = depth}

fun write_text_file path text =
  let val out = TextIO.openOut path
  in TextIO.output(out, text); TextIO.closeOut out end

fun take_at_most n xs =
  let
    fun loop 0 _ acc = rev acc
      | loop _ [] acc = rev acc
      | loop k (x :: rest) acc = loop (k - 1) rest (x :: acc)
  in loop (Int.max(0, n)) xs [] end

fun path_component_text component =
  case component of
      HolbuildProofIr.PathStep n => "step:" ^ Int.toString n
    | HolbuildProofIr.PathEach n => "each:" ^ Int.toString n
    | HolbuildProofIr.PathSelect => "select"
    | HolbuildProofIr.PathCase n => "case:" ^ Int.toString n
    | HolbuildProofIr.PathAlternative n => "alternative:" ^ Int.toString n
    | HolbuildProofIr.PathTry => "try"
    | HolbuildProofIr.PathRepeat n => "repeat:" ^ Int.toString n

fun path_text path = String.concatWith "/" (map path_component_text path)

fun dynamic_event_text event =
  case event of
      HolbuildProofIr.ChoiceEvent (path, n) => "choice\t" ^ path_text path ^ "\t" ^ Int.toString n
    | HolbuildProofIr.TryEvent (path, taken) => "try\t" ^ path_text path ^ "\t" ^ (if taken then "1" else "0")
    | HolbuildProofIr.RepeatIterEvent (path, n) => "repeat-iter\t" ^ path_text path ^ "\t" ^ Int.toString n
    | HolbuildProofIr.RepeatStopEvent (path, n) => "repeat-stop\t" ^ path_text path ^ "\t" ^ Int.toString n

fun encode_step_signature proof_step =
  let val (kind, program) = HolbuildProofIr.step_signature proof_step
  in kind ^ "\t" ^ String.toString program ^ "\n" end

fun save_failed_prefix_steps path plan step_count =
  let
    val text = String.concat (map encode_step_signature (take_at_most step_count plan))
  in write_text_file (path ^ ".steps") text end
  handle _ => ()

fun decode_step_signature line =
  case String.fields (fn c => c = #"\t") line of
      kind :: rest =>
        let val encoded_program = String.concatWith "\t" rest
        in Option.map (fn program => (kind, program)) (String.fromString encoded_program) end
    | [] => NONE

fun read_failed_prefix_steps path =
  let
    val input = TextIO.openIn (path ^ ".steps")
    fun loop acc =
      case TextIO.inputLine input of
          NONE => (TextIO.closeIn input; SOME (rev acc))
        | SOME line =>
            let val trimmed = String.substring(line, 0, Int.max(0, size line - (if size line > 0 andalso String.sub(line, size line - 1) = #"\n" then 1 else 0)))
            in
              case decode_step_signature trimmed of
                  SOME sig_pair => loop (sig_pair :: acc)
                | NONE => (TextIO.closeIn input; NONE)
            end
  in loop [] end
  handle _ => NONE

fun save_failed_prefix_checkpoint () =
  case !theorem_info_ref of
      NONE => ()
    | SOME (kind, _, _, _, _, _, _, failed_prefix_path, failed_prefix_ok, _, depth) =>
        if not (kind = "theorem" orelse kind = "resume") orelse
           not (!checkpoint_enabled_ref) orelse
           !failed_prefix_resume_active_ref then ()
        else
          let
            val prefix_end = !successful_prefix_end_ref
            val prefix_text = String.substring(!active_tactic_text_ref, 0, prefix_end)
            val step_count = !successful_step_count_ref
            val meta_text =
              String.concat (["proof_ir_failed_prefix_version=1\n",
                              "step_count=", Int.toString step_count, "\n",
                              "prefix_end=", Int.toString prefix_end, "\n",
                              "path=", path_text (!successful_path_ref), "\n"] @
                             map (fn event => "event=" ^ dynamic_event_text event ^ "\n") (rev (!dynamic_events_ref)))
            val _ =
              (case !proof_history_ref of
                   NONE => ()
                 | SOME history =>
                     proof_history_ref := SOME (History.set_limit history (Int.max(15, step_count + 1))))
            val _ = save_checkpoint "failed_prefix" false failed_prefix_path failed_prefix_ok depth
            val _ = write_text_file (failed_prefix_path ^ ".meta") meta_text
            val _ = write_text_file (failed_prefix_path ^ ".prefix") prefix_text
            val plan = case !active_plan_ref of SOME p => p | NONE => raise Fail "internal error: proof-IR plan is not installed"
            val _ = save_failed_prefix_steps failed_prefix_path plan step_count
          in () end

fun restore_failed_prefix_checkpoint_info (name, tactic_text, failed_prefix_path, failed_prefix_ok) =
  let val depth = length (PolyML.SaveState.showHierarchy())
  in
    theorem_info_ref := SOME ("theorem", name, tactic_text, "", "", "", "",
                              failed_prefix_path, failed_prefix_ok, false, depth)
  end

fun set_theorem_plan plan = active_plan_ref := plan

fun begin_theorem (kind, name, tactic_text, context_path, context_ok,
                   end_path, end_ok, failed_prefix_path, failed_prefix_ok, has_attrs) =
  let val depth = length (PolyML.SaveState.showHierarchy())
  in
    theorem_info_ref := SOME (kind, name, tactic_text, context_path, context_ok,
                              end_path, end_ok, failed_prefix_path, failed_prefix_ok, has_attrs, depth);
    context_info_ref := SOME (context_path, context_ok, depth)
  end

fun save_theorem_context () =
  case !context_info_ref of
      NONE => ()
    | SOME (context_path, context_ok, depth) =>
        (context_info_ref := NONE;
         save_checkpoint "theorem_context" false context_path context_ok depth)

fun goal_text goal = PP.pp_to_string 100 goalStack.std_pp_goal goal ^ "\n"

fun top_goal_text [] = "<no open goals>\n"
  | top_goal_text (goal :: _) = goal_text goal

fun numbered_goal_text total (index, goal) =
  String.concat ["holbuild goal ", Int.toString index, " of ", Int.toString total, ":\n",
                 goal_text goal]

val all_goals_limit = 4096

fun limited_all_goals_text text =
  if size text <= all_goals_limit then text
  else
    String.concat [String.substring(text, 0, all_goals_limit),
                   "\nholbuild failed tactic input goals truncated after ", Int.toString all_goals_limit, " bytes\n"]

fun all_goals_text goals =
  if length goals <= 1 then ""
  else
    let
      val total = length goals
      val indexed = ListPair.zip (List.tabulate(total, fn i => i + 1), goals)
      val text = String.concat (map (numbered_goal_text total) indexed)
    in
      String.concat ["holbuild all failed tactic input goals:\n", limited_all_goals_text text,
                     "holbuild end all failed tactic input goals\n"]
    end

fun active_theorem_name () =
  case !theorem_info_ref of
      SOME (_, name, _, _, _, _, _, _, _, _, _) => SOME name
    | NONE => NONE

fun failed_theorem_line () =
  case active_theorem_name () of
      NONE => ""
    | SOME name => "\nholbuild failed theorem: " ^ name

fun failed_step_end_line () =
  case !failed_step_end_ref of
      NONE => ""
    | SOME end_pos => "\nholbuild failed fragment end: " ^ Int.toString end_pos

fun failed_step_span_line () =
  case !failed_step_span_ref of
      NONE => ""
    | SOME (start_pos, end_pos) =>
        String.concat ["\nholbuild failed fragment span: ", Int.toString start_pos,
                       " ", Int.toString end_pos]

fun display_label label =
  String.translate (fn #"\n" => "\\n" | #"\t" => "\\t" | c => String.str c) label

fun failed_plan_position_line () =
  case !failed_plan_position_ref of
      NONE => ""
    | SOME (index, kind, label) =>
        String.concat ["\nholbuild plan position: ", HolbuildProofIr.format_index index,
                       " ", kind, " ", display_label label]

fun current_history () =
  case !proof_history_ref of
      SOME history => history
    | NONE => raise Fail "proof IR goal history is not initialized"

fun install_repl_proof_state () =
  (proofManagerLib.add
     (Manager.PF (Manager.GOALSTACK (current_history()), Manager.id_tacm));
   ())

fun set_history history = proof_history_ref := SOME history
fun clear_history () = proof_history_ref := NONE

fun project_history f = History.project f (current_history())

fun init_history g limit =
  set_history (History.new_history {obj = goalStack.new_goal g Lib.I,
                                    limit = Int.max(15, limit)})

fun apply_history f =
  Lib.with_flag (goalStack.chatting, false)
    (fn () => History.apply f (current_history())) ()

fun append_history f = set_history (apply_history f)

fun append_history_with_timeout label f =
  let val new_history = with_tactic_timeout label apply_history f
  in set_history new_history end

fun ensure_history_limit limit = set_history (History.set_limit (current_history()) (Int.max(15, limit)))

fun history_top_goals () = project_history goalStack.top_goals

fun alpha_convert_to_goal g th =
  let
    val goal_concl = #2 g
    val th_concl = Thm.concl th
  in
    if Term.identical th_concl goal_concl then th
    else Thm.EQ_MP (Thm.ALPHA th_concl goal_concl) th
  end

fun history_top_thm g = alpha_convert_to_goal g (project_history goalStack.extract_thm)

fun trim_left s =
  let
    val n = size s
    fun loop i = if i >= n orelse not (Char.isSpace (String.sub(s, i))) then i else loop (i + 1)
    val i = loop 0
  in String.extract(s, i, NONE) end

fun drop_prefix prefix s =
  if String.isPrefix prefix s then SOME (String.extract(s, size prefix, NONE)) else NONE

fun diagnostic_fragment_label label =
  let val s = trim_left label
  in
    if s = ">- solved" then "branch close"
    else
      case drop_prefix ">> " s of
          SOME rest => rest
        | NONE =>
          case drop_prefix ">- " s of
              SOME rest => rest
            | NONE => s
  end

fun print_goal_state label goals =
  TextIO.output(TextIO.stdErr,
    String.concat ["\nholbuild goal state at failed fragment: ", diagnostic_fragment_label label,
                   failed_theorem_line (),
                   failed_step_end_line (),
                   failed_step_span_line (),
                   failed_plan_position_line (),
                   "\nholbuild failed tactic input goal count: ", Int.toString (length goals), "\n",
                   "holbuild failed tactic top input goal:\n",
                   top_goal_text goals,
                   "holbuild end failed tactic top input goal\n",
                   all_goals_text goals])

fun print_current_goal_state label =
  print_goal_state label (history_top_goals() handle _ => [])

fun print_finish_goal_state name =
  let
    val old_failed_step_end = !failed_step_end_ref
    val old_failed_step_span = !failed_step_span_ref
    val tactic_end = size (!active_tactic_text_ref)
    val _ = failed_step_end_ref := SOME tactic_end
    val _ = failed_step_span_ref := SOME (tactic_end, tactic_end)
    val result = (print_current_goal_state (name ^ " finish"); true) handle e => (failed_step_end_ref := old_failed_step_end; failed_step_span_ref := old_failed_step_span; raise e)
    val _ = failed_step_end_ref := old_failed_step_end
    val _ = failed_step_span_ref := old_failed_step_span
  in
    result
  end

fun report_step_failure_with_goals label goals e =
  if !suppress_expected_failure_diagnostics_ref then raise e
  else
    (save_failed_prefix_checkpoint ();
     print_goal_state label goals
     handle print_e =>
       TextIO.output(TextIO.stdErr,
         String.concat ["holbuild failed to print goal state: ", General.exnMessage print_e, "\n"]);
     raise e)

fun report_step_failure label e =
  report_step_failure_with_goals label (history_top_goals() handle _ => []) e

fun take_goals n goals =
  let
    fun loop 0 _ acc = rev acc
      | loop _ [] acc = rev acc
      | loop k (goal :: rest) acc = loop (k - 1) rest (goal :: acc)
  in
    loop (Int.max(0, n)) goals []
  end

fun top_input_goals () = take_goals 1 (history_top_goals())

fun compile_tactic label program =
  if smlExecute.quse_string ("HolbuildProofRuntime.compiled_tactic_ref := (" ^ program ^ ");") then
    !compiled_tactic_ref
  else
    raise Fail ("tactic fragment did not compile: " ^ label)

fun compile_list_tactic label program =
  if smlExecute.quse_string ("HolbuildProofRuntime.compiled_list_tactic_ref := (" ^ program ^ ");") then
    !compiled_list_tactic_ref
  else
    raise Fail ("list tactic fragment did not compile: " ^ label)

fun history_is_proved () =
  ((project_history goalStack.extract_thm; true) handle _ => false)

fun active_focus_snapshot label =
  case !branch_tail_count_ref of
      [] =>
        let val goals = history_top_goals()
        in {goals = goals, total_count = length goals, generated_count = length goals, tail_count = 0} end
        handle e => if history_is_proved () then {goals = [], total_count = 0, generated_count = 0, tail_count = 0} else raise e
    | tail_count :: _ =>
        let
          val goals = history_top_goals()
          val total_count = length goals
          val generated_count = total_count - tail_count
        in
          if generated_count < 0 then raise Fail ("focus tail count exceeds open goals: " ^ label)
          else {goals = goals, total_count = total_count, generated_count = generated_count, tail_count = tail_count}
        end
        handle e => if tail_count = 0 andalso history_is_proved () then {goals = [], total_count = 0, generated_count = 0, tail_count = tail_count} else raise e

fun apply_focus_list_tactic label list_tactic =
  let
    val {goals, total_count, generated_count, ...} = active_focus_snapshot label
    val input_goals = take_goals generated_count goals
    val scoped_list_tactic =
      case !branch_tail_count_ref of
          [] => list_tactic
        | _ => Tactical.SPLIT_LT generated_count (list_tactic, Tactical.ALL_LT)
  in
    (if generated_count = 0 then
       (if total_count = 0 then () else append_history (goalStack.expand_listf Tactical.ALL_LT))
     else
       append_history_with_timeout label (goalStack.expand_listf scoped_list_tactic))
    handle e => report_step_failure_with_goals label input_goals e
  end

fun apply_tactic_step label program =
  let val tactic = compile_tactic label program
  in apply_focus_list_tactic label (Tactical.ALLGOALS tactic) end

fun no_open_goals () =
  ((history_top_goals (); false)
   handle _ => true)

fun allgoals_suffix_label label = String.isPrefix ">> " label

fun apply_list_tactic_step label program =
  if allgoals_suffix_label label andalso no_open_goals () then ()
  else
    let val list_tactic = compile_list_tactic label program
    in apply_focus_list_tactic label list_tactic end

fun recording_allgoals tactic goals =
  let
    val results = map tactic goals
    val goal_groups = map (fn (generated, _) => generated) results
    val validators = map (fn (_, validate) => validate) results
    val lengths = map length goal_groups
    val _ = reverse_group_lengths_ref := SOME lengths
  in
    (List.concat goal_groups, Lib.mapshape lengths validators)
  end

fun split_by_lengths lengths xs =
  let
    fun loop [] rest = ([], rest)
      | loop (n :: ns) rest =
          let
            val (group, tail) = Lib.split_after n rest
            val (groups, final_tail) = loop ns tail
          in
            (group :: groups, final_tail)
          end
  in
    loop lengths xs
  end

fun reverse_recorded_groups goals =
  case !reverse_group_lengths_ref of
      NONE => raise Fail "reverse_recorded_groups without recorded ALLGOALS groups"
    | SOME lengths =>
        let
          val (goal_groups, remaining_goals) = split_by_lengths lengths goals
          val _ = if null remaining_goals then () else raise Fail "reverse_recorded_groups saw unexpected extra goals"
          val _ = reverse_group_lengths_ref := NONE
          fun validate thms =
            let
              val (thm_groups, remaining_thms) = split_by_lengths lengths thms
              val _ = if null remaining_thms then () else raise Fail "reverse_recorded_groups validation saw unexpected extra theorems"
            in
              List.concat (map rev thm_groups)
            end
        in
          (List.concat (map rev goal_groups), validate)
        end

fun current_goal_total () = length (history_top_goals()) handle _ => 0

fun push_branch_tail_count tail_count =
  branch_tail_count_ref := tail_count :: !branch_tail_count_ref

fun pop_branch_tail_count label =
  case !branch_tail_count_ref of
      [] => raise Fail ("focus close without active focus: " ^ label)
    | _ :: rest => branch_tail_count_ref := rest

fun push_first_focus label =
  let
    val {generated_count, tail_count, ...} = active_focus_snapshot label
    val _ = if generated_count <= 0 then raise Fail ("select with no focused goals: " ^ label) else ()
  in push_branch_tail_count (tail_count + generated_count - 1) end

fun focused_goal_count label = #generated_count (active_focus_snapshot label)

fun close_focus label HolbuildProofIr.SelectKeep = pop_branch_tail_count label
  | close_focus label HolbuildProofIr.SelectSolve =
      let val remaining = focused_goal_count label
      in
        if remaining = 0 then pop_branch_tail_count label
        else raise Fail "selected goals were not solved"
      end

fun step proof_step =
  case proof_step of
      HolbuildProofIr.StepTactic {label, program, ...} => apply_tactic_step label program
    | HolbuildProofIr.StepList {label, program, ...} => apply_list_tactic_step label program
    | HolbuildProofIr.StepEach _ => raise Fail "internal error: StepEach is handled by structural runner"
    | HolbuildProofIr.StepSelect _ => raise Fail "internal error: StepSelect is handled by structural runner"
    | HolbuildProofIr.StepCases _ => raise Fail "internal error: StepCases is handled by structural runner"
    | HolbuildProofIr.StepChoice _ => raise Fail "internal error: StepChoice is handled by structural runner"
    | HolbuildProofIr.StepRepeat _ => raise Fail "internal error: StepRepeat is handled by structural runner"
    | HolbuildProofIr.StepTry _ => raise Fail "internal error: StepTry is handled by structural runner"

fun inspection_matches wanted name =
  case wanted of NONE => false | SOME selected => selected = name

fun trace_enabled () =
  !trace_active_ref orelse Option.getOpt(env_bool "HOLBUILD_GOALFRAG_TRACE", false)

fun plan_enabled () =
  !plan_active_ref orelse trace_enabled ()

fun current_goal_count () = length (history_top_goals()) handle _ => ~1

fun trace_line parts =
  if trace_enabled () then TextIO.output(TextIO.stdErr, String.concat parts) else ()

fun trace_plan theorem_name plan =
  if plan_enabled () then
    (TextIO.output(TextIO.stdErr,
       String.concat ["holbuild proof-ir plan theorem=", theorem_name,
                      " steps=", Int.toString (length plan), "\n"]);
     List.app
       (fn (index, proof_step) =>
          TextIO.output(TextIO.stdErr,
            String.concat ["holbuild proof-ir plan step=", Int.toString index,
                           " theorem=", theorem_name,
                           " kind=", HolbuildProofIr.step_kind proof_step,
                           " end=", Int.toString (HolbuildProofIr.step_end proof_step),
                           " label=", display_label (HolbuildProofIr.step_label proof_step), "\n"]))
       (ListPair.zip (List.tabulate(length plan, fn i => i), plan)))
  else ()

fun stop_after_plan_if_requested () =
  if !plan_active_ref andalso not (!trace_active_ref) then
    case !plan_only_marker_ref of
        NONE => ()
      | SOME path => (write_text_file path "holbuild-proof-ir-plan-ok\n";
                      OS.Process.exit OS.Process.success)
  else ()

fun trace_before index proof_step =
  trace_line ["holbuild proof-ir before theorem=", !trace_current_theorem_ref,
              " step=", Int.toString index,
              " kind=", HolbuildProofIr.step_kind proof_step,
              " goals=", Int.toString (current_goal_count()),
              " label=", display_label (HolbuildProofIr.step_label proof_step), "\n"]

fun trace_after status elapsed index proof_step =
  trace_line ["holbuild proof-ir after theorem=", !trace_current_theorem_ref,
              " step=", Int.toString index,
              " kind=", HolbuildProofIr.step_kind proof_step,
              " status=", status,
              " elapsed_ms=", fmt_ms elapsed,
              " goals=", Int.toString (current_goal_count()),
              " label=", display_label (HolbuildProofIr.step_label proof_step), "\n"]

fun with_expected_failures_suppressed f =
  let val old = !suppress_expected_failure_diagnostics_ref
      val _ = suppress_expected_failure_diagnostics_ref := true
      val result = (f (); NONE) handle e => SOME e
      val _ = suppress_expected_failure_diagnostics_ref := old
  in case result of NONE => () | SOME e => raise e end

fun with_plan_position display_index kind label span f =
  let
    val old_failed_step_end = !failed_step_end_ref
    val old_failed_step_span = !failed_step_span_ref
    val old_failed_plan_position = !failed_plan_position_ref
    val _ = failed_step_end_ref := SOME (#2 span)
    val _ = failed_step_span_ref := SOME span
    val _ = failed_plan_position_ref := SOME (display_index, kind, label)
    fun restore () = (failed_step_end_ref := old_failed_step_end;
                      failed_step_span_ref := old_failed_step_span;
                      failed_plan_position_ref := old_failed_plan_position)
    val result = (f (); NONE) handle e => SOME e
    val _ = restore ()
  in
    case result of NONE => () | SOME e => raise e
  end

fun run_maybe_traced_step index display_index proof_step =
  let
    fun run () = step proof_step
    fun traced () =
      if trace_enabled () then
        let
          val _ = trace_before index proof_step
          val t0 = Time.now()
          val result = (step proof_step; NONE) handle e => SOME e
          val elapsed = seconds (t0, Time.now())
        in
          case result of
              NONE => trace_after "ok" elapsed index proof_step
            | SOME e => (trace_after "failed" elapsed index proof_step; raise e)
        end
      else run ()
  in
    with_plan_position display_index (HolbuildProofIr.step_kind proof_step) (HolbuildProofIr.step_label proof_step)
      (HolbuildProofIr.step_start proof_step, HolbuildProofIr.step_end proof_step) traced
  end

fun run_structural_steps display_index steps =
  let
    fun run_list _ _ _ [] = ()
      | run_list d path i (proof_step :: rest) =
          let val next = run_one d (path @ [HolbuildProofIr.PathStep i]) proof_step
          in run_list next path (i + 1) rest end
    and run_leaf d path proof_step =
      let val n = !successful_step_count_ref
          val old_path = !current_path_ref
          val _ = current_path_ref := path
          val result = (run_maybe_traced_step n d proof_step; NONE) handle e => SOME e
          val _ = current_path_ref := old_path
      in
        case result of
            SOME e => raise e
          | NONE =>
              (successful_step_count_ref := n + 1;
               successful_prefix_end_ref := HolbuildProofIr.step_end proof_step;
               successful_path_ref := path;
               d + HolbuildProofIr.display_line_count proof_step)
      end
    and run_select d path proof_step mode body =
      let
        val label = HolbuildProofIr.step_label proof_step
        val close_display = d + HolbuildProofIr.display_line_count proof_step - 1
        val _ = push_first_focus label
        val result = (run_list (d + 1) (path @ [HolbuildProofIr.PathSelect]) 0 body; NONE) handle e => SOME e
      in
        case result of
            SOME e => (pop_branch_tail_count label handle _ => (); raise e)
          | NONE =>
              (with_plan_position close_display "end" "end" (HolbuildProofIr.step_end proof_step, HolbuildProofIr.step_end proof_step)
                 (fn () => close_focus label mode);
               d + HolbuildProofIr.display_line_count proof_step)
      end
    and run_each d path proof_step body =
      let
        val count = focused_goal_count "each"
        fun loop iter 0 = ()
          | loop iter n =
              (push_first_focus "each";
               run_list (d + 1) (path @ [HolbuildProofIr.PathEach iter]) 0 body;
               with_plan_position (d + HolbuildProofIr.display_line_count proof_step - 1) "end" "end" (HolbuildProofIr.step_end proof_step, HolbuildProofIr.step_end proof_step)
                 (fn () => close_focus "each" HolbuildProofIr.SelectSolve);
               loop (iter + 1) (n - 1))
      in loop 0 count; d + HolbuildProofIr.display_line_count proof_step end
    and run_cases d path proof_step cases =
      let
        fun loop _ [] = ()
          | loop n (body :: rest) =
              let val label = "case " ^ Int.toString n
              in push_first_focus label;
                 run_list (d + 2) (path @ [HolbuildProofIr.PathCase n]) 0 body;
                 with_plan_position (d + HolbuildProofIr.display_line_count proof_step - 1) "end" "end" (HolbuildProofIr.step_end proof_step, HolbuildProofIr.step_end proof_step)
                   (fn () => close_focus label HolbuildProofIr.SelectSolve);
                 loop (n + 1) rest
              end
      in loop 1 cases; d + HolbuildProofIr.display_line_count proof_step end
    and run_choice d path proof_step label alternatives =
      let
        fun attempt _ [] last = (case last of SOME e => raise e | NONE => raise Fail ("choice has no alternatives: " ^ label))
          | attempt n (body :: rest) _ =
              let val saved = current_history()
                  val saved_path = !current_path_ref
                  val saved_success = !successful_path_ref
                  val saved_count = !successful_step_count_ref
                  val saved_end = !successful_prefix_end_ref
                  val saved_events = !dynamic_events_ref
                  val result = (with_expected_failures_suppressed (fn () => run_list (d + 2) (path @ [HolbuildProofIr.PathAlternative n]) 0 body); NONE) handle e => SOME e
              in
                case result of
                    NONE => dynamic_events_ref := HolbuildProofIr.ChoiceEvent (path, n) :: !dynamic_events_ref
                  | SOME e =>
                      (set_history saved;
                       current_path_ref := saved_path;
                       successful_path_ref := saved_success;
                       successful_step_count_ref := saved_count;
                       successful_prefix_end_ref := saved_end;
                       dynamic_events_ref := saved_events;
                       attempt (n + 1) rest (SOME e))
              end
      in attempt 1 alternatives NONE; d + HolbuildProofIr.display_line_count proof_step end
    and run_try d path proof_step body =
      let val saved = current_history()
          val saved_path = !current_path_ref
          val saved_success = !successful_path_ref
          val saved_count = !successful_step_count_ref
          val saved_end = !successful_prefix_end_ref
          val saved_events = !dynamic_events_ref
          val result = (with_expected_failures_suppressed (fn () => run_list (d + 1) (path @ [HolbuildProofIr.PathTry]) 0 body); NONE) handle e => SOME e
      in (case result of
              NONE => dynamic_events_ref := HolbuildProofIr.TryEvent (path, true) :: !dynamic_events_ref
            | SOME _ =>
                (set_history saved;
                 current_path_ref := saved_path;
                 successful_path_ref := saved_success;
                 successful_step_count_ref := saved_count;
                 successful_prefix_end_ref := saved_end;
                 dynamic_events_ref := HolbuildProofIr.TryEvent (path, false) :: saved_events));
         d + HolbuildProofIr.display_line_count proof_step end
    and run_repeat d path proof_step body =
      let
        fun loop iter =
          if iter > 10000 then raise Fail "repeat proof step exceeded iteration guard"
          else let val before = current_goal_count()
                   val saved = current_history()
                   val saved_path = !current_path_ref
                   val saved_success = !successful_path_ref
                   val saved_count = !successful_step_count_ref
                   val saved_end = !successful_prefix_end_ref
                   val saved_events = !dynamic_events_ref
                   val result = (with_expected_failures_suppressed (fn () => run_list (d + 1) (path @ [HolbuildProofIr.PathRepeat iter]) 0 body); NONE) handle e => SOME e
                   val after = current_goal_count()
               in case result of
                      SOME _ =>
                        (set_history saved;
                         current_path_ref := saved_path;
                         successful_path_ref := saved_success;
                         successful_step_count_ref := saved_count;
                         successful_prefix_end_ref := saved_end;
                         dynamic_events_ref := HolbuildProofIr.RepeatStopEvent (path, iter) :: saved_events)
                    | NONE =>
                        if after = before then dynamic_events_ref := HolbuildProofIr.RepeatStopEvent (path, iter) :: !dynamic_events_ref
                        else (dynamic_events_ref := HolbuildProofIr.RepeatIterEvent (path, iter) :: !dynamic_events_ref; loop (iter + 1))
               end
      in loop 0; d + HolbuildProofIr.display_line_count proof_step end
    and run_one d path proof_step =
      case proof_step of
          HolbuildProofIr.StepTactic _ => run_leaf d path proof_step
        | HolbuildProofIr.StepList _ => run_leaf d path proof_step
        | HolbuildProofIr.StepSelect {mode, body, ...} => run_select d path proof_step mode body
        | HolbuildProofIr.StepEach {body, ...} => run_each d path proof_step body
        | HolbuildProofIr.StepCases {cases, ...} => run_cases d path proof_step cases
        | HolbuildProofIr.StepChoice {label, alternatives, ...} => run_choice d path proof_step label alternatives
        | HolbuildProofIr.StepTry {body, ...} => run_try d path proof_step body
        | HolbuildProofIr.StepRepeat {body, ...} => run_repeat d path proof_step body
  in run_list display_index [] 0 steps end

fun run_steps_from _ display_index steps = run_structural_steps display_index steps

fun drop_steps _ steps = steps

fun run_steps steps =
  (successful_step_count_ref := 0;
   successful_prefix_end_ref := 0;
   current_path_ref := [];
   successful_path_ref := [];
   dynamic_events_ref := [];
   suppress_expected_failure_diagnostics_ref := false;
   branch_tail_count_ref := [];
   reverse_group_lengths_ref := NONE;
   run_structural_steps 0 steps)

fun display_index_at_count _ _ = 0
datatype 'a traced_result = TraceOk of 'a | TraceError of exn

fun run_whole_tactic g label tac =
  with_tactic_timeout label (fn () => Tactical.TAC_PROOF(g, tac)) ()
  handle e => (init_history g 15; print_goal_state label; clear_history (); raise e)

fun backup_n 0 = ()
  | backup_n n = (set_history (History.undo (current_history())); backup_n (n - 1))

fun drop_all () = clear_history ()

fun atomic_prove label g tac =
  with_tactic_timeout label (fn () => Tactical.TAC_PROOF(g, tac)) ()
  handle e => (init_history g 15; report_step_failure label e)

fun with_theorem_trace name f =
  let
    val old_active = !trace_active_ref
    val old_plan_active = !plan_active_ref
    val old_name = !trace_current_theorem_ref
    val _ = plan_active_ref := (inspection_matches (!plan_theorem_ref) name orelse !trace_all_ref)
    val _ = trace_active_ref := !trace_all_ref
    val _ = trace_current_theorem_ref := name
    val result = TraceOk (f ()) handle e => TraceError e
    val _ = trace_active_ref := old_active
    val _ = plan_active_ref := old_plan_active
    val _ = trace_current_theorem_ref := old_name
  in
    case result of TraceOk value => value | TraceError e => raise e
  end

fun proof_ir_prove name end_path end_ok checkpoint_depth g original_tac tactic_text =
  let
    val _ = active_tactic_text_ref := tactic_text
    val plan = case !active_plan_ref of SOME p => p | NONE => raise Fail "internal error: proof-IR plan is not installed"
    val _ = trace_plan name plan
    val _ = stop_after_plan_if_requested ()
  in
    let
            val _ = init_history g (HolbuildProofIr.display_step_count plan + 1)
            val _ = run_steps plan
            val th = history_top_thm g
                     handle e => (ignore (print_finish_goal_state name); raise e)
            val _ = save_checkpoint "end_of_proof" false end_path end_ok checkpoint_depth
            val _ = drop_all()
          in th end
  end

fun common_prefix_size old_text new_text =
  let
    val old_n = size old_text
    val new_n = size new_text
    val limit = Int.min(old_n, new_n)
    fun loop i =
      if i >= limit then i
      else if String.sub(old_text, i) = String.sub(new_text, i) then loop (i + 1)
      else i
  in
    loop 0
  end

fun step_count_at_prefix common_bytes plan =
  let
    fun loop count [] = count
      | loop count (proof_step :: rest) =
          if HolbuildProofIr.step_end proof_step <= common_bytes then loop (count + 1) rest else count
  in
    loop 0 plan
  end

fun common_step_prefix old_signatures new_plan =
  let
    fun loop n [] _ = n
      | loop n _ [] = n
      | loop n (old :: old_rest) (new :: new_rest) =
          if old = HolbuildProofIr.step_signature new then loop (n + 1) old_rest new_rest else n
  in loop 0 old_signatures new_plan end

fun safe_failed_prefix_skip old_prefix_text old_step_count tactic_text failed_prefix_path plan =
  case read_failed_prefix_steps failed_prefix_path of
      SOME old_signatures => common_step_prefix (take_at_most old_step_count old_signatures) plan
    | NONE =>
        (* Compatibility with old checkpoints that lack step signatures: only
           trust the old byte-prefix heuristic when the saved prefix is still a
           literal prefix of the new tactic text. Otherwise restart from the
           theorem goal by rewinding the retained history to step 0. *)
        if String.isPrefix old_prefix_text tactic_text then
          step_count_at_prefix (size old_prefix_text) plan
        else 0

fun prefix_end_after_steps 0 _ = 0
  | prefix_end_after_steps _ [] = 0
  | prefix_end_after_steps n plan = HolbuildProofIr.step_end (List.last (take_at_most n plan))

fun finish_failed_prefix name old_prefix_text old_step_count tactic_text failed_prefix_path failed_prefix_ok =
  let
    val old_resume_active = !failed_prefix_resume_active_ref
    fun restore_resume_flag () = failed_prefix_resume_active_ref := old_resume_active
    val _ = failed_prefix_resume_active_ref := true
    val result =
      (restore_failed_prefix_checkpoint_info (name, tactic_text, failed_prefix_path, failed_prefix_ok);
       with_theorem_trace name (fn () =>
        let
          val _ = active_tactic_text_ref := tactic_text
          val plan = case !active_plan_ref of SOME p => p | NONE => raise Fail "internal error: proof-IR plan is not installed"
          val _ = ensure_history_limit (Int.max(HolbuildProofIr.display_step_count plan + 1, old_step_count + 1))
          val _ = trace_plan name plan
          val _ = stop_after_plan_if_requested ()
          val skip_count = safe_failed_prefix_skip old_prefix_text old_step_count tactic_text failed_prefix_path plan
          val backup_count = Int.max(0, old_step_count - skip_count)
          val _ =
            (backup_n backup_count
             handle History.CANT_BACKUP_ANYMORE =>
               raise Fail (String.concat ["failed-prefix checkpoint cannot rewind ",
                                          Int.toString backup_count,
                                          " proof IR steps; checkpoint history retained fewer steps than its metadata step_count=",
                                          Int.toString old_step_count]))
          val _ = successful_step_count_ref := skip_count
          val _ = successful_prefix_end_ref := prefix_end_after_steps skip_count plan
          val _ = run_steps_from skip_count (display_index_at_count skip_count plan) (drop_steps skip_count plan)
          val th = history_top_thm (project_history goalStack.initial_goal)
                   handle e => (ignore (print_finish_goal_state name); raise e)
          val _ = drop_all()
          val _ = theorem_info_ref := NONE
        in th end))
      handle e => (restore_resume_flag (); raise e)
    val _ = restore_resume_flag ()
  in
    result
  end

fun prove_outer_theorem (g, tac) (_, name, tactic_text, _, _, end_path, end_ok, _, _, has_attrs, checkpoint_depth) =
  let
    val atomic = has_attrs orelse tactic_text = ""
    val _ = proving_with_proof_ir_ref := true
    val th =
      with_theorem_trace name (fn () =>
        if atomic then atomic_prove name g tac
        else proof_ir_prove name end_path end_ok checkpoint_depth g tac tactic_text)
      handle e => (proving_with_proof_ir_ref := false; raise e)
    val _ = proving_with_proof_ir_ref := false
    val _ = theorem_info_ref := NONE
  in
    th
  end

fun proof_ir_prover (g, tac) =
  if !proving_with_proof_ir_ref then
    Tactical.TAC_PROOF(g, tac)
  else
    case !theorem_info_ref of
        NONE => Tactical.TAC_PROOF(g, tac)
      | SOME info =>
          prove_outer_theorem (g, tac) info
          handle e =>
            (proving_with_proof_ir_ref := false;
             theorem_info_ref := NONE;
             context_info_ref := NONE;
             drop_all();
             raise e)

fun install ({checkpoint_enabled, tactic_timeout, timeout_marker, plan_theorem, trace_all, plan_only_marker} : config) =
  (checkpoint_enabled_ref := checkpoint_enabled;
   tactic_timeout_ref := tactic_timeout;
   tactic_timeout_marker_ref := timeout_marker;
   plan_theorem_ref := plan_theorem;
   trace_all_ref := trace_all;
   plan_only_marker_ref := plan_only_marker;
   plan_active_ref := false;
   trace_active_ref := false;
   theorem_info_ref := NONE;
   context_info_ref := NONE;
   failed_step_end_ref := NONE;
   failed_step_span_ref := NONE;
   failed_plan_position_ref := NONE;
   failed_prefix_resume_active_ref := false;
   proving_with_proof_ir_ref := false;
   Tactical.set_prover proof_ir_prover)

end
