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
datatype proof_path_component =
    PathStep of int
  | PathEach of int
  | PathSelect
  | PathCase of int
  | PathAlternative of int
  | PathTry
  | PathRepeat of int

val current_proof_path_ref = ref ([] : proof_path_component list)
val successful_proof_path_ref = ref ([] : proof_path_component list)
val dynamic_event_log_ref = ref ([] : string list)
val successful_dynamic_event_log_ref = ref ([] : string list)
val successful_step_count_ref = ref 0
val successful_prefix_end_ref = ref 0
val failed_step_end_ref = ref NONE : int option ref
val failed_step_span_ref = ref NONE : (int * int) option ref
val failed_plan_position_ref = ref NONE : (int * string * string) option ref
val compiled_tactic_ref = ref Tactical.ALL_TAC
val compiled_list_tactic_ref = ref Tactical.ALL_LT
val proof_history_ref = ref (NONE : goalStack.gstk History.history option)
val trial_depth_ref = ref 0
datatype focus_frame_kind = SelectFrame of HolbuildProofIr.select_mode | EachFrame | CaseFrame
val focus_stack_ref = ref ([] : {prefix : int, suffix : int, kind : focus_frame_kind} list)

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

fun proof_path_component_text component =
  case component of
      PathStep n => "step:" ^ Int.toString n
    | PathEach n => "each:" ^ Int.toString n
    | PathSelect => "select"
    | PathCase n => "case:" ^ Int.toString n
    | PathAlternative n => "alternative:" ^ Int.toString n
    | PathTry => "try"
    | PathRepeat n => "repeat:" ^ Int.toString n

fun proof_path_text path = String.concatWith "/" (map proof_path_component_text path)

fun first_some _ [] = NONE
  | first_some f (x :: xs) =
      case f x of SOME y => SOME y | NONE => first_some f xs

fun dynamic_event_text events = String.concatWith "," (rev events)
fun record_dynamic_event text = dynamic_event_log_ref := text :: !dynamic_event_log_ref

fun dynamic_event_value path_text =
  let val prefix = path_text ^ "="
  in
    first_some (fn event =>
      if String.isPrefix prefix event then SOME (String.extract(event, size prefix, NONE)) else NONE)
      (rev (!dynamic_event_log_ref))
  end

fun int_after prefix text =
  if String.isPrefix prefix text then Int.fromString (String.extract(text, size prefix, NONE)) else NONE

fun has_dynamic_event text = List.exists (fn event => event = text) (!dynamic_event_log_ref)

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
                             "prefix_end=", Int.toString prefix_end, "\n",
                             "proof_path=", proof_path_text (!successful_proof_path_ref), "\n",
                             "dynamic_events=", dynamic_event_text (!successful_dynamic_event_log_ref), "\n"]
            val _ =
              (case !proof_history_ref of
                   NONE => ()
                 | SOME history =>
                     proof_history_ref := SOME (History.set_limit history (Int.max(15, step_count + 1))))
            val _ = save_checkpoint "failed_prefix" false failed_prefix_path failed_prefix_ok depth
            val _ = write_text_file (failed_prefix_path ^ ".meta") meta_text
            val _ = write_text_file (failed_prefix_path ^ ".prefix") prefix_text
            val plan = case !active_plan_ref of SOME p => p | NONE => raise Fail "internal error: proof-IR plan is not installed"
            val _ = save_failed_prefix_steps failed_prefix_path (HolbuildProofIr.flat_steps plan) step_count
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

fun failed_proof_path_line () =
  case !current_proof_path_ref of
      [] => ""
    | path => "\nholbuild proof path: " ^ proof_path_text path

fun current_history () =
  case !proof_history_ref of
      SOME history => history
    | NONE => raise Fail "proof IR goal history is not initialized"

fun install_repl_proof_state () =
  (proofManagerLib.add
     (Manager.PF (Manager.GOALSTACK (current_history()), Manager.id_tacm));
   ())

