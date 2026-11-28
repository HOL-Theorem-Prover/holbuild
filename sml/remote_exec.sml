structure HolbuildRemoteExec =
struct

(* Client of a remote-execution coordinator: submits an action batch, as
   `action-spec --upload` prints it, and follows the batch's events until it
   finishes.  A curl config file named by HOLBUILD_REMOTE_EXEC_CURL_CONFIG
   supplies the coordinator's credentials (an `Authorization: Bearer`
   header), so they never appear on a command line.  A batch is submitted
   and followed through the remote cache's libcurl client when it is loaded
   and the config holds only headers; otherwise, and for every other request,
   through the curl command.  See README, "Building on remote workers". *)

(* A step that yields text (a batch, a batch id) or says why it couldn't. *)
datatype attempt = Ok of string | Refused of string

(* A final action failure and its worker log, when one was uploaded.  THEORY
   is the action's `package:theory`, as the coordinator names it. *)
type action_failure = {input_key : string, theory : string, kind : string, log_sha256 : string option}

datatype outcome = Done
                 | Failed of string * action_failure list
                 | Cancelled of action_failure list * action_failure list
                   (* someone cancelled the batch: its stopped actions with a
                      worker log, and the actions that had failed before *)
                 | Unfollowable of string (* the coordinator won't stream it; it may still run *)
                 | Unreachable of string  (* the coordinator couldn't be asked *)

(* How many of a batch's actions are done, of how many, as its events last
   said. *)
type progress = {built : int, total : int}

val command_action = ref (fn (_ : string * string) => ())
val command_follow = ref (fn (_ : string * Time.time * Time.time) => ())
val command_batch = ref (fn (_ : string) => ())

val connect_timeout_seconds = 10
val request_max_time_seconds = 60
(* Waits before each retry of a request the coordinator couldn't answer (a
   submission answered 5xx or 429, an event stream that broke without
   delivering a state change): doubling up to 8 seconds, almost six minutes
   in all, long enough to ride out a coordinator restart such as an image
   upgrade (which pulls the new image first), or the move to a replacement
   instance.  Tests shorten them
   with HOLBUILD_TEST_RETRY_DELAYS, comma-separated seconds. *)
fun retry_delays_seconds () =
  case OS.Process.getEnv "HOLBUILD_TEST_RETRY_DELAYS" of
      SOME text => List.mapPartial Int.fromString (String.tokens (fn c => c = #",") text)
    | NONE => [1, 2, 4] @ List.tabulate (43, fn _ => 8)

fun retry_after delay = OS.Process.sleep (Time.fromSeconds (Int.toLarge delay))

fun curl_config_args () =
  case OS.Process.getEnv "HOLBUILD_REMOTE_EXEC_CURL_CONFIG" of
      SOME path => ["-K", path]
    | NONE => []

fun curl_args url options =
  ["-q", "-sS", "--connect-timeout", Int.toString connect_timeout_seconds] @
  curl_config_args () @ options @ [url]

(* The coordinator's headers from HOLBUILD_REMOTE_EXEC_CURL_CONFIG, when
   libcurl can send its requests: SOME [] without a config.  NONE leaves them
   to the curl command: the remote cache doesn't use libcurl, or the config
   can't be read or holds what only the curl command knows, an option other
   than `header` or a header file (`@path`). *)
fun libcurl_headers () =
  if not (HolbuildRemoteCacheConfig.uses_libcurl ()) then NONE
  else
    case OS.Process.getEnv "HOLBUILD_REMOTE_EXEC_CURL_CONFIG" of
        NONE => SOME []
      | SOME path =>
          (let val options = HolbuildRemoteCacheConfig.parse_curl_config (HolbuildHash.read_all path)
           in if List.all (fn (name, value) => name = "header" andalso not (String.isPrefix "@" value)) options then SOME (map #2 options) else NONE end
           handle HolbuildRemoteCacheConfig.Error _ => NONE
                | IO.Io _ => NONE)

(* Sends a request through libcurl with HEADERS, passing each line of the
   response to on_line as HolbuildSpawn.run_lines passes the curl command's
   output, a transport error, as the curl command prints it, ending the last.
   BODY, if any, is POSTed.  Returns the HTTP status, 0 when no answer
   came. *)
fun libcurl_lines headers {url, body, max_time} on_line =
  let
    val partial = ref ""
    fun on_data text =
      let
        fun lines [last] = partial := last
          | lines (line :: rest) = (on_line (line ^ "\n"); lines rest)
          | lines [] = ()
      in
        lines (String.fields (fn c => c = #"\n") (!partial ^ text))
      end
    val {status, failure} =
      HolbuildHttp.stream {url = url, headers = headers, body = body, connect_timeout = connect_timeout_seconds,
                           max_time = max_time, on_data = on_data}
      handle HolbuildHttp.Error message => {status = 0, failure = SOME message}
    val last = !partial ^ Option.getOpt (failure, "")
  in
    if last = "" then () else on_line last;
    status
  end

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

(* The value of an integer field in one JSON object, as the coordinator
   writes it: NONE when the field is missing or not a number. *)
fun json_int_field name text =
  let val key = "\"" ^ name ^ "\""
  in
    case HolbuildStatus.find_substring key text of
        NONE => NONE
      | SOME start =>
          case Substring.getc (Substring.dropl Char.isSpace (Substring.extract (text, start + size key, NONE))) of
              SOME (#":", value) => LargeInt.fromString (Substring.string value)
            | _ => NONE
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
  in (HolbuildBoundedOutput.text (out, text); TextIO.closeOut out) handle e => (TextIO.closeOut out; raise e) end

(* A random batch id in UUID form, for the coordinator to store a batch under. *)
fun new_batch_id () =
  let
    val hex = String.map Char.toLower (HolbuildTempPath.new_token () ^ HolbuildTempPath.new_token ())
    fun part (start, length) = String.substring (hex, start, length)
  in
    String.concatWith "-" [part (0, 8), part (8, 4), part (12, 4), part (16, 4), part (20, 12)]
  end

(* Submits a batch, with QUERY ("" or "?...") after the path; Ok carries
   its id.  A 5xx answer (a proxy's 502-504 while the coordinator restarts,
   or the coordinator's own 500 while it's overloaded) or a 429 is retried after each of retry_delays_seconds, since
   it passes like a restart; other 4xx errors aren't.  An unreachable
   coordinator is retried the same way when WAIT_UNREACHABLE (the caller has
   nothing to fall back to, as under --remote-only), and refused at once
   otherwise, so that a build that can go on locally does.  Every attempt
   names the same batch id, chosen here, so an attempt the coordinator stored
   but never answered (it was slower than request_max_time_seconds, or was
   stopped between storing and answering) leaves no second copy: the
   coordinator answers a repeat with the batch it stored. *)
fun submit_with_query wait_unreachable url query maxheap batch_text : attempt =
  let
    val _ = HolbuildOffline.require_online "submit a remote batch"
    val query = query ^ (case maxheap of
        NONE => ""
      | SOME n => (if query = "" then "?" else "&") ^ "max_heap_mb=" ^ Int.toString n)
    val id = new_batch_id ()
    val target = endpoint url ("/v1/batches" ^ query)
    val request_headers = ["Content-Type: text/plain", "Holbuild-Batch-Id: " ^ id]
    val libcurl = libcurl_headers ()
    val body = HolbuildTempPath.temporary "remote-exec-batch"
    val _ = if Option.isSome libcurl then () else write_text body batch_text
    (* The HTTP status, 0 when no answer came, and the answer's lines. *)
    fun send () =
      case libcurl of
          SOME headers =>
            let
              val lines = ref []
              val status =
                libcurl_lines (headers @ request_headers)
                  {url = target, body = SOME batch_text, max_time = SOME request_max_time_seconds}
                  (fn line => lines := line :: !lines)
            in
              (String.tokens (fn c => c = #"\n") (String.concat (rev (!lines))), status)
            end
        | NONE =>
            split_status (#output (HolbuildSpawn.run
              {program = "curl",
               args = curl_args target
                        (["--max-time", Int.toString request_max_time_seconds, "-X", "POST"] @
                         List.concat (map (fn header => ["-H", header]) request_headers) @
                         ["--data-binary", "@" ^ body, "-w", "\n%{http_code}"]),
               stderr = HolbuildSpawn.Merge}))
    fun post delays =
      let
        val (lines, status) = send ()
        val text = String.concatWith "\n" lines
        val refusal =
          if status = 0 then
            "could not reach the coordinator at " ^ HolbuildRemoteCache.redact_userinfo url ^
            (if text = "" then "" else ": " ^ text)
          else "coordinator refused the batch (HTTP " ^ Int.toString status ^ "): " ^ text
      in
        if status = 201 then
          case json_string_field "batch_id" text of
              SOME id => (!command_batch id; Ok id)
            | NONE => Refused ("coordinator answered without a batch_id: " ^ text)
        else if (status = 0 andalso wait_unreachable) orelse status = 429 orelse status >= 500 then
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

fun submit wait_unreachable url maxheap batch_text =
  submit_with_query wait_unreachable url "" maxheap batch_text

(* The input keys of the theories a failed batch's workers could not use,
   when the coordinator failed it for resubmission naming each as
   "theory <input_key>". *)
fun resubmit_theory_keys reason =
  case HolbuildStatus.find_substring "resubmit: " reason of
      NONE => []
    | SOME start =>
        let
          fun scan text =
            case HolbuildStatus.find_substring "theory " text of
                NONE => []
              | SOME i =>
                  let
                    val rest = String.extract (text, i + size "theory ", NONE)
                    val key = Substring.string (Substring.takel Char.isHexDigit (Substring.full rest))
                    val keys = scan rest
                  in
                    if HolbuildHash.valid_hex 64 key then key :: List.filter (fn k => k <> key) keys else keys
                  end
        in
          scan (String.extract (reason, start, NONE))
        end

(* Whether the coordinator failed the batch for resubmission naming a blob a
   worker found missing ("blob <sha256>"), first or among the others. *)
fun resubmit_missing_blob reason =
  case HolbuildStatus.find_substring "resubmit: " reason of
      NONE => false
    | SOME start =>
        let
          fun scan text =
            case HolbuildStatus.find_substring "blob " text of
                NONE => false
              | SOME i =>
                  let val rest = String.extract (text, i + size "blob ", NONE)
                  in
                    HolbuildHash.valid_hex 64 (Substring.string (Substring.takel Char.isHexDigit (Substring.full rest)))
                    orelse scan rest
                  end
        in
          scan (String.extract (reason, start, NONE))
        end

fun report_action line =
  let
    val field = fn name => json_string_field name line
    val theory = Option.getOpt (field "theory", "?")
    val raw_state = Option.getOpt (field "state", "?")
    val state = if raw_state = "cancelled" andalso
                   String.isPrefix "skipped because of " (Option.getOpt (field "last_failure", ""))
                then "skipped" else raw_state
    (* A done action's detail says why it has no log, or why its pipelined
       attempt was given up. *)
    val failure =
      case (field "last_failure", field "failure_detail") of
          (SOME f, SOME detail) => " (" ^ f ^ ": " ^ detail ^ ")"
        | (SOME f, NONE) => " (" ^ f ^ ")"
        | (NONE, SOME detail) => " (" ^ detail ^ ")"
        | (NONE, NONE) => ""
    (* An action back to waiting, ready or running after a failure is
       being retried: the attempts it has used, its tier, and the log a
       failed attempt left tell a retry loop from a slow proof. *)
    val retried = Option.isSome (field "last_failure") andalso
                  List.exists (fn s => s = state) ["waiting", "ready", "running"]
    val attempt =
      if not retried then ""
      else
        (case json_int_field "attempts" line of
             SOME n => ", attempts " ^ LargeInt.toString n
           | NONE => "") ^
        (case field "tier" of SOME tier => ", tier " ^ tier | NONE => "")
    (* A cancelled action's log is the one its worker uploaded as it
       stopped it, as at the batch deadline. *)
    val log = case field "log_sha256" of
                  SOME sha => if List.exists (fn s => s = state) ["failed", "cancelled"] orelse retried
                              then ", log /cas/" ^ sha else ""
                | NONE => ""
  in
    HolbuildStatus.message_stderr ("holbuild: remote " ^ theory ^ ": " ^ state ^ failure ^ attempt ^ log ^ "\n")
  end

(* Follows a batch's event stream until the batch finishes, printing each
   action whose state changes, and passing on_change the input key, the
   new state, last failure, log hash and failure detail, if any, of each.  A stream that breaks (the connection drops,
   or the coordinator answers 5xx while it restarts) is reattached: after a
   second when it delivered a state change, and after each of
   retry_delays_seconds in a row when it delivered none.  Every stream
   starts with the states of all the batch's actions, so a state seen
   before is no change, and a stream that only repeats them before it
   breaks counts against the retries.  The coordinator writes a blank line
   on a quiet stream, so a proxy doesn't close a healthy one for being
   idle.  The coordinator ends a batch at its deadline, so this ends too.  A failed
   batch comes with the action whose proof failed, when one did. *)
fun follow url batch_id (on_change : string * string * string option * string option * string option -> unit)
    : outcome * progress =
  let
    val followed_at = Time.now ()
    val _ = HolbuildOffline.require_online "follow a remote batch"
    val libcurl = libcurl_headers ()
    val states : (string * (string * string option * string option)) list ref = ref []
    val names = ref ([] : (string * string) list)
    (* Each action's last failure detail: a new one is a change too. *)
    val details = ref ([] : (string * string option) list)
    (* Actions that ran more than once: an earlier attempt failed. *)
    val retried : string list ref = ref []
    (* The hold last printed for each action: the batch whose build of the
       same key and spec holds it back, and when that batch claimed it. *)
    val holds : (string * (string * string option)) list ref = ref []
    fun name key = Option.getOpt (Option.map #2 (List.find (fn (k, _) => k = key) (!names)), key)
    (* An action the deadline stopped failed with its batch. *)
    fun failures () =
      List.mapPartial (fn (key, (state, kind, log)) =>
        if state = "failed" orelse (state = "cancelled" andalso kind = SOME "deadline") then
          SOME {input_key = key, theory = name key, kind = Option.getOpt (kind, "internal"), log_sha256 = log}
        else NONE) (rev (!states))
    (* Actions that failed, which a batch cancelled afterwards still holds. *)
    fun failed () =
      List.mapPartial (fn (key, (state, kind, log)) =>
        if state = "failed" then
          SOME {input_key = key, theory = name key, kind = Option.getOpt (kind, "internal"), log_sha256 = log}
        else NONE) (rev (!states))
    (* An action stopped by a cancel, or by the batch deadline before a cancel
       ended the batch, with the log its worker uploaded as it stopped it:
       what it printed up to then.  After an earlier attempt failed, the log
       may be that attempt's, if the stopped one uploaded none. *)
    fun stopped () =
      List.mapPartial (fn (key, (state, kind, log)) =>
        case (state, kind, log) of
            ("cancelled", NONE, SOME _) => SOME {input_key = key, theory = name key, kind = "cancelled", log_sha256 = log}
          | ("cancelled", SOME "deadline", SOME _) =>
              SOME {input_key = key, theory = name key,
                    kind = if List.exists (fn k => k = key) (!retried)
                           then "stopped at the batch deadline after an earlier attempt failed; the log below may be that attempt's"
                           else "stopped at the batch deadline",
                    log_sha256 = log}
          | ("cancelled", SOME earlier, SOME _) =>
              if String.isPrefix "skipped because of " earlier then NONE
              else SOME {input_key = key, theory = name key,
                         kind = "cancelled after an attempt that failed (" ^ earlier ^ "); the log below may be that attempt's",
                         log_sha256 = log}
          | _ => NONE) (rev (!states))
    (* Actions a worker ran, whose log may arrive after their cancellation. *)
    val ran : string list ref = ref []
    (* A line cut off by a dropped connection, perhaps with curl's error
       after it, is no event. *)
    fun complete line = Substring.isSuffix "}" (Substring.dropr Char.isSpace (Substring.full line))
    fun on_line outcome changed others line =
      case (if complete line then json_string_field "type" line else NONE) of
          SOME "action" =>
            let
              val _ = !command_action (batch_id, line)
              val key = Option.getOpt (json_string_field "input_key" line, "")
              val state = Option.getOpt (json_string_field "state" line, "")
              val failure = json_string_field "last_failure" line
              val log = json_string_field "log_sha256" line
              val previous = List.find (fn (k, _) => k = key) (!states)
              val status = (state, failure, log)
              val detail = json_string_field "failure_detail" line
              val previous_detail = Option.map #2 (List.find (fn (k, _) => k = key) (!details))
              val _ = if state = "running" orelse Option.getOpt (json_int_field "attempts" line, 0) > 0
                      then ran := key :: List.filter (fn k => k <> key) (!ran) else ()
              val _ = if Option.getOpt (json_int_field "attempts" line, 0) > 1
                      then retried := key :: List.filter (fn k => k <> key) (!retried) else ()
            in
              names := (key, Option.getOpt (json_string_field "theory" line, key)) ::
                       List.filter (fn (k, _) => k <> key) (!names);
              if previous = SOME (key, status) andalso previous_detail = SOME detail then ()
              else
                (states := (key, status) :: List.filter (fn (k, _) => k <> key) (!states);
                 details := (key, detail) :: List.filter (fn (k, _) => k <> key) (!details);
                 (* A new log can arrive in a repeated done snapshot after a
                    missed requeue. Only state progress resets stream retries. *)
                 if Option.map (fn (_, (s, _, _)) => s) previous = SOME state then ()
                 else (changed := true; report_action line);
                 on_change (key, state, failure, log, detail));
              (* A hold starts or its holder claims again without a state
                 change, so it isn't one for the stream retries. *)
              case (state, json_string_field "held_by" line) of
                  ("ready", SOME holder) =>
                    let val hold = (holder, json_string_field "held_since" line)
                    in
                      if List.exists (fn h => h = (key, hold)) (!holds) then ()
                      else
                        (holds := (key, hold) :: List.filter (fn (k, _) => k <> key) (!holds);
                         HolbuildStatus.message_stderr
                           ("holbuild: remote " ^ name key ^ ": held by batch " ^ holder ^
                            (case #2 hold of SOME since => " since " ^ since | NONE => "") ^ "\n"))
                    end
                | _ => ()
            end
        | SOME "batch" =>
            outcome :=
              SOME (case json_string_field "state" line of
                        SOME "done" => Done
                      | SOME "cancelled" => Cancelled (stopped (), failed ())
                      | SOME state =>
                          Failed (state ^ (case json_string_field "failure" line of
                                               SOME failure => ": " ^ failure
                                             | NONE => ""),
                                  failures ())
                      | NONE => Failed ("finished in an unknown state", failures ()))
        | _ => others := line :: !others
    fun attach delays =
      let
        val outcome : outcome option ref = ref NONE
        val changed = ref false
        val others : string list ref = ref []
        val events = endpoint url ("/v1/batches/" ^ batch_id ^ "/events")
        val (lines, status) =
          case libcurl of
              SOME headers =>
                let val status = libcurl_lines headers {url = events, body = NONE, max_time = NONE}
                                   (on_line outcome changed others)
                in (String.tokens (fn c => c = #"\n") (String.concat (rev (!others))), status) end
            | NONE =>
                (ignore (HolbuildSpawn.run_lines
                   {program = "curl", args = curl_args events ["-N", "-w", "\n%{http_code}"],
                    stderr = HolbuildSpawn.Merge}
                   (on_line outcome changed others));
                 split_status (String.concat (rev (!others))))
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
                  handle e => (!command_follow (batch_id, followed_at, Time.now ()); raise e)
    val _ = !command_follow (batch_id, followed_at, Time.now ())
    val skipped = List.filter (fn (_, (state, reason, _)) =>
      state = "cancelled" andalso String.isPrefix "skipped because of " (Option.getOpt (reason, ""))) (!states)
    (* A cancel doesn't wait for a stopped worker's log, which a later
       follow of the batch fetches. *)
    val _ =
      case outcome of
          Cancelled _ =>
            List.app (fn (key, _) =>
              HolbuildStatus.message_stderr ("holbuild: remote " ^ name key ^ ": stopped with no worker log yet; " ^
                "if its worker uploads one, holbuild build --attach " ^ batch_id ^ " shows it\n"))
              (List.filter (fn (key, (state, kind, log)) =>
                 state = "cancelled" andalso log = NONE andalso List.exists (fn k => k = key) (!ran) andalso
                 (* A skipped action's lease is gone, so no log can follow. *)
                 not (String.isPrefix "skipped because of " (Option.getOpt (kind, "")))) (rev (!states)))
        | _ => ()
    val _ =
      if null (failures ()) andalso null skipped then ()
      else
        (HolbuildStatus.message_stderr ("holbuild: remote failure summary: " ^
           Int.toString (length (failures ())) ^ " failed, " ^ Int.toString (length skipped) ^ " skipped\n");
         List.app (fn {input_key, kind, log_sha256, ...} : action_failure =>
           HolbuildStatus.message_stderr ("holbuild: remote " ^ name input_key ^ ": failed (" ^ kind ^ ")" ^
             (case log_sha256 of SOME sha => ", log /cas/" ^ sha | NONE => ", no worker log") ^ "\n")) (failures ());
         List.app (fn (key, (_, reason, _)) =>
           HolbuildStatus.message_stderr ("holbuild: remote " ^ name key ^ ": " ^ Option.getOpt (reason, "skipped") ^ "\n"))
           (rev skipped))
  in
    (outcome,
     {built = length (List.filter (fn (_, (state, _, _)) => state = "done") (!states)),
      total = length (!states)})
  end

(* Asks the coordinator to cancel a batch; true when it did.  It answers
   with the batch's state, which for a batch that already ended is that
   end, not "cancelled".  A failure only warns, since the coordinator ends
   an abandoned batch at its deadline anyway. *)
fun cancel_within max_time_seconds url batch_id =
  let
    val _ = HolbuildOffline.require_online "cancel a remote batch"
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

(* The logs of an ended batch's cancelled actions.  A worker can finish one
   after the batch failed: the coordinator leaves it cancelled, with any
   earlier attempt's failure, and stores its log as its result comes, after
   the batch's event stream ended.  An ended batch's stream replays each
   action's last state.  A failure only warns, as the logs are a
   diagnostic. *)
fun late_logs url batch_id =
  let
    val result =
      HolbuildSpawn.run
        {program = "curl",
         args = curl_args (endpoint url ("/v1/batches/" ^ batch_id ^ "/events"))
                  ["--max-time", Int.toString request_max_time_seconds, "-w", "\n%{http_code}"],
         stderr = HolbuildSpawn.Merge}
    val (lines, status) = split_status (#output result)
    fun late line =
      if json_string_field "type" line = SOME "action" andalso json_string_field "state" line = SOME "cancelled"
      then
        case (json_string_field "input_key" line, json_string_field "log_sha256" line) of
            (SOME key, SOME sha) => SOME (key, sha)
          | _ => NONE
      else NONE
  in
    if status >= 200 andalso status < 300 then List.mapPartial late lines
    else
      (HolbuildStatus.message_stderr
         ("holbuild: warning: could not read the logs of remote batch " ^ batch_id ^
          (if status = 0 then "" else " (HTTP " ^ Int.toString status ^ ")") ^
          (case lines of [] => "" | _ => ": " ^ String.concatWith " " lines) ^ "\n");
       [])
  end

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

(* With HOLBUILD_KEEP_BATCH_ON_INTERRUPT=1 an interrupt leaves the batch
   running, so a caller that stops the build at a time limit keeps what the
   workers finish in the remote cache for its next build. *)
fun keep_batch_on_interrupt () =
  OS.Process.getEnv "HOLBUILD_KEEP_BATCH_ON_INTERRUPT" = SOME "1"

fun cancel_followed () =
  case !followed of
      NONE => ()
    | SOME (url, batch_id) =>
        (followed := NONE;
         if keep_batch_on_interrupt () then
           HolbuildStatus.message_stderr
             ("holbuild: left remote batch " ^ batch_id ^ " running; reattach with --attach " ^
              batch_id ^ "\n")
         else if cancel_within interrupt_cancel_seconds url batch_id
         then HolbuildStatus.message_stderr ("holbuild: cancelled remote batch " ^ batch_id ^ "\n")
         else ())

end
