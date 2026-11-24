structure HolbuildTheoryCheckpoints =
struct

exception Error of string

type boundary = {kind : string, name : string, safe_name : string, theorem_start : int,
                 theorem_stop : int, boundary : int, tactic_start : int,
                 tactic_end : int, tactic_text : string,
                 proof_attrs : (string * string list) list, prefix_hash : string}
type checkpoint = {kind : string, name : string, safe_name : string, theorem_start : int,
                   theorem_stop : int, boundary : int, tactic_start : int,
                   tactic_end : int, tactic_text : string,
                   proof_attrs : (string * string list) list, prefix_hash : string,
                   context_path : string, context_ok : string,
                   failed_prefix_path : string, failed_prefix_ok : string,
                   deps_key : string, checkpoint_key : string,
                   proof_ir_plan : string option, proof_ir_factories : string option}

(* Where a checkpoint's proof unit is in the script. *)
fun checkpoint_boundary ({kind, name, safe_name, theorem_start, theorem_stop, boundary, tactic_start,
                          tactic_end, tactic_text, proof_attrs, prefix_hash, ...} : checkpoint) : boundary =
  {kind = kind, name = name, safe_name = safe_name, theorem_start = theorem_start,
   theorem_stop = theorem_stop, boundary = boundary, tactic_start = tactic_start,
   tactic_end = tactic_end, tactic_text = tactic_text, proof_attrs = proof_attrs,
   prefix_hash = prefix_hash}

type termination = {name : string, safe_name : string, definition_start : int,
                    definition_stop : int, boundary : int,
                    quote_start : int, quote_end : int, quote_text : string,
                    tactic_start : int, tactic_end : int, tactic_text : string,
                    proof_ir_plan : string option}

type declaration_checkpoint = {name : string, safe_name : string,
                               definition_start : int, boundary : int,
                               prefix_hash : string,
                               context_path : string, context_ok : string,
                               deps_key : string, checkpoint_key : string}

fun is_ident c = Char.isAlphaNum c orelse c = #"_" orelse c = #"'"

fun starts_with text i needle =
  let val n = size text
      val m = size needle
  in i + m <= n andalso String.substring(text, i, m) = needle end

fun skip_comment text i =
  let
    val n = size text
    fun loop j depth =
      if j >= n then n
      else if starts_with text j "(*" then loop (j + 2) (depth + 1)
      else if starts_with text j "*)" then
        if depth = 1 then j + 2 else loop (j + 2) (depth - 1)
      else loop (j + 1) depth
  in
    loop (i + 2) 1
  end

fun skip_ws_comments text i =
  let
    val n = size text
    fun loop j =
      if j >= n then n
      else if Char.isSpace (String.sub(text, j)) then loop (j + 1)
      else if starts_with text j "(*" then loop (skip_comment text j)
      else j
  in
    loop i
  end

fun statement_boundary text i =
  let val j = skip_ws_comments text i
  in if j < size text andalso String.sub(text, j) = #";" then j + 1 else i end

fun safe_name name =
  let
    fun safe c = if is_ident c then c else #"_"
    val s = String.map safe name
  in
    if s = "" then "unnamed" else s
  end

fun prefix_hash text boundary =
  HolbuildToolchain.hash_text (String.substring(text, 0, boundary))

fun begin_theorem_line ({kind, name, tactic_text, context_path, context_ok,
                         failed_prefix_path, failed_prefix_ok,
                         proof_attrs, proof_ir_plan, ...} : checkpoint) =
  String.concat
    [(case proof_ir_plan of
          SOME expr => "val _ = HolbuildProofRuntime.set_theorem_plan (SOME (" ^ expr ^ "));\n"
        | NONE => "val _ = HolbuildProofRuntime.set_theorem_plan NONE;\n"),
     "val _ = holbuild_begin_theorem(",
     HolbuildToolchain.sml_string kind, ", ",
     HolbuildToolchain.sml_string name, ", ",
     HolbuildToolchain.sml_string tactic_text, ", ",
     HolbuildToolchain.sml_string context_path, ", ",
     HolbuildToolchain.sml_string context_ok, ", ",
     HolbuildToolchain.sml_string failed_prefix_path, ", ",
     HolbuildToolchain.sml_string failed_prefix_ok, ", ",
     "[" ^ String.concatWith ", "
       (map (fn (key, values) => "(" ^ HolbuildToolchain.sml_string key ^ ", [" ^
         String.concatWith ", " (map HolbuildToolchain.sml_string values) ^ "])") proof_attrs) ^ "]",
     ");\n"]

fun begin_termination_line ({name, definition_start, ...} : termination) =
  String.concat
    ["val _ = HolbuildTerminationDiagnosticsRuntime.begin_definition ",
     HolbuildToolchain.sml_string name, " ",
     Int.toString definition_start,
     ";\n"]

fun end_termination_line ({name, definition_start, ...} : termination) =
  String.concat
    ["\nval _ = HolbuildTerminationDiagnosticsRuntime.end_definition ",
     HolbuildToolchain.sml_string name, " ",
     Int.toString definition_start,
     ";\n"]

fun termination_tactic_prefix ({name, definition_start, tactic_text, proof_ir_plan, ...} : termination) =
  String.concat
    ["(HolbuildTerminationDiagnosticsRuntime.report_goal ",
     HolbuildToolchain.sml_string name, " ",
     Int.toString definition_start, " (",
     case proof_ir_plan of
         NONE => ""
       | SOME plan =>
           String.concat
             ["(HolbuildProofRuntime.termination_tactic ",
              HolbuildToolchain.sml_string name, " ",
              HolbuildToolchain.sml_string tactic_text, " (", plan, ") (",
              "HolbuildTacticCompat.delay_tactic (fn () => ("]]

fun termination_tactic_suffix ({proof_ir_plan, ...} : termination) =
  case proof_ir_plan of NONE => "))" | SOME _ => "))))))"

(* With the proof runtime installed, the save is timed as its holsave. *)
fun save_declaration_context_line timed ({safe_name, context_path, context_ok, ...} : declaration_checkpoint) =
  let
    val save =
      String.concat
        ["HolbuildCheckpointSaveRuntime.save_context_checkpoint {label = ",
         HolbuildToolchain.sml_string ("definition_context:" ^ safe_name),
         ", default_share = false, path = ", HolbuildToolchain.sml_string context_path,
         ", ok_text = ", HolbuildToolchain.sml_string context_ok,
         ", depth = HolbuildRuntime.save_hierarchy_depth ()}"]
  in
    if timed then "\nval _ = HolbuildProofRuntime.timed_hol_phase \"holsave\" (fn () => " ^ save ^ ");\n"
    else "\nval _ = " ^ save ^ ";\n"
  end

fun runtime_lines lines =
  String.concat (map (fn line => line ^ "\n") lines)

(* The goal is printed from inside the Termination tactic: deriving it with a
   second Defn.Hol_defn would advance HOL's theorem numbering, so the theory
   would differ from an uninstrumented build.  A definition that fails before
   HOL runs its tactic prints no goal, so each definition first prints a start
   marker; an earlier definition's goal is then not reported for it. The end
   marker clears the goal once the definition returns successfully. *)
val termination_runtime_lines =
  ["structure HolbuildTerminationDiagnosticsRuntime = struct",
   "fun print_line text = (TextIO.output(TextIO.stdOut, text ^ \"\\n\"); TextIO.flushOut TextIO.stdOut)",
   "fun assumptions_text [] = \"\"",
   "  | assumptions_text asms = String.concat (map (fn tm => \"asm: \" ^ Parse.term_to_string tm ^ \"\\n\") asms)",
   "fun goal_text (asms, concl) = assumptions_text asms ^ \"goal: \" ^ Parse.term_to_string concl",
   "fun marker name start = String.concat [\"holbuild termination condition goal for \", name, \" at \", Int.toString start, \":\"]",
   "fun print_goal name start text = (print_line (marker name start); print_line text; print_line \"holbuild termination condition goal end\")",
   "fun begin_definition name start = print_line (String.concat [\"holbuild termination definition start for \", name, \" at \", Int.toString start])",
   "fun end_definition name start = print_line (String.concat [\"holbuild termination definition end for \", name, \" at \", Int.toString start])",
   "fun report_goal name start tac =",
   "  HolbuildTacticCompat.lift_context_tactic (fn ctxt => fn g =>",
   "    (print_goal name start (goal_text g); HolbuildTacticCompat.run_tactic ctxt tac g))",
   "end;"]

fun termination_runtime_prelude [] = ""
  | termination_runtime_prelude _ = runtime_lines termination_runtime_lines

fun option_real_sml NONE = "NONE : real option"
  | option_real_sml (SOME r) = "SOME " ^ Real.toString r

fun option_string_sml NONE = "NONE : string option"
  | option_string_sml (SOME s) = "SOME " ^ HolbuildToolchain.sml_string s

fun proof_ir_runtime_helper_path () =
  case OS.Process.getEnv "HOLBUILD_PROOF_IR_RUNTIME" of
      SOME path => path
    | NONE => OS.Path.concat(HolbuildRuntimePaths.runtime_root (), "sml/proof_runtime.sml")

fun source_helper_path relative =
  OS.Path.concat(HolbuildRuntimePaths.runtime_root (), relative)

fun sha256_runtime_helper_path () = source_helper_path "sml/sha256.sml"

fun proof_ir_helper_path () = source_helper_path "sml/proof_ir_types.sml"

fun tactic_compat_runtime_helper_path () =
  source_helper_path "sml/tactic_compat_runtime.sml"

fun checkpoint_save_runtime_helper_path () =
  OS.Path.concat(HolbuildRuntimePaths.runtime_root (), "sml/checkpoint_save_runtime.sml")

(* For a script that doesn't install the proof runtime: the save runtime
   alone, its context gate started at the build's checkpoint_seconds. *)
fun checkpoint_save_runtime_prelude checkpoint_seconds =
  runtime_lines
    ["HolbuildRuntime.use " ^ HolbuildToolchain.sml_string (checkpoint_save_runtime_helper_path ()) ^ ";",
     "val _ = HolbuildCheckpointSaveRuntime.reset_context_checkpoint_gate " ^
       Real.toString checkpoint_seconds ^ ";"]

fun runtime_install_lines {checkpoint_enabled, context_checkpoints, share_failed_prefix, checkpoint_seconds, tactic_timeout, heavy_tactic_timeout, timeout_marker, plan_theorem, trace_all, plan_only_marker, new_ir} =
  ["val _ = HolbuildProofRuntime.install {checkpoint_enabled = " ^
     (if checkpoint_enabled then "true" else "false") ^
     ", context_checkpoints = " ^ (if context_checkpoints then "true" else "false") ^
     ", share_failed_prefix = " ^ (if share_failed_prefix then "true" else "false") ^
     ", checkpoint_seconds = " ^ Real.toString checkpoint_seconds ^
     ", tactic_timeout = " ^ option_real_sml tactic_timeout ^
     ", heavy_tactic_timeout = " ^ option_real_sml heavy_tactic_timeout ^
     ", timeout_marker = " ^ option_string_sml timeout_marker ^
     ", plan_theorem = " ^ option_string_sml plan_theorem ^
     ", trace_all = " ^ (if trace_all then "true" else "false") ^
     ", plan_only_marker = " ^ option_string_sml plan_only_marker ^ "};",
   "val holbuild_begin_theorem = HolbuildProofRuntime.begin_theorem;",
   "val holbuild_save_theorem_context = HolbuildProofRuntime.save_theorem_context;"]

(* A process resuming from a heap that holds the save runtime starts its
   share of the theory's CPU time here, as loading checkpoint_save_runtime.sml
   does.  It doesn't load that file again: a second HolbuildCheckpointSaveRuntime
   would have its own context gate, apart from the one the proof runtime the
   heap holds was compiled against. *)
val resume_theory_cpu_line =
  "val _ = if Option.isSome (!HolbuildTheoryCpuState.carried) andalso \
  \Bool.not (Option.isSome (!HolbuildTheoryCpuState.since)) \
  \then HolbuildTheoryCpuState.since := SOME (HolbuildCheckpointSaveRuntime.process_cpu ()) else ();"

(* A heap saved after the proof runtime was installed (a theorem-context
   checkpoint, say) already holds it: its key includes the runtime's identity,
   so it is the same runtime, and the script only reinstalls it.  Otherwise
   the script compiles it. *)
fun runtime_prelude config =
  runtime_lines
    (("val _ = if Option.isSome (#lookupStruct PolyML.globalNameSpace \"HolbuildProofRuntime\") then () \
       \else List.app HolbuildRuntime.use [" ^
        String.concatWith ", "
          (map HolbuildToolchain.sml_string
             [source_helper_path "sml/diagnostic_limits.sml",
              sha256_runtime_helper_path (),
              proof_ir_helper_path (),
              checkpoint_save_runtime_helper_path (),
              tactic_compat_runtime_helper_path (),
              proof_ir_runtime_helper_path ()]) ^ "];") ::
     resume_theory_cpu_line ::
     runtime_install_lines config)

(* For a script resumed from a failed-prefix checkpoint, whose heap holds the
   proof runtime. *)
fun runtime_reinstall_prelude config =
  runtime_lines (resume_theory_cpu_line :: runtime_install_lines config)

(* HOL's source parser reads top-level `#(FILE="...")` and `#(LINE=...)`
   declarations as location pragmas.  Staged scripts use them so that the
   locations HOL records for theorems name the source script and its lines
   rather than the instrumented copy. *)
fun file_pragma source_name =
  "#(FILE=" ^ HolbuildToolchain.sml_string source_name ^ ")\n"

type position = {offset : int, line : int, col : int}

val start_position : position = {offset = 0, line = 1, col = 1}

(* Advance from an earlier position, so that a forward walk over the source
   stays linear in its size. *)
fun advance_position source (position as {offset, ...} : position) target =
  if target < offset then advance_position source start_position target
  else
    let
      fun loop i line col =
        if i >= target then {offset = target, line = line, col = col}
        else if String.sub(source, i) = #"\n" then loop (i + 1) (line + 1) 1
        else loop (i + 1) line (col + 1)
    in
      loop offset (#line position) (#col position)
    end

(* Emitted at the start of an output line: the text after the pragma starts
   at line and col of the source.  The pragma takes a line of its own, since
   HOL recognises declarations such as `Theory` only at the start of a line;
   for source line 1 that means claiming line 0 for the pragma. *)
fun line_pragma ({line, col, ...} : position) =
  "#(LINE=" ^ Int.toString (line - 1) ^ ")\n" ^ CharVector.tabulate(col - 1, fn _ => #" ")

fun source_line_pragma source offset =
  line_pragma (advance_position source start_position offset)

fun line_at source offset = #line (advance_position source start_position offset)

(* Placed before holbuild's own code at the top of a staged script: it numbers
   that code past the end of the source, so an error in it is not reported at
   a line of the source. *)
fun generated_code_pragma source =
  "#(LINE=" ^ Int.toString (line_at source (size source) + 1) ^ ")\n"

datatype instrument_event =
  CheckpointEvent of checkpoint
| DeclarationCheckpointEvent of declaration_checkpoint
| TerminationEvent of termination

(* How a pipelined build runs a theorem's or `Resume` block's proof (see
   HolbuildDeferred): in place, deferred alone, or deferred with the
   `Resume` blocks of the theorem, given the labels they resume and how
   many there are, as the block THEOREM[LABEL] of that group. *)
datatype deferral =
  Inline
| Defer
| DeferGroup of {labels : string list, resumes : int}
| DeferResume of {theorem : string, label : string}

(* DEFER: how a pipelined build runs a theorem's proof.  A deferred proof
   keeps its precompiled steps (its factories), so no step is compiled
   after the script has run, where later bindings would shadow the
   theorem's; a theorem without them is not deferred, nor is a group with
   a block without them (build_exec's checkpoint_deferral). *)
fun instrument ({source, source_name, start_offset, checkpoints, declaration_checkpoints, terminations, save_checkpoints, context_checkpoints, share_failed_prefix, checkpoint_seconds, tactic_timeout, heavy_tactic_timeout, timeout_marker, plan_theorem, trace_all, plan_only_marker, new_ir, runtime_installed, defer} :
                {source : string, source_name : string, start_offset : int, checkpoints : checkpoint list,
                 declaration_checkpoints : declaration_checkpoint list,
                 terminations : termination list, save_checkpoints : bool,
                 context_checkpoints : bool, share_failed_prefix : bool,
                 checkpoint_seconds : real,
                 tactic_timeout : real option, heavy_tactic_timeout : real option,
                 timeout_marker : string option,
                 plan_theorem : string option, trace_all : bool,
                 plan_only_marker : string option, new_ir : bool,
                 runtime_installed : bool,
                 defer : checkpoint -> deferral}) =
  let
    val n = size source
    val deferred = ref 0
    fun one_line text = String.map (fn #"\n" => #" " | c => c) text
    fun source_slice i j = String.substring(source, i, j - i)
    fun active_checkpoint ({boundary, ...} : checkpoint) = boundary > start_offset
    fun active_declaration_checkpoint ({boundary, ...} : declaration_checkpoint) = boundary > start_offset
    fun active_termination ({definition_start, ...} : termination) = definition_start >= start_offset
    val active_checkpoints = List.filter active_checkpoint checkpoints
    val active_declaration_checkpoints = List.filter active_declaration_checkpoint declaration_checkpoints
    val active_terminations = List.filter active_termination terminations
    fun event_start (CheckpointEvent ({theorem_start, ...} : checkpoint)) = theorem_start
      | event_start (DeclarationCheckpointEvent ({boundary, ...} : declaration_checkpoint)) = boundary
      | event_start (TerminationEvent ({definition_start, ...} : termination)) = definition_start
    fun insert_event event [] = [event]
      | insert_event event (current :: rest) =
          if event_start event <= event_start current then event :: current :: rest
          else current :: insert_event event rest
    fun sorted_events () =
      List.foldl (fn (event, events) => insert_event event events) []
        (map CheckpointEvent active_checkpoints @
         map DeclarationCheckpointEvent active_declaration_checkpoints @
         map TerminationEvent active_terminations)
    fun runtime_config () =
      {checkpoint_enabled = save_checkpoints,
       context_checkpoints = context_checkpoints,
       share_failed_prefix = share_failed_prefix,
       checkpoint_seconds = checkpoint_seconds,
       tactic_timeout = tactic_timeout,
       heavy_tactic_timeout = heavy_tactic_timeout,
       timeout_marker = timeout_marker,
       plan_theorem = plan_theorem,
       trace_all = trace_all,
       plan_only_marker = plan_only_marker,
       new_ir = new_ir}
    (* A resumed script loads the checkpoint runtime even with no checkpoint
       left to save: it carries the theory's CPU time over from the checkpoint. *)
    val proof_runtime = not (null active_checkpoints andalso null active_terminations)
    fun prelude () =
      (if not proof_runtime then
         if start_offset > 0 orelse not (null active_declaration_checkpoints)
         then checkpoint_save_runtime_prelude checkpoint_seconds else ""
       else if runtime_installed then ""
       else runtime_prelude (runtime_config ())) ^
      termination_runtime_prelude active_terminations
    val position = ref start_position
    fun resume_at offset =
      (position := advance_position source (!position) offset;
       line_pragma (!position))
    fun loop pos events acc =
      case events of
          [] => String.concat (rev (source_slice pos n :: acc))
        | CheckpointEvent (checkpoint as {theorem_start, boundary, tactic_start, tactic_end, ...}) :: rest =>
            if boundary <= start_offset then loop pos rest acc
            else
              let
                val theorem_pragma = resume_at theorem_start
                val boundary_pragma = resume_at boundary
                fun factories_suffix factories =
                  ")) (let\n" ^ generated_code_pragma source ^ "in " ^ factories ^ " end)"
                fun emit setup opening closing after =
                  loop boundary rest
                    (boundary_pragma ::
                     after ::
                     "\n" ::
                     source_slice tactic_end boundary ::
                     closing ::
                     source_slice tactic_start tactic_end ::
                     opening ::
                     source_slice theorem_start tactic_start ::
                     theorem_pragma ::
                     setup ::
                     source_slice pos theorem_start ::
                     acc)
                fun next () = let val k = !deferred in deferred := k + 1; Int.toString k end
                fun inline () =
                  let
                    val factories =
                      if null (#proof_attrs checkpoint) then "NONE"
                      else case #proof_ir_factories checkpoint of
                               NONE => "NONE"
                             | SOME code => "SOME (" ^ code ^ ")"
                  in
                    emit (begin_theorem_line checkpoint)
                         "HolbuildProofRuntime.proof_ir_tactic (fn () => ("
                         (factories_suffix factories)
                         "val _ = holbuild_save_theorem_context();\n"
                  end
              in
                case (defer checkpoint, #proof_ir_factories checkpoint) of
                    (Inline, _) => inline ()
                  | (_, NONE) => inline ()
                  | (deferral, SOME code) =>
                      (* The runtime learns which theorem it proves when
                         the proof runs (`begin_theorem` inside the setup
                         thunk), written on one line so the tactic keeps
                         its own lines. *)
                      emit ""
                           (String.concat
                              [case deferral of
                                   DeferGroup {labels, resumes} =>
                                     String.concatWith " "
                                       ["HolbuildDeferred.defer_group_steps", next (),
                                        HolbuildToolchain.sml_string (#name checkpoint),
                                        HolbuildToolchain.sml_list labels, Int.toString resumes]
                                 | DeferResume {theorem, label} =>
                                     String.concatWith " "
                                       ["HolbuildDeferred.defer_resume_steps",
                                        HolbuildToolchain.sml_string theorem, HolbuildToolchain.sml_string label]
                                 | _ =>
                                     String.concatWith " "
                                       ["HolbuildDeferred.defer_steps", next (),
                                        HolbuildToolchain.sml_string (#name checkpoint)],
                               " (fn () => let ", one_line (begin_theorem_line checkpoint),
                               "in () end) (fn () => HolbuildProofRuntime.proof_ir_tactic (fn () => ("])
                           (factories_suffix ("SOME (" ^ code ^ ")") ^ ")")
                           ""
              end
        | DeclarationCheckpointEvent (declaration_checkpoint as {boundary, ...}) :: rest =>
            if boundary <= start_offset orelse boundary < pos then loop pos rest acc
            else
              loop boundary rest
                (resume_at boundary ::
                 save_declaration_context_line proof_runtime declaration_checkpoint ::
                 source_slice pos boundary ::
                 acc)
        | TerminationEvent (termination as {definition_start, boundary, tactic_start, tactic_end, ...}) :: rest =>
            if definition_start < pos then loop pos rest acc
            else
              let
                val definition_pragma = resume_at definition_start
                val boundary_pragma = resume_at boundary
              in
                loop boundary rest
                (boundary_pragma ::
                 end_termination_line termination ::
                 source_slice tactic_end boundary ::
                 termination_tactic_suffix termination ::
                 source_slice tactic_start tactic_end ::
                 termination_tactic_prefix termination ::
                 source_slice definition_start tactic_start ::
                 definition_pragma ::
                 begin_termination_line termination ::
                 source_slice pos definition_start ::
                 acc)
              end
    val prelude_text = prelude ()
    val start_pragma = resume_at start_offset
  in
    String.concat [generated_code_pragma source, prelude_text, file_pragma source_name, start_pragma,
                   loop start_offset (sorted_events ()) []]
  end

end