fun set_history history = proof_history_ref := SOME history

fun backup_n 0 = ()
  | backup_n n = (set_history (History.undo (current_history())); backup_n (n - 1))
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
                   failed_proof_path_line (),
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
  if !trial_depth_ref > 0 then raise e
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

fun no_open_goals () =
  ((history_top_goals (); false)
   handle _ => true)

fun allgoals_suffix_label label = String.isPrefix ">> " label

fun total_goals () = length (history_top_goals()) handle _ => 0

fun current_focus_bounds () =
  case !focus_stack_ref of
      [] => {prefix = 0, suffix = 0}
    | {prefix, suffix, ...} :: _ => {prefix = prefix, suffix = suffix}

fun current_focus_count () =
  let val {prefix, suffix} = current_focus_bounds()
  in Int.max(0, total_goals() - prefix - suffix) end

fun focus_goals () =
  let
    val goals = history_top_goals()
    val {prefix, suffix} = current_focus_bounds()
    val focus_n = Int.max(0, length goals - prefix - suffix)
    val (_, rest) = Lib.split_after prefix goals
    val (focus, _) = Lib.split_after focus_n rest
  in focus end

fun scoped_list_tactic ltac =
  let
    val {prefix, suffix} = current_focus_bounds()
    val focus_n = current_focus_count()
  in
    if prefix = 0 andalso suffix = 0 then ltac
    else Tactical.SPLIT_LT prefix (Tactical.ALL_LT, Tactical.SPLIT_LT focus_n (ltac, Tactical.ALL_LT))
  end

fun apply_focused_list_tactic label ltac =
  if current_focus_count() = 0 then ()
  else
    let val input_goals = focus_goals()
    in
      append_history_with_timeout label (goalStack.expand_listf (scoped_list_tactic ltac))
      handle e => report_step_failure_with_goals label input_goals e
    end

fun apply_list_tactic_step label program =
  if allgoals_suffix_label label andalso no_open_goals () then ()
  else
    let val list_tactic = compile_list_tactic label program
    in apply_focused_list_tactic label list_tactic end

fun apply_tactic_step label program =
  let val tactic = compile_tactic label program
  in apply_focused_list_tactic label (Tactical.ALLGOALS tactic) end

fun apply_select_begin label selector mode =
  let
    val {prefix, suffix} = current_focus_bounds()
    val focus_n = current_focus_count()
    val selected =
      case selector of
          HolbuildProofIr.SelectFirst => 1
        | HolbuildProofIr.SelectMatchingFirst _ => focus_n
        | HolbuildProofIr.SelectMatchingAll _ => focus_n
  in
    if focus_n <= 0 then raise Fail ("select with no open goals: " ^ label) else ();
    focus_stack_ref := {prefix = prefix, suffix = suffix + Int.max(0, focus_n - selected), kind = SelectFrame mode} :: !focus_stack_ref
  end

fun apply_structural_end label =
  case !focus_stack_ref of
      [] => raise Fail ("structural end without active frame: " ^ label)
    | {kind = SelectFrame HolbuildProofIr.SelectSolve, ...} :: rest =>
        if current_focus_count() = 0 then focus_stack_ref := rest
        else report_step_failure_with_goals label (focus_goals()) (Fail "selected goals were not solved")
    | _ :: rest => focus_stack_ref := rest

type exec_snapshot = {history : goalStack.gstk History.history,
                      focus_stack : {prefix : int, suffix : int, kind : focus_frame_kind} list,
                      successful_step_count : int,
                      successful_prefix_end : int,
                      failed_step_end : int option,
                      failed_step_span : (int * int) option,
                      failed_plan_position : (int * string * string) option,
                      current_proof_path : proof_path_component list,
                      successful_proof_path : proof_path_component list,
                      dynamic_event_log : string list,
                      successful_dynamic_event_log : string list}

