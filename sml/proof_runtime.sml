structure HolbuildProofRuntime =
struct

(* context_checkpoints: save a context after each theorem (the build's
   targets do; other theories save only failed prefixes).
   share_failed_prefix: the process started from the toolchain's base state
   with no deps heap, so a failed prefix carries every ancestor and is
   compacted before it is saved. *)
type config = {checkpoint_enabled : bool,
               context_checkpoints : bool,
               share_failed_prefix : bool,
               checkpoint_seconds : real,
               tactic_timeout : real option,
               heavy_tactic_timeout : real option,
               timeout_marker : string option,
               plan_theorem : string option,
               trace_all : bool,
               plan_only_marker : string option}

val diagnostic_marker_ref = ref (NONE : string option)
val tainted_ref = ref false
val diagnostic_timer_ref = ref (NONE : Timer.real_timer option)
val diagnostic_failure_count_ref = ref 0
val secondary_goal_ref = ref (NONE : string option)
val diagnostic_seconds = 10.0
val diagnostic_failure_limit = 8

fun diagnostic_time_left () =
  Option.map (fn timer => diagnostic_seconds - Time.toReal (Timer.checkRealTimer timer))
             (!diagnostic_timer_ref)

fun check_diagnostic_deadline () =
  case diagnostic_time_left () of
      SOME seconds => if seconds <= 0.0 then OS.Process.exit OS.Process.failure else ()
    | NONE => ()

val _ = Theory.register_hook
  ("holbuild diagnostic continuation",
   fn TheoryDelta.ExportTheory _ =>
        if !tainted_ref then OS.Process.exit OS.Process.failure else ()
    | _ => ())

fun install_diagnostics before_declaration finish_script marker =
  (diagnostic_marker_ref := SOME marker;
   before_declaration := check_diagnostic_deadline;
   finish_script := (fn record_peak_rss =>
     if !tainted_ref then (record_peak_rss (); OS.Process.exit OS.Process.failure) else ()))

val checkpoint_enabled_ref = ref false
val context_checkpoints_ref = ref false
val share_failed_prefix_ref = ref false
val tactic_timeout_ref = ref (NONE : real option)
val heavy_tactic_timeout_ref = ref (NONE : real option)
val tactic_timeout_marker_ref = ref (NONE : string option)
val plan_theorem_ref = ref (NONE : string option)
val trace_all_ref = ref false
val plan_only_marker_ref = ref (NONE : string option)
val plan_active_ref = ref false
val trace_active_ref = ref false
val trace_current_theorem_ref = ref ""
val theorem_info_ref = ref NONE : (string * string * string * string * string * string * string * (string * string list) list * int) option ref
val context_info_ref = ref NONE : (string * string * int) option ref
val failed_prefix_resume_active_ref = ref false
(* While a failed-prefix resume runs, the step count of the prefix it restored,
   once known. *)
val failed_prefix_resumed_step_count_ref = ref (NONE : int option)
val proving_with_proof_ir_ref = ref false
(* The context handed to the installed prover for the proof being run: every
   step, selector probe and nested proof runs in it.  A failed-prefix
   checkpoint saves it with the rest of the heap, so a resumed prefix runs in
   the context the original proof was given. *)
val proof_context_ref = ref (NONE : HolbuildTacticCompat.proof_context option)
val proof_factories_ref = ref (NONE : HolbuildTacticCompat.proof_factories option)
val plan_runner_ref = ref (NONE : HolbuildTacticCompat.proof_runner option)
val proof_ir_tactic = HolbuildTacticCompat.intercept_proof plan_runner_ref
val active_tactic_text_ref = ref ""
val active_plan_ref = ref (NONE : HolbuildProofIr.step list option)
val successful_step_count_ref = ref 0
val successful_prefix_end_ref = ref 0
(* Each frame records the branch it is in, the branches left, and the number of
   subgoals each earlier branch left; a resume needs those to restore goal order. *)
datatype structural_frame = EachFrame of HolbuildProofIr.proof_path * int * int * int list
                          | CaseFrame of HolbuildProofIr.proof_path * int * int * int list

val current_path_ref = ref ([] : HolbuildProofIr.proof_path)
val successful_path_ref = ref ([] : HolbuildProofIr.proof_path)
val current_frames_ref = ref ([] : structural_frame list)
val successful_frames_ref = ref ([] : structural_frame list)
val resume_frames_ref = ref ([] : structural_frame list)
val successful_branch_tail_counts_ref = ref ([] : int list)
type leaf_snapshot = {count : int, prefix_end : int, path : HolbuildProofIr.proof_path,
                      focus : int list, frames : structural_frame list,
                      events : HolbuildProofIr.dynamic_event list,
                      sig_text : string * string, prefix_signature : string option,
                      history_count : int}
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
val suppressed_failure_diagnostic_ref = ref (NONE : (unit -> unit) option)
val compiled_tactic_ref = ref (fn () => Tactical.ALL_TAC)
val compiled_list_tactic_ref = ref (fn () => Tactical.ALL_LT)
val proof_history_ref = ref (NONE : goalStack.gstk History.history option)
val history_step_count_ref = ref 0
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

val strict_nonnegative_int = HolbuildDiagnosticLimits.strict_nonnegative_int

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

(* Where this process's proving time went, for exec-action's result: wall
   milliseconds per part, each excluding the parts timed inside it, and
   counts.  install resets them, since a failed-prefix heap carries the
   values of the process that saved it, and they are printed at exit as one
   "holbuild hol-phases" line.  A resumed script that goes on past the
   resumed theorem loads the runtime again, and that copy prints its own
   line; exec-action sums the lines.  Names are phase names of a result
   record: lowercase letters only. *)
val hol_phases_ref = ref ([] : (string * LargeInt.int) list)
val hol_phase_nested_ms_ref = ref (0 : LargeInt.int)

fun add_hol_phase name n =
  hol_phases_ref :=
    (case List.find (fn (m, _) => m = name) (!hol_phases_ref) of
         SOME (_, earlier) => (name, earlier + n) :: List.filter (fn (m, _) => m <> name) (!hol_phases_ref)
       | NONE => (name, n) :: !hol_phases_ref)

fun timed_hol_phase name f =
  let
    val outer_nested = !hol_phase_nested_ms_ref
    val _ = hol_phase_nested_ms_ref := 0
    val t0 = Time.now ()
    fun record () =
      (* The wall clock can step back: a part never takes less than 0 ms. *)
      let val elapsed = LargeInt.max (0, Time.toMilliseconds (Time.-(Time.now (), t0)))
      in
        add_hol_phase name (LargeInt.max (0, elapsed - !hol_phase_nested_ms_ref));
        hol_phase_nested_ms_ref := outer_nested + elapsed
      end
  in
    (f () before record ()) handle e => (record (); raise e)
  end

fun print_hol_phases () =
  HolbuildBoundedOutput.text (TextIO.stdErr,
    String.concat ("holbuild hol-phases" ::
                   map (fn (name, n) => " " ^ name ^ "=" ^ LargeInt.toString n) (rev (!hol_phases_ref))) ^ "\n")

fun write_timeout_marker label seconds =
  if !tainted_ref then ()
  else case !tactic_timeout_marker_ref of
      NONE => ()
    | SOME path =>
        let val out = TextIO.openOut path
        in HolbuildBoundedOutput.text (out, String.concat [label, "\t", Real.toString seconds, "\n"]);
           TextIO.closeOut out
        end

(* Minimal local string compiler used for proof-fragment compilation.  This is
   equivalent to the small quse_string helper holbuild previously loaded from
   HOL's src/AI/sml_inspection/smlExecute, without depending on that
   post-upto-hol source package at runtime. *)
fun quse_string s =
  let
    val stream = TextIO.openString (HOLSource.fromString {quietOpen = false, print = fn _ => ()} s)
    fun infn () = TextIO.input1 stream
  in
    (while not (TextIO.endOfStream stream) do PolyML.compiler (infn, []) ();
     TextIO.closeIn stream;
     true)
    handle Interrupt => (TextIO.closeIn stream; raise Interrupt)
         | _ => (TextIO.closeIn stream; false)
  end

exception FunctionTimeout
exception FunctionInterrupted

datatype 'a timeout_result = TimeoutResult of 'a | TimeoutException of exn

fun capture_timeout f x = TimeoutResult (f x)
  handle e => TimeoutException e

fun release_timeout (TimeoutResult y) = y
  | release_timeout (TimeoutException e) = raise e

val timeout_attrib_async =
  [Thread.InterruptState Thread.InterruptAsynchOnce,
   Thread.EnableBroadcastInterrupt true]

val timeout_attrib_sync =
  [Thread.InterruptState Thread.InterruptSynch,
   Thread.EnableBroadcastInterrupt true]

fun interruptkill worker =
  let
    open Thread
    val delay = Time.fromReal 0.01
    val _ = interrupt worker handle Thread _ => ()
    fun loop n =
      if not (isActive worker) then ()
      else if n > 0 then (OS.Process.sleep delay; loop (n - 1))
      else (Feedback.HOL_WARNING "HolbuildProofRuntime" "interruptkill" "thread killed";
            kill worker handle Thread _ => ())
  in
    loop 100
  end

(* Local timeout helper adapted from HOL's smlTimeout.  Keeping this here avoids
   making holbuild's theorem runtime depend on src/AI/sml_inspection being built
   into the shared HOL toolchain. *)
fun timeout seconds f x =
  let
    val m = Mutex.mutex ()
    val curattrib = Thread.getAttributes ()
    val _ = Thread.setAttributes timeout_attrib_sync
    val _ = Mutex.lock m
    val c = ConditionVar.conditionVar ()
    val resultref = ref NONE
    fun worker_fun () =
      (resultref := SOME (capture_timeout f x);
       Thread.setAttributes timeout_attrib_sync;
       Mutex.lock m; ConditionVar.signal c; Mutex.unlock m)
    val worker = Thread.fork (worker_fun, timeout_attrib_async)
    (* A broadcast Interrupt (heap exhausted) also reaches this waiter, whose
       wait reacquires m before raising.  Stop the worker and report the step
       as interrupted, like an Interrupt raised in the worker itself.
       Interrupts are deferred meanwhile so another broadcast can't cut
       interruptkill short. *)
    val completed = ConditionVar.waitUntil (c, m, Time.now () + Time.fromReal seconds)
      handle Interrupt =>
        (Mutex.unlock m;
         Thread.setAttributes [Thread.InterruptState Thread.InterruptDefer];
         interruptkill worker;
         Thread.setAttributes curattrib;
         raise FunctionInterrupted)
    val _ = Mutex.unlock m
    val _ = Thread.setAttributes curattrib
    val _ = if completed then () else interruptkill worker
    (* An Interrupt before the deadline didn't come from interruptkill. *)
    val result =
      if not completed then TimeoutException FunctionTimeout
      else case !resultref of
          NONE => TimeoutException FunctionTimeout
        | SOME (TimeoutException Interrupt) => TimeoutException FunctionInterrupted
        | SOME r => r
  in
    release_timeout result
  end

fun timeout_message label seconds =
  String.concat ["holbuild tactic timeout after ", Real.toString seconds, "s: ", label]

(* Raised when a proof step exceeds the tactic timeout.  It is not a tactic
   failure: TRY, ORELSE and structural repeat propagate it instead of taking
   their failure branch, so a step that only stopped because of the timeout
   fails the build. *)
exception TacticTimeout of string

(* Raised when the Poly/ML runtime interrupts a proof step before the tactic
   timeout: it interrupts a thread whose stack can't grow (a stack overflow,
   such as a runaway recursion) and, when the heap is exhausted, every thread.
   Combinators propagate it like TacticTimeout. *)
