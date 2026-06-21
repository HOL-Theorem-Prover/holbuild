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
datatype structural_frame = EachFrame of HolbuildProofIr.proof_path * int * int | CaseFrame of HolbuildProofIr.proof_path * int * int

val current_path_ref = ref ([] : HolbuildProofIr.proof_path)
val successful_path_ref = ref ([] : HolbuildProofIr.proof_path)
val current_frames_ref = ref ([] : structural_frame list)
val successful_frames_ref = ref ([] : structural_frame list)
val resume_frames_ref = ref ([] : structural_frame list)
val successful_branch_tail_counts_ref = ref ([] : int list)
type leaf_snapshot = {count : int, prefix_end : int, path : HolbuildProofIr.proof_path,
                      focus : int list, frames : structural_frame list,
                      events : HolbuildProofIr.dynamic_event list,
                      sig_text : string * string}
val successful_leaf_snapshots_ref = ref ([] : leaf_snapshot list)
(* Frame stacks are stored innermost-first, matching current_frames_ref push/pop order.
   Dynamic events are accumulated newest-first internally; metadata stores them in
   chronological order and resume_events_ref consumes that chronological stream. *)
val dynamic_events_ref = ref ([] : HolbuildProofIr.dynamic_event list)
val resume_events_ref = ref ([] : HolbuildProofIr.dynamic_event list)
val failed_step_end_ref = ref NONE : int option ref
val failed_step_span_ref = ref NONE : (int * int) option ref
val failed_plan_position_ref = ref NONE : (int * string * string) option ref
val failed_goal_state_printed_ref = ref false
val suppress_expected_failure_diagnostics_ref = ref false
val compiled_tactic_ref = ref Tactical.ALL_TAC
val compiled_list_tactic_ref = ref Tactical.ALL_LT
val proof_history_ref = ref (NONE : goalStack.gstk History.history option)
val branch_tail_count_ref = ref ([] : int list)
val reverse_group_lengths_ref = ref (NONE : int list option)
val default_repeat_iteration_limit = 10000
val repeat_iteration_limit_ref = ref default_repeat_iteration_limit

fun env_bool name =
  case OS.Process.getEnv name of
      SOME "1" => SOME true
    | SOME "true" => SOME true
    | SOME "yes" => SOME true
    | SOME "0" => SOME false
    | SOME "false" => SOME false
    | SOME "no" => SOME false
    | _ => NONE

fun all_digits text =
  size text > 0 andalso List.all Char.isDigit (String.explode text)

fun strict_nonnegative_int text =
  if all_digits text then Int.fromString text else NONE

fun strict_positive_int text =
  case strict_nonnegative_int text of
      SOME n => if n > 0 then SOME n else NONE
    | NONE => NONE

fun env_positive_int name =
  case OS.Process.getEnv name of
      NONE => NONE
    | SOME value =>
        (case strict_positive_int value of
             SOME n => SOME n
           | NONE => raise Fail (name ^ " must be a positive integer"))

fun repeat_iteration_limit () =
  Option.getOpt(env_positive_int "HOLBUILD_PROOF_IR_REPEAT_LIMIT", !repeat_iteration_limit_ref)

fun repeat_iteration_guard_message limit =
  String.concat ["proof-ir repeat exceeded ", Int.toString limit,
                 " successful iterations; possible nonterminating rpt"]

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

fun int_list_text xs = String.concatWith "," (map Int.toString xs)

