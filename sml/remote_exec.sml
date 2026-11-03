structure HolbuildRemoteExec =
struct

(* Client of a remote-execution coordinator: submits an action batch, as
   `action-spec --upload` prints it, and follows the batch's events until it
   finishes.  Requests go through the curl command; a curl config file named
   by HOLBUILD_REMOTE_EXEC_CURL_CONFIG supplies the coordinator's credentials
   (an `Authorization: Bearer` header), so they never appear on a command
   line.  See README, "Building on remote workers". *)

(* A step that yields text (a batch, a batch id) or says why it couldn't. *)
datatype attempt = Ok of string | Refused of string

datatype outcome = Done
                 | Failed of string       (* the batch failed or was cancelled *)
                 | Unreachable of string  (* the coordinator couldn't be asked *)

val connect_timeout_seconds = 10
val request_max_time_seconds = 60

fun curl_config_args () =
  case OS.Process.getEnv "HOLBUILD_REMOTE_EXEC_CURL_CONFIG" of
      SOME path => ["-K", path]
    | NONE => []

fun curl_args url options =
  ["-q", "-sS", "--connect-timeout", Int.toString connect_timeout_seconds] @
  curl_config_args () @ options @ [url]

fun endpoint base path =
  (if String.isSuffix "/" base then String.substring (base, 0, size base - 1) else base) ^ path

(* The string value of a field in one JSON object, as the coordinator writes
   it: NONE when the field is missing or not a string.  Only the escapes a
   theory name, state or failure message can carry are decoded. *)
fun json_string_field name text =
  let
    val key = "\"" ^ name ^ "\""
    fun unescape (#"\\" :: c :: rest) acc =
          unescape rest ((case c of #"n" => #"\n" | #"t" => #"\t" | c => c) :: acc)
      | unescape (#"\"" :: _) acc = SOME (String.implode (rev acc))
      | unescape (c :: rest) acc = unescape rest (c :: acc)
      | unescape [] _ = NONE
    val skip_space = Substring.dropl Char.isSpace
  in
    case HolbuildStatus.find_substring key text of
        NONE => NONE
      | SOME start =>
          let val after_key = skip_space (Substring.extract (text, start + size key, NONE))
          in
            case Substring.getc after_key of
                SOME (#":", value) =>
                  (case Substring.getc (skip_space value) of
                       SOME (#"\"", rest) => unescape (Substring.explode rest) []
                     | _ => NONE)
              | _ => NONE
          end
  end

(* curl's output split into lines, and the HTTP status `-w` appends as the
   last line (0 when no response came). *)
fun split_status output =
  let val lines = String.tokens (fn c => c = #"\n") output
  in
    case rev lines of
        [] => ([], 0)
      | last :: earlier => (rev earlier, Option.getOpt (Int.fromString last, 0))
  end

fun write_text path text =
  let val out = TextIO.openOut path
  in (TextIO.output (out, text); TextIO.closeOut out) handle e => (TextIO.closeOut out; raise e) end

(* Submits a batch; Ok carries its id. *)
fun submit url batch_text : attempt =
  let
    val body = HolbuildTempPath.temporary "remote-exec-batch"
    val _ = write_text body batch_text
    val result =
      HolbuildSpawn.run
        {program = "curl",
         args = curl_args (endpoint url "/v1/batches")
                  ["--max-time", Int.toString request_max_time_seconds, "-X", "POST",
                   "-H", "Content-Type: text/plain", "--data-binary", "@" ^ body,
                   "-w", "\n%{http_code}"],
         stderr = HolbuildSpawn.Merge}
    val _ = OS.FileSys.remove body handle OS.SysErr _ => ()
    val (lines, status) = split_status (#output result)
    val text = String.concatWith "\n" lines
  in
    if status = 201 then
      case json_string_field "batch_id" text of
          SOME id => Ok id
        | NONE => Refused ("coordinator answered without a batch_id: " ^ text)
    else if status = 0 then
      Refused ("could not reach the coordinator at " ^ HolbuildRemoteCache.redact_userinfo url ^
               (if text = "" then "" else ": " ^ text))
    else Refused ("coordinator refused the batch (HTTP " ^ Int.toString status ^ "): " ^ text)
  end

fun report_action line =
  let
    val field = fn name => json_string_field name line
    val theory = Option.getOpt (field "theory", "?")
    val state = Option.getOpt (field "state", "?")
    val failure = case field "last_failure" of SOME f => " (" ^ f ^ ")" | NONE => ""
    val log = case (state, field "log_sha256") of
                  ("failed", SOME sha) => ", log /cas/" ^ sha
                | _ => ""
  in
    HolbuildStatus.message_stderr ("holbuild: remote " ^ theory ^ ": " ^ state ^ failure ^ log ^ "\n")
  end

(* Follows a batch's event stream until the batch finishes, printing each
   action whose state changes. *)
fun follow url batch_id : outcome =
  let
    val states : (string * string) list ref = ref []
    val outcome : outcome option ref = ref NONE
    val others : string list ref = ref []
    fun on_line line =
      case json_string_field "type" line of
          SOME "action" =>
            let
              val key = Option.getOpt (json_string_field "input_key" line, "")
              val state = Option.getOpt (json_string_field "state" line, "")
            in
              if List.exists (fn entry => entry = (key, state)) (!states) then ()
              else (states := (key, state) :: List.filter (fn (k, _) => k <> key) (!states);
                    report_action line)
            end
        | SOME "batch" =>
            outcome :=
              SOME (case json_string_field "state" line of
                        SOME "done" => Done
                      | SOME state =>
                          Failed (state ^ (case json_string_field "failure" line of
                                               SOME failure => ": " ^ failure
                                             | NONE => ""))
                      | NONE => Failed "finished in an unknown state")
        | _ => others := line :: !others
    val _ =
      HolbuildSpawn.run_lines
        {program = "curl",
         args = curl_args (endpoint url ("/v1/batches/" ^ batch_id ^ "/events"))
                  ["-N", "-w", "\n%{http_code}"],
         stderr = HolbuildSpawn.Merge}
        on_line
    val (lines, status) = split_status (String.concat (rev (!others)))
    val text = String.concatWith "\n" lines
  in
    case !outcome of
        SOME outcome => outcome
      | NONE =>
          if status = 0 orelse (status >= 200 andalso status < 300) then
            Unreachable ("lost the coordinator's event stream for batch " ^ batch_id ^
                         (if text = "" then "" else ": " ^ text))
          else Failed ("can't be followed (HTTP " ^ Int.toString status ^ "): " ^ text)
  end

end
