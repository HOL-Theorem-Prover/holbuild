structure HolbuildStatus =
struct

datatype outcome = Built | UpToDate | Restored | Inspected

type active_node = {key : string, label : string, started_at : Time.time}

type t = {
  enabled : bool,
  total : int,
  jobs : int,
  width : int option ref,
  width_checked_at : Time.time ref,
  finished : int ref,
  built : int ref,
  up_to_date : int ref,
  restored : int ref,
  active : active_node list ref,
  started_at : Time.time,
  ended : bool ref,
  mutex : Mutex.mutex
}

val current_status : t option ref = ref NONE
val json_mode_ref = ref false
datatype verbosity = Quiet | Normal | Verbose

val verbosity_ref = ref Normal
val retain_debug_artifacts_ref = ref false
val json_mutex = Mutex.mutex ()

type debug_artifacts = {log : string option}

val no_debug_artifacts : debug_artifacts = {log = NONE}

val clear_to_eol = "\027[0K"

fun set_json_mode enabled = json_mode_ref := enabled
fun json_mode () = !json_mode_ref
fun set_verbosity verbosity = verbosity_ref := verbosity
fun set_verbose_mode enabled = set_verbosity (if enabled then Verbose else Normal)
fun verbosity () = !verbosity_ref
fun verbose_mode () = verbosity () = Verbose
fun quiet_mode () = verbosity () = Quiet
fun set_retain_debug_artifacts enabled = retain_debug_artifacts_ref := enabled
fun retain_debug_artifacts () = !retain_debug_artifacts_ref

fun hex_digit n =
  String.sub("0123456789abcdef", n)

