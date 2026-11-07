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

(* An action that failed for good because its proof did, and the cache
   blob that holds its worker's build log. *)
type proof_failure = {input_key : string, kind : string, log_sha256 : string}

datatype outcome = Done
                 | Failed of string * proof_failure option
                                          (* the batch failed, and the proof that failed it *)
                 | Cancelled              (* someone cancelled the batch *)
                 | Unfollowable of string (* the coordinator won't stream it; it may still run *)
                 | Unreachable of string  (* the coordinator couldn't be asked *)

(* How many of a batch's actions are done, of how many, as its events last
   said. *)
type progress = {built : int, total : int}

val connect_timeout_seconds = 10
val request_max_time_seconds = 60
(* Waits before each retry of a request the coordinator couldn't answer (a
   submission answered 5xx or 429, an event stream that broke without
   delivering a state change): doubling up to 8 seconds, about two and a half
   minutes in all, long enough to ride out a coordinator restart such as an
   image upgrade.  Tests shorten them with HOLBUILD_TEST_RETRY_DELAYS,
   comma-separated seconds. *)
fun retry_delays_seconds () =
  case OS.Process.getEnv "HOLBUILD_TEST_RETRY_DELAYS" of
      SOME text => List.mapPartial Int.fromString (String.tokens (fn c => c = #",") text)
    | NONE => [1, 2, 4] @ List.tabulate (18, fn _ => 8)

fun retry_after delay = OS.Process.sleep (Time.fromSeconds (Int.toLarge delay))

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

(* Submits a batch; Ok carries its id.  A 5xx answer (a proxy's 502-504
   while the coordinator restarts, or the coordinator's own 500 while it's
   overloaded) or a 429 is retried after each of retry_delays_seconds, since
   it passes like a restart; other 4xx errors aren't, and an unreachable
   coordinator is refused at once.  A gateway error that comes after the
   coordinator stored the batch (it was stopped between storing and
   answering) leaves a copy that nobody follows: it runs to its end or
   deadline, repeating work whose results the cache dedupes. *)
fun submit url batch_text : attempt =
  let
    val body = HolbuildTempPath.temporary "remote-exec-batch"
    val _ = write_text body batch_text
    fun post delays =
      let
        val result =
          HolbuildSpawn.run
            {program = "curl",
             args = curl_args (endpoint url "/v1/batches")
                      ["--max-time", Int.toString request_max_time_seconds, "-X", "POST",
                       "-H", "Content-Type: text/plain", "--data-binary", "@" ^ body,
                       "-w", "\n%{http_code}"],
             stderr = HolbuildSpawn.Merge}
        val (lines, status) = split_status (#output result)
        val text = String.concatWith "\n" lines
        val refusal = "coordinator refused the batch (HTTP " ^ Int.toString status ^ "): " ^ text
      in
        if status = 201 then
          case json_string_field "batch_id" text of
              SOME id => Ok id
            | NONE => Refused ("coordinator answered without a batch_id: " ^ text)
        else if status = 0 then
          Refused ("could not reach the coordinator at " ^ HolbuildRemoteCache.redact_userinfo url ^
                   (if text = "" then "" else ": " ^ text))
        else if status = 429 orelse status >= 500 then
          case delays of
              [] => Refused refusal
            | delay :: rest =>
                (HolbuildStatus.message_stderr ("holbuild: " ^ refusal ^ "; retrying\n");
                 retry_after delay;
                 post rest)
        else Refused refusal
      end
    val outcome = post (retry_delays_seconds ())
                  handle e => (OS.FileSys.remove body handle OS.SysErr _ => (); raise e)
  in
    OS.FileSys.remove body handle OS.SysErr _ => ();
    outcome
  end

(* The input key of the theory a failed batch's workers could not use, when
   the coordinator failed it for resubmission naming the theory as
   "theory <input_key>". *)
fun resubmit_theory_key reason =
  case HolbuildStatus.find_substring "resubmit: " reason of
      NONE => NONE
    | SOME start =>
        let
          fun scan text =
            case HolbuildStatus.find_substring "theory " text of
                NONE => NONE
              | SOME i =>
                  let
                    val rest = String.extract (text, i + size "theory ", NONE)
                    val key = Substring.string (Substring.takel Char.isHexDigit (Substring.full rest))
                  in
                    if HolbuildHash.valid_hex 64 key then SOME key else scan rest
                  end
        in
          scan (String.extract (reason, start, NONE))
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
   action whose state changes, and passing on_done the input key of each
   action that becomes done.  A stream that breaks (the connection drops,
   or the coordinator answers 5xx while it restarts) is reattached: after a
   second when it delivered a state change, and after each of
   retry_delays_seconds in a row when it delivered none.  Every stream
   starts with the states of all the batch's actions, so a state seen
   before is no change, and a stream that only repeats them before it
   breaks counts against the retries.  The coordinator writes a blank line
   on a quiet stream, so a proxy doesn't close a healthy one for being
   idle.  The coordinator ends a batch at its deadline, so this ends too.  A failed
   batch comes with the action whose proof failed, when one did. *)
fun follow url batch_id (on_done : string -> unit) : outcome * progress =
  let
    val states : (string * string) list ref = ref []
    val proof_failure : proof_failure option ref = ref NONE
    (* A line cut off by a dropped connection, perhaps with curl's error
       after it, is no event. *)
    fun complete line = Substring.isSuffix "}" (Substring.dropr Char.isSpace (Substring.full line))
    fun on_line outcome changed others line =
      case (if complete line then json_string_field "type" line else NONE) of
          SOME "action" =>
            let
              val key = Option.getOpt (json_string_field "input_key" line, "")
              val state = Option.getOpt (json_string_field "state" line, "")
            in
              (case (state, json_string_field "last_failure" line, json_string_field "log_sha256" line) of
                   ("failed", SOME kind, SOME log_sha256) =>
                     if kind = "proof" orelse kind = "tactic-timeout" then
                       proof_failure := SOME {input_key = key, kind = kind, log_sha256 = log_sha256}
                     else ()
                 | _ => ());
              if List.exists (fn entry => entry = (key, state)) (!states) then ()
              else (states := (key, state) :: List.filter (fn (k, _) => k <> key) (!states);
                    changed := true;
                    report_action line;
                    if state = "done" then on_done key else ())
            end
        | SOME "batch" =>
            outcome :=
              SOME (case json_string_field "state" line of
                        SOME "done" => Done
                      | SOME "cancelled" => Cancelled
                      | SOME state =>
                          Failed (state ^ (case json_string_field "failure" line of
                                               SOME failure => ": " ^ failure
                                             | NONE => ""),
                                  !proof_failure)
                      | NONE => Failed ("finished in an unknown state", !proof_failure))
        | _ => others := line :: !others
    fun attach delays =
      let
        val outcome : outcome option ref = ref NONE
        val changed = ref false
        val others : string list ref = ref []
        val _ =
          HolbuildSpawn.run_lines
            {program = "curl",
             args = curl_args (endpoint url ("/v1/batches/" ^ batch_id ^ "/events"))
                      ["-N", "-w", "\n%{http_code}"],
             stderr = HolbuildSpawn.Merge}
            (on_line outcome changed others)
        val (lines, status) = split_status (String.concat (rev (!others)))
        val text = String.concatWith "\n" lines
        val broken = status = 0 orelse (status >= 200 andalso status < 300) orelse status >= 500
        val reason =
          (if status >= 500 then "the coordinator answered HTTP " ^ Int.toString status ^ " to"
           else "lost") ^ " the event stream for batch " ^ batch_id ^
          (if text = "" then "" else ": " ^ text)
        fun again delay delays =
          (HolbuildStatus.message_stderr ("holbuild: " ^ reason ^ "; reattaching\n");
           retry_after delay;
           attach delays)
      in
        case !outcome of
            SOME outcome => outcome
          | NONE =>
              if not broken then Unfollowable ("can't be followed (HTTP " ^ Int.toString status ^ "): " ^ text)
              else if !changed then again 1 (retry_delays_seconds ())
              else
                case delays of
                    [] => Unreachable reason
                  | delay :: rest => again delay rest
      end
    val outcome = attach (retry_delays_seconds ())
  in
    (outcome,
     {built = length (List.filter (fn (_, state) => state = "done") (!states)),
      total = length (!states)})
  end

(* Asks the coordinator to cancel a batch; true when it did.  It answers
   with the batch's state, which for a batch that already ended is that
   end, not "cancelled".  A failure only warns, since the coordinator ends
   an abandoned batch at its deadline anyway. *)
fun cancel_within max_time_seconds url batch_id =
  let
    val result =
      HolbuildSpawn.run
        {program = "curl",
         args = curl_args (endpoint url ("/v1/batches/" ^ batch_id ^ "/cancel"))
                  ["--max-time", Int.toString max_time_seconds, "-X", "POST",
                   "-w", "\n%{http_code}"],
         stderr = HolbuildSpawn.Merge}
    val (lines, status) = split_status (#output result)
  in
    if status >= 200 andalso status < 300 then
      json_string_field "state" (String.concatWith "\n" lines) = SOME "cancelled"
    else
      (HolbuildStatus.message_stderr
         ("holbuild: warning: could not cancel remote batch " ^ batch_id ^
          (if status = 0 then "" else " (HTTP " ^ Int.toString status ^ ")") ^
          (case lines of [] => "" | _ => ": " ^ String.concatWith " " lines) ^ "\n");
       false)
  end

val cancel = cancel_within request_max_time_seconds

(* The batch a build is following and would cancel if it stopped following
   it, so that an interrupted build cancels it too (cancel_followed) rather
   than leave it running for nobody until its deadline. *)
val followed : (string * string) option ref = ref NONE

(* Runs f, which follows the batch, with the batch registered as followed. *)
fun while_followed url batch_id f =
  (followed := SOME (url, batch_id);
   f () before followed := NONE)
  handle e => (followed := NONE; raise e)

(* Whoever interrupts a build may kill it soon after, so this waits briefly. *)
val interrupt_cancel_seconds = 5

fun cancel_followed () =
  case !followed of
      NONE => ()
    | SOME (url, batch_id) =>
        (followed := NONE;
         if cancel_within interrupt_cancel_seconds url batch_id
         then HolbuildStatus.message_stderr ("holbuild: cancelled remote batch " ^ batch_id ^ "\n")
         else ())

end