fun exec_snapshot () =
  {history = current_history(),
   focus_stack = !focus_stack_ref,
   successful_step_count = !successful_step_count_ref,
   successful_prefix_end = !successful_prefix_end_ref,
   failed_step_end = !failed_step_end_ref,
   failed_step_span = !failed_step_span_ref,
   failed_plan_position = !failed_plan_position_ref,
   current_proof_path = !current_proof_path_ref,
   successful_proof_path = !successful_proof_path_ref,
   dynamic_event_log = !dynamic_event_log_ref,
   successful_dynamic_event_log = !successful_dynamic_event_log_ref}

fun restore_exec_snapshot ({history, focus_stack, successful_step_count,
                            successful_prefix_end, failed_step_end,
                            failed_step_span, failed_plan_position,
                            current_proof_path, successful_proof_path,
                            dynamic_event_log, successful_dynamic_event_log} : exec_snapshot) =
  (set_history history;
   focus_stack_ref := focus_stack;
   successful_step_count_ref := successful_step_count;
   successful_prefix_end_ref := successful_prefix_end;
   failed_step_end_ref := failed_step_end;
   failed_step_span_ref := failed_step_span;
   failed_plan_position_ref := failed_plan_position;
   current_proof_path_ref := current_proof_path;
   successful_proof_path_ref := successful_proof_path;
   dynamic_event_log_ref := dynamic_event_log;
   successful_dynamic_event_log_ref := successful_dynamic_event_log)

fun goal_fingerprint () =
  let val goals = history_top_goals()
  in String.concatWith "\n---goal---\n" (map goal_text goals) end
  handle _ => "<closed>"

fun trial f =
  let val old = !trial_depth_ref
      val _ = trial_depth_ref := old + 1
      val result = (f (); NONE) handle e => SOME e
      val _ = trial_depth_ref := old
  in case result of NONE => () | SOME e => raise e end

fun step proof_step =
  case proof_step of
      HolbuildProofIr.StepTactic {label, program, ...} => apply_tactic_step label program
    | HolbuildProofIr.StepList {label, program, ...} => apply_list_tactic_step label program
    | HolbuildProofIr.StepEach _ => raise Fail "each is handled by the structural proof-IR interpreter"
    | HolbuildProofIr.StepSelect _ => raise Fail "select is handled by the structural proof-IR interpreter"
    | HolbuildProofIr.StepCases _ => raise Fail "cases is handled by the structural proof-IR interpreter"
    | HolbuildProofIr.StepChoice _ => raise Fail "choice is handled by the structural proof-IR interpreter"
    | HolbuildProofIr.StepRepeat _ => raise Fail "repeat is handled by the structural proof-IR interpreter"
    | HolbuildProofIr.StepTry _ => raise Fail "try is handled by the structural proof-IR interpreter"

fun inspection_matches wanted name =
  case wanted of NONE => false | SOME selected => selected = name

fun trace_enabled () =
  !trace_active_ref orelse Option.getOpt(env_bool "HOLBUILD_PROOF_TRACE", false)

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

