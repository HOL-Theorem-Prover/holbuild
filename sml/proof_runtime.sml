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
val successful_step_count_ref = ref 0
val successful_prefix_end_ref = ref 0
val failed_step_end_ref = ref NONE : int option ref
val failed_step_span_ref = ref NONE : (int * int) option ref
val failed_plan_position_ref = ref NONE : (int * string * string) option ref
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

fun encode_step_signature proof_step =
  let val (kind, program) = HolbuildProofIr.step_signature proof_step
  in kind ^ "\t" ^ String.toString program ^ "\n" end

fun save_failed_prefix_steps path tactic_text step_count =
  let
    val plan = HolbuildProofIr.steps tactic_text
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
              String.concat ["step_count=", Int.toString step_count, "\n",
                             "prefix_end=", Int.toString prefix_end, "\n"]
            val _ =
              (case !proof_history_ref of
                   NONE => ()
                 | SOME history =>
                     proof_history_ref := SOME (History.set_limit history (Int.max(15, step_count + 1))))
            val _ = save_checkpoint "failed_prefix" false failed_prefix_path failed_prefix_ok depth
            val _ = write_text_file (failed_prefix_path ^ ".meta") meta_text
            val _ = write_text_file (failed_prefix_path ^ ".prefix") prefix_text
            val _ = save_failed_prefix_steps failed_prefix_path (!active_tactic_text_ref) step_count
          in () end

fun restore_failed_prefix_checkpoint_info (name, tactic_text, failed_prefix_path, failed_prefix_ok) =
  let val depth = length (PolyML.SaveState.showHierarchy())
  in
    theorem_info_ref := SOME ("theorem", name, tactic_text, "", "", "", "",
                              failed_prefix_path, failed_prefix_ok, false, depth)
  end

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

fun append_history f =
  set_history (Lib.with_flag (goalStack.chatting, false)
                 (fn () => History.apply f (current_history())) ())
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