exception TacticInterrupted of string
exception TacticStaticError of string
exception InvalidFailedPrefix of string

fun display_label label =
  String.translate (fn #"\n" => "\\n" | #"\t" => "\\t" | c => String.str c) label

fun active_theorem_name () =
  case !theorem_info_ref of
      SOME (_, name, _, _, _, _, _, _, _) => SOME name
    | NONE => NONE

fun tactic_interrupted label =
  TacticInterrupted ("holbuild tactic interrupted by Poly/ML (stack overflow or out of memory): " ^ label)

(* A step that times out runs once more with half the budget, meant to let a
   cheap step that stalled pass while one that needs about the budget still
   fails.  Callers compute the step from unchanged proof state and commit it
   to the history only when it returns, so the first attempt leaves the proof
   history unchanged (side effects of the tactic itself remain).  A retry that
   passes is reported on stderr, which is the theory's build log; one that
   times out fails as the first attempt would have, with the full budget in
   the marker and the message. *)
fun retry_after_timeout label seconds first_attempt f x =
  let
    val gc = Timer.checkGCTime first_attempt
    val retry = Timer.startRealTimer ()
    val y = timeout (seconds / 2.0) f x
      handle FunctionTimeout =>
               (write_timeout_marker label seconds;
                raise TacticTimeout (timeout_message label seconds))
           | FunctionInterrupted => raise tactic_interrupted label
  in
    HolbuildBoundedOutput.text (TextIO.stdErr,
      String.concat ["holbuild tactic timeout retry passed: ", display_label label,
                     " (budget ", Real.toString seconds, "s; retry ",
                     fmt_ms (Time.toReal (Timer.checkRealTimer retry)), " ms wall; GC during first attempt ",
                     fmt_ms (Time.toReal gc), " ms)\n"]);
    y
  end

(* The time budget of a step: NONE (untimed) when the step names a public
   HolSmtLib tactic, whose solver run and proof replay can exceed any step
   budget; the heavy budget when it names a long-running proof-search tactic
   such as metis, whose proofs (e.g. those reconstructed from external
   provers) often need more than the default; the tactic timeout otherwise.
   Names match under any structure qualifier, so re-exports count. Lower
   quotations first so HOL constants and string literals cannot accidentally
   change the budget. *)
fun step_budget program =
  let
    val untimed_names = ["GENERIC_SMT_TAC", "CVC_ORACLE_TAC", "CVC_TAC", "YICES_TAC",
                         "Z3_ORACLE_TAC", "Z3_TAC", "cvco_tac", "cvc_tac", "z3_tac", "z3o_tac"]
    val long_names = ["METIS_TAC", "metis_tac"]
    fun member names name = List.exists (fn candidate => name = candidate) names
    val text = HOLSource.fromString {quietOpen = false, print = fn _ => ()} program
    val n = size text
    fun at i s = i + size s <= n andalso String.substring (text, i, size s) = s
    fun comment i depth =
      if i >= n then n
      else if at i "(*" then comment (i + 2) (depth + 1)
      else if at i "*)" then if depth = 1 then i + 2 else comment (i + 2) (depth - 1)
      else comment (i + 1) depth
    fun gap_end i =
      if i < n andalso Char.isSpace (String.sub (text, i)) then gap_end (i + 1)
      else i + 1
    fun string_end i =
      if i >= n then n
      else case String.sub (text, i) of
          #"\\" => string_end (if i + 1 < n andalso Char.isSpace (String.sub (text, i + 1))
                                     then gap_end (i + 1) else i + 2)
        | #"\"" => i + 1
        | _ => string_end (i + 1)
    fun ident_char c = Char.isAlphaNum c orelse c = #"_" orelse c = #"'" orelse c = #"."
    fun ident_end i = if i < n andalso ident_char (String.sub (text, i)) then ident_end (i + 1) else i
    fun scan i long =
      if i >= n then if long then !heavy_tactic_timeout_ref else !tactic_timeout_ref
      else if at i "(*" then scan (comment (i + 2) 1) long
      else if at i "\"" then scan (string_end (i + 1)) long
      else if ident_char (String.sub (text, i)) then
        let
          val stop = ident_end i
          val parts = String.fields (fn c => c = #".") (String.substring (text, i, stop - i))
          val name = List.last parts
        in
          if member untimed_names name then NONE
          else scan stop (long orelse member long_names name)
        end
      else scan (i + 1) long
  in scan 0 false end

fun with_tactic_timeout label program f x =
  let
    val step =
      case (!tactic_timeout_ref, !heavy_tactic_timeout_ref) of
          (NONE, NONE) => NONE
        | _ => step_budget program
    val budget =
      case (diagnostic_time_left (), step) of
          (NONE, _) => step
        | (SOME remaining, NONE) => SOME remaining
        | (SOME remaining, SOME seconds) => SOME (Real.min (remaining, seconds))
    val _ = check_diagnostic_deadline ()
  in
    case budget of
      NONE => f x
    | SOME seconds =>
        let
          val first_attempt = Timer.startCPUTimer ()
          val wall = Timer.startRealTimer ()
          val name = Option.getOpt (active_theorem_name (), !trace_current_theorem_ref)
          val position = !failed_plan_position_ref
          val result = capture_timeout (fn () =>
            timeout seconds f x
            handle FunctionTimeout =>
                     if !tainted_ref then raise TacticTimeout (timeout_message label seconds)
                     else retry_after_timeout label seconds first_attempt f x
                 | FunctionInterrupted => raise tactic_interrupted label) ()
          val elapsed = Time.toReal (Timer.checkRealTimer wall)
          val _ =
            if elapsed <= seconds / 2.0 then ()
            else
              let
                val (index, kind) =
                  case position of
                      SOME (index, kind, _) => (Int.toString index, kind)
                    | NONE => ("unknown", "atomic")
                val status = case result of TimeoutResult _ => "ok" | TimeoutException _ => "failed"
              in
                HolbuildBoundedOutput.text (TextIO.stdErr,
                  String.concat ["holbuild slow-proof-step\t", display_label name,
                    "\t", index, "\t", kind, "\t", status,
                    "\t", fmt_ms elapsed, "\t", fmt_ms seconds,
                    "\t", display_label label, "\n"])
              end
        in
          release_timeout result
        end
  end

fun save_checkpoint label default_share path ok_text depth =
  if not (!checkpoint_enabled_ref) then ()
  else
    HolbuildCheckpointSaveRuntime.save_checkpoint
      {label = label, default_share = default_share, path = path,
       ok_text = ok_text, depth = depth}

fun write_text_file path text =
  let val out = TextIO.openOut path
  in HolbuildBoundedOutput.text (out, text); TextIO.closeOut out end

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
      EachFrame (path, iter, remaining, prior) =>
        "each\t" ^ path_text path ^ "\t" ^ Int.toString iter ^ "\t" ^ Int.toString remaining ^ "\t" ^ int_list_text prior
    | CaseFrame (path, n, remaining, prior) =>
        "case\t" ^ path_text path ^ "\t" ^ Int.toString n ^ "\t" ^ Int.toString remaining ^ "\t" ^ int_list_text prior

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
      ["each", path_text', iter_text, remaining_text, prior_text] =>
        (case (parse_path_text path_text', strict_nonnegative_int iter_text, strict_positive_int remaining_text,
               parse_int_list_text prior_text) of
             (SOME path, SOME iter, SOME remaining, SOME prior) => SOME (EachFrame (path, iter, remaining, prior))
           | _ => NONE)
    | ["case", path_text', n_text, remaining_text, prior_text] =>
        (case (parse_path_text path_text', strict_positive_int n_text, strict_positive_int remaining_text,
               parse_int_list_text prior_text) of
             (SOME path, SOME n, SOME remaining, SOME prior) => SOME (CaseFrame (path, n, remaining, prior))
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

fun leaf_snapshot_text ({count, prefix_end, path, focus, frames, events,
                         sig_text = (kind, program), prefix_signature, history_count} : leaf_snapshot) =
  String.concat [Int.toString count, "\t", Int.toString prefix_end, "\t",
                 path_text path, "\t", int_list_text focus, "\t",
                 encode_metadata_list (map structural_frame_text frames), "\t",
                 encode_metadata_list (map dynamic_event_text events), "\t",
                 Option.getOpt(prefix_signature, ""), "\t", Int.toString history_count, "\t",
                 kind, "\t", String.toString program]

fun parse_step_signature_text text =
  case String.fields (fn c => c = #"\t") text of
      kind :: rest => Option.map (fn program => (kind, program)) (String.fromString (String.concatWith "\t" rest))
    | [] => NONE

fun parse_leaf_snapshot_text text =
  case String.fields (fn c => c = #"\t") text of
      count_text :: end_text :: path_text' :: focus_text :: frames_text :: events_text :: prefix_signature :: history_text :: kind :: [program_text] =>
        (case (strict_positive_int count_text, strict_nonnegative_int end_text,
               parse_path_text path_text', parse_int_list_text focus_text,
               decode_metadata_list frames_text, decode_metadata_list events_text,
               strict_nonnegative_int history_text, String.fromString program_text) of
             (SOME count, SOME prefix_end, SOME path, SOME focus, SOME frame_texts, SOME event_texts,
              SOME history_count, SOME program) =>
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
                              sig_text = (kind, program),
                              prefix_signature = if prefix_signature = "" then NONE else SOME prefix_signature,
                              history_count = history_count} : leaf_snapshot)
                   | _ => NONE
               end
           | _ => NONE)
    | _ => NONE

(* The .meta and .prefix texts of a failed-prefix checkpoint at the current
   step.  Limits the proof history to what the metadata needs, so call it just
   before saving the heap. *)
fun failed_prefix_texts () =
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
    val prefix_signature_lines =
      case !successful_leaf_snapshots_ref of
          ({prefix_signature = SOME saved_signature, ...} : leaf_snapshot) :: _ =>
            ["prefix_signature=" ^ saved_signature ^ "\n"]
        | _ => []
    val meta_text =
      String.concat (["proof_ir_failed_prefix_version=5\n",
                      "step_count=", Int.toString step_count, "\n",
                      "prefix_end=", Int.toString prefix_end, "\n",
                      "path=", path_text (!successful_path_ref), "\n",
                      "focus=", int_list_text (!successful_branch_tail_counts_ref), "\n",
                      "history_count=", Int.toString (!history_step_count_ref), "\n"] @
                     leaf_signature_lines @ prefix_signature_lines @
                     map (fn snap => "leaf=" ^ leaf_snapshot_text snap ^ "\n") (rev (!successful_leaf_snapshots_ref)) @
                     map (fn frame => "frame=" ^ structural_frame_text frame ^ "\n") (!successful_frames_ref) @
                     map (fn event => "event=" ^ dynamic_event_text event ^ "\n") (rev (!dynamic_events_ref)))
    val _ =
      (case !proof_history_ref of
           NONE => ()
         | SOME history =>
             proof_history_ref := SOME (History.set_limit history (Int.max(15, !history_step_count_ref + 1))))
  in
    (meta_text, String.substring(!active_tactic_text_ref, 0, prefix_end))
  end

(* A resumed proof runs in the heap it loaded from path, the last state in
   Poly's hierarchy, at depth.  Saving at depth - 1 writes the new heap as a
   child of that heap's parent, which stays as it is, and replaces the loaded
   heap in the hierarchy.  Poly read the loaded heap whole, so the process no
   longer needs its file.

   The new checkpoint is written under a temporary name and renamed into place
   once complete, so a process killed mid-save leaves the old one intact; only
   the few renames that install it can leave neither.  Renaming the heap is
   safe here: a heap's header names only its parent, and this failing process
   saves no child under it.  Renames also replace the old directory entries
   rather than writing into the old files, which may be links into a shared
   store (see HolbuildCheckpointSaveRuntime.begin_replacement).  The old .ok
   goes first and the new .ok last, so the files are never resumed as a mixed
   set. *)
fun advance_failed_prefix_checkpoint path ok_text depth =
  let
    val new = path ^ ".new"
    val suffixes = ["", ".meta", ".prefix", ".ok"]
    fun exists file = OS.FileSys.access (file, []) handle OS.SysErr _ => false
    fun remove file = OS.FileSys.remove file handle OS.SysErr _ => ()
    fun discard_new () =
      List.app (fn suffix => (remove (new ^ suffix); remove (new ^ suffix ^ ".tmp"))) suffixes
    fun install () =
      (remove (path ^ ".ok");
       List.app (fn suffix => OS.FileSys.rename {old = new ^ suffix, new = path ^ suffix}) suffixes)
  in
    (discard_new ();
     let val (meta_text, prefix_text) = failed_prefix_texts ()
     in
       save_checkpoint "failed_prefix" false new ok_text depth;
       (* save_checkpoint drops the checkpoint on an I/O failure; then no .ok. *)
       if exists (new ^ ".ok") then
         (HolbuildCheckpointSaveRuntime.write_text_atomically (new ^ ".meta") meta_text;
          HolbuildCheckpointSaveRuntime.write_text_atomically (new ^ ".prefix") prefix_text;
          install ())
       else discard_new ()
     end)
    handle e =>
      (discard_new ();
       if HolbuildCheckpointSaveRuntime.checkpoint_io_failure e then
         HolbuildCheckpointSaveRuntime.warn_checkpoint_failure "failed_prefix" new e
       else raise e)
  end

fun discard_failed_prefix path =
  (HolbuildCheckpointSaveRuntime.discard_checkpoint path;
   List.app (fn suffix => OS.FileSys.remove (path ^ suffix) handle OS.SysErr _ => ())
       [".meta", ".prefix"])

(* A resumed proof saves only when it got past the prefix it restored: one that
   fails at the same step would save the same state again.  A first save that
   can't write its files leaves none, as advance_failed_prefix_checkpoint
   does. *)
fun save_failed_prefix_checkpoint () =
  if !tainted_ref then ()
  else timed_hol_phase "holsave" (fn () =>
  case !theorem_info_ref of
      NONE => ()
    | SOME (kind, _, _, _, _, failed_prefix_path, failed_prefix_ok, proof_attrs, depth) =>
        if not (kind = "theorem" orelse kind = "resume") orelse
           not (!checkpoint_enabled_ref) orelse not (null proof_attrs) then ()
        else if !failed_prefix_resume_active_ref then
          (case !failed_prefix_resumed_step_count_ref of
               SOME resumed =>
                 if !successful_step_count_ref > resumed andalso not (QUse.hadError ()) then
                   advance_failed_prefix_checkpoint failed_prefix_path failed_prefix_ok (depth - 1)
                 else ()
             | NONE => ())
        else if QUse.hadError () then
          (* No checkpoint after a parse error: see HolbuildCheckpointSaveRuntime. *)
          discard_failed_prefix failed_prefix_path
        else
          let
            val (meta_text, prefix_text) = failed_prefix_texts ()
            (* Once compacted, the heap stays so for a later save here. *)
            val share = !share_failed_prefix_ref
            val _ = share_failed_prefix_ref := false
            val _ = save_checkpoint "failed_prefix" share failed_prefix_path failed_prefix_ok depth
          in
            (write_text_file (failed_prefix_path ^ ".meta") meta_text;
             write_text_file (failed_prefix_path ^ ".prefix") prefix_text)
            handle e =>
              if HolbuildCheckpointSaveRuntime.checkpoint_io_failure e then
                (HolbuildCheckpointSaveRuntime.warn_checkpoint_failure "failed_prefix" failed_prefix_path e;
                 discard_failed_prefix failed_prefix_path)
              else raise e
          end)

fun restore_failed_prefix_checkpoint_info (name, tactic_text, failed_prefix_path, failed_prefix_ok) =
  let val depth = length (PolyML.SaveState.showHierarchy())
  in
    theorem_info_ref := SOME ("theorem", name, tactic_text, "", "",
                              failed_prefix_path, failed_prefix_ok, [], depth)
  end

fun set_theorem_plan plan = active_plan_ref := plan

fun begin_theorem (kind, name, tactic_text, context_path, context_ok,
                   failed_prefix_path, failed_prefix_ok, proof_attrs) =
  let val depth = length (PolyML.SaveState.showHierarchy())
  in
    theorem_info_ref := SOME (kind, name, tactic_text, context_path, context_ok,
                              failed_prefix_path, failed_prefix_ok, proof_attrs, depth);
    context_info_ref := SOME (context_path, context_ok, depth)
  end

fun save_theorem_context () =
  case !context_info_ref of
      NONE => ()
    | SOME (context_path, context_ok, depth) =>
        (context_info_ref := NONE;
         if !tainted_ref orelse not (!checkpoint_enabled_ref andalso !context_checkpoints_ref) then ()
         else
           timed_hol_phase "holsave" (fn () =>
             HolbuildCheckpointSaveRuntime.save_context_checkpoint
               {label = "theorem_context", default_share = false, path = context_path,
                ok_text = context_ok, depth = depth}))

fun save_declaration_context save =
  if !tainted_ref then () else timed_hol_phase "holsave" save

(* Parse.pp_term rebuilds the printer's token splitter from the whole grammar
   for every term (about 17 ms each with vyper-hol's grammar), so a goal with
   hundreds of assumptions took seconds to print.  A one-shot user printer on
   a sentinel term captures the term printer once it is set up; printing each
   term through it does what Parse.pp_term does, without the rebuild.  HOL
   from 9bbea3b4b0 on keeps the splitter, which leaves this little to save.
   The goal is printed with the current grammars even when a script installed
   its own printer with Parse.set_term_printer.  NONE when the capture did not
   run. *)
fun cached_grammar_term_printer () =
  let
    val (tyG, tmG) = Parse.current_grammars ()
    val name = " holbuild goal printer "
    val sentinel =
      Term.mk_var (GrammarSpecials.mk_fakeconst_name
                     {original = SOME {Thy = "min", Name = name}, fake = name},
                   Type.bool)
    val captured = ref NONE
    fun capture _ _ sysprint (ppfns : term_pp_types.ppstream_funs) gravs _ _ =
      case !captured of
          SOME _ => raise term_pp_types.UserPP_Failed
        | NONE =>
            (captured := SOME (fn t =>
               Parse.mlower
                 (#ublock ppfns HOLPP.CONSISTENT 0
                    (sysprint {gravs = gravs, binderp = false,
                               depth = !Globals.max_print_depth} t)));
             smpp.nothing)
    val (_, boot) =
      Parse.print_from_grammars
        (tyG, term_grammar.add_user_printer (name, sentinel, capture) tmG)
    val _ = boot sentinel
  in
    !captured
  end
  handle Interrupt => raise Interrupt
       | _ => NONE

fun with_cached_grammar_term_printer f =
  case cached_grammar_term_printer () of
      NONE => f ()
    | SOME printer =>
        let val old = Parse.set_term_printer printer
        in
          (f () before ignore (Parse.set_term_printer old))
          handle e => (ignore (Parse.set_term_printer old); raise e)
        end

fun goal_text goal = PP.pp_to_string 100 goalStack.std_pp_goal goal ^ "\n"

fun top_goal_text [] = "<no open goals>\n"
  | top_goal_text (goal :: _) = goal_text goal

fun numbered_goal_text total (index, goal) =
  String.concat ["holbuild goal ", Int.toString index, " of ", Int.toString total, ":\n",
                 goal_text goal]

(* Goals are formatted only up to the limit: a failed step can leave many
   large goals, and only the first limit bytes are printed. *)
fun all_goals_text goals =
  if length goals <= 1 then ""
  else
    let
      val total = length goals
      val limit = HolbuildDiagnosticLimits.failed_goals ()
      fun collect _ [] _ texts = (String.concat (rev texts), false)
        | collect index (goal :: rest) bytes texts =
            if limit > 0 andalso bytes >= limit then (String.concat (rev texts), true)
            else
              let val text = numbered_goal_text total (index, goal)
              in collect (index + 1) rest (bytes + size text) (text :: texts) end
      val (text, omitted) = collect 1 goals 0 []
      val shown =
        if limit = 0 orelse (size text <= limit andalso not omitted) then text
        else
          String.concat [String.substring(text, 0, limit),
                         "\nholbuild failed tactic input goals truncated after ", Int.toString limit, " bytes\n"]
    in
      String.concat ["holbuild all failed tactic input goals:\n", shown,
                     "holbuild end all failed tactic input goals\n"]
    end

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
  (set_history (History.new_history {obj = goalStack.new_goal g Lib.I,
                                     limit = Int.max(15, limit)});
   history_step_count_ref := 0)

fun apply_history f =
  HolbuildHolFlags.quiet_goalstack (fn () => History.apply f (current_history()))

fun ensure_history_limit limit =
  set_history (History.set_limit (current_history()) (Int.max(15, limit)))

fun prepare_history_append () =
  ensure_history_limit (!history_step_count_ref + 2)

fun current_proof_context () =
  case !proof_context_ref of
      SOME ctxt => ctxt
    | NONE => raise Fail "internal error: no proof context is installed"

fun append_history f =
  (prepare_history_append ();
   set_history (apply_history f);
   history_step_count_ref := !history_step_count_ref + 1)

fun append_history_with_timeout label program f =
  let
    val _ = prepare_history_append ()
    val new_history = with_tactic_timeout label program apply_history f
  in
    set_history new_history;
    history_step_count_ref := !history_step_count_ref + 1
  end

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

fun print_goal_state label goals = timed_hol_phase "holprint" (fn () =>
  (failed_goal_state_printed_ref := true;
   if !tainted_ref then
     let val goal = with_cached_grammar_term_printer (fn () => top_goal_text goals)
     in secondary_goal_ref := SOME (String.substring (goal, 0, Int.min (size goal, 1024))) end
   else HolbuildBoundedOutput.text (TextIO.stdErr, with_cached_grammar_term_printer (fn () =>
    String.concat ["\nholbuild goal state at failed fragment: ", diagnostic_fragment_label label,
                   failed_theorem_line (),
                   failed_step_end_line (),
                   failed_step_span_line (),
                   failed_plan_position_line (),
                   "\nholbuild failed tactic input goal count: ", Int.toString (length goals), "\n",
                   "holbuild failed tactic top input goal:\n",
                   top_goal_text goals,
                   "holbuild end failed tactic top input goal\n",
                   all_goals_text goals]))))

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

fun print_step_failure_goal_state label goals =
  print_goal_state label goals
  handle print_e =>
    HolbuildBoundedOutput.text (TextIO.stdErr,
      String.concat ["holbuild failed to print goal state: ", General.exnMessage print_e, "\n"])

fun emit_step_failure_diagnostic label goals =
  (save_failed_prefix_checkpoint ();
   print_step_failure_goal_state label goals)

(* A timeout inside a TRY, ORELSE or repeat body is reported at once, since no
   combinator recovers from it.  It saves no failed-prefix checkpoint inside
   the body: resuming there would commit to that body without rerunning the
   combinator that chose it.  raise_body_timeout saves one where the outermost
   combinator started the body instead. *)
fun report_step_failure_with_goals label goals e =
  case (e, !suppress_expected_failure_diagnostics_ref) of
      (TacticTimeout _, true) =>
        (print_step_failure_goal_state label goals;
         raise e)
    | (TacticInterrupted _, true) =>
        (print_step_failure_goal_state label goals;
         raise e)
    | (_, true) =>
        (suppressed_failure_diagnostic_ref := SOME (fn () => emit_step_failure_diagnostic label goals);
         raise e)
    | (_, false) =>
        (emit_step_failure_diagnostic label goals;
         raise e)

(* A proof that fails outside a step (goals left at its end, say) saves a
   failed-prefix checkpoint too, so an edit that only appends steps resumes
   after the last one that ran. *)
fun report_finish_failure name e =
  let
    val _ = save_failed_prefix_checkpoint ()
    val _ =
      (ignore (print_finish_goal_state name)
       handle print_e =>
         HolbuildBoundedOutput.text (TextIO.stdErr,
           String.concat ["holbuild failed to print goal state: ", General.exnMessage print_e, "\n"]))
  in
    raise e
  end

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
  case Option.mapPartial (fn {tactics, ...} => List.find (fn (text, _) => text = program) tactics) (!proof_factories_ref) of
      SOME (_, make) => make
    | NONE =>
        if (add_hol_phase "holcompiledn" 1;
            quse_string ("HolbuildProofRuntime.compiled_tactic_ref := (fn () => (" ^ program ^ "));")) then
          !compiled_tactic_ref
        else raise TacticStaticError ("tactic fragment did not compile: " ^ label)

fun compile_list_tactic label program =
  case Option.mapPartial (fn {list_tactics, ...} => List.find (fn (text, _) => text = program) list_tactics) (!proof_factories_ref) of
      SOME (_, make) => make
    | NONE =>
        if (add_hol_phase "holcompiledn" 1;
            quse_string ("HolbuildProofRuntime.compiled_list_tactic_ref := (fn () => (" ^ program ^ "));")) then
          !compiled_list_tactic_ref
        else raise TacticStaticError ("list tactic fragment did not compile: " ^ label)

(* Plain HOL evaluates a proof's whole tactic expression before it applies
   any of it, so a leaf whose construction raises fails the proof wherever
   it sits: after the goal closes, in an ORELSE alternative never tried, or
   inside a TRY.  So the runner constructs every leaf of the plan, and every
   matching selector's RENAME_TAC, once before the first step
   (construct_plan_leaves) and applies those values, keyed by the leaf's
   source span and program.  A leaf can carry state (`REWRITE_RULE [Once th]`
   spends its bound when applied), so a failed-prefix resume must see each
   leaf as a fresh run would at its resume point (leaf_rewind_count). *)
datatype built_leaf = BuiltTactic of Tactical.tactic | BuiltListTactic of Tactical.list_tactic

fun no_built_leaves () = Binarymap.mkDict String.compare : (string, built_leaf) Binarymap.dict

val built_leaves_ref = ref (no_built_leaves ())

(* Compiled leaf programs of the current theorem, keyed by kind and program
   but not span: an edit that shifts the spans of unchanged leaves rebuilds
   them from these without compiling them again.  Every leaf of one proof
   compiles in the same environment, so a program compiles to the same
   factory wherever it sits. *)
datatype compiled_leaf = CompiledTactic of unit -> Tactical.tactic
                       | CompiledListTactic of unit -> Tactical.list_tactic

fun no_compiled_leaves () = Binarymap.mkDict String.compare : (string, compiled_leaf) Binarymap.dict

val compiled_leaves_ref = ref (no_compiled_leaves ())

(* Leaf applications are numbered in order; a TRY, ORELSE or REPEAT that
   rolls the proof back doesn't reuse the numbers, since it doesn't undo what
   the applications did to their leaves.  leaf_uses_ref holds, for each
   applied leaf, the numbers of its first and its last application;
   leaf_boundaries_ref, for each successful-leaf count, how many applications
   came before the success that reached it (the latest one: earlier ones were
   rolled back). *)
fun no_leaf_uses () = Binarymap.mkDict String.compare : (string, int * int) Binarymap.dict
fun no_leaf_boundaries () = Binarymap.mkDict Int.compare : (int, int) Binarymap.dict

val leaf_applications_ref = ref 0
val leaf_uses_ref = ref (no_leaf_uses ())
val leaf_boundaries_ref = ref (no_leaf_boundaries ())

fun reset_built_leaves () =
  (built_leaves_ref := no_built_leaves ();
   compiled_leaves_ref := no_compiled_leaves ();
   leaf_applications_ref := 0;
   leaf_uses_ref := no_leaf_uses ();
   leaf_boundaries_ref := no_leaf_boundaries ())

fun record_leaf_boundary count =
  leaf_boundaries_ref := Binarymap.insert (!leaf_boundaries_ref, count, !leaf_applications_ref)

fun leaf_key start_pos end_pos program =
  String.concat [Int.toString start_pos, ":", Int.toString end_pos, ":", program]

fun built_leaf start_pos end_pos program =
  let
    val key = leaf_key start_pos end_pos program
    val n = !leaf_applications_ref
  in
    case Binarymap.peek (!built_leaves_ref, key) of
        SOME leaf =>
          (leaf_applications_ref := n + 1;
           leaf_uses_ref :=
             Binarymap.insert (!leaf_uses_ref, key,
                               case Binarymap.peek (!leaf_uses_ref, key) of
                                   SOME (first, _) => (first, n)
                                 | NONE => (n, n));
           leaf)
      | NONE => raise Fail ("internal error: proof-ir leaf was not constructed: " ^ program)
  end

fun leaf_boundary 0 = 0
  | leaf_boundary count =
      case Binarymap.peek (!leaf_boundaries_ref, count) of
          SOME applications => applications
        | NONE => raise Fail ("internal error: no leaf boundary for successful leaf " ^ Int.toString count)

(* A failed-prefix resume restores the heap the failed run saved, after the
   failed step ran, so a leaf there has the state of every application up to
   the failure.  The resume point, after the count-th successful leaf, can
   only keep leaves applied wholly before it.  This is the latest count no
   leaf was applied on both sides of; the failed step and steps an edit
   rewound count as after. *)
fun leaf_rewind_count count =
  let val boundary = leaf_boundary count
  in
    case List.find (fn (_, (first, last)) => first < boundary andalso last >= boundary)
                   (Binarymap.listItems (!leaf_uses_ref)) of
        NONE => count
      | SOME (_, (first, _)) =>
          let fun back k = if leaf_boundary k <= first then k else back (k - 1)
          in leaf_rewind_count (back (count - 1)) end
  end

(* Leaves first applied at or after the resume point are constructed again. *)
fun drop_leaves_from count =
  let val boundary = leaf_boundary count
  in
    List.app (fn (key, (first, _)) =>
                if first < boundary then ()
                else (built_leaves_ref := #1 (Binarymap.remove (!built_leaves_ref, key));
                      leaf_uses_ref := #1 (Binarymap.remove (!leaf_uses_ref, key))))
             (Binarymap.listItems (!leaf_uses_ref))
  end

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
           if generated_count < 0 then
             raise Fail (String.concat ["focus tail count exceeds open goals: ", label,
                                        " (tail count ", Int.toString tail_count,
                                        ", open goals ", Int.toString total_count, ")"])
           else {goals = goals, total_count = total_count, generated_count = generated_count, tail_count = tail_count}
         end
         handle e => if tail_count = 0 andalso history_is_proved () then {goals = [], total_count = 0, generated_count = 0, tail_count = tail_count} else raise e)

fun apply_focus_list_tactic label program make_list_tactic =
  let
    val {goals, total_count, generated_count, ...} = active_focus_snapshot label
    val input_goals = take_goals generated_count goals
    fun expand history =
      let
        val list_tactic = make_list_tactic ()
        val scoped_list_tactic =
          case !branch_tail_count_ref of
              [] => list_tactic
            | _ => Tactical.SPLIT_LT generated_count (list_tactic, Tactical.ALL_LT)
      in
        HolbuildTacticCompat.expand_listf (current_proof_context ()) scoped_list_tactic history
      end
  in
    (if generated_count = 0 then
       (* Plain HOL applies a list tactic to an empty goal list too: ALLGOALS
          does nothing there, NTH_GOAL raises. *)
       (with_tactic_timeout label program (fn () =>
          case HolbuildTacticCompat.run_list_tactic (current_proof_context ()) (make_list_tactic ()) [] of
              ([], validation) => ignore (validation [])
            | _ => raise Fail ("list tactic produced goals from no goals: " ^ label)) ();
        if total_count = 0 then ()
        else append_history (HolbuildTacticCompat.expand_listf (current_proof_context ()) Tactical.ALL_LT))
     else
       append_history_with_timeout label program expand)
    handle e => report_step_failure_with_goals label input_goals e
  end

fun apply_tactic_step label program tactic =
  apply_focus_list_tactic label program (fn () => Tactical.ALLGOALS tactic)

fun no_open_goals () =
  ((history_top_goals (); false)
   handle _ => true)

fun allgoals_suffix_label label = String.isPrefix ">> " label

fun apply_list_tactic_step label program list_tactic =
  if allgoals_suffix_label label andalso no_open_goals () then ()
  else apply_focus_list_tactic label program (fn () => list_tactic)

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


(* The selector's tactic, built by construct_plan_leaves; NONE for SelectFirst. *)
fun built_selector start_pos end_pos selector =
  case HolbuildProofIr.selector_program selector of
      NONE => NONE
    | SOME program =>
        (case built_leaf start_pos end_pos program of
             BuiltTactic tac => SOME (program, tac)
           | BuiltListTactic _ => raise Fail ("internal error: selector built as a list tactic: " ^ program))

fun matching_selector_count label selector goals =
  case selector of
      NONE => if null goals then NONE else SOME 1
    | SOME (matching, (program, tac)) =>
        with_tactic_timeout label program (fn () =>
        let
          val probe = HolbuildTacticCompat.run_tactic (current_proof_context ()) tac
          fun matches g = Option.isSome (Lib.total probe g)
        in
          case matching of
              HolbuildProofIr.SelectMatchingFirst _ =>
                if List.exists matches goals then SOME 1 else NONE
            | _ => SOME (length (List.filter matches goals))
        end) ()


fun push_select_focus label start_pos end_pos selector =
  let
    val {goals, generated_count, tail_count, ...} = active_focus_snapshot label
    val focused_goals = take_goals generated_count goals
    val built = Option.map (fn tac => (selector, tac)) (built_selector start_pos end_pos selector)
    val selected_count =
      case matching_selector_count label built focused_goals of
          SOME n => n
        | NONE => raise Fail ("select with no matching focused goals: " ^ label)
    val _ =
      case (built, HolbuildProofIr.selector_list_tactic selector) of
          (SOME (HolbuildProofIr.SelectMatchingFirst _, (_, tac)), SOME program) =>
            apply_focus_list_tactic label program (fn () => Tactical.FIRST_LT tac)
        | (SOME (_, (_, tac)), SOME program) =>
            apply_focus_list_tactic label program (fn () => Tactical.SELECT_LT tac)
        | _ => ()
  in push_branch_tail_count (tail_count + generated_count - selected_count); selected_count end

fun push_first_focus label = push_select_focus label 0 0 HolbuildProofIr.SelectFirst

fun focused_goal_count label = #generated_count (active_focus_snapshot label)

fun close_focus label HolbuildProofIr.SelectKeep = pop_branch_tail_count label
  | close_focus label HolbuildProofIr.SelectSolve =
      let val remaining = focused_goal_count label
      in
        if remaining = 0 then pop_branch_tail_count label
        else raise Fail ("selected goals were not solved: " ^ label)
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
    in apply_focus_list_tactic label "" (fn () => HolbuildTacticCompat.lift_list_tactic reorder) end

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
        in apply_focus_list_tactic label "" (fn () => HolbuildTacticCompat.lift_list_tactic reorder) end

fun step proof_step =
  case proof_step of
      HolbuildProofIr.StepTactic {start_pos, end_pos, label, program} =>
        (case built_leaf start_pos end_pos program of
             BuiltTactic tactic => apply_tactic_step label program tactic
           | BuiltListTactic _ => raise Fail ("internal error: tactic step built as a list tactic: " ^ label))
    | HolbuildProofIr.StepList {start_pos, end_pos, label, program} =>
        (case built_leaf start_pos end_pos program of
             BuiltListTactic list_tactic => apply_list_tactic_step label program list_tactic
           | BuiltTactic _ => raise Fail ("internal error: list step built as a tactic: " ^ label))
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
  if trace_enabled () then HolbuildBoundedOutput.text (TextIO.stdErr, String.concat parts) else ()

fun trace_plan theorem_name plan =
  if plan_enabled () then
    (HolbuildBoundedOutput.text (TextIO.stdErr,
       String.concat ["holbuild proof-ir plan theorem=", theorem_name,
                      " steps=", Int.toString (length plan), "\n"]);
     List.app
       (fn (index, proof_step) =>
          HolbuildBoundedOutput.text (TextIO.stdErr,
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
   successful_leaf_snapshots = !successful_leaf_snapshots_ref,
   events = !dynamic_events_ref,
   resume_events = !resume_events_ref,
   branch_tail_counts = !branch_tail_count_ref,
   reverse_group_lengths = !reverse_group_lengths_ref,
   history_step_count = !history_step_count_ref}

fun restore_runtime_state {history, current_path, successful_path, current_frames,
                           successful_frames, resume_frames, successful_branch_tail_counts, successful_count,
                           successful_end, successful_leaf_snapshots, events, resume_events, branch_tail_counts,
                           reverse_group_lengths, history_step_count} =
  (set_history history;
   current_path_ref := current_path;
   successful_path_ref := successful_path;
   current_frames_ref := current_frames;
   successful_frames_ref := successful_frames;
   resume_frames_ref := resume_frames;
   successful_branch_tail_counts_ref := successful_branch_tail_counts;
   successful_step_count_ref := successful_count;
   successful_prefix_end_ref := successful_end;
   successful_leaf_snapshots_ref := successful_leaf_snapshots;
   dynamic_events_ref := events;
   resume_events_ref := resume_events;
   branch_tail_count_ref := branch_tail_counts;
   reverse_group_lengths_ref := reverse_group_lengths;
   history_step_count_ref := history_step_count)

fun with_expected_failures_suppressed f =
  let val old = !suppress_expected_failure_diagnostics_ref
      val _ = suppress_expected_failure_diagnostics_ref := true
      val _ = suppressed_failure_diagnostic_ref := NONE
      val result = (f (); NONE) handle e => SOME e
      val _ = suppress_expected_failure_diagnostics_ref := old
      val _ = case result of NONE => suppressed_failure_diagnostic_ref := NONE | SOME _ => ()
  in case result of NONE => () | SOME e => raise e end

fun discard_suppressed_failure_diagnostic () = suppressed_failure_diagnostic_ref := NONE

(* Re-raises a timeout from a TRY, ORELSE or repeat body.  The outermost such
   combinator restores the state from before it ran the body -- its entry for
   TRY and ORELSE, the start of the timed-out iteration for repeat -- and saves
   the failed-prefix checkpoint there, the latest point no combinator choice
   depends on. *)
fun raise_body_timeout saved e =
  (if !suppress_expected_failure_diagnostics_ref then ()
   else (restore_runtime_state saved; save_failed_prefix_checkpoint ());
   raise e)

fun raise_choice_failure (e, diagnostic) =
  (suppressed_failure_diagnostic_ref := diagnostic;
   if !suppress_expected_failure_diagnostics_ref then ()
   else
     (case diagnostic of SOME emit => emit () | NONE => ());
   raise e)

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
    val value = f ()
  in
    restore ();
    value
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
    check_diagnostic_deadline ();
    with_plan_position display_index (HolbuildProofIr.step_kind proof_step) (HolbuildProofIr.step_label proof_step)
      (HolbuildProofIr.step_start proof_step, HolbuildProofIr.step_end proof_step) traced
  end

(* Display indices follow run_structural_steps_with_resume's numbering, so a
   leaf whose construction fails is reported at its plan position.
   Compilation is outside the step budget, construction inside it: rule
   arguments can do arbitrary work before returning a tactic.  Leaves already
   in built_leaves_ref are kept, and a leaf missing there is compiled only if
   its program isn't in compiled_leaves_ref.  Entries for leaves no longer in
   the plan are dropped. *)
fun construct_plan_leaves display_index steps =
  let
    val no_keys = Binarymap.mkDict String.compare : (string, unit) Binarymap.dict
    val leaf_keys = ref no_keys
    val compile_keys = ref no_keys
    fun construct (CompiledTactic make) = BuiltTactic (make ())
      | construct (CompiledListTactic make) = BuiltListTactic (make ())
    fun build d proof_step start_pos end_pos label program kind compile =
      let
        val _ = check_diagnostic_deadline ()
        val key = leaf_key start_pos end_pos program
        val compile_key = kind ^ ":" ^ program
        val _ = leaf_keys := Binarymap.insert (!leaf_keys, key, ())
        val _ = compile_keys := Binarymap.insert (!compile_keys, compile_key, ())
      in
        if Option.isSome (Binarymap.peek (!built_leaves_ref, key)) then ()
        else
          let
            val compiled =
              case Binarymap.peek (!compiled_leaves_ref, compile_key) of
                  SOME compiled => compiled
                | NONE =>
                    let val compiled = compile label program
                    in compiled_leaves_ref := Binarymap.insert (!compiled_leaves_ref, compile_key, compiled);
                       compiled
                    end
          in
            with_plan_position d (HolbuildProofIr.step_kind proof_step) label (start_pos, end_pos) (fn () =>
              built_leaves_ref :=
                Binarymap.insert (!built_leaves_ref, key,
                                  with_tactic_timeout label program (fn () => construct compiled) ()))
          end
      end
    fun tactic label program = CompiledTactic (compile_tactic label program)
    fun list_tactic label program = CompiledListTactic (compile_list_tactic label program)
    fun walk_list _ [] = ()
      | walk_list d (proof_step :: rest) =
          (walk d proof_step; walk_list (d + HolbuildProofIr.display_line_count proof_step) rest)
    and walk_headed_bodies d bodies =
      ignore (List.foldl (fn (body, line) =>
                            (walk_list (line + 1) body;
                             line + 1 + HolbuildProofIr.display_line_count_list body))
                         d bodies)
    and walk d proof_step =
      case proof_step of
          HolbuildProofIr.StepTactic {start_pos, end_pos, label, program} =>
            build d proof_step start_pos end_pos label program "tactic" tactic
        | HolbuildProofIr.StepList {start_pos, end_pos, label, program} =>
            build d proof_step start_pos end_pos label program "list_tactic" list_tactic
        | HolbuildProofIr.StepEach {body, ...} => walk_list (d + 1) body
        | HolbuildProofIr.StepSelect {start_pos, end_pos, selector, body, ...} =>
            ((case HolbuildProofIr.selector_program selector of
                  NONE => ()
                | SOME program =>
                    build d proof_step start_pos end_pos (HolbuildProofIr.step_label proof_step) program
                          "tactic" tactic);
             walk_list (d + 1) body)
        | HolbuildProofIr.StepRepeat {body, ...} => walk_list (d + 1) body
        | HolbuildProofIr.StepTry {body, ...} => walk_list (d + 1) body
        | HolbuildProofIr.StepCases {cases, ...} => walk_headed_bodies (d + 1) cases
        | HolbuildProofIr.StepChoice {alternatives, ...} => walk_headed_bodies (d + 1) alternatives
    fun keep_only keys dict =
      Binarymap.foldl (fn (key, _, kept) =>
                         if Option.isSome (Binarymap.peek (keys, key)) then kept
                         else #1 (Binarymap.remove (kept, key)))
                      dict dict
  in
    walk_list display_index steps;
    built_leaves_ref := keep_only (!leaf_keys) (!built_leaves_ref);
    leaf_uses_ref := keep_only (!leaf_keys) (!leaf_uses_ref);
    compiled_leaves_ref := keep_only (!compile_keys) (!compiled_leaves_ref)
  end

fun run_built_steps resume_after_path display_index steps =
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
            else raise InvalidFailedPrefix (String.concat ["proof-ir dynamic replay mismatch: expected ",
                                            dynamic_event_text expected,
                                            ", found ", dynamic_event_text event])
        | [] =>
            raise InvalidFailedPrefix ("proof-ir dynamic replay mismatch: missing " ^ dynamic_event_text expected)
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
        val prefix_signature =
          Option.map HolbuildSha256.string_hex
            (HolbuildProofIr.canonical_dependency_prefix steps path)
      in
        add_hol_phase "holreplayedn" 1;
        successful_step_count_ref := count;
        record_leaf_boundary count;
        successful_prefix_end_ref := prefix_end;
        successful_path_ref := path;
        successful_frames_ref := !current_frames_ref;
        successful_branch_tail_counts_ref := !branch_tail_count_ref;
        successful_leaf_snapshots_ref := {count = count, prefix_end = prefix_end, path = path,
                                          focus = !branch_tail_count_ref,
                                          frames = !current_frames_ref,
                                          events = rev (!dynamic_events_ref),
                                          sig_text = sig_text,
                                          prefix_signature = prefix_signature,
                                          history_count = !history_step_count_ref} ::
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
          val selected_count = if entering_from_resume then 1
            else push_select_focus label (HolbuildProofIr.step_start proof_step) (HolbuildProofIr.step_end proof_step) selector
          val result = ((if selected_count = 0 then () else run_list (d + 1) (path @ [HolbuildProofIr.PathSelect]) 0 body); NONE) handle e => SOME e
        in
          case result of
              SOME e => ((pop_branch_tail_count label handle _ => ()); raise e)
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
          List.find (fn frame => case frame of EachFrame (p, _, _, _) => p = path | _ => false) (!resume_frames_ref)
        val count = focused_goal_count "each"
        val resume_frame = if !resume_reached_ref then NONE else resume_each_frame()
        fun run_one_each iter remaining prior =
          let
            val frame = EachFrame (path, iter, remaining, prior)
            (* A resumed checkpoint already holds this frame and its focus. *)
            val entering_from_resume = not (!resume_reached_ref) andalso resume_frame = SOME frame
            val _ = if entering_from_resume then () else push_structural_frame frame
            val _ = if entering_from_resume then () else ignore (push_first_focus "each")
            val result = (run_list (d + 1) (path @ [HolbuildProofIr.PathEach iter]) 0 body; NONE) handle e => SOME e
          in
            case result of
                SOME e => (pop_structural_frame frame "each";
                           (pop_branch_tail_count "each" handle _ => ());
                           raise e)
              | NONE =>
                  let val generated = focused_goal_count "each"
                  in pop_structural_frame frame "each";
                     close_focus "each" HolbuildProofIr.SelectKeep;
                     reorder_focused_front_after "each" generated (remaining - 1);
                     generated
                  end
          end
        fun loop _ 0 acc = rev acc
          | loop iter remaining acc = loop (iter + 1) (remaining - 1) (run_one_each iter remaining (rev acc) :: acc)
      in (case resume_frame of
              SOME (EachFrame (_, iter, remaining, prior)) => restore_focused_group_order "each" (loop iter remaining (rev prior))
            | _ => restore_focused_group_order "each" (loop 0 count []));
         d + HolbuildProofIr.display_line_count proof_step end)
    and run_cases d path proof_step cases =
      skip_or_enter_structural d path proof_step (fn () =>
      let
        fun resume_case_frame () =
          List.find (fn frame => case frame of CaseFrame (p, _, _, _) => p = path | _ => false) (!resume_frames_ref)
        val count = focused_goal_count "cases"
        val case_count = length cases
        val resume_frame = if !resume_reached_ref then NONE else resume_case_frame()
        (* Like plain THENL (NULL_OK_LT), cases on no goals do nothing. *)
        val _ = if Option.isSome resume_frame orelse count = 0 orelse case_count = count then ()
                else raise Fail (String.concat ["case count mismatch: ", Int.toString case_count,
                                                " cases for ", Int.toString count, " focused goals"])
        fun run_one_case body_display n remaining prior body =
          let
            val label = "case " ^ Int.toString n
            val frame = CaseFrame (path, n, remaining, prior)
            (* A resumed checkpoint already holds this frame and its focus. *)
            val entering_from_resume = not (!resume_reached_ref) andalso resume_frame = SOME frame
            val _ = if entering_from_resume then () else push_structural_frame frame
            val _ = if entering_from_resume then () else ignore (push_first_focus label)
            val result = (run_list body_display (path @ [HolbuildProofIr.PathCase n]) 0 body; NONE) handle e => SOME e
          in
            case result of
                SOME e => (pop_structural_frame frame label;
                           (pop_branch_tail_count label handle _ => ());
                           raise e)
              | NONE =>
                  let val generated = focused_goal_count label
                  in pop_structural_frame frame label;
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
                   (run_one_case (case_line + 1) n remaining (rev acc) body :: acc)
      in (case resume_frame of
              SOME (CaseFrame (_, n, remaining, prior)) =>
                restore_focused_group_order "cases" (loop n remaining (case_line_index n) (drop_cases n cases) (rev prior))
            | _ => if count = 0 then () else restore_focused_group_order "cases" (loop 1 count (d + 1) cases []));
         d + HolbuildProofIr.display_line_count proof_step end)
    and run_choice d path proof_step label alternatives =
      skip_or_enter_structural d path proof_step (fn () =>
      let
        fun nth_body 1 (body :: _) = SOME body
          | nth_body n (_ :: rest) = nth_body (n - 1) rest
          | nth_body _ [] = NONE
        fun attempt _ _ [] last =
              (case last of
                   SOME failure => raise_choice_failure failure
                 | NONE => raise Fail ("choice has no alternatives: " ^ label))
          | attempt n alt_line (body :: rest) _ =
              let val saved = runtime_state_snapshot()
                  val result = (with_expected_failures_suppressed (fn () => run_list (alt_line + 1) (path @ [HolbuildProofIr.PathAlternative n]) 0 body); NONE) handle e => SOME e
                  val diagnostic = !suppressed_failure_diagnostic_ref
              in
                case result of
                    NONE =>
                      (discard_suppressed_failure_diagnostic ();
                       record_or_replay_event (HolbuildProofIr.ChoiceEvent (path, n)))
                  | SOME (e as TacticTimeout _) => raise_body_timeout saved e
                  | SOME (e as TacticInterrupted _) => raise_body_timeout saved e
                  | SOME e =>
                      (restore_runtime_state saved;
                       attempt (n + 1) (alt_line + 1 + HolbuildProofIr.display_line_count_list body) rest (SOME (e, diagnostic)))
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
               | SOME (e as TacticTimeout _) => raise_body_timeout saved e
               | SOME (e as TacticInterrupted _) => raise_body_timeout saved e
               | SOME _ =>
                   (restore_runtime_state saved;
                    discard_suppressed_failure_diagnostic ();
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
                      SOME (e as TacticTimeout _) => raise_body_timeout saved e
                    | SOME (e as TacticInterrupted _) => raise_body_timeout saved e
                    | SOME _ =>
                        (restore_runtime_state saved;
                         discard_suppressed_failure_diagnostic ();
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
      with_plan_position d (HolbuildProofIr.step_kind proof_step) (HolbuildProofIr.step_label proof_step)
        (HolbuildProofIr.step_start proof_step, HolbuildProofIr.step_end proof_step)
        (fn () =>
          case proof_step of
              HolbuildProofIr.StepTactic _ => run_leaf d path proof_step
            | HolbuildProofIr.StepList _ => run_leaf d path proof_step
            | HolbuildProofIr.StepSelect {selector, mode, body, ...} => run_select d path proof_step selector mode body
            | HolbuildProofIr.StepEach {body, ...} => run_each d path proof_step body
            | HolbuildProofIr.StepCases {cases, ...} => run_cases d path proof_step cases
            | HolbuildProofIr.StepChoice {label, alternatives, ...} => run_choice d path proof_step label alternatives
            | HolbuildProofIr.StepTry {body, ...} => run_try d path proof_step body
            | HolbuildProofIr.StepRepeat {body, ...} => run_repeat d path proof_step body)
  in
    run_list display_index [] 0 steps;
    case resume_after_path of
        SOME _ => if !resume_reached_ref then ()
                  else raise InvalidFailedPrefix "failed-prefix proof path is not present in current proof-ir plan"
      | NONE => ()
  end

(* A failed-prefix resume from before the first leaf rebuilds every leaf but
   keeps the compiled programs its heap holds. *)
fun run_structural_steps_with_resume resume_after_path display_index steps =
  ((case resume_after_path of
        NONE =>
          let val compiled = !compiled_leaves_ref
          in
            reset_built_leaves ();
            if !failed_prefix_resume_active_ref then compiled_leaves_ref := compiled else ()
          end
      | SOME _ => ());
   timed_hol_phase "holleaves" (fn () => construct_plan_leaves display_index steps);
   timed_hol_phase "holtactics" (fn () => run_built_steps resume_after_path display_index steps))

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
   suppressed_failure_diagnostic_ref := NONE;
   history_step_count_ref := 0;
   branch_tail_count_ref := [];
   reverse_group_lengths_ref := NONE;
   run_structural_steps 0 steps)

fun report_secondary_failure name e =
  let
    val message =
      case e of
          TacticTimeout detail => detail
        | TacticInterrupted detail => detail
        | Interrupt => "interrupted"
        | _ => Feedback.exn_to_string e
    fun field text = String.toString (String.substring (text, 0, Int.min (size text, 1024)))
    val offset = case !failed_step_span_ref of SOME (start, _) => start | NONE => 0
    val goal = Option.getOpt (!secondary_goal_ref, "")
  in
    HolbuildBoundedOutput.text (TextIO.stdErr,
      String.concat ["holbuild secondary failure: ", field name, "\t", Int.toString offset,
                     "\t", field message, "\t", field goal, "\n"])
  end

fun print_first_failure name e =
  let
    val text =
      case (e, !theorem_info_ref) of
          (Feedback.HOL_ERR err, SOME ("theorem", _, _, _, _, _, _, _, _)) =>
            if !failed_prefix_resume_active_ref then Feedback.exn_to_string e
            else
              Feedback.exn_to_string (Feedback.wrap_exn "boolLib" "store_thm_at"
                (Feedback.HOL_ERR (Feedback.set_message
                  ("Failed to prove theorem " ^ Lib.quote name ^ ":\n" ^
                   Feedback.message_of err) err)))
        | (Feedback.HOL_ERR _, _) => Feedback.exn_to_string e
        | _ =>
            "Uncaught exception" ^
            (case PolyML.Exception.exceptionLocation e of
                 NONE => ""
               | SOME {file, startLine, ...} => " at " ^ file ^ ":" ^ FixedInt.toString startLine) ^
            ": " ^ Feedback.exn_to_string e
  in
    HolbuildBoundedOutput.text (TextIO.stdErr,
      text ^ (if String.isSuffix "\n" text then "" else "\n") ^
      "holbuild: continuing after first failure\n")
  end

fun proof_failure name goal e =
  let
    fun stop cause =
      if !tainted_ref then
        (report_secondary_failure name cause; OS.Process.exit OS.Process.failure)
      else PolyML.Exception.reraise cause
    val proof_error =
      case e of Feedback.HOL_ERR _ => true | Fail "Static Errors" => false | Fail _ => true | _ => false
  in
    case (!diagnostic_marker_ref, goal, proof_error) of
        (SOME marker, SOME g, true) =>
          let
            val _ =
              if !tainted_ref then report_secondary_failure name e
              else
                (print_first_failure name e;
                 write_text_file marker "";
                 diagnostic_timer_ref := SOME (Timer.startRealTimer ());
                 tainted_ref := true)
            val _ = diagnostic_failure_count_ref := !diagnostic_failure_count_ref + 1
          in
            if !diagnostic_failure_count_ref >= diagnostic_failure_limit then
              OS.Process.exit OS.Process.failure
            else Thm.mk_oracle_thm "holbuild_diagnostic_admit" g
          end
      | _ =>
          (case e of
               TacticStaticError message => stop (Fail message)
             | InvalidFailedPrefix message => stop (Fail message)
             | _ => stop e)
  end

(* Runs a proof's steps and returns its theorem.  The leaves stay built until
   it returns: a failed-prefix checkpoint that report_finish_failure saves
   needs their boundaries to resume. *)
fun finish_proof name goal run top =
  let
    val th =
      (run ()
       handle e =>
         if !failed_goal_state_printed_ref then raise e
         else report_finish_failure name e;
       top () handle e => report_finish_failure name e)
      handle e => proof_failure name goal e
  in
    reset_built_leaves ();
    th
  end
  handle e => (reset_built_leaves (); raise e)

datatype 'a traced_result = TraceOk of 'a | TraceError of exn

fun backup_n 0 = ()
  | backup_n n =
      (set_history (History.undo (current_history()));
       history_step_count_ref := !history_step_count_ref - 1;
       backup_n (n - 1))

fun drop_all () = clear_history ()

fun atomic_prove label g tac =
  with_tactic_timeout label ""
    (fn () => HolbuildTacticCompat.tac_proof (current_proof_context ()) (g, tac)) ()
  handle e =>
    (init_history g 15;
     report_step_failure label e
     handle failure => proof_failure label (SOME g) failure)

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

fun with_proof_ir_execution ctxt f =
  let
    val old_proving = !proving_with_proof_ir_ref
    val old_context = !proof_context_ref
    val _ = proving_with_proof_ir_ref := true
    val _ = proof_context_ref := SOME ctxt
    val result = TraceOk (f ()) handle e => TraceError e
    val _ = proving_with_proof_ir_ref := old_proving
    val _ = proof_context_ref := old_context
  in
    case result of TraceOk value => value | TraceError e => raise e
  end

fun proof_ir_prove name g original_tac tactic_text =
  let
    val _ = active_tactic_text_ref := tactic_text
    val plan = case !active_plan_ref of SOME p => p | NONE => raise Fail "internal error: proof-IR plan is not installed"
    val _ = trace_plan name plan
    val _ = stop_after_plan_if_requested ()
    fun run factories ctxt goal =
      let
        val old_factories = !proof_factories_ref
        val _ = proof_factories_ref := factories
        val result = TraceOk (with_proof_ir_execution ctxt (fn () =>
          (init_history goal (HolbuildProofIr.display_step_count plan + 1);
           finish_proof name (SOME goal) (fn () => run_steps plan) (fn () => history_top_thm goal))))
          handle e => TraceError e
        val _ = proof_factories_ref := old_factories
      in
        case result of TraceOk th => th | TraceError e => raise e
      end
    (* HOL's supplied tactic owns the native modifier and its lexical scope.
       The injected entry consumes this hook before running any nested proof. *)
    val _ = plan_runner_ref := SOME run
    val th = HolbuildTacticCompat.tac_proof (current_proof_context ()) (g, original_tac)
             handle e => (plan_runner_ref := NONE; raise e)
    val _ = plan_runner_ref := NONE
    val _ = drop_all ()
  in
    th
  end

fun termination_tactic name tactic_text plan original_tac =
  HolbuildTacticCompat.lift_context_tactic (fn ctxt => fn g =>
  let
    val depth = length (PolyML.SaveState.showHierarchy())
    val _ = theorem_info_ref := SOME ("termination", name, tactic_text,
                                      "", "", "", "", [], depth)
    val _ = failed_step_end_ref := NONE
    val _ = failed_step_span_ref := NONE
    val _ = failed_plan_position_ref := NONE
    val _ = failed_goal_state_printed_ref := false
    val _ = secondary_goal_ref := NONE
    fun execute () =
      let
        val _ = active_tactic_text_ref := tactic_text
        val _ = active_plan_ref := SOME plan
        val _ = trace_plan name plan
        val _ = stop_after_plan_if_requested ()
        val _ = init_history g (HolbuildProofIr.display_step_count plan + 1)
        val th = finish_proof name NONE (fn () => run_steps plan) (fn () => history_top_thm g)
        val _ = drop_all ()
        val _ = theorem_info_ref := NONE
      in
        ([], fn [] => th | _ => raise Fail "termination tactic validation received theorems")
      end
  in
    with_proof_ir_execution ctxt (fn () => with_theorem_trace name execute)
  end)

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
          if version = "5" then
            (case (metadata_value "step_count" lines,
                   metadata_value "prefix_end" lines,
                   metadata_value "path" lines,
                   metadata_value "focus" lines,
                   metadata_value "prefix_signature" lines,
                   metadata_value "history_count" lines,
                   parse_events event_texts [],
                   parse_frames frame_texts [],
                   parse_leaf_snapshots leaf_texts []) of
                 (SOME count_text, SOME end_text, SOME path_text', SOME focus_text,
                  prefix_signature, SOME history_text, SOME events, SOME frames, SOME leaves) =>
                   (case (strict_nonnegative_int count_text, strict_nonnegative_int end_text,
                          parse_path_text path_text', parse_int_list_text focus_text,
                          strict_nonnegative_int history_text) of
                        (SOME step_count, SOME prefix_end, SOME path, SOME focus, SOME history_count) =>
                          let
                            val leaf_signature =
                              case metadata_value "leaf_signature" lines of
                                  SOME text => parse_step_signature_text text
                                | NONE => NONE
                          in
                            if step_count > 0 andalso
                               (not (Option.isSome leaf_signature) orelse
                                not (Option.isSome prefix_signature) orelse
                                List.exists (fn ({prefix_signature, ...} : leaf_snapshot) =>
                                               not (Option.isSome prefix_signature)) leaves) then NONE
                            else SOME {step_count = step_count, prefix_end = prefix_end, path = path, focus = focus,
                                       leaf_signature = leaf_signature, prefix_signature = prefix_signature,
                                       history_count = history_count,
                                       events = events, frames = frames, leaves = leaves}
                          end
                      | _ => NONE)
               | _ => NONE)
          else NONE
      | _ => NONE
  end

fun validate_failed_prefix_metadata plan (metadata : {step_count : int, prefix_end : int, path : HolbuildProofIr.proof_path,
                                               focus : int list, leaf_signature : (string * string) option,
                                               prefix_signature : string option, history_count : int,
                                               events : HolbuildProofIr.dynamic_event list,
                                               frames : structural_frame list,
                                               leaves : leaf_snapshot list}) =
  let
    val path = #path metadata
    val _ = if #step_count metadata >= 0 andalso #prefix_end metadata >= 0 andalso
               #history_count metadata >= 0 then ()
            else raise Fail "invalid proof-ir failed-prefix metadata: negative step_count, prefix_end, or history_count"
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
                val current_prefix_signature =
                  Option.map HolbuildSha256.string_hex
                    (HolbuildProofIr.canonical_dependency_prefix plan path)
                val _ =
                  case (#prefix_signature metadata, current_prefix_signature) of
                      (SOME saved, SOME current) =>
                        if saved = current then ()
                        else raise Fail "invalid proof-ir failed-prefix metadata: execution prefix changed"
                    | _ => raise Fail "invalid proof-ir failed-prefix metadata: missing execution prefix signature"
              in
                case #leaf_signature metadata of
                    SOME saved_signature =>
                      if saved_signature = current_signature then ()
                      else raise Fail "invalid proof-ir failed-prefix metadata: leaf tactic changed"
                  | NONE => ()
              end
          | NONE => raise Fail "failed-prefix proof path is not present in current proof-ir plan"
    fun validate_endpoint_snapshot () =
      case rev (#leaves metadata) of
          [] => raise Fail "invalid proof-ir failed-prefix metadata: missing endpoint leaf snapshot"
        | ({count, prefix_end, path = leaf_path, focus, frames, events, sig_text,
            prefix_signature, history_count} : leaf_snapshot) :: _ =>
            if count = #step_count metadata andalso
               prefix_end = #prefix_end metadata andalso
               leaf_path = #path metadata andalso
               focus = #focus metadata andalso
               frames = #frames metadata andalso
               events = #events metadata andalso
               SOME sig_text = #leaf_signature metadata andalso
               prefix_signature = #prefix_signature metadata andalso
               history_count = #history_count metadata then ()
            else raise Fail "invalid proof-ir failed-prefix metadata: endpoint snapshot mismatch"
    fun validate_history_counts expected [] =
          if expected = #step_count metadata + 1 then ()
          else raise Fail "invalid proof-ir failed-prefix metadata: leaf snapshot count mismatch"
      | validate_history_counts expected (({count, history_count, ...} : leaf_snapshot) :: rest) =
          if count <> expected orelse history_count <= 0 then
            raise Fail "invalid proof-ir failed-prefix metadata: invalid leaf history count"
          else
            (case rest of
                 ({history_count = next, ...} : leaf_snapshot) :: _ =>
                   if history_count <= next then validate_history_counts (expected + 1) rest
                   else raise Fail "invalid proof-ir failed-prefix metadata: decreasing leaf history count"
               | [] =>
                   if history_count = #history_count metadata then
                     validate_history_counts (expected + 1) rest
                   else raise Fail "invalid proof-ir failed-prefix metadata: endpoint history count mismatch")
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
          EachFrame (frame_path, iter, remaining, prior) =>
            if iter >= 0 andalso remaining > 0 andalso length prior = iter andalso
               (case current_node_at_path frame_path of SOME (HolbuildProofIr.StepEach _) => true | _ => false) andalso
               frame_path_matches_path frame_path (fn HolbuildProofIr.PathEach n => n = iter | _ => false) then ()
            else raise Fail "invalid proof-ir failed-prefix metadata: stale each frame"
        | CaseFrame (frame_path, n, remaining, prior) =>
            if n > 0 andalso remaining > 0 andalso length prior = n - 1 andalso
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
              case frame of EachFrame (p, _, _, _) => p | CaseFrame (p, _, _, _) => p
          in
            if path_has_prefix (frame_path outer) (frame_path inner) then validate_frame_order (outer :: rest)
            else raise Fail "invalid proof-ir failed-prefix metadata: inconsistent frame stack order"
          end
  in
    if #step_count metadata = 0 then
      (if #history_count metadata = 0 andalso null (#leaves metadata) then ()
       else raise Fail "invalid proof-ir failed-prefix metadata: nonempty zero-step history")
    else
      (validate_endpoint_snapshot ();
       validate_history_counts 1 (#leaves metadata));
    validate_focus (#focus metadata);
    List.app validate_frame (#frames metadata);
    validate_frame_order (#frames metadata);
    List.app validate_event (#events metadata)
  end

fun take_at_most 0 _ = []
  | take_at_most _ [] = []
  | take_at_most n (x :: xs) = if n > 0 then x :: take_at_most (n - 1) xs else []

val no_salvage = {step_count = 0, prefix_end = 0, path = [], focus = [], leaf_signature = NONE,
                  prefix_signature = NONE, history_count = 0,
                  events = [], frames = [], leaves = []}

fun salvaged_through leaves ({count, path, focus, frames, events, sig_text, prefix_signature, history_count, ...} : leaf_snapshot)
                     prefix_end =
  {step_count = count, prefix_end = prefix_end, path = path, focus = focus,
   leaf_signature = SOME sig_text, prefix_signature = prefix_signature,
   history_count = history_count,
   events = events, frames = frames, leaves = take_at_most count leaves}

(* The longest prefix of leaves the edited plan still reaches the same way,
   checking each leaf's dependency-prefix hash. *)
fun salvage_leaf_by_leaf plan leaves =
  let
    fun current_signature path =
      case step_at_path plan path of
          SOME step =>
            Option.map
              (fn prefix_signature =>
                 (HolbuildProofIr.step_kind step, HolbuildProofIr.step_program step,
                  HolbuildProofIr.step_end step, HolbuildSha256.string_hex prefix_signature))
              (HolbuildProofIr.canonical_dependency_prefix plan path)
        | NONE => NONE
    fun valid_leaf ({count, prefix_end, path, sig_text, prefix_signature, ...} : leaf_snapshot) expected_count =
      count = expected_count andalso
      (case (current_signature path, prefix_signature) of
           (SOME (kind, program, current_end, current_prefix_signature), SOME saved_prefix_signature) =>
             prefix_end = current_end andalso sig_text = (kind, program) andalso
             saved_prefix_signature = current_prefix_signature
         | _ => false)
    fun loop _ [] last = last
      | loop expected (leaf :: rest) last =
          if valid_leaf leaf expected then loop (expected + 1) rest (SOME leaf)
          else last
  in
    case loop 1 leaves NONE of
        NONE => no_salvage
      | SOME (leaf as {path, ...} : leaf_snapshot) =>
          (case current_signature path of
               SOME (_, _, current_end, _) => salvaged_through leaves leaf current_end
             | NONE => no_salvage)
  end

(* As salvage_leaf_by_leaf, hashing once: a leaf's dependency prefix holds
   everything run before it, so if the last leaf passing the cheap checks
   has its saved hash, every leaf before it does too.  Otherwise the leaves
   before it are checked one by one. *)
fun salvage_failed_prefix_leaves plan leaves =
  let
    fun cheap_valid ({count, prefix_end, path, sig_text, prefix_signature, ...} : leaf_snapshot) expected_count =
      count = expected_count andalso Option.isSome prefix_signature andalso
      (case step_at_path plan path of
           SOME step =>
             prefix_end = HolbuildProofIr.step_end step andalso
             sig_text = (HolbuildProofIr.step_kind step, HolbuildProofIr.step_program step)
         | NONE => false)
    fun scan _ [] last = last
      | scan expected (leaf :: rest) last =
          if cheap_valid leaf expected then scan (expected + 1) rest (SOME leaf)
          else last
    val salvaged =
      case scan 1 leaves NONE of
          NONE => no_salvage
        | SOME (leaf as {count, path, prefix_end, prefix_signature, ...} : leaf_snapshot) =>
            if Option.map HolbuildSha256.string_hex (HolbuildProofIr.canonical_dependency_prefix plan path) =
               prefix_signature
            then salvaged_through leaves leaf prefix_end
            else salvage_leaf_by_leaf plan (take_at_most (count - 1) leaves)
  in
    (* Tests check the single hash against the leaf-by-leaf check. *)
    if Option.getOpt (HolbuildCheckpointSaveRuntime.env_bool "HOLBUILD_CHECK_SALVAGE", false) andalso
       salvaged <> salvage_leaf_by_leaf plan leaves
    then raise Fail "internal error: failed-prefix salvage disagrees with the leaf-by-leaf check"
    else salvaged
  end

fun resumable_failed_prefix_metadata plan metadata =
  (validate_failed_prefix_metadata plan metadata; metadata)
  handle _ =>
    let
      val salvaged = salvage_failed_prefix_leaves plan (#leaves metadata)
    in
      validate_failed_prefix_metadata plan salvaged;
      salvaged
    end

fun rewind_past_shared_leaves plan metadata =
  let val count = leaf_rewind_count (#step_count metadata)
  in
    if count = #step_count metadata then metadata
    else
      let val rewound = salvage_failed_prefix_leaves plan (take_at_most count (#leaves metadata))
      in
        validate_failed_prefix_metadata plan rewound;
        rewind_past_shared_leaves plan rewound
      end
  end

fun finish_failed_prefix name metadata_text tactic_text failed_prefix_path failed_prefix_ok =
  let
    val old_resume_active = !failed_prefix_resume_active_ref
    val old_resumed_step_count = !failed_prefix_resumed_step_count_ref
    fun restore_resume_flag () =
      (failed_prefix_resume_active_ref := old_resume_active;
       failed_prefix_resumed_step_count_ref := old_resumed_step_count)
    val _ = failed_prefix_resume_active_ref := true
    val result =
      with_proof_ir_execution (current_proof_context ()) (fn () =>
       (restore_failed_prefix_checkpoint_info (name, tactic_text, failed_prefix_path, failed_prefix_ok);
        with_theorem_trace name (fn () =>
        let
          val _ = active_tactic_text_ref := tactic_text
          val plan = case !active_plan_ref of SOME p => p | NONE => raise Fail "internal error: proof-IR plan is not installed"
          val metadata =
            case parse_failed_prefix_metadata metadata_text of
                SOME m => m
              | NONE => raise Fail "invalid proof-ir failed-prefix metadata"
          val _ = ensure_history_limit (Int.max(HolbuildProofIr.display_step_count plan + 1,
                                                  #history_count metadata + 1))
          val _ =
            if !history_step_count_ref = #history_count metadata then ()
            else raise Fail (String.concat ["failed-prefix checkpoint history does not match metadata: heap=",
                                            Int.toString (!history_step_count_ref),
                                            " metadata=", Int.toString (#history_count metadata)])
          val resume_metadata =
            timed_hol_phase "holsalvage" (fn () =>
              rewind_past_shared_leaves plan (resumable_failed_prefix_metadata plan metadata))
          val _ = add_hol_phase "holrewoundn" (LargeInt.fromInt (#step_count metadata - #step_count resume_metadata))
          val backup_count = #history_count metadata - #history_count resume_metadata
          val _ =
            if backup_count >= 0 then ()
            else raise Fail "invalid proof-ir failed-prefix metadata: salvage history exceeds checkpoint history"
          val _ = timed_hol_phase "holrewind" (fn () =>
            (drop_leaves_from (#step_count resume_metadata);
             backup_n backup_count
             handle History.CANT_BACKUP_ANYMORE =>
               raise Fail (String.concat ["failed-prefix checkpoint cannot rewind ",
                                          Int.toString backup_count,
                                          " proof history steps; checkpoint history retained fewer steps than its metadata history_count=",
                                          Int.toString (#history_count metadata)])))
          val _ = trace_plan name plan
          val _ = stop_after_plan_if_requested ()
          val metadata = resume_metadata
          val _ = failed_prefix_resumed_step_count_ref := SOME (#step_count metadata)
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
          (* Metadata lists leaves oldest first; the ref holds them newest first. *)
          val _ = successful_leaf_snapshots_ref := rev (take_at_most (#step_count metadata) (#leaves metadata))
          val _ = branch_tail_count_ref := #focus metadata
          val _ = successful_branch_tail_counts_ref := #focus metadata
          val _ = dynamic_events_ref := rev (#events metadata)
          val _ = resume_events_ref := #events metadata
          val th =
            let val goal = project_history goalStack.initial_goal
            in finish_proof name (SOME goal)
              (fn () =>
                 if #step_count metadata = 0 then run_structural_steps 0 plan
                 else run_steps_from_path (#path metadata) 0 plan)
              (fn () => history_top_thm goal)
            end
          val _ = drop_all()
          val _ = theorem_info_ref := NONE
        in th end)))
      handle e => (restore_resume_flag (); raise e)
    val _ = restore_resume_flag ()
  in
    result
  end

fun prove_outer_theorem ctxt (g, tac) (_, name, tactic_text, _, _, _, _, _, _) =
  let
    val _ = secondary_goal_ref := NONE
    val _ = failed_step_span_ref := NONE
    val atomic = tactic_text = ""
    val th =
      with_proof_ir_execution ctxt (fn () =>
        with_theorem_trace name (fn () =>
          if atomic then atomic_prove name g tac
          else proof_ir_prove name g tac tactic_text))
    val _ = theorem_info_ref := NONE
  in
    th
  end

fun proof_ir_prover ctxt (g, tac) =
  if !proving_with_proof_ir_ref then
    HolbuildTacticCompat.tac_proof ctxt (g, tac)
  else
    case !theorem_info_ref of
        NONE => HolbuildTacticCompat.tac_proof ctxt (g, tac)
      | SOME info =>
          prove_outer_theorem ctxt (g, tac) info
          handle e =>
            (proving_with_proof_ir_ref := false;
             theorem_info_ref := NONE;
             context_info_ref := NONE;
             drop_all();
             raise e)

fun install ({checkpoint_enabled, context_checkpoints, share_failed_prefix, checkpoint_seconds, tactic_timeout, heavy_tactic_timeout, timeout_marker, plan_theorem, trace_all, plan_only_marker} : config) =
  (hol_phases_ref := [("holloadend", Time.toMilliseconds (Time.now ()))];
   hol_phase_nested_ms_ref := 0;
   OS.Process.atExit print_hol_phases;
   diagnostic_marker_ref := NONE;
   checkpoint_enabled_ref := checkpoint_enabled;
   context_checkpoints_ref := context_checkpoints;
   share_failed_prefix_ref := share_failed_prefix;
   tactic_timeout_ref := tactic_timeout;
   heavy_tactic_timeout_ref := heavy_tactic_timeout;
   tactic_timeout_marker_ref := timeout_marker;
   plan_theorem_ref := plan_theorem;
   trace_all_ref := trace_all;
   plan_only_marker_ref := plan_only_marker;
   plan_active_ref := false;
   trace_active_ref := false;
   theorem_info_ref := NONE;
   plan_runner_ref := NONE;
   proof_factories_ref := NONE;
   context_info_ref := NONE;
   failed_step_end_ref := NONE;
   failed_step_span_ref := NONE;
   failed_plan_position_ref := NONE;
   failed_goal_state_printed_ref := false;
   suppressed_failure_diagnostic_ref := NONE;
   failed_prefix_resume_active_ref := false;
   failed_prefix_resumed_step_count_ref := NONE;
   proving_with_proof_ir_ref := false;
   HolbuildCheckpointSaveRuntime.reset_context_checkpoint_gate checkpoint_seconds;
   HolbuildTacticCompat.install_prover proof_ir_prover;
   case tactic_timeout of
       NONE => ()
     | SOME seconds => HolbuildBoundedOutput.text (TextIO.stdErr,
         "holbuild slow-proof-steps v1 coverage=executed limit_ms=" ^ fmt_ms seconds ^ "\n"))

end
