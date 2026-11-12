use "sml/holbuild-script.sml";

fun event state started failure =
  "{\"type\":\"action\",\"input_key\":\"key\",\"state\":\"" ^ state ^ "\",\"attempts\":0," ^
  "\"last_failure\":\"" ^ failure ^ "\",\"timings\":{\"started\":" ^ Int.toString started ^ "}}";
val _ = HolbuildCommandSummary.observe_action ("batch", event "ready" 1000 "unavailable");
val _ = HolbuildCommandSummary.observe_action ("batch", event "running" 1000 "unavailable");
val _ = if Binarymap.numItems (!HolbuildCommandSummary.actions) = 2 then ()
        else raise Fail "lost the active retry's coverage marker";
val _ = HolbuildCommandSummary.observe_action ("batch", event "done" 2000 "");
val _ = HolbuildCommandSummary.observe_action ("batch", event "done" 2000 "");
val snapshots = Binarymap.listItems (!HolbuildCommandSummary.actions);
val _ = if length snapshots = 2 andalso
    List.exists (fn (_, line) => Option.isSome (HolbuildStatus.find_substring "unavailable" line)) snapshots
  then () else raise Fail "lost interrupted execution when its attempt number was reused";

val _ = HolbuildCommandSummary.actions := Binarymap.mkDict String.compare;
fun lease_event state attempt =
  "{\"type\":\"action\",\"input_key\":\"key\",\"state\":\"" ^ state ^ "\",\"attempts\":" ^ Int.toString attempt ^ "}";
val _ = List.app (fn (state, attempt) => HolbuildCommandSummary.observe_action ("batch", lease_event state attempt))
  [("running", 1), ("waiting", 1), ("ready", 1), ("running", 2), ("done", 2)];
val snapshots = map #2 (Binarymap.listItems (!HolbuildCommandSummary.actions));
val _ = if length snapshots = 2 andalso
    List.exists (fn line => HolbuildCommandSummary.integer_field "attempts" line = SOME 1) snapshots
  then () else raise Fail "lost the observed attempt whose lease expired without a result";

fun reset () =
  (HolbuildCommandSummary.actions := Binarymap.mkDict String.compare;
   HolbuildCommandSummary.executions := Binarymap.mkDict String.compare);
val _ = reset ();
val _ = List.app (fn (state, attempt) => HolbuildCommandSummary.observe_action ("batch", lease_event state attempt))
  [("running", 1), ("waiting", 1), ("done", 2)];
val snapshots = map #2 (Binarymap.listItems (!HolbuildCommandSummary.actions));
val _ = if length snapshots = 2 andalso
    List.exists (fn line => HolbuildCommandSummary.integer_field "attempts" line = SOME 1) snapshots
  then () else raise Fail "lost an expired lease when the retry completed between polls";

val _ = reset ();
fun retry_event state attempt began =
  "{\"type\":\"action\",\"input_key\":\"key\",\"state\":\"" ^ state ^ "\",\"attempts\":" ^ Int.toString attempt ^
  ",\"last_failure\":\"unavailable\",\"timings\":{\"started\":" ^ Int.toString began ^ "}}";
val _ = HolbuildCommandSummary.observe_action ("batch", lease_event "running" 1);
val _ = List.app (fn (state, attempt, began) =>
    HolbuildCommandSummary.observe_action ("batch", retry_event state attempt began))
  [("waiting", 1, 1000), ("running", 2, 1000), ("waiting", 2, 1000), ("running", 3, 1000), ("done", 3, 5000)];
val snapshots = map #2 (Binarymap.listItems (!HolbuildCommandSummary.actions));
val expired = List.filter (fn line => HolbuildCommandSummary.integer_field "attempts" line = SOME 2) snapshots;
val _ = if length snapshots = 3 andalso length expired = 1 andalso
    Option.isSome (HolbuildStatus.find_substring "\"timings_current\":false" (hd expired))
  then () else raise Fail "inherited result timings hid an expired retry";