fun unicode_escape code =
  String.implode [#"\\", #"u", #"0", #"0", hex_digit (code div 16), hex_digit (code mod 16)]

fun json_escape s =
  String.translate
    (fn #"\\" => "\\\\"
      | #"\"" => "\\\""
      | #"\n" => "\\n"
      | #"\r" => "\\r"
      | #"\t" => "\\t"
      | #"\b" => "\\b"
      | #"\f" => "\\f"
      | c => if Char.ord c < 32 then unicode_escape (Char.ord c) else String.str c)
    s

fun json_string_field name value =
  "\"" ^ name ^ "\":\"" ^ json_escape value ^ "\""

fun json_int_field name value =
  "\"" ^ name ^ "\":" ^ Int.toString value

fun json_bool_field name value =
  "\"" ^ name ^ "\":" ^ (if value then "true" else "false")

fun json_object_field name fields =
  "\"" ^ name ^ "\":{" ^ String.concatWith "," fields ^ "}"

fun json_optional_string_field name value =
  case value of
      NONE => []
    | SOME text => [json_string_field name text]

fun json_optional_int_field name value =
  case value of
      NONE => []
    | SOME n => [json_int_field name n]

fun json_optional_bool_field name value =
  case value of
      NONE => []
    | SOME b => [json_bool_field name b]

fun json_debug_artifacts_fields ({log} : debug_artifacts) =
  let val fields = json_optional_string_field "log" log
  in if null fields then [] else [json_object_field "debug_artifacts" fields] end

fun debug_artifacts_empty artifacts = null (json_debug_artifacts_fields artifacts)

fun short_hash text = String.substring(HolbuildHash.string_sha1 text, 0, 12)

fun json_node_key key label = label ^ "#" ^ short_hash key

fun json_node_package_source key =
  case String.fields (fn c => c = #"\000") key of
      [package, source, _] => SOME {package = package, source = source}
    | _ => NONE

fun json_node_metadata key =
  case json_node_package_source key of
      SOME {package, source} =>
        json_optional_string_field "package" (SOME package) @
        json_optional_string_field "source" (SOME source)
    | NONE => []

fun json_node_source key = Option.map #source (json_node_package_source key)

fun json_node_fields key label =
  [json_string_field "key" (json_node_key key label),
   json_string_field "target" label] @
  json_node_metadata key

fun find_substring needle haystack =
  let
    val n = size needle
    val h = size haystack
    fun at i = i + n <= h andalso String.substring(haystack, i, n) = needle
    fun loop i = if i + n > h then NONE else if at i then SOME i else loop (i + 1)
  in
    if n = 0 then NONE else loop 0
  end

fun parse_decimal_prefix text start =
  let
    val n = size text
    fun scan i =
      if i < n andalso Char.isDigit (String.sub(text, i)) then scan (i + 1) else i
    val stop = scan start
  in
    if stop = start then NONE
    else Int.fromString (String.substring(text, start, stop - start))
  end

fun first_some f values =
  case values of
      [] => NONE
    | x :: xs =>
        case f x of
            SOME y => SOME y
          | NONE => first_some f xs

fun line_after prefix line =
  if String.isPrefix prefix line then SOME (String.extract(line, size prefix, NONE)) else NONE

fun first_line_after prefix lines = first_some (line_after prefix) lines

fun take_before marker text =
  case find_substring marker text of
      NONE => text
    | SOME i => String.substring(text, 0, i)

fun failure_kind message =
  if String.isSubstring "tactic timed out" message then "tactic_timeout"
  else if String.isSubstring "termination condition goal" message orelse
          String.isSubstring "\ntermination: " message orelse String.isPrefix "termination: " message then
    "termination_failure"
  else if String.isSubstring "HOL source parse error" message orelse
          String.isSubstring ": parse error:" message then
    "parse_error"
  else if String.isSubstring "static error:" message orelse String.isSubstring ": error:" message then
    "type_error"
  else if String.isSubstring "failed tactic top input goal:" message orelse
          String.isSubstring "\ntheorem: " message orelse String.isPrefix "theorem: " message orelse
          String.isSubstring "\nplan position: " message then
    "proof_failure"
  else if String.isSubstring "child failure:" message orelse
          String.isSubstring "child log:" message orelse
          String.isSubstring "Couldn't load HOL base-state" message orelse
          String.isSubstring "Uncaught exception" message then
    "child_failure"
  else "unknown"

fun theorem_from_lines lines =
  Option.map (fn text => take_before " (line " text)
             (first_line_after "theorem: " lines)

fun plan_position_from_lines lines = first_line_after "plan position: " lines

fun input_goal_count_from_lines lines =
  Option.mapPartial (fn text => parse_decimal_prefix text 0)
                    (first_line_after "failed tactic input goals: " lines)

val top_goal_preview_prefix = "top goal exceeded 4 KiB; showing first "

fun top_goal_truncated message =
  if String.isSubstring top_goal_preview_prefix message then SOME true else NONE

fun top_goal_preview_bytes message =
  case find_substring top_goal_preview_prefix message of
      NONE => NONE
    | SOME i => parse_decimal_prefix message (i + size top_goal_preview_prefix)

fun json_evidence_limit_fields message =
  case top_goal_truncated message of
      SOME true =>
        json_optional_int_field "top_goal_preview_bytes" (top_goal_preview_bytes message) @
        [json_string_field "evidence_mode" "preview_only"]
    | _ => []

fun source_location_from_line line =
  case line_after "source: " line of
      NONE => NONE
    | SOME rest =>
        let
          val n = size rest
          fun scan i =
            if i >= n then NONE
            else if String.sub(rest, i) = #":" then
              case parse_decimal_prefix rest (i + 1) of
                  SOME line_no => SOME {file = String.substring(rest, 0, i), line = line_no}
                | NONE => scan (i + 1)
            else scan (i + 1)
        in
          scan 0
        end

fun source_location_from_lines lines = first_some source_location_from_line lines

fun json_failure_fields source_override message =
  let
    val lines = String.fields (fn c => c = #"\n") message
    val source_location = source_location_from_lines lines
    val source_file =
      case source_override of
          SOME source => SOME source
        | NONE => Option.map #file source_location
    val source_line = Option.map #line source_location
  in
    [json_string_field "kind" (failure_kind message)] @
    json_optional_string_field "theorem" (theorem_from_lines lines) @
    json_optional_string_field "source_file" source_file @
    json_optional_int_field "source_line" source_line @
    json_optional_string_field "plan_position" (plan_position_from_lines lines) @
    json_optional_int_field "input_goal_count" (input_goal_count_from_lines lines) @
    json_optional_bool_field "top_goal_truncated" (top_goal_truncated message) @
    json_evidence_limit_fields message
  end

fun json_failure_field message = [json_object_field "failure" (json_failure_fields NONE message)]
fun json_failure_field_for_node key message =
  [json_object_field "failure" (json_failure_fields (json_node_source key) message)]

fun json_fields fields = "{" ^ String.concatWith "," fields ^ "}\n"

fun emit_json event fields =
  (Mutex.lock json_mutex;
   (TextIO.output(TextIO.stdOut, json_fields (json_string_field "event" event :: fields));
    TextIO.flushOut TextIO.stdOut)
   before Mutex.unlock json_mutex)
  handle e => (Mutex.unlock json_mutex; raise e)

fun json_message stream_name text =
  emit_json "message"
    [json_string_field "stream" stream_name,
     json_string_field "message" text]

fun error_with_debug_artifacts msg artifacts =
  emit_json "error"
    (json_string_field "message" msg ::
     json_failure_field msg @
     json_debug_artifacts_fields artifacts)

fun error msg = error_with_debug_artifacts msg no_debug_artifacts

fun env_truthy s = s = "1" orelse s = "true" orelse s = "yes" orelse s = "on"
fun env_falsey s = s = "0" orelse s = "false" orelse s = "no" orelse s = "off"

fun env_status () =
  case OS.Process.getEnv "HOLBUILD_STATUS" of
      NONE => NONE
    | SOME s =>
        let val lower = String.map Char.toLower s
        in
          if env_truthy lower then SOME true
          else if env_falsey lower then SOME false
          else NONE
        end

fun ansi_stdout () = terminal_primitives.strmIsTTY TextIO.stdOut andalso terminal_primitives.TERM_isANSI ()

fun enabled_by_default () =
  if json_mode () then false
  else
    case env_status () of
        SOME b => b
      | NONE => ansi_stdout ()

fun positive_int s =
  case Int.fromString s of
      SOME n => if n > 0 then SOME n else NONE
    | NONE => NONE

fun shell_output command =
  let
    val proc = Unix.execute ("/bin/sh", ["-c", command])
    val output = TextIO.inputAll (Unix.textInstreamOf proc)
  in
    if OS.Process.isSuccess (Unix.reap proc) then SOME output else NONE
  end
  handle OS.SysErr _ => NONE

fun first_positive_int text =
  let
    fun first words =
      case words of
          [] => NONE
        | word :: rest =>
            (case positive_int word of
                 SOME n => SOME n
               | NONE => first rest)
  in
    first (String.tokens Char.isSpace text)
  end

fun stty_width () =
  Option.mapPartial first_positive_int
    (shell_output "stty size < /dev/tty 2>/dev/null | awk '{print $2}'")

fun tput_width () =
  Option.mapPartial first_positive_int (shell_output "tput cols 2>/dev/null")

fun env_width () = Option.mapPartial positive_int (OS.Process.getEnv "COLUMNS")

fun terminal_width () =
  if terminal_primitives.strmIsTTY TextIO.stdOut then
    case stty_width () of
        SOME width => SOME width
      | NONE => (case tput_width () of SOME width => SOME width | NONE => env_width ())
  else
    env_width ()

fun outcome_text Built = "built"
  | outcome_text UpToDate = "is up to date"
  | outcome_text Restored = "restored from cache"
  | outcome_text Inspected = "inspected"

fun count_outcome ({built, up_to_date, restored, ...} : t) outcome =
  case outcome of
      Built => built := !built + 1
    | UpToDate => up_to_date := !up_to_date + 1
    | Restored => restored := !restored + 1
    | Inspected => ()

fun elapsed ({started_at, ...} : t) = Time.-(Time.now (), started_at)

fun elapsed_seconds_text status = Real.fmt (StringCvt.FIX (SOME 3)) (Time.toReal (elapsed status)) ^ "s"

fun elapsed_ms status = Real.round (Time.toReal (elapsed status) * 1000.0)

fun remove_active key active = List.filter (fn {key = k, ...} => k <> key) active

fun find_active key active = List.find (fn {key = k, ...} => k = key) active

fun active_labels active = map (fn {label, ...} => label) active

fun active_elapsed_text NONE = ""
  | active_elapsed_text (SOME {started_at, ...}) =
      " in " ^ Real.fmt (StringCvt.FIX (SOME 3))
        (Time.toReal (Time.-(Time.now (), started_at))) ^ "s"

fun line ({total, jobs, finished, built, up_to_date, restored, active, ...} : t) =
  let
    val running = active_labels (!active)
    val prefix =
      String.concat
        ["holbuild done=", Int.toString (!finished), "/", Int.toString total,
         " running=", Int.toString (length running), "/", Int.toString jobs,
         " built=", Int.toString (!built),
         " from_cache=", Int.toString (!restored),
         " unchanged=", Int.toString (!up_to_date)]
  in
    case running of
        [] => prefix
      | _ => prefix ^ " :: " ^ String.concatWith ", " running
  end

fun final_line status = line status ^ " elapsed=" ^ elapsed_seconds_text status

fun finish_text status = "holbuild finished in " ^ elapsed_seconds_text status ^ "\n"

fun fit width s =
  case width of
      NONE => s
    | SOME columns =>
        if size s <= columns then s
        else if columns <= 3 then ""
        else String.substring (s, 0, columns - 3) ^ "..."

val width_refresh_seconds = 0.5

fun refresh_width_if_stale ({width, width_checked_at, ...} : t) =
  let
    val now = Time.now ()
    val age = Time.toReal (Time.-(now, !width_checked_at))
  in
    if age >= width_refresh_seconds then
      (width := terminal_width (); width_checked_at := now)
    else ()
  end

fun redraw (status as {enabled, ended, width, ...} : t) =
  if not enabled orelse !ended then ()
  else
    (refresh_width_if_stale status;
     TextIO.output (TextIO.stdOut, "\r" ^ fit (!width) (line status) ^ clear_to_eol);
     TextIO.flushOut TextIO.stdOut)

fun with_lock ({mutex, ...} : t) f =
  (Mutex.lock mutex; f () before Mutex.unlock mutex)
  handle e => (Mutex.unlock mutex; raise e)

fun create {total, jobs} =
  let
    val status =
      {enabled = enabled_by_default (),
       total = total,
       jobs = jobs,
       width = ref (terminal_width ()),
       width_checked_at = ref (Time.now ()),
       finished = ref 0,
       built = ref 0,
       up_to_date = ref 0,
       restored = ref 0,
       active = ref [],
       started_at = Time.now (),
       ended = ref false,
       mutex = Mutex.mutex ()}
  in
    current_status := SOME status;
    status
  end

fun start_node status key label =
  with_lock status
    (fn () =>
        let val {enabled, active, ended, ...} = status
        in
          if !ended then ()
          else
            (active := {key = key, label = label, started_at = Time.now ()} :: remove_active key (!active);
             if json_mode () then
               emit_json "node_started" (json_node_fields key label)
             else if enabled then redraw status
             else if verbose_mode () then
               (TextIO.output (TextIO.stdOut, label ^ " started\n");
                TextIO.flushOut TextIO.stdOut)
             else ())
        end)

fun finish_node status key label outcome =
  with_lock status
    (fn () =>
        let
          val {enabled, total, finished, active, ended, ...} = status
          val elapsed = active_elapsed_text (find_active key (!active))
        in
          if !ended then ()
          else
            (finished := !finished + 1;
             count_outcome status outcome;
             active := remove_active key (!active);
             if json_mode () then
               emit_json "node_finished"
                 (json_node_fields key label @
                  [json_string_field "outcome" (outcome_text outcome),
                   json_int_field "finished" (!finished),
                   json_int_field "total" total])
             else if enabled then redraw status
             else if quiet_mode () then ()
             else if outcome = UpToDate andalso not (verbose_mode ()) then ()
             else
               (TextIO.output (TextIO.stdOut,
                  label ^ " " ^ outcome_text outcome ^
                  (if verbose_mode () then elapsed else "") ^ "\n");
                TextIO.flushOut TextIO.stdOut))
        end)

fun finish status =
  (with_lock status
     (fn () =>
         let val {enabled, ended, total, finished, built, restored, up_to_date, ...} = status
         in
           if !ended then ()
           else
             (if json_mode () then
                emit_json "build_finished"
                  [json_int_field "elapsed_ms" (elapsed_ms status),
                   json_int_field "total" total,
                   json_int_field "built" (!built),
                   json_int_field "from_cache" (!restored),
                   json_int_field "unchanged" (!up_to_date)]
              else if enabled then
                (TextIO.output (TextIO.stdOut, "\r" ^ fit (!(#width status)) (final_line status) ^ clear_to_eol ^ "\n");
                 TextIO.flushOut TextIO.stdOut)
              else if !finished = total then
                (TextIO.output (TextIO.stdOut, finish_text status); TextIO.flushOut TextIO.stdOut)
              else ();
              ended := true)
         end);
   current_status := NONE)

fun message_to stream_name stream text =
  if json_mode () then json_message stream_name text
  else
    case !current_status of
        NONE => (TextIO.output (stream, text); TextIO.flushOut stream)
      | SOME status =>
          with_lock status
            (fn () =>
                let val {enabled, ended, ...} = status
                in
                  if enabled andalso not (!ended) then
                    (TextIO.output (TextIO.stdOut, "\r" ^ clear_to_eol);
                     TextIO.flushOut TextIO.stdOut;
                     TextIO.output (stream, text);
                     TextIO.flushOut stream;
                     redraw status)
                  else
                    (TextIO.output (stream, text); TextIO.flushOut stream)
                end)

fun message_stdout text = message_to "stdout" TextIO.stdOut text
fun message_stderr text = message_to "stderr" TextIO.stdErr text
fun message stream text = message_to "stdout" stream text

fun cache_trace_enabled () =
  case OS.Process.getEnv "HOLBUILD_CACHE_TRACE" of
      SOME s => s = "1" orelse s = "true" orelse s = "yes"
    | NONE => false

fun cache_trace line =
  if cache_trace_enabled () then message_stdout (line ^ "\n") else ()

fun fail_with_debug_artifacts status key label msg artifacts =
  (with_lock status
     (fn () =>
         let val {enabled, active, ended, ...} = status
         in
           if !ended then ()
           else
             (active := remove_active key (!active);
              if json_mode () then
                emit_json "node_failed"
                  (json_node_fields key label @
                   json_failure_field_for_node key msg @
                   json_debug_artifacts_fields artifacts)
              else if enabled then
                (TextIO.output (TextIO.stdOut, "\r" ^ clear_to_eol);
                 TextIO.flushOut TextIO.stdOut)
              else ();
              ended := true)
         end);
   current_status := NONE)

fun fail status key label msg =
  fail_with_debug_artifacts status key label msg no_debug_artifacts

end
