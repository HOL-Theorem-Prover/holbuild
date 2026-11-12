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