fun print_goal_state label goals =
  TextIO.output(TextIO.stdErr,
    String.concat ["\nholbuild goal state at failed fragment: ", label,
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

fun apply_tactic_step label program =
  let
    val input_goals = top_input_goals()
    val tactic = compile_tactic label program
  in
    with_tactic_timeout label (fn () => append_history (goalStack.expandf tactic)) ()
    handle e => report_step_failure_with_goals label input_goals e
  end

fun no_open_goals () =
  ((history_top_goals (); false)
   handle _ => true)

fun allgoals_suffix_label label = String.isPrefix ">> " label

fun apply_list_tactic_step label program =
  if allgoals_suffix_label label andalso no_open_goals () then ()
  else
    let
      val input_goals = history_top_goals()
      val list_tactic = compile_list_tactic label program
    in
      with_tactic_timeout label (fn () => append_history (goalStack.expand_listf list_tactic)) ()
      handle e => report_step_failure_with_goals label input_goals e
    end

fun gentle_then1 tac1 tac2 goal =
  let
    fun chop 0 front rest = (List.rev front, rest)
      | chop n front (x :: xs) = chop (n - 1) (x :: front) xs
      | chop _ _ [] = raise Fail "gentle_then1 validation underflow"
    val (subgoals, validation) = tac1 goal
  in
    case subgoals of
        [] => ([], validation)
      | head :: tail =>
          let val (head_goals, head_validation) = tac2 head
          in
            (head_goals @ tail,
             fn thms =>
               let val (head_thms, tail_thms) = chop (length head_goals) [] thms
               in validation (head_validation head_thms :: tail_thms) end)
          end
  end

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

fun apply_then1_step label false first_program second_program =
      let
        val input_goals = top_input_goals()
        val first_tactic = compile_tactic label first_program
        val second_tactic = compile_tactic label second_program
      in
        with_tactic_timeout label
          (fn () => append_history (goalStack.expandf (Tactical.THEN1(first_tactic, second_tactic)))) ()
        handle e => report_step_failure_with_goals label input_goals e
      end
  | apply_then1_step label true first_program second_program =
      if no_open_goals () then ()
      else
        let
          val input_goals = history_top_goals()
          val first_tactic = compile_tactic label first_program
          val second_tactic = compile_tactic label second_program
        in
          with_tactic_timeout label
            (fn () => append_history (goalStack.expand_listf (Tactical.ALLGOALS (Tactical.THEN1(first_tactic, second_tactic))))) ()
          handle e => report_step_failure_with_goals label input_goals e
        end

fun apply_gentle_then1_step label false first_program second_program =
      let
        val input_goals = top_input_goals()
        val first_tactic = compile_tactic label first_program
        val second_tactic = compile_tactic label second_program
      in
        with_tactic_timeout label
          (fn () => append_history (goalStack.expandf (gentle_then1 first_tactic second_tactic))) ()
        handle e => report_step_failure_with_goals label input_goals e
      end
  | apply_gentle_then1_step label true first_program second_program =
      if no_open_goals () then ()
      else
        let
          val input_goals = history_top_goals()
          val first_tactic = compile_tactic label first_program
          val second_tactic = compile_tactic label second_program
        in
          with_tactic_timeout label
            (fn () => append_history (goalStack.expand_listf (Tactical.ALLGOALS (gentle_then1 first_tactic second_tactic)))) ()
          handle e => report_step_failure_with_goals label input_goals e
        end

fun current_goal_total () = length (history_top_goals()) handle _ => 0

fun current_branch_tail_count label =
  case !branch_tail_count_ref of
      [] => raise Fail ("branch suffix without active branch: " ^ label)
    | tail_count :: _ => tail_count

fun history_is_proved () =
  ((project_history goalStack.extract_thm; true) handle _ => false)

fun branch_goal_snapshot label =
  let
    val tail_count = current_branch_tail_count label
    fun snapshot goals =
      let
        val total_count = length goals
        val generated_count = total_count - tail_count
      in
        if generated_count < 0 then
          raise Fail ("branch tail count exceeds open goals: " ^ label)
        else {goals = goals, total_count = total_count, generated_count = generated_count}
      end
  in
    snapshot (history_top_goals())
    handle e =>
      if tail_count = 0 andalso history_is_proved () then
        {goals = [], total_count = 0, generated_count = 0}
      else raise e
  end

fun push_branch_tail_count tail_count =
  branch_tail_count_ref := tail_count :: !branch_tail_count_ref

fun pop_branch_tail_count label =
  case !branch_tail_count_ref of
      [] => raise Fail ("branch close without active branch: " ^ label)
    | _ :: rest => branch_tail_count_ref := rest

fun apply_branch_start_step label program =
  let
    val goals = history_top_goals()
    val before_count = length goals
    val input_goals = take_goals 1 goals
    val tactic = compile_tactic label program
    val tail_count = before_count - 1
  in
    if before_count <= 0 then raise Fail ("branch start with no open goals: " ^ label) else ();
    (with_tactic_timeout label
       (fn () => append_history (goalStack.expand_listf (Tactical.NTH_GOAL tactic 1))) ();
     push_branch_tail_count tail_count)
    handle e => report_step_failure_with_goals label input_goals e
  end

fun apply_branch_suffix_list_tactic label list_tactic =
  let
    val {goals, total_count, generated_count} = branch_goal_snapshot label
    val input_goals = take_goals generated_count goals
    val scoped_list_tactic = Tactical.SPLIT_LT generated_count (list_tactic, Tactical.ALL_LT)
  in
    (if generated_count = 0 then
       (if total_count = 0 then () else append_history (goalStack.expand_listf Tactical.ALL_LT))
     else
       with_tactic_timeout label
         (fn () => append_history (goalStack.expand_listf scoped_list_tactic)) ())
    handle e => report_step_failure_with_goals label input_goals e
  end

fun apply_branch_suffix_step label program =
  let val tactic = compile_tactic label program
  in apply_branch_suffix_list_tactic label (Tactical.ALLGOALS tactic) end

fun apply_branch_list_suffix_step label program =
  let val list_tactic = compile_list_tactic label program
  in apply_branch_suffix_list_tactic label list_tactic end

fun apply_branch_close_step label =
  let
    val {goals, total_count, generated_count} = branch_goal_snapshot label
    val input_goals = take_goals generated_count goals
  in
    (if generated_count = 0 then
       (if total_count = 0 then () else append_history (goalStack.expand_listf Tactical.ALL_LT);
        pop_branch_tail_count label)
     else
       raise Fail "THEN1 first subgoal not solved by branch tactic")
    handle e => report_step_failure_with_goals label input_goals e
  end

fun apply_branch_step label program phase =
  case phase of
      HolbuildProofIr.BranchStart => apply_branch_start_step label program
    | HolbuildProofIr.BranchSuffix => apply_branch_suffix_step label program
    | HolbuildProofIr.BranchClose => apply_branch_close_step label

fun step proof_step =
  case proof_step of
      HolbuildProofIr.StepTactic {label, program, ...} => apply_tactic_step label program
    | HolbuildProofIr.StepList {label, program, ...} => apply_list_tactic_step label program
    | HolbuildProofIr.StepChoice {label, program, ...} => apply_tactic_step label program
    | HolbuildProofIr.StepListChoice {label, program, ...} => apply_list_tactic_step label program
    | HolbuildProofIr.StepThen1 {label, list_suffix, first_program, second_program, ...} =>
        apply_then1_step label list_suffix first_program second_program
    | HolbuildProofIr.StepGentleThen1 {label, list_suffix, first_program, second_program, ...} =>
        apply_gentle_then1_step label list_suffix first_program second_program
    | HolbuildProofIr.StepBranch {label, program, phase, ...} => apply_branch_step label program phase
    | HolbuildProofIr.StepBranchList {label, program, ...} => apply_branch_list_suffix_step label program
    | HolbuildProofIr.StepPlain _ => raise Fail "plain proof step must cover the whole theorem"

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

fun run_maybe_traced_step index display_index proof_step =
  let
    val old_failed_step_end = !failed_step_end_ref
    val old_failed_step_span = !failed_step_span_ref
    val old_failed_plan_position = !failed_plan_position_ref
    val _ = failed_step_end_ref := SOME (HolbuildProofIr.step_end proof_step)
    val _ = failed_step_span_ref := SOME (HolbuildProofIr.step_start proof_step,
                                          HolbuildProofIr.step_end proof_step)
    val _ = failed_plan_position_ref := SOME (display_index,
                                              HolbuildProofIr.step_kind proof_step,
                                              HolbuildProofIr.step_label proof_step)
    fun restore () = (failed_step_end_ref := old_failed_step_end;
                      failed_step_span_ref := old_failed_step_span;
                      failed_plan_position_ref := old_failed_plan_position)
  in
    if trace_enabled () then
      let
        val _ = trace_before index proof_step
        val t0 = Time.now()
        val result = (step proof_step; NONE) handle e => SOME e
        val elapsed = seconds (t0, Time.now())
      in
        case result of
            NONE => (trace_after "ok" elapsed index proof_step; restore ())
          | SOME e => (trace_after "failed" elapsed index proof_step; restore (); raise e)
      end
    else (step proof_step; restore ())
  end

fun run_steps_from_at _ _ [] = ()
  | run_steps_from_at index display_index (proof_step :: rest) =
      (successful_step_count_ref := index;
       run_maybe_traced_step index display_index proof_step;
       successful_step_count_ref := index + 1;
       successful_prefix_end_ref := HolbuildProofIr.step_end proof_step;
       run_steps_from_at (index + 1)
                         (display_index + HolbuildProofIr.display_line_count proof_step)
                         rest)

fun run_steps_from index display_index steps = run_steps_from_at index display_index steps

fun drop_steps 0 steps = steps
  | drop_steps _ [] = []
  | drop_steps n (_ :: rest) = drop_steps (n - 1) rest

fun run_steps steps =
  (successful_step_count_ref := 0;
   successful_prefix_end_ref := 0;
   branch_tail_count_ref := [];
   reverse_group_lengths_ref := NONE;
   run_steps_from 0 0 steps)

fun display_index_at_count count steps =
  let
    fun loop _ display_index [] = display_index
      | loop remaining display_index (proof_step :: rest) =
          if remaining <= 0 then display_index
          else loop (remaining - 1)
                    (display_index + HolbuildProofIr.display_line_count proof_step)
                    rest
  in
    loop count 0 steps
  end
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
    val plan = HolbuildProofIr.steps tactic_text
    val _ = trace_plan name plan
    val _ = stop_after_plan_if_requested ()
  in
    case plan of
        [plain_step as HolbuildProofIr.StepPlain {label, ...}] =>
          let
            val old_failed_step_span = !failed_step_span_ref
            val old_failed_plan_position = !failed_plan_position_ref
            val _ = failed_step_span_ref := SOME (HolbuildProofIr.step_start plain_step,
                                                  HolbuildProofIr.step_end plain_step)
            val _ = failed_plan_position_ref := SOME (0, HolbuildProofIr.step_kind plain_step, label)
            val result = TraceOk (atomic_prove label g original_tac)
                         handle e => TraceError e
            val _ = failed_step_span_ref := old_failed_step_span
            val _ = failed_plan_position_ref := old_failed_plan_position
          in
            case result of
                TraceError e => raise e
              | TraceOk th =>
                  let val _ = save_checkpoint "end_of_proof" false end_path end_ok checkpoint_depth
                  in th end
          end
      | _ =>
          let
            val _ = init_history g (length plan + 1)
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
          val plan = HolbuildProofIr.steps tactic_text
          val _ = ensure_history_limit (Int.max(length plan + 1, old_step_count + 1))
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
