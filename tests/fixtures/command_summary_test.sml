use "sml/holbuild-script.sml";

fun reset () = (HolbuildCommandSummary.actions := Binarymap.mkDict String.compare;
                HolbuildCommandSummary.batches := Binaryset.empty String.compare);
fun event state attempt timing =
  "{\"input_key\":\"key\",\"state\":\"" ^ state ^ "\",\"attempts\":" ^ Int.toString attempt ^ timing ^ "}";
fun result state attempt started failure = event state attempt
  (",\"last_failure\":\"" ^ failure ^ "\",\"timings\":{\"started\":" ^ Int.toString started ^
   ",\"finished\":" ^ Int.toString (started + 500) ^ "}");
fun observe line = HolbuildCommandSummary.observe_action ("batch", line);
fun entries kind = List.filter (fn line => HolbuildRemoteExec.json_string_field "observation" line = SOME kind)
  (map #2 (Binarymap.listItems (!HolbuildCommandSummary.actions)));
fun assert condition message = if condition then () else raise Fail message;

(* A result first seen during a running retry must survive that retry. *)
val _ = observe (event "running" 1 "");
val _ = observe (result "running" 2 1000 "internal");
val first = hd (entries "result");
val _ = observe (result "done" 2 2000 "");
val _ = observe (result "done" 2 2000 "");
val _ = assert (length (entries "result") = 2 andalso length (entries "attempt") = 2)
  "lost observed results or running markers across coalesced snapshots";
val _ = assert (List.exists (fn line => line = first) (entries "result"))
  "changed an immutable observed result";
val _ = assert (List.all (fn line => not (Option.isSome (HolbuildStatus.find_substring "timings" line)))
  (entries "attempt")) "attached result timings to a running marker";

(* Reused counters still retain distinct results; repeated inherited payloads do not duplicate them. *)
val _ = reset ();
val _ = observe (result "ready" 0 1000 "unavailable");
val _ = observe (result "running" 0 1000 "unavailable");
val _ = observe (result "done" 0 2000 "");
val _ = assert (length (entries "result") = 2 andalso length (entries "attempt") = 1)
  "lost observed executions when the coordinator reused its counter";

(* Lease expiry has no result; retain the marker whether or not a retry's running state was polled. *)
val _ = reset ();
val _ = List.app observe [event "running" 1 "", event "waiting" 1 "", event "done" 2 ""];
val _ = assert (length (entries "attempt") = 1 andalso null (entries "result"))
  "invented an execution result for an expired lease";
val _ = assert (not (HolbuildCommandSummary.fleet_history_complete ()))
  "claimed complete history after a missed result";

(* Attaching during a retry sees an old result and a separate running marker, never a binding between them. *)
val _ = reset ();
val _ = observe (result "running" 2 1000 "unavailable");
val _ = observe (result "waiting" 2 1000 "unavailable");
val _ = observe (result "running" 3 1000 "unavailable");
val _ = observe (result "done" 3 5000 "");
val _ = assert (length (entries "result") = 2 andalso length (entries "attempt") = 2)
  "late attachment lost an observed result or expired running marker";
val _ = assert (not (HolbuildCommandSummary.fleet_history_complete ()))
  "claimed complete history after late attachment";

(* Worker failures with no timings can first appear in a running retry. *)
val _ = reset ();
val failed = ",\"last_failure\":\"memory\",\"failure_detail\":\"oom\",\"log_sha256\":\"log\",\"timings\":null";
val _ = observe (event "running" 2 failed);
val untimed = hd (entries "untimed");
val _ = observe (event "waiting" 2 failed);
val _ = observe (event "running" 3 failed);
val _ = assert (entries "untimed" = [untimed] andalso length (entries "attempt") = 2)
  "lost or duplicated an untimed failure across retry states";
val _ = assert (HolbuildRemoteExec.json_string_field "failure_detail" untimed = SOME "oom" andalso
                HolbuildRemoteExec.json_string_field "log_sha256" untimed = SOME "log" andalso
                not (HolbuildCommandSummary.fleet_history_complete ()))
  "dropped untimed failure fields or claimed complete coverage";
val _ = reset ();
val _ = HolbuildCommandSummary.batches := Binaryset.add (!HolbuildCommandSummary.batches, "submitted");
val _ = assert (not (HolbuildCommandSummary.fleet_history_complete ()))
  "claimed complete history for an unobserved batch";