fun run_steps_from_at_path _ _ _ [] = ()
  | run_steps_from_at_path path index display_index (proof_step :: rest) =
      let val step_path = path @ [PathStep index]
          fun mark_structural_success () =
            (successful_proof_path_ref := step_path;
             successful_dynamic_event_log_ref := !dynamic_event_log_ref)
          val _ = current_proof_path_ref := step_path
      in
      (case proof_step of
           HolbuildProofIr.StepEach {body, ...} =>
             let
               val consumed = HolbuildProofIr.display_line_count proof_step
               val parent = current_focus_bounds()
               val original_n = current_focus_count()
               fun iter j acc =
                 if j >= original_n then ()
                 else
                   let
                     val remaining = original_n - j - 1
                     val frame = {prefix = #prefix parent + acc, suffix = #suffix parent + remaining, kind = EachFrame}
                     val _ = focus_stack_ref := frame :: !focus_stack_ref
                     val _ = run_steps_from_at_path (step_path @ [PathEach (j + 1)]) (index + 1) (display_index + 1) body
                     val gen = current_focus_count()
                     val _ = (case !focus_stack_ref of _ :: rest => focus_stack_ref := rest | [] => raise Fail "each frame underflow")
                   in iter (j + 1) (acc + gen) end
               val saved = exec_snapshot ()
               val result = (iter 0 0; NONE) handle e => SOME e
               val _ = case result of NONE => () | SOME e => (restore_exec_snapshot saved; raise e)
             in
               successful_prefix_end_ref := HolbuildProofIr.step_end proof_step;
               mark_structural_success ();
               run_steps_from_at_path path (index + 1) (display_index + consumed) rest
             end
         | HolbuildProofIr.StepSelect {selector, mode, body, ...} =>
             let
               val consumed = HolbuildProofIr.display_line_count proof_step
               val saved = exec_snapshot ()
               val _ = apply_select_begin (HolbuildProofIr.step_label proof_step) selector mode
               val body_result = (run_steps_from_at_path (step_path @ [PathSelect]) (index + 1) (display_index + 1) body; NONE) handle e => SOME e
               val _ = case body_result of NONE => () | SOME e => (restore_exec_snapshot saved; raise e)
               val old_failed_step_end = !failed_step_end_ref
               val old_failed_step_span = !failed_step_span_ref
               val old_failed_plan_position = !failed_plan_position_ref
               val _ = failed_step_end_ref := SOME (HolbuildProofIr.step_end proof_step)
               val _ = failed_step_span_ref := SOME (HolbuildProofIr.step_start proof_step, HolbuildProofIr.step_end proof_step)
               val _ = failed_plan_position_ref := SOME (display_index + consumed - 1, "end", "end")
               val result = (apply_structural_end "end"; NONE) handle e => SOME e
               val _ = (failed_step_end_ref := old_failed_step_end;
                        failed_step_span_ref := old_failed_step_span;
                        failed_plan_position_ref := old_failed_plan_position)
               val _ = case result of NONE => () | SOME e => (restore_exec_snapshot saved; raise e)
             in
               successful_prefix_end_ref := HolbuildProofIr.step_end proof_step;
               mark_structural_success ();
               run_steps_from_at_path path (index + 1) (display_index + consumed) rest
             end
         | HolbuildProofIr.StepCases {cases = bodies, ...} =>
             let
               val consumed = HolbuildProofIr.display_line_count proof_step
               val parent = current_focus_bounds()
               val original_n = current_focus_count()
               val _ = if length bodies = original_n then () else raise Fail "cases length mismatch"
               fun display_offset upto =
                 2 + upto + List.foldl (fn (body, n) => n + HolbuildProofIr.display_step_count body) 0 (List.take(bodies, upto))
               fun iter _ _ [] = ()
                 | iter j acc (case_body :: more) =
                   let
                     val remaining = original_n - j - 1
                     val frame = {prefix = #prefix parent + acc, suffix = #suffix parent + remaining, kind = CaseFrame}
                     val _ = focus_stack_ref := frame :: !focus_stack_ref
                     val _ = run_steps_from_at_path (step_path @ [PathCase (j + 1)]) (index + 1) (display_index + display_offset j) case_body
                     val gen = current_focus_count()
                     val _ = (case !focus_stack_ref of _ :: rest => focus_stack_ref := rest | [] => raise Fail "case frame underflow")
                   in iter (j + 1) (acc + gen) more end
               val saved = exec_snapshot ()
               val result = (iter 0 0 bodies; NONE) handle e => SOME e
               val _ = case result of NONE => () | SOME e => (restore_exec_snapshot saved; raise e)
             in
               successful_prefix_end_ref := HolbuildProofIr.step_end proof_step;
               mark_structural_success ();
               run_steps_from_at_path path (index + 1) (display_index + consumed) rest
             end
         | HolbuildProofIr.StepChoice {alternatives, ...} =>
             let
               val consumed = HolbuildProofIr.display_line_count proof_step
               val saved = exec_snapshot ()
               fun try_alts _ _ [] last =
                     (restore_exec_snapshot saved;
                      raise (case last of SOME e => e | NONE => Fail "choice has no alternatives"))
                 | try_alts alt_index offset (alt :: alts) last =
                     ((trial (fn () => run_steps_from_at_path (step_path @ [PathAlternative alt_index]) (index + 1) (display_index + offset) alt);
                       record_dynamic_event (proof_path_text step_path ^ "=alternative:" ^ Int.toString alt_index);
                       true)
                      handle e =>
                        (restore_exec_snapshot saved;
                         try_alts (alt_index + 1) (offset + 1 + HolbuildProofIr.display_step_count alt) alts (SOME e)))
               fun nth_alt wanted alt_index offset [] = raise Fail "recorded choice alternative is out of range"
                 | nth_alt wanted alt_index offset (alt :: alts) =
                     if wanted = alt_index then
                       trial (fn () => run_steps_from_at_path (step_path @ [PathAlternative alt_index]) (index + 1) (display_index + offset) alt)
                     else nth_alt wanted (alt_index + 1) (offset + 1 + HolbuildProofIr.display_step_count alt) alts
               val event = dynamic_event_value (proof_path_text step_path)
               val _ =
                 case Option.mapPartial (int_after "alternative:") event of
                     SOME alt_index => nth_alt alt_index 1 2 alternatives
                   | NONE => try_alts 1 2 alternatives NONE
             in
               successful_prefix_end_ref := HolbuildProofIr.step_end proof_step;
               mark_structural_success ();
               run_steps_from_at_path path (index + 1) (display_index + consumed) rest
             end
         | HolbuildProofIr.StepTry {body, ...} =>
             let
               val consumed = HolbuildProofIr.display_line_count proof_step
               val saved = exec_snapshot ()
               val event = dynamic_event_value (proof_path_text step_path)
               val _ =
                 case event of
                     SOME "try:skip" => ()
                   | SOME "try:body" => run_steps_from_at_path (step_path @ [PathTry]) (index + 1) (display_index + 1) body
                   | _ =>
                       ((trial (fn () => run_steps_from_at_path (step_path @ [PathTry]) (index + 1) (display_index + 1) body);
                         record_dynamic_event (proof_path_text step_path ^ "=try:body"))
                        handle _ => (restore_exec_snapshot saved;
                                     record_dynamic_event (proof_path_text step_path ^ "=try:skip")))
             in
               successful_prefix_end_ref := HolbuildProofIr.step_end proof_step;
               mark_structural_success ();
               run_steps_from_at_path path (index + 1) (display_index + consumed) rest
             end
         | HolbuildProofIr.StepRepeat {body, ...} =>
             let
               val consumed = HolbuildProofIr.display_line_count proof_step
               fun loop iteration =
                 let
                   val saved = exec_snapshot ()
                   val before = goal_fingerprint ()
                 in
                   (trial (fn () => run_steps_from_at_path (step_path @ [PathRepeat iteration]) (index + 1) (display_index + 1) body);
                    if goal_fingerprint () = before then record_dynamic_event (proof_path_text step_path ^ "=repeat:stop:" ^ Int.toString iteration)
                    else (record_dynamic_event (proof_path_text step_path ^ "=repeat:iter:" ^ Int.toString iteration);
                          loop (iteration + 1)))
                   handle _ => restore_exec_snapshot saved
                 end
               fun replay iteration =
                 let
                   val path_text = proof_path_text step_path
                   val iter_event = path_text ^ "=repeat:iter:" ^ Int.toString iteration
                   val stop_event = path_text ^ "=repeat:stop:" ^ Int.toString iteration
                 in
                   if has_dynamic_event stop_event then ()
                   else if has_dynamic_event iter_event then
                     (run_steps_from_at_path (step_path @ [PathRepeat iteration]) (index + 1) (display_index + 1) body;
                      replay (iteration + 1))
                   else loop iteration
                 end
               val _ = replay 1
             in
               successful_prefix_end_ref := HolbuildProofIr.step_end proof_step;
               mark_structural_success ();
               run_steps_from_at_path path (index + 1) (display_index + consumed) rest
             end
         | _ =>
             (current_proof_path_ref := step_path;
              run_maybe_traced_step index display_index proof_step;
              successful_step_count_ref := !successful_step_count_ref + 1;
              successful_prefix_end_ref := HolbuildProofIr.step_end proof_step;
              successful_proof_path_ref := step_path;
              successful_dynamic_event_log_ref := !dynamic_event_log_ref;
              run_steps_from_at_path path (index + 1)
                                (display_index + HolbuildProofIr.display_line_count proof_step)
                                rest))

      end

fun run_steps_from index display_index steps = run_steps_from_at_path [] index display_index steps

fun drop_steps 0 steps = steps
  | drop_steps _ [] = []
  | drop_steps n (_ :: rest) = drop_steps (n - 1) rest

fun run_steps steps =
  (successful_step_count_ref := 0;
   successful_prefix_end_ref := 0;
   current_proof_path_ref := [];
   successful_proof_path_ref := [];
   dynamic_event_log_ref := [];
   successful_dynamic_event_log_ref := [];
   focus_stack_ref := [];
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

fun balanced_structural_prefix_count wanted plan =
  let
    fun loop _ count [] = count
      | loop used count (step :: rest) =
          let val step_flat = length (HolbuildProofIr.flat_steps [step])
          in
            if used + step_flat <= wanted then loop (used + step_flat) (count + 1) rest
            else count
          end
  in loop 0 0 plan end

fun safe_failed_prefix_skip old_prefix_text old_step_count tactic_text failed_prefix_path plan =
  let
    val raw_skip =
      case read_failed_prefix_steps failed_prefix_path of
          SOME old_signatures => balanced_structural_prefix_count (common_step_prefix (take_at_most old_step_count old_signatures) (HolbuildProofIr.flat_steps plan)) plan
        | NONE =>
            (* Compatibility with old checkpoints that lack step signatures: only
               trust the old byte-prefix heuristic when the saved prefix is still a
               literal prefix of the new tactic text. Otherwise restart from the
               theorem goal by rewinding the retained history to step 0. *)
            if String.isPrefix old_prefix_text tactic_text then
              step_count_at_prefix (size old_prefix_text) plan
            else 0
  in
    balanced_structural_prefix_count raw_skip plan
  end

fun prefix_end_after_steps 0 _ = 0
  | prefix_end_after_steps _ [] = 0
  | prefix_end_after_steps n plan = HolbuildProofIr.step_end (List.last (take_at_most n plan))

fun finish_failed_prefix name old_prefix_text old_step_count old_proof_path old_dynamic_events tactic_text failed_prefix_path failed_prefix_ok =
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
          val _ = ensure_history_limit (Int.max(length plan + 1, old_step_count + 1))
          val _ = trace_plan name plan
          val _ = stop_after_plan_if_requested ()
          val skip_count =
            if old_proof_path = "" then safe_failed_prefix_skip old_prefix_text old_step_count tactic_text failed_prefix_path plan
            else 0
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
          val _ = current_proof_path_ref := []
          val _ = successful_proof_path_ref := []
          val _ = dynamic_event_log_ref := if old_dynamic_events = "" then [] else rev (String.fields (fn c => c = #",") old_dynamic_events)
          val _ = successful_dynamic_event_log_ref := !dynamic_event_log_ref
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