fun parse_int_list_text "" = SOME []
  | parse_int_list_text text =
      let
        fun loop [] acc = SOME (rev acc)
          | loop (part :: rest) acc =
              case strict_nonnegative_int part of
                  SOME n => loop rest (n :: acc)
                | NONE => NONE
      in loop (String.fields (fn c => c = #",") text) [] end

fun structural_frame_text frame =
  case frame of
      EachFrame (path, iter, remaining) => "each\t" ^ path_text path ^ "\t" ^ Int.toString iter ^ "\t" ^ Int.toString remaining
    | CaseFrame (path, n, remaining) => "case\t" ^ path_text path ^ "\t" ^ Int.toString n ^ "\t" ^ Int.toString remaining

fun parse_path_component text =
  case text of
      "select" => SOME HolbuildProofIr.PathSelect
    | "try" => SOME HolbuildProofIr.PathTry
    | _ =>
        (case String.fields (fn c => c = #":") text of
             ["step", n] => Option.map HolbuildProofIr.PathStep (strict_nonnegative_int n)
           | ["each", n] => Option.map HolbuildProofIr.PathEach (strict_nonnegative_int n)
           | ["case", n] => Option.map HolbuildProofIr.PathCase (strict_positive_int n)
           | ["alternative", n] => Option.map HolbuildProofIr.PathAlternative (strict_positive_int n)
           | ["repeat", n] => Option.map HolbuildProofIr.PathRepeat (strict_nonnegative_int n)
           | _ => NONE)

fun parse_path_text "" = SOME []
  | parse_path_text text =
      let
        fun loop [] acc = SOME (rev acc)
          | loop (part :: rest) acc =
              case parse_path_component part of
                  SOME component => loop rest (component :: acc)
                | NONE => NONE
      in loop (String.fields (fn c => c = #"/") text) [] end

fun parse_structural_frame_text text =
  case String.fields (fn c => c = #"\t") text of
      ["each", path_text', iter_text, remaining_text] =>
        (case (parse_path_text path_text', strict_nonnegative_int iter_text, strict_positive_int remaining_text) of
             (SOME path, SOME iter, SOME remaining) => SOME (EachFrame (path, iter, remaining))
           | _ => NONE)
    | ["case", path_text', n_text, remaining_text] =>
        (case (parse_path_text path_text', strict_positive_int n_text, strict_positive_int remaining_text) of
             (SOME path, SOME n, SOME remaining) => SOME (CaseFrame (path, n, remaining))
           | _ => NONE)
    | _ => NONE

fun parse_dynamic_event_text text =
  case String.fields (fn c => c = #"\t") text of
      ["choice", path_text', n_text] =>
        (case (parse_path_text path_text', strict_positive_int n_text) of
             (SOME path, SOME n) => SOME (HolbuildProofIr.ChoiceEvent (path, n))
           | _ => NONE)
    | ["try", path_text', taken_text] =>
        (case (parse_path_text path_text', taken_text) of
             (SOME path, "1") => SOME (HolbuildProofIr.TryEvent (path, true))
           | (SOME path, "0") => SOME (HolbuildProofIr.TryEvent (path, false))
           | _ => NONE)
    | ["repeat-iter", path_text', n_text] =>
        (case (parse_path_text path_text', strict_nonnegative_int n_text) of
             (SOME path, SOME n) => SOME (HolbuildProofIr.RepeatIterEvent (path, n))
           | _ => NONE)
    | ["repeat-stop", path_text', n_text] =>
        (case (parse_path_text path_text', strict_nonnegative_int n_text) of
             (SOME path, SOME n) => SOME (HolbuildProofIr.RepeatStopEvent (path, n))
           | _ => NONE)
    | _ => NONE

fun path_has_prefix prefix path =
  let
    fun loop [] _ = true
      | loop _ [] = false
      | loop (a :: rest_a) (b :: rest_b) = a = b andalso loop rest_a rest_b
  in loop prefix path end

fun path_display_index plan target_path =
  let
    exception Found of int
    fun run_list d path i [] = d
      | run_list d path i (proof_step :: rest) =
          let val step_path = path @ [HolbuildProofIr.PathStep i]
              val next = run_one d step_path proof_step
          in run_list next path (i + 1) rest end
    and run_one d path proof_step =
      (if path = target_path then raise Found d else ();
       case proof_step of
           HolbuildProofIr.StepTactic _ => d + HolbuildProofIr.display_line_count proof_step
         | HolbuildProofIr.StepList _ => d + HolbuildProofIr.display_line_count proof_step
         | HolbuildProofIr.StepSelect {body, ...} =>
             let val _ = run_list (d + 1) (path @ [HolbuildProofIr.PathSelect]) 0 body
             in d + HolbuildProofIr.display_line_count proof_step end
         | HolbuildProofIr.StepEach {body, ...} =>
             let
               val child_path =
                 if path_has_prefix path target_path then
                   case List.drop(target_path, length path) of
                       HolbuildProofIr.PathEach n :: _ => SOME (path @ [HolbuildProofIr.PathEach n])
                     | _ => NONE
                 else NONE
               val _ = case child_path of
                           SOME p => if path_has_prefix p target_path then ignore (run_list (d + 1) p 0 body) else ()
                         | NONE => ()
             in d + HolbuildProofIr.display_line_count proof_step end
         | HolbuildProofIr.StepCases {cases, ...} =>
             let fun loop _ _ [] = ()
                   | loop n j (body :: rest) =
                       let val next = run_list (j + 1) (path @ [HolbuildProofIr.PathCase n]) 0 body
                       in loop (n + 1) next rest end
                 val _ = loop 1 (d + 1) cases
             in d + HolbuildProofIr.display_line_count proof_step end
         | HolbuildProofIr.StepChoice {alternatives, ...} =>
             let fun loop _ _ [] = ()
                   | loop n j (body :: rest) =
                       let val next = run_list (j + 1) (path @ [HolbuildProofIr.PathAlternative n]) 0 body
                       in loop (n + 1) next rest end
                 val _ = loop 1 (d + 1) alternatives
             in d + HolbuildProofIr.display_line_count proof_step end
         | HolbuildProofIr.StepRepeat {body, ...} =>
             let
               val child_path =
                 if path_has_prefix path target_path then
                   case List.drop(target_path, length path) of
                       HolbuildProofIr.PathRepeat n :: _ => SOME (path @ [HolbuildProofIr.PathRepeat n])
                     | _ => NONE
                 else NONE
               val _ = case child_path of
                           SOME p => if path_has_prefix p target_path then ignore (run_list (d + 1) p 0 body) else ()
                         | NONE => ()
             in d + HolbuildProofIr.display_line_count proof_step end
         | HolbuildProofIr.StepTry {body, ...} =>
             let val _ = run_list (d + 1) (path @ [HolbuildProofIr.PathTry]) 0 body
             in d + HolbuildProofIr.display_line_count proof_step end)
  in (ignore (run_list 0 [] 0 plan); NONE) handle Found d => SOME d end

fun step_at_path plan target =
  let
    fun nth 0 (x :: _) = SOME x
      | nth n (_ :: rest) = if n > 0 then nth (n - 1) rest else NONE
      | nth _ [] = NONE
    fun find_steps steps [] = NONE
      | find_steps steps [HolbuildProofIr.PathStep i] = nth i steps
      | find_steps steps (HolbuildProofIr.PathStep i :: rest) =
          (case nth i steps of SOME step => find_in_step step rest | NONE => NONE)
      | find_steps _ _ = NONE
    and find_in_step step rest =
      case (step, rest) of
          (HolbuildProofIr.StepSelect {body, ...}, HolbuildProofIr.PathSelect :: more) => find_steps body more
        | (HolbuildProofIr.StepEach {body, ...}, HolbuildProofIr.PathEach _ :: more) => find_steps body more
        | (HolbuildProofIr.StepCases {cases, ...}, HolbuildProofIr.PathCase n :: more) =>
            if n > 0 then (case nth (n - 1) cases of SOME body => find_steps body more | NONE => NONE) else NONE
        | (HolbuildProofIr.StepChoice {alternatives, ...}, HolbuildProofIr.PathAlternative n :: more) =>
            if n > 0 then (case nth (n - 1) alternatives of SOME body => find_steps body more | NONE => NONE) else NONE
        | (HolbuildProofIr.StepTry {body, ...}, HolbuildProofIr.PathTry :: more) => find_steps body more
        | (HolbuildProofIr.StepRepeat {body, ...}, HolbuildProofIr.PathRepeat _ :: more) => find_steps body more
        | _ => NONE
  in find_steps plan target end

fun node_at_path plan target =
  case step_at_path plan target of
      SOME step => SOME step
    | NONE =>
        (case rev target of
             HolbuildProofIr.PathSelect :: rest => step_at_path plan (rev rest)
           | HolbuildProofIr.PathEach _ :: rest => step_at_path plan (rev rest)
           | HolbuildProofIr.PathCase _ :: rest => step_at_path plan (rev rest)
           | HolbuildProofIr.PathAlternative _ :: rest => step_at_path plan (rev rest)
           | HolbuildProofIr.PathTry :: rest => step_at_path plan (rev rest)
           | HolbuildProofIr.PathRepeat _ :: rest => step_at_path plan (rev rest)
           | _ => NONE)

fun step_signature_text step =
  HolbuildProofIr.step_kind step ^ "\t" ^ String.toString (HolbuildProofIr.step_program step)

fun encode_metadata_list xs = String.toString (String.concatWith "|" xs)
fun decode_metadata_list text =
  Option.map (fn decoded => if decoded = "" then [] else String.fields (fn c => c = #"|") decoded)
             (String.fromString text)

fun leaf_snapshot_text ({count, prefix_end, path, focus, frames, events, sig_text = (kind, program)} : leaf_snapshot) =
  String.concat [Int.toString count, "\t", Int.toString prefix_end, "\t",
                 path_text path, "\t", int_list_text focus, "\t",
                 encode_metadata_list (map structural_frame_text frames), "\t",
                 encode_metadata_list (map dynamic_event_text events), "\t",
                 kind, "\t", String.toString program]

fun parse_step_signature_text text =
  case String.fields (fn c => c = #"\t") text of
      kind :: rest => Option.map (fn program => (kind, program)) (String.fromString (String.concatWith "\t" rest))
    | [] => NONE

fun parse_leaf_snapshot_text text =
  case String.fields (fn c => c = #"\t") text of
      count_text :: end_text :: path_text' :: focus_text :: frames_text :: events_text :: kind :: rest =>
        (case (strict_positive_int count_text, strict_nonnegative_int end_text,
               parse_path_text path_text', parse_int_list_text focus_text,
               decode_metadata_list frames_text, decode_metadata_list events_text,
               String.fromString (String.concatWith "\t" rest)) of
             (SOME count, SOME prefix_end, SOME path, SOME focus, SOME frame_texts, SOME event_texts, SOME program) =>
               let
                 fun parse_frames [] acc = SOME (rev acc)
                   | parse_frames (frame_text :: more) acc =
                       (case parse_structural_frame_text frame_text of
                            SOME frame => parse_frames more (frame :: acc)
                          | NONE => NONE)
                 fun parse_events [] acc = SOME (rev acc)
                   | parse_events (event_text :: more) acc =
                       (case parse_dynamic_event_text event_text of
                            SOME event => parse_events more (event :: acc)
                          | NONE => NONE)
               in
                 case (parse_frames frame_texts [], parse_events event_texts []) of
                     (SOME frames, SOME events) =>
                       SOME ({count = count, prefix_end = prefix_end, path = path,
                              focus = focus, frames = frames, events = events,
                              sig_text = (kind, program)} : leaf_snapshot)
                   | _ => NONE
               end
           | _ => NONE)
    | count_text :: end_text :: path_text' :: focus_text :: kind :: rest =>
        (case (strict_positive_int count_text, strict_nonnegative_int end_text,
               parse_path_text path_text', parse_int_list_text focus_text,
               String.fromString (String.concatWith "\t" rest)) of
             (SOME count, SOME prefix_end, SOME path, SOME focus, SOME program) =>
               SOME ({count = count, prefix_end = prefix_end, path = path,
                      focus = focus, frames = [], events = [], sig_text = (kind, program)} : leaf_snapshot)
           | _ => NONE)
    | _ => NONE

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
            val step_count = !successful_step_count_ref
            val leaf_signature_lines =
              case (!active_plan_ref, step_count, !successful_path_ref) of
                  (SOME plan, n, path) =>
                    if n = 0 then []
                    else (case step_at_path plan path of
                              SOME step => ["leaf_signature=" ^ step_signature_text step ^ "\n"]
                            | NONE => [])
                | _ => []
            val meta_text =
              String.concat (["proof_ir_failed_prefix_version=3\n",
                              "step_count=", Int.toString step_count, "\n",
                              "prefix_end=", Int.toString prefix_end, "\n",
                              "path=", path_text (!successful_path_ref), "\n",
                              "focus=", int_list_text (!successful_branch_tail_counts_ref), "\n"] @
                             leaf_signature_lines @
                             map (fn snap => "leaf=" ^ leaf_snapshot_text snap ^ "\n") (rev (!successful_leaf_snapshots_ref)) @
                             map (fn frame => "frame=" ^ structural_frame_text frame ^ "\n") (!successful_frames_ref) @
                             map (fn event => "event=" ^ dynamic_event_text event ^ "\n") (rev (!dynamic_events_ref)))
            val _ =
              (case !proof_history_ref of
                   NONE => ()
                 | SOME history =>
                     proof_history_ref := SOME (History.set_limit history (Int.max(15, step_count + 1))))
            val _ = save_checkpoint "failed_prefix" false failed_prefix_path failed_prefix_ok depth
            val _ = write_text_file (failed_prefix_path ^ ".meta") meta_text
            val _ = write_text_file (failed_prefix_path ^ ".prefix") (String.substring(!active_tactic_text_ref, 0, prefix_end))
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
  (failed_goal_state_printed_ref := true;
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
                   all_goals_text goals]))

fun print_current_goal_state label =
  print_goal_state label (history_top_goals() handle _ => [])

fun print_finish_goal_state name =
  let
    val old_failed_step_end = !failed_step_end_ref
    val old_failed_step_span = !failed_step_span_ref
    val tactic_end = size (!active_tactic_text_ref)
    val has_specific_span = Option.isSome old_failed_step_span
    val _ = if has_specific_span then () else failed_step_end_ref := SOME tactic_end
    val _ = if has_specific_span then () else failed_step_span_ref := SOME (tactic_end, tactic_end)
    val label =
      if has_specific_span then
        (case !failed_plan_position_ref of
             SOME (_, _, plan_label) => plan_label
           | NONE => name ^ " finish")
      else name ^ " finish"
    val result = (print_current_goal_state label; true) handle e => (failed_step_end_ref := old_failed_step_end; failed_step_span_ref := old_failed_step_span; raise e)
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
        (let val goals = history_top_goals()
         in {goals = goals, total_count = length goals, generated_count = length goals, tail_count = 0} end
         handle e => if history_is_proved () then {goals = [], total_count = 0, generated_count = 0, tail_count = 0} else raise e)
    | tail_count :: _ =>
        (let
           val goals = history_top_goals()
           val total_count = length goals
           val generated_count = total_count - tail_count
         in
           if generated_count < 0 then raise Fail ("focus tail count exceeds open goals: " ^ label)
           else {goals = goals, total_count = total_count, generated_count = generated_count, tail_count = tail_count}
         end
         handle e => if tail_count = 0 andalso history_is_proved () then {goals = [], total_count = 0, generated_count = 0, tail_count = tail_count} else raise e)

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

fun selector_program HolbuildProofIr.SelectFirst = NONE
  | selector_program (HolbuildProofIr.SelectMatchingFirst pats) = SOME ("Q.RENAME_TAC " ^ pats)
  | selector_program (HolbuildProofIr.SelectMatchingAll pats) = SOME ("Q.RENAME_TAC " ^ pats)

fun matching_selector_count label selector goals =
  case selector_program selector of
      NONE => if null goals then NONE else SOME 1
    | SOME program =>
        let
          val tac = compile_tactic label program
          fun loop [] count = SOME count
            | loop (g :: rest) count =
                if Option.isSome (Lib.total tac g) then
                  (case selector of
                       HolbuildProofIr.SelectMatchingFirst _ => SOME 1
                     | HolbuildProofIr.SelectMatchingAll _ => loop rest (count + 1)
                     | _ => loop rest (count + 1))
                else loop rest count
        in
          case selector of
              HolbuildProofIr.SelectMatchingFirst _ =>
                if List.exists (fn g => Option.isSome (Lib.total tac g)) goals then SOME 1 else NONE
            | HolbuildProofIr.SelectMatchingAll _ => loop goals 0
            | _ => loop goals 0
        end

fun selector_list_tactic HolbuildProofIr.SelectFirst = NONE
  | selector_list_tactic (HolbuildProofIr.SelectMatchingFirst pats) = SOME ("Tactical.FIRST_LT (Q.RENAME_TAC " ^ pats ^ ")")
  | selector_list_tactic (HolbuildProofIr.SelectMatchingAll pats) = SOME ("Tactical.SELECT_LT (Q.RENAME_TAC " ^ pats ^ ")")

fun push_select_focus label selector =
  let
    val {goals, generated_count, tail_count, ...} = active_focus_snapshot label
    val focused_goals = take_goals generated_count goals
    val selected_count =
      case matching_selector_count label selector focused_goals of
          SOME n => n
        | NONE => raise Fail ("select with no matching focused goals: " ^ label)
    val _ =
      case selector_list_tactic selector of
          NONE => ()
        | SOME program =>
            apply_focus_list_tactic label (compile_list_tactic label program)
  in push_branch_tail_count (tail_count + generated_count - selected_count); selected_count end

fun push_first_focus label = push_select_focus label HolbuildProofIr.SelectFirst

fun focused_goal_count label = #generated_count (active_focus_snapshot label)

fun close_focus label HolbuildProofIr.SelectKeep = pop_branch_tail_count label
  | close_focus label HolbuildProofIr.SelectSolve =
      let val remaining = focused_goal_count label
      in
        if remaining = 0 then pop_branch_tail_count label
        else raise Fail "selected goals were not solved"
      end

fun reorder_focused_front_after label front_count middle_count =
  if front_count = 0 orelse middle_count = 0 then ()
  else
    let
      fun reorder goals =
        let
          val (front, rest) = Lib.split_after front_count goals
          val (middle, tail) = Lib.split_after middle_count rest
          fun validate thms =
            let
              val (middle_thms, rest_thms) = Lib.split_after middle_count thms
              val (front_thms, tail_thms) = Lib.split_after front_count rest_thms
            in front_thms @ middle_thms @ tail_thms end
        in (middle @ front @ tail, validate) end
    in apply_focus_list_tactic label reorder end

fun restore_focused_group_order label lengths =
  case List.filter (fn n => n <> 0) lengths of
      [] => ()
    | [_] => ()
    | nonzero_lengths =>
        let
          val reversed_lengths = rev nonzero_lengths
          fun reorder goals =
            let
              val (reversed_groups, tail) = split_by_lengths reversed_lengths goals
              val groups = rev reversed_groups
              fun validate thms =
                let
                  val (normal_groups, tail_thms) = split_by_lengths nonzero_lengths thms
                in List.concat (rev normal_groups) @ tail_thms end
            in (List.concat groups @ tail, validate) end
        in apply_focus_list_tactic label reorder end

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
  !trace_active_ref orelse Option.getOpt(env_bool "HOLBUILD_PROOF_STEPS_TRACE", false)

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

fun runtime_state_snapshot () =
  {history = current_history(),
   current_path = !current_path_ref,
   successful_path = !successful_path_ref,
   current_frames = !current_frames_ref,
   successful_frames = !successful_frames_ref,
   resume_frames = !resume_frames_ref,
   successful_branch_tail_counts = !successful_branch_tail_counts_ref,
   successful_count = !successful_step_count_ref,
   successful_end = !successful_prefix_end_ref,
   events = !dynamic_events_ref,
   resume_events = !resume_events_ref,
   branch_tail_counts = !branch_tail_count_ref,
   reverse_group_lengths = !reverse_group_lengths_ref}

fun restore_runtime_state {history, current_path, successful_path, current_frames,
                           successful_frames, resume_frames, successful_branch_tail_counts, successful_count,
                           successful_end, events, resume_events, branch_tail_counts,
                           reverse_group_lengths} =
  (set_history history;
   current_path_ref := current_path;
   successful_path_ref := successful_path;
   current_frames_ref := current_frames;
   successful_frames_ref := successful_frames;
   resume_frames_ref := resume_frames;
   successful_branch_tail_counts_ref := successful_branch_tail_counts;
   successful_step_count_ref := successful_count;
   successful_prefix_end_ref := successful_end;
   dynamic_events_ref := events;
   resume_events_ref := resume_events;
   branch_tail_count_ref := branch_tail_counts;
   reverse_group_lengths_ref := reverse_group_lengths)

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
  in
    case result of
        NONE => (restore (); ())
      | SOME e => raise e
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

fun run_structural_steps_with_resume resume_after_path display_index steps =
  let
    val resume_reached_ref = ref (not (Option.isSome resume_after_path))
    fun target_in_path path =
      case resume_after_path of
          NONE => false
        | SOME target => path_has_prefix path target
    fun before_resume_leaf path =
      case resume_after_path of
          NONE => false
        | SOME target => path = target
    fun resume_child_after path =
      case resume_after_path of
          SOME target => if path_has_prefix path target then SOME (List.drop(target, length path)) else NONE
        | NONE => NONE
    fun emit_event event = dynamic_events_ref := event :: !dynamic_events_ref
    fun replay_active () = not (!resume_reached_ref)
    fun require_replay_event expected =
      case !resume_events_ref of
          event :: rest =>
            if event = expected then resume_events_ref := rest
            else raise Fail (String.concat ["proof-ir dynamic replay mismatch: expected ",
                                            dynamic_event_text expected,
                                            ", found ", dynamic_event_text event])
        | [] =>
            raise Fail ("proof-ir dynamic replay mismatch: missing " ^ dynamic_event_text expected)
    fun event_path event =
      case event of
          HolbuildProofIr.ChoiceEvent (p, _) => p
        | HolbuildProofIr.TryEvent (p, _) => p
        | HolbuildProofIr.RepeatIterEvent (p, _) => p
        | HolbuildProofIr.RepeatStopEvent (p, _) => p
    fun replay_event_is_resume_ancestor event =
      case resume_after_path of
          SOME target => path_has_prefix (event_path event) target
        | NONE => false
    fun record_or_replay_event event =
      case !resume_events_ref of
          expected :: _ =>
            if expected = event then require_replay_event event
            else if replay_active() then require_replay_event event
            else (resume_events_ref := []; emit_event event)
        | [] => if replay_active() then require_replay_event event else emit_event event
    fun finish_resume_boundary () =
      (resume_reached_ref := true;
       resume_events_ref := List.filter replay_event_is_resume_ancestor (!resume_events_ref))
    fun push_structural_frame frame = current_frames_ref := frame :: !current_frames_ref
    fun pop_structural_frame expected label =
      case !current_frames_ref of
          frame :: rest =>
            if frame = expected then current_frames_ref := rest
            else raise Fail ("proof-ir structural frame mismatch while closing " ^ label)
        | [] => raise Fail ("proof-ir structural frame underflow while closing " ^ label)
    fun record_successful_leaf path proof_step =
      let
        val count = !successful_step_count_ref + 1
        val prefix_end = HolbuildProofIr.step_end proof_step
        val sig_text = (HolbuildProofIr.step_kind proof_step, HolbuildProofIr.step_program proof_step)
      in
        successful_step_count_ref := count;
        successful_prefix_end_ref := prefix_end;
        successful_path_ref := path;
        successful_frames_ref := !current_frames_ref;
        successful_branch_tail_counts_ref := !branch_tail_count_ref;
        successful_leaf_snapshots_ref := {count = count, prefix_end = prefix_end, path = path,
                                          focus = !branch_tail_count_ref,
                                          frames = !current_frames_ref,
                                          events = rev (!dynamic_events_ref),
                                          sig_text = sig_text} ::
                                         !successful_leaf_snapshots_ref
      end
    fun run_list _ _ _ [] = ()
      | run_list d path i (proof_step :: rest) =
          let val next = run_one d (path @ [HolbuildProofIr.PathStep i]) proof_step
          in run_list next path (i + 1) rest end
    and skip_or_enter_structural d path proof_step enter =
      if !resume_reached_ref then enter ()
      else if target_in_path path then enter ()
      else d + HolbuildProofIr.display_line_count proof_step
    and run_leaf d path proof_step =
      if not (!resume_reached_ref) then
        if before_resume_leaf path then (finish_resume_boundary(); d + HolbuildProofIr.display_line_count proof_step)
        else d + HolbuildProofIr.display_line_count proof_step
      else
        let val n = !successful_step_count_ref
            val old_path = !current_path_ref
            val _ = current_path_ref := path
            val result = (run_maybe_traced_step n d proof_step; NONE) handle e => SOME e
            val _ = current_path_ref := old_path
        in
          case result of
              SOME e => raise e
            | NONE =>
                (record_successful_leaf path proof_step;
                 d + HolbuildProofIr.display_line_count proof_step)
        end
    and run_select d path proof_step selector mode body =
      skip_or_enter_structural d path proof_step (fn () =>
        let
          val label = HolbuildProofIr.step_label proof_step
          val close_display = d + HolbuildProofIr.display_line_count proof_step - 1
          val entering_from_resume = not (!resume_reached_ref)
          val selected_count = if entering_from_resume then 1 else push_select_focus label selector
          val result = ((if selected_count = 0 then () else run_list (d + 1) (path @ [HolbuildProofIr.PathSelect]) 0 body); NONE) handle e => SOME e
        in
          case result of
              SOME e => ((if entering_from_resume then () else (pop_branch_tail_count label handle _ => ())); raise e)
            | NONE =>
                (with_plan_position close_display "end" (case mode of HolbuildProofIr.SelectSolve => ">- solved" | _ => "end")
                   (case mode of
                        HolbuildProofIr.SelectSolve => (HolbuildProofIr.step_start proof_step, HolbuildProofIr.step_end proof_step)
                      | _ => (HolbuildProofIr.step_end proof_step, HolbuildProofIr.step_end proof_step))
                   (fn () => close_focus label mode);
                 d + HolbuildProofIr.display_line_count proof_step)
        end)
    and run_each d path proof_step body =
      skip_or_enter_structural d path proof_step (fn () =>
      let
        fun resume_each_frame () =
          List.find (fn frame => case frame of EachFrame (p, _, _) => p = path | _ => false) (!resume_frames_ref)
        val count = focused_goal_count "each"
        val resume_frame = if !resume_reached_ref then NONE else resume_each_frame()
        fun run_one_each iter remaining =
          let
            val frame = EachFrame (path, iter, remaining)
            val entering_from_resume = not (!resume_reached_ref) andalso Option.isSome resume_frame andalso
                                       (case resume_frame of SOME (EachFrame (_, iter', r)) => iter' = iter andalso r = remaining | _ => false)
            val _ = if entering_from_resume then () else push_structural_frame frame
            val _ = if entering_from_resume then () else ignore (push_first_focus "each")
            val result = (run_list (d + 1) (path @ [HolbuildProofIr.PathEach iter]) 0 body; NONE) handle e => SOME e
          in
            case result of
                SOME e => ((if entering_from_resume then () else pop_structural_frame frame "each");
                           (if entering_from_resume then () else (pop_branch_tail_count "each" handle _ => ()));
                           raise e)
              | NONE =>
                  let val generated = focused_goal_count "each"
                  in if entering_from_resume then () else pop_structural_frame frame "each";
                     close_focus "each" HolbuildProofIr.SelectKeep;
                     reorder_focused_front_after "each" generated (remaining - 1);
                     generated
                  end
          end
        fun loop _ 0 acc = rev acc
          | loop iter remaining acc = loop (iter + 1) (remaining - 1) (run_one_each iter remaining :: acc)
      in (case resume_frame of
              SOME (EachFrame (_, iter, remaining)) => restore_focused_group_order "each" (loop iter remaining [])
            | _ => restore_focused_group_order "each" (loop 0 count []));
         d + HolbuildProofIr.display_line_count proof_step end)
    and run_cases d path proof_step cases =
      skip_or_enter_structural d path proof_step (fn () =>
      let
        fun resume_case_frame () =
          List.find (fn frame => case frame of CaseFrame (p, _, _) => p = path | _ => false) (!resume_frames_ref)
        val count = focused_goal_count "cases"
        val case_count = length cases
        val resume_frame = if !resume_reached_ref then NONE else resume_case_frame()
        val _ = if Option.isSome resume_frame orelse case_count = count then ()
                else raise Fail (String.concat ["case count mismatch: ", Int.toString case_count,
                                                " cases for ", Int.toString count, " focused goals"])
        fun run_one_case body_display n remaining body =
          let
            val label = "case " ^ Int.toString n
            val frame = CaseFrame (path, n, remaining)
            val entering_from_resume = not (!resume_reached_ref) andalso Option.isSome resume_frame andalso
                                       (case resume_frame of SOME (CaseFrame (_, n', r)) => n' = n andalso r = remaining | _ => false)
            val _ = if entering_from_resume then () else push_structural_frame frame
            val _ = if entering_from_resume then () else ignore (push_first_focus label)
            val result = (run_list body_display (path @ [HolbuildProofIr.PathCase n]) 0 body; NONE) handle e => SOME e
          in
            case result of
                SOME e => ((if entering_from_resume then () else pop_structural_frame frame label);
                           (if entering_from_resume then () else (pop_branch_tail_count label handle _ => ()));
                           raise e)
              | NONE =>
                  let val generated = focused_goal_count label
                  in if entering_from_resume then () else pop_structural_frame frame label;
                     close_focus label HolbuildProofIr.SelectKeep;
                     reorder_focused_front_after label generated (remaining - 1);
                     generated
                  end
          end
        fun drop_cases 1 xs = xs
          | drop_cases n (_ :: rest) = drop_cases (n - 1) rest
          | drop_cases _ [] = []
        fun case_line_index target =
          let fun loop _ j [] = j
                | loop n j (body :: rest) =
                    if n = target then j
                    else loop (n + 1) (j + 1 + HolbuildProofIr.display_line_count_list body) rest
          in loop 1 (d + 1) cases end
        fun loop _ _ _ [] acc = rev acc
          | loop n remaining case_line (body :: rest) acc =
              loop (n + 1) (remaining - 1) (case_line + 1 + HolbuildProofIr.display_line_count_list body) rest
                   (run_one_case (case_line + 1) n remaining body :: acc)
      in (case resume_frame of
              SOME (CaseFrame (_, n, remaining)) => restore_focused_group_order "cases" (loop n remaining (case_line_index n) (drop_cases n cases) [])
            | _ => restore_focused_group_order "cases" (loop 1 count (d + 1) cases []));
         d + HolbuildProofIr.display_line_count proof_step end)
    and run_choice d path proof_step label alternatives =
      skip_or_enter_structural d path proof_step (fn () =>
      let
        fun nth_body 1 (body :: _) = SOME body
          | nth_body n (_ :: rest) = nth_body (n - 1) rest
          | nth_body _ [] = NONE
        fun attempt _ _ [] last = (case last of SOME e => raise e | NONE => raise Fail ("choice has no alternatives: " ^ label))
          | attempt n alt_line (body :: rest) _ =
              let val saved = runtime_state_snapshot()
                  val result = (with_expected_failures_suppressed (fn () => run_list (alt_line + 1) (path @ [HolbuildProofIr.PathAlternative n]) 0 body); NONE) handle e => SOME e
              in
                case result of
                    NONE => record_or_replay_event (HolbuildProofIr.ChoiceEvent (path, n))
                  | SOME e =>
                      (restore_runtime_state saved;
                       attempt (n + 1) (alt_line + 1 + HolbuildProofIr.display_line_count_list body) rest (SOME e))
              end
      in
        if not (!resume_reached_ref) then
          (case resume_child_after path of
               SOME (HolbuildProofIr.PathAlternative n :: _) =>
                 (case nth_body n alternatives of
                      SOME body =>
                        let
                          fun alt_line_index target =
                            let fun loop _ j [] = j
                                  | loop i j (b :: rest) =
                                      if i = target then j
                                      else loop (i + 1) (j + 1 + HolbuildProofIr.display_line_count_list b) rest
                            in loop 1 (d + 1) alternatives end
                        in run_list (alt_line_index n + 1) (path @ [HolbuildProofIr.PathAlternative n]) 0 body;
                           record_or_replay_event (HolbuildProofIr.ChoiceEvent (path, n))
                        end
                    | NONE => raise Fail "failed-prefix choice alternative is not present in current proof-ir plan")
             | _ => attempt 1 (d + 1) alternatives NONE)
        else attempt 1 (d + 1) alternatives NONE;
        d + HolbuildProofIr.display_line_count proof_step
      end)
    and run_try d path proof_step body =
      skip_or_enter_structural d path proof_step (fn () =>
      let val saved = runtime_state_snapshot()
      in
        if not (!resume_reached_ref) andalso
           (case resume_child_after path of SOME (HolbuildProofIr.PathTry :: _) => true | _ => false) then
          (run_list (d + 1) (path @ [HolbuildProofIr.PathTry]) 0 body;
           record_or_replay_event (HolbuildProofIr.TryEvent (path, true)))
        else
          let val result = (with_expected_failures_suppressed (fn () => run_list (d + 1) (path @ [HolbuildProofIr.PathTry]) 0 body); NONE) handle e => SOME e
          in case result of
                 NONE => record_or_replay_event (HolbuildProofIr.TryEvent (path, true))
               | SOME _ =>
                   (restore_runtime_state saved;
                    record_or_replay_event (HolbuildProofIr.TryEvent (path, false)))
          end;
        d + HolbuildProofIr.display_line_count proof_step
      end)
    and run_repeat d path proof_step body =
      skip_or_enter_structural d path proof_step (fn () =>
      let
        val limit = repeat_iteration_limit()
        val span = (HolbuildProofIr.step_start proof_step, HolbuildProofIr.step_end proof_step)
        fun guard_failure () =
          with_plan_position d "repeat" (HolbuildProofIr.step_label proof_step) span
            (fn () => raise Fail (repeat_iteration_guard_message limit))
        fun loop iter =
          if iter >= limit then guard_failure()
          else let val saved = runtime_state_snapshot()
                   val result = (with_expected_failures_suppressed (fn () => run_list (d + 1) (path @ [HolbuildProofIr.PathRepeat iter]) 0 body); NONE) handle e => SOME e
               in case result of
                      SOME _ =>
                        (restore_runtime_state saved;
                         record_or_replay_event (HolbuildProofIr.RepeatStopEvent (path, iter)))
                    | NONE =>
                        (record_or_replay_event (HolbuildProofIr.RepeatIterEvent (path, iter));
                         loop (iter + 1))
               end
        fun resume_loop iter =
          if iter >= limit then guard_failure()
          else (run_list (d + 1) (path @ [HolbuildProofIr.PathRepeat iter]) 0 body;
                record_or_replay_event (HolbuildProofIr.RepeatIterEvent (path, iter));
                loop (iter + 1))
      in
        if not (!resume_reached_ref) then
          (case resume_child_after path of
               SOME (HolbuildProofIr.PathRepeat iter :: _) => resume_loop iter
             | _ => loop 0)
        else loop 0;
        d + HolbuildProofIr.display_line_count proof_step
      end)
    and run_one d path proof_step =
      case proof_step of
          HolbuildProofIr.StepTactic _ => run_leaf d path proof_step
        | HolbuildProofIr.StepList _ => run_leaf d path proof_step
        | HolbuildProofIr.StepSelect {selector, mode, body, ...} => run_select d path proof_step selector mode body
        | HolbuildProofIr.StepEach {body, ...} => run_each d path proof_step body
        | HolbuildProofIr.StepCases {cases, ...} => run_cases d path proof_step cases
        | HolbuildProofIr.StepChoice {label, alternatives, ...} => run_choice d path proof_step label alternatives
        | HolbuildProofIr.StepTry {body, ...} => run_try d path proof_step body
        | HolbuildProofIr.StepRepeat {body, ...} => run_repeat d path proof_step body
  in
    run_list display_index [] 0 steps;
    case resume_after_path of
        SOME _ => if !resume_reached_ref then () else raise Fail "failed-prefix proof path is not present in current proof-ir plan"
      | NONE => ()
  end

fun run_structural_steps display_index steps = run_structural_steps_with_resume NONE display_index steps

fun run_steps_from_path path display_index steps = run_structural_steps_with_resume (SOME path) display_index steps

fun run_steps steps =
  (successful_step_count_ref := 0;
   successful_prefix_end_ref := 0;
   current_path_ref := [];
   successful_path_ref := [];
   current_frames_ref := [];
   successful_frames_ref := [];
   resume_frames_ref := [];
   successful_branch_tail_counts_ref := [];
   successful_leaf_snapshots_ref := [];
   dynamic_events_ref := [];
   resume_events_ref := [];
   suppress_expected_failure_diagnostics_ref := false;
   branch_tail_count_ref := [];
   reverse_group_lengths_ref := NONE;
   run_structural_steps 0 steps)

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
                     handle e => (if !failed_goal_state_printed_ref then () else ignore (print_finish_goal_state name); raise e)
            val th = history_top_thm g
                     handle e => (ignore (print_finish_goal_state name); raise e)
            val _ = save_checkpoint "end_of_proof" false end_path end_ok checkpoint_depth
            val _ = drop_all()
          in th end
  end

fun metadata_value key lines =
  let val prefix = key ^ "="
  in case List.find (String.isPrefix prefix) lines of
         SOME line => SOME (String.extract(line, size prefix, NONE))
       | NONE => NONE
  end

fun parse_failed_prefix_metadata text =
  let val lines = String.tokens (fn c => c = #"\n") text
      val event_prefix = "event="
      val frame_prefix = "frame="
      val leaf_prefix = "leaf="
      val event_texts = List.mapPartial (fn line =>
        if String.isPrefix event_prefix line then SOME (String.extract(line, size event_prefix, NONE)) else NONE) lines
      val frame_texts = List.mapPartial (fn line =>
        if String.isPrefix frame_prefix line then SOME (String.extract(line, size frame_prefix, NONE)) else NONE) lines
      val leaf_texts = List.mapPartial (fn line =>
        if String.isPrefix leaf_prefix line then SOME (String.extract(line, size leaf_prefix, NONE)) else NONE) lines
      fun parse_events [] acc = SOME (rev acc)
        | parse_events (event_text :: rest) acc =
            case parse_dynamic_event_text event_text of
                SOME event => parse_events rest (event :: acc)
              | NONE => NONE
      fun parse_frames [] acc = SOME (rev acc)
        | parse_frames (frame_text :: rest) acc =
            case parse_structural_frame_text frame_text of
                SOME frame => parse_frames rest (frame :: acc)
              | NONE => NONE
      fun parse_leaf_snapshots [] acc = SOME (rev acc)
        | parse_leaf_snapshots (leaf_text :: rest) acc =
            case parse_leaf_snapshot_text leaf_text of
                SOME leaf => parse_leaf_snapshots rest (leaf :: acc)
              | NONE => NONE
  in
    case metadata_value "proof_ir_failed_prefix_version" lines of
        SOME version =>
          if version = "1" orelse version = "3" then
            (case (metadata_value "step_count" lines,
                   metadata_value "prefix_end" lines,
                   metadata_value "path" lines,
                   metadata_value "focus" lines,
                   parse_events event_texts [],
                   parse_frames frame_texts [],
                   parse_leaf_snapshots leaf_texts []) of
                 (SOME count_text, SOME end_text, SOME path_text', SOME focus_text, SOME events, SOME frames, SOME leaves) =>
                   (case (strict_nonnegative_int count_text, strict_nonnegative_int end_text, parse_path_text path_text', parse_int_list_text focus_text) of
                        (SOME step_count, SOME prefix_end, SOME path, SOME focus) =>
                          let
                            val leaf_signature =
                              case metadata_value "leaf_signature" lines of
                                  SOME text => parse_step_signature_text text
                                | NONE => NONE
                          in
                            if version = "3" andalso step_count > 0 andalso not (Option.isSome leaf_signature) then NONE
                            else SOME {step_count = step_count, prefix_end = prefix_end, path = path, focus = focus,
                                       leaf_signature = leaf_signature, events = events, frames = frames,
                                       leaves = if version = "3" then leaves else []}
                          end
                      | _ => NONE)
               | _ => NONE)
          else NONE
      | _ => NONE
  end

fun validate_failed_prefix_metadata plan (metadata : {step_count : int, prefix_end : int, path : HolbuildProofIr.proof_path,
                                               focus : int list, leaf_signature : (string * string) option,
                                               events : HolbuildProofIr.dynamic_event list,
                                               frames : structural_frame list,
                                               leaves : leaf_snapshot list}) =
  let
    val path = #path metadata
    val _ = if #step_count metadata >= 0 andalso #prefix_end metadata >= 0 then ()
            else raise Fail "invalid proof-ir failed-prefix metadata: negative step_count or prefix_end"
    val _ = if #step_count metadata <> 0 orelse
               (path = [] andalso #focus metadata = [] andalso #frames metadata = [] andalso #events metadata = []) then ()
            else raise Fail "invalid proof-ir failed-prefix metadata: nonempty zero-step state"
    val _ = if #step_count metadata = 0 andalso path = [] then ()
            else case path_display_index plan path of
                     SOME _ => ()
                   | NONE => raise Fail "failed-prefix proof path is not present in current proof-ir plan"
    val _ =
      if #step_count metadata = 0 then ()
      else
        case step_at_path plan path of
            SOME step =>
              let
                val _ = if HolbuildProofIr.step_end step = #prefix_end metadata then ()
                        else raise Fail "invalid proof-ir failed-prefix metadata: leaf source end changed"
                val current_signature = (HolbuildProofIr.step_kind step, HolbuildProofIr.step_program step)
              in
                case #leaf_signature metadata of
                    SOME saved_signature =>
                      if saved_signature = current_signature then ()
                      else raise Fail "invalid proof-ir failed-prefix metadata: leaf tactic changed"
                  | NONE => ()
              end
          | NONE => raise Fail "failed-prefix proof path is not present in current proof-ir plan"
    fun validate_focus [] = ()
      | validate_focus (n :: rest) =
          if n >= 0 then validate_focus rest
          else raise Fail "invalid proof-ir failed-prefix metadata: negative focus count"
    fun current_node_at_path target = node_at_path plan target
    fun frame_path_matches_path frame_path component_ok =
      path_has_prefix frame_path path andalso
      (case List.drop(path, length frame_path) of
           component :: _ => component_ok component
         | [] => false)
    fun validate_frame frame =
      case frame of
          EachFrame (frame_path, iter, remaining) =>
            if iter >= 0 andalso remaining > 0 andalso
               (case current_node_at_path frame_path of SOME (HolbuildProofIr.StepEach _) => true | _ => false) andalso
               frame_path_matches_path frame_path (fn HolbuildProofIr.PathEach n => n = iter | _ => false) then ()
            else raise Fail "invalid proof-ir failed-prefix metadata: stale each frame"
        | CaseFrame (frame_path, n, remaining) =>
            if n > 0 andalso remaining > 0 andalso
               (case current_node_at_path frame_path of SOME (HolbuildProofIr.StepCases _) => true | _ => false) andalso
               frame_path_matches_path frame_path (fn HolbuildProofIr.PathCase n' => n' = n | _ => false) then ()
            else raise Fail "invalid proof-ir failed-prefix metadata: stale case frame"
    fun validate_event event =
      case event of
          HolbuildProofIr.ChoiceEvent (event_path, n) =>
            if n > 0 andalso (case current_node_at_path event_path of SOME (HolbuildProofIr.StepChoice _) => true | _ => false) then ()
            else raise Fail "invalid proof-ir failed-prefix metadata: stale choice event"
        | HolbuildProofIr.TryEvent (event_path, _) =>
            if (case current_node_at_path event_path of SOME (HolbuildProofIr.StepTry _) => true | _ => false) then ()
            else raise Fail "invalid proof-ir failed-prefix metadata: stale try event"
        | HolbuildProofIr.RepeatIterEvent (event_path, n) =>
            if n >= 0 andalso (case current_node_at_path event_path of SOME (HolbuildProofIr.StepRepeat _) => true | _ => false) then ()
            else raise Fail "invalid proof-ir failed-prefix metadata: stale repeat event"
        | HolbuildProofIr.RepeatStopEvent (event_path, n) =>
            if n >= 0 andalso (case current_node_at_path event_path of SOME (HolbuildProofIr.StepRepeat _) => true | _ => false) then ()
            else raise Fail "invalid proof-ir failed-prefix metadata: stale repeat event"
    fun validate_frame_order [] = ()
      | validate_frame_order [_] = ()
      | validate_frame_order (inner :: outer :: rest) =
          let
            fun frame_path frame =
              case frame of EachFrame (p, _, _) => p | CaseFrame (p, _, _) => p
          in
            if path_has_prefix (frame_path outer) (frame_path inner) then validate_frame_order (outer :: rest)
            else raise Fail "invalid proof-ir failed-prefix metadata: inconsistent frame stack order"
          end
  in
    validate_focus (#focus metadata);
    List.app validate_frame (#frames metadata);
    validate_frame_order (#frames metadata);
    List.app validate_event (#events metadata)
  end

fun take_at_most 0 _ = []
  | take_at_most _ [] = []
  | take_at_most n (x :: xs) = if n > 0 then x :: take_at_most (n - 1) xs else []

fun salvage_failed_prefix_metadata plan metadata =
  let
    fun current_signature path =
      case step_at_path plan path of
          SOME step => SOME (HolbuildProofIr.step_kind step, HolbuildProofIr.step_program step,
                             HolbuildProofIr.step_end step)
        | NONE => NONE
    fun valid_leaf ({count, prefix_end, path, sig_text, ...} : leaf_snapshot) expected_count =
      count = expected_count andalso
      (case current_signature path of
           SOME (kind, program, current_end) => prefix_end = current_end andalso sig_text = (kind, program)
         | NONE => false)
    fun loop _ [] last = last
      | loop expected (leaf :: rest) last =
          if valid_leaf leaf expected then loop (expected + 1) rest (SOME leaf)
          else last
    val leaves = #leaves metadata
  in
    case loop 1 leaves NONE of
        NONE => {step_count = 0, prefix_end = 0, path = [], focus = [], leaf_signature = NONE,
                 events = [], frames = [], leaves = leaves}
      | SOME ({count, path, focus, frames, events, sig_text, ...} : leaf_snapshot) =>
          (case current_signature path of
               SOME (_, _, current_end) =>
                 {step_count = count, prefix_end = current_end, path = path, focus = focus,
                  leaf_signature = SOME sig_text, events = events, frames = frames, leaves = leaves}
             | NONE => {step_count = 0, prefix_end = 0, path = [], focus = [], leaf_signature = NONE,
                         events = [], frames = [], leaves = leaves})
  end

fun resumable_failed_prefix_metadata plan metadata =
  (validate_failed_prefix_metadata plan metadata; metadata)
  handle _ =>
    let
      val salvaged = salvage_failed_prefix_metadata plan metadata
    in
      validate_failed_prefix_metadata plan salvaged;
      salvaged
    end

fun finish_failed_prefix name metadata_text tactic_text failed_prefix_path failed_prefix_ok =
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
          val metadata =
            case parse_failed_prefix_metadata metadata_text of
                SOME m => m
              | NONE => raise Fail "invalid proof-ir failed-prefix metadata"
          val _ = ensure_history_limit (Int.max(HolbuildProofIr.display_step_count plan + 1, #step_count metadata + 1))
          val resume_metadata = resumable_failed_prefix_metadata plan metadata
          val backup_count = Int.max(0, #step_count metadata - #step_count resume_metadata)
          val _ =
            (backup_n backup_count
             handle History.CANT_BACKUP_ANYMORE =>
               raise Fail (String.concat ["failed-prefix checkpoint cannot rewind ",
                                          Int.toString backup_count,
                                          " proof IR steps; checkpoint history retained fewer steps than its metadata step_count=",
                                          Int.toString (#step_count metadata)]))
          val _ = trace_plan name plan
          val _ = stop_after_plan_if_requested ()
          val metadata = resume_metadata
          val resume_display =
            if #step_count metadata = 0 andalso #path metadata = [] then 0
            else case path_display_index plan (#path metadata) of
                     SOME d => d
                   | NONE => raise Fail "failed-prefix proof path is not present in current proof-ir plan"
          val _ = successful_step_count_ref := #step_count metadata
          val _ = successful_prefix_end_ref := #prefix_end metadata
          val _ = successful_path_ref := #path metadata
          val _ = successful_frames_ref := #frames metadata
          val _ = current_frames_ref := #frames metadata
          val _ = resume_frames_ref := #frames metadata
          val _ = successful_leaf_snapshots_ref := take_at_most (#step_count metadata) (#leaves metadata)
          val _ = branch_tail_count_ref := #focus metadata
          val _ = successful_branch_tail_counts_ref := #focus metadata
          val _ = dynamic_events_ref := rev (#events metadata)
          val _ = resume_events_ref := #events metadata
          val _ =
            if #step_count metadata = 0 then run_structural_steps 0 plan
            else run_steps_from_path (#path metadata) 0 plan
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
   failed_goal_state_printed_ref := false;
   failed_prefix_resume_active_ref := false;
   proving_with_proof_ir_ref := false;
   Tactical.set_prover proof_ir_prover)

end
