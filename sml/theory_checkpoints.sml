structure HolbuildTheoryCheckpoints =
struct

exception Error of string

type boundary = {kind : string, name : string, safe_name : string, theorem_start : int,
                 theorem_stop : int, boundary : int, tactic_start : int,
                 tactic_end : int, tactic_text : string,
                 has_proof_attrs : bool, prefix_hash : string}
type checkpoint = {kind : string, name : string, safe_name : string, theorem_start : int,
                   theorem_stop : int, boundary : int, tactic_start : int,
                   tactic_end : int, tactic_text : string,
                   has_proof_attrs : bool, prefix_hash : string,
                   context_path : string, context_ok : string,
                   end_of_proof_path : string, end_of_proof_ok : string,
                   failed_prefix_path : string, failed_prefix_ok : string,
                   deps_key : string, checkpoint_key : string,
                   proof_ir_plan : string option}

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

fun parse_int field value =
  case Int.fromString value of
      SOME n => n
    | NONE => raise Error ("bad AST theorem report integer for " ^ field ^ ": " ^ value)

fun slice text start stop =
  if start < 0 orelse stop < start orelse stop > size text then
    raise Error "AST theorem report span is outside source text"
  else String.substring(text, start, stop - start)

fun boundary_from_report_line source line =
  case String.tokens (fn c => c = #"\t") line of
      [kind, name, theorem_start_s, theorem_stop_s,
       tactic_start_s, tactic_end_s, attrs_s] =>
        let
          val _ = if kind = "theorem" orelse kind = "resume" then ()
                  else raise Error ("bad AST proof-unit kind: " ^ kind)
          val theorem_start = parse_int "theorem_start" theorem_start_s
          val theorem_stop = parse_int "theorem_stop" theorem_stop_s
          val tactic_start = parse_int "tactic_start" tactic_start_s
          val tactic_end = parse_int "tactic_end" tactic_end_s
          val boundary = statement_boundary source theorem_stop
        in
          {kind = kind, name = name, safe_name = safe_name name,
           theorem_start = theorem_start, theorem_stop = theorem_stop,
           boundary = boundary, tactic_start = tactic_start, tactic_end = tactic_end,
           tactic_text = slice source tactic_start tactic_end,
           has_proof_attrs = attrs_s = "1",
           prefix_hash = prefix_hash source boundary}
        end
    | [] => raise Error "empty AST theorem report line"
    | _ => raise Error ("bad AST theorem report line: " ^ line)

fun discover_from_report {source, report} : boundary list =
  map (boundary_from_report_line source)
      (List.filter (fn line => line <> "")
                   (String.tokens (fn c => c = #"\n") report))

fun begin_theorem_line ({kind, name, tactic_text, context_path, context_ok,
                         end_of_proof_path, end_of_proof_ok,
                         failed_prefix_path, failed_prefix_ok,
                         has_proof_attrs, proof_ir_plan, ...} : checkpoint) =
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
     HolbuildToolchain.sml_string end_of_proof_path, ", ",
     HolbuildToolchain.sml_string end_of_proof_ok, ", ",
     HolbuildToolchain.sml_string failed_prefix_path, ", ",
     HolbuildToolchain.sml_string failed_prefix_ok, ", ",
     if has_proof_attrs then "true" else "false",
     ");\n"]

fun begin_termination_line ({name, definition_start, ...} : termination) =
  String.concat
    ["val _ = HolbuildTerminationDiagnosticsRuntime.begin_definition ",
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
              HolbuildToolchain.sml_string tactic_text, " (", plan, ") ("]]

fun termination_tactic_suffix ({proof_ir_plan, ...} : termination) =
  case proof_ir_plan of NONE => "))" | SOME _ => "))))"

fun save_declaration_context_line ({safe_name, context_path, context_ok, ...} : declaration_checkpoint) =
  String.concat
    ["\nval _ = HolbuildCheckpointSaveRuntime.save_checkpoint {label = ",
     HolbuildToolchain.sml_string ("definition_context:" ^ safe_name),
     ", default_share = false, path = ", HolbuildToolchain.sml_string context_path,
     ", ok_text = ", HolbuildToolchain.sml_string context_ok,
     ", depth = HolbuildRuntime.save_hierarchy_depth ()};\n"]

fun runtime_lines lines =
  String.concat (map (fn line => line ^ "\n") lines)

val runtime_load_lines = []

(* The goal is printed from inside the Termination tactic: deriving it with a
   second Defn.Hol_defn would advance HOL's theorem numbering, so the theory
   would differ from an uninstrumented build.  A definition that fails before
   HOL runs its tactic prints no goal, so each definition first prints a start
   marker; an earlier definition's goal is then not reported for it. *)
val termination_runtime_lines =
  ["structure HolbuildTerminationDiagnosticsRuntime = struct",
   "fun print_line text = (TextIO.output(TextIO.stdOut, text ^ \"\\n\"); TextIO.flushOut TextIO.stdOut)",
   "fun assumptions_text [] = \"\"",
   "  | assumptions_text asms = String.concat (map (fn tm => \"asm: \" ^ Parse.term_to_string tm ^ \"\\n\") asms)",
   "fun goal_text (asms, concl) = assumptions_text asms ^ \"goal: \" ^ Parse.term_to_string concl",
   "fun marker name start = String.concat [\"holbuild termination condition goal for \", name, \" at \", Int.toString start, \":\"]",
   "fun print_goal name start text = (print_line (marker name start); print_line text; print_line \"holbuild termination condition goal end\")",
   "fun begin_definition name start = print_line (String.concat [\"holbuild termination definition start for \", name, \" at \", Int.toString start])",
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
    | NONE => OS.Path.concat(HolbuildRuntimePaths.source_root, "sml/proof_runtime.sml")

fun source_helper_path relative =
  OS.Path.concat(HolbuildRuntimePaths.source_root, relative)

fun string_hash_runtime_helper_path () = source_helper_path "sml/string_hash.sml"

fun proof_ir_helper_path () = source_helper_path "sml/proof_ir_types.sml"

fun tactic_compat_runtime_helper_path () =
  source_helper_path "sml/tactic_compat_runtime.sml"

fun checkpoint_save_runtime_helper_path () =
  OS.Path.concat(HolbuildRuntimePaths.source_root, "sml/checkpoint_save_runtime.sml")

fun declaration_checkpoint_runtime_prelude [] = ""
  | declaration_checkpoint_runtime_prelude _ =
      runtime_lines ["HolbuildRuntime.use " ^ HolbuildToolchain.sml_string (checkpoint_save_runtime_helper_path ()) ^ ";"]

fun runtime_install_lines {checkpoint_enabled, tactic_timeout, timeout_marker, plan_theorem, trace_all, plan_only_marker, new_ir} =
  ["HolbuildRuntime.use " ^ HolbuildToolchain.sml_string (string_hash_runtime_helper_path ()) ^ ";",
   "HolbuildRuntime.use " ^ HolbuildToolchain.sml_string (proof_ir_helper_path ()) ^ ";",
   "HolbuildRuntime.use " ^ HolbuildToolchain.sml_string (checkpoint_save_runtime_helper_path ()) ^ ";",
   "HolbuildRuntime.use " ^ HolbuildToolchain.sml_string (tactic_compat_runtime_helper_path ()) ^ ";",
   "HolbuildRuntime.use " ^ HolbuildToolchain.sml_string (proof_ir_runtime_helper_path ()) ^ ";",
   "val _ = HolbuildProofRuntime.install {checkpoint_enabled = " ^
     (if checkpoint_enabled then "true" else "false") ^
     ", tactic_timeout = " ^ option_real_sml tactic_timeout ^
     ", timeout_marker = " ^ option_string_sml timeout_marker ^
     ", plan_theorem = " ^ option_string_sml plan_theorem ^
     ", trace_all = " ^ (if trace_all then "true" else "false") ^
     ", plan_only_marker = " ^ option_string_sml plan_only_marker ^ "};",
   "val holbuild_begin_theorem = HolbuildProofRuntime.begin_theorem;",
   "val holbuild_save_theorem_context = HolbuildProofRuntime.save_theorem_context;"]


fun runtime_prelude _ [] = ""
  | runtime_prelude config _ = runtime_lines (runtime_load_lines @ runtime_install_lines config)

fun runtime_reinstall_prelude {checkpoint_enabled, tactic_timeout, timeout_marker, plan_theorem, trace_all, plan_only_marker, new_ir} =
  let
    val install =
      ["HolbuildRuntime.use " ^ HolbuildToolchain.sml_string (checkpoint_save_runtime_helper_path ()) ^ ";",
       "val _ = HolbuildProofRuntime.install {checkpoint_enabled = " ^
         (if checkpoint_enabled then "true" else "false") ^
         ", tactic_timeout = " ^ option_real_sml tactic_timeout ^
         ", timeout_marker = " ^ option_string_sml timeout_marker ^
         ", plan_theorem = " ^ option_string_sml plan_theorem ^
         ", trace_all = " ^ (if trace_all then "true" else "false") ^
         ", plan_only_marker = " ^ option_string_sml plan_only_marker ^ "};",
       "val holbuild_begin_theorem = HolbuildProofRuntime.begin_theorem;",
       "val holbuild_save_theorem_context = HolbuildProofRuntime.save_theorem_context;"]
  in
    runtime_lines install
  end

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

fun instrument ({source, source_name, start_offset, checkpoints, declaration_checkpoints, terminations, save_checkpoints, tactic_timeout, timeout_marker, plan_theorem, trace_all, plan_only_marker, new_ir} :
                {source : string, source_name : string, start_offset : int, checkpoints : checkpoint list,
                 declaration_checkpoints : declaration_checkpoint list,
                 terminations : termination list, save_checkpoints : bool,
                 tactic_timeout : real option, timeout_marker : string option,
                 plan_theorem : string option, trace_all : bool,
                 plan_only_marker : string option, new_ir : bool}) =
  let
    val n = size source
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
       tactic_timeout = tactic_timeout,
       timeout_marker = timeout_marker,
       plan_theorem = plan_theorem,
       trace_all = trace_all,
       plan_only_marker = plan_only_marker,
       new_ir = new_ir}
    fun prelude () =
      runtime_prelude (runtime_config ())
        (if null active_checkpoints andalso null active_terminations then [] else [()]) ^
      declaration_checkpoint_runtime_prelude
        (if null active_checkpoints andalso null active_terminations then active_declaration_checkpoints else []) ^
      termination_runtime_prelude active_terminations
    val position = ref start_position
    fun resume_at offset =
      (position := advance_position source (!position) offset;
       line_pragma (!position))
    fun loop pos events acc =
      case events of
          [] => String.concat (rev (source_slice pos n :: acc))
        | CheckpointEvent (checkpoint as {theorem_start, boundary, ...}) :: rest =>
            if boundary <= start_offset then loop pos rest acc
            else
              let
                val theorem_pragma = resume_at theorem_start
                val boundary_pragma = resume_at boundary
              in
                loop boundary rest
                  (boundary_pragma ::
                   "val _ = holbuild_save_theorem_context();\n" ::
                   "\n" ::
                   source_slice theorem_start boundary ::
                   theorem_pragma ::
                   begin_theorem_line checkpoint ::
                   source_slice pos theorem_start ::
                   acc)
              end
        | DeclarationCheckpointEvent (declaration_checkpoint as {boundary, ...}) :: rest =>
            if boundary <= start_offset orelse boundary < pos then loop pos rest acc
            else
              loop boundary rest
                (resume_at boundary ::
                 save_declaration_context_line declaration_checkpoint ::
                 source_slice pos boundary ::
                 acc)
        | TerminationEvent (termination as {definition_start, tactic_start, tactic_end, ...}) :: rest =>
            if definition_start < pos then loop pos rest acc
            else
              loop tactic_end rest
                (termination_tactic_suffix termination ::
                 source_slice tactic_start tactic_end ::
                 termination_tactic_prefix termination ::
                 source_slice definition_start tactic_start ::
                 resume_at definition_start ::
                 begin_termination_line termination ::
                 source_slice pos definition_start ::
                 acc)
    val prelude_text = prelude ()
    val start_pragma = resume_at start_offset
  in
    String.concat [generated_code_pragma source, prelude_text, file_pragma source_name, start_pragma,
                   loop start_offset (sorted_events ()) []]
  end

end
