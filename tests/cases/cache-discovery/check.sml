val _ = OS.FileSys.chDir (valOf (OS.Process.getEnv "HOLBUILD_ROOT"));
use "sml/holbuild-script.sml";
structure D = HolbuildCacheDiscovery;
structure RC = HolbuildRemoteCache;
fun assert message ok = if ok then () else raise Fail message;
val dir = valOf (OS.Process.getEnv "DISCOVERY_DIR");
val defaults = ["http://ci:password@a.example", "http://ci:password@b.example"];
val identities = map (fn letter => "http://" ^ letter ^ ".example") ["a","b","c","d","e","f"];
val header = "holbuild-cache-members-v1\n";
val snapshot = header ^ String.concatWith "\n" identities ^ "\n";
val cache = RC.remote (String.concatWith "," defaults);
val _ = RC.write_text (dir ^ "/body") snapshot;
val nodes = D.urls defaults;
val _ = assert "discovered all six members" (length nodes = 6);
val _ = assert "credentials come from local config" (List.all (String.isSubstring "ci:password@") nodes);
val _ = assert "one snapshot per thirty seconds" (D.urls defaults = nodes andalso
  RC.read_text (dir ^ "/requests") = "Bearer fixture-token\n");
val _ = assert "reject a new credential recipient"
  ((ignore (D.parse defaults (D.allowed defaults) (snapshot ^ "http://attacker.example\n")); false)
   handle D.Error _ => true);
val _ = assert "reject API credentials"
  ((ignore (D.parse defaults (D.allowed defaults) (header ^ String.concatWith "\n" nodes)); false)
   handle D.Error _ => true);
val _ = assert "reject missing permanent member"
  ((ignore (D.parse defaults (D.allowed defaults) (header ^ String.concatWith "\n" (tl identities))); false)
   handle D.Error _ => true);
val digest = HolbuildHash.string_sha256 "join-window";
val ranked = RC.ranked_urls cache digest;
val former = List.last ranked;
val asked = ref ([] : string list);
fun request url = (asked := !asked @ [url];
  HolbuildHttp.Response (if url = former then 200 else 404));
val _ = assert "join grace reads a former owner below rank two"
  (#2 (RC.routed_status "GET" ranked "" request) = HolbuildHttp.Response 200 andalso length (!asked) = 6);
val _ = asked := [];
val _ = assert "join grace also covers HEAD"
  (#2 (RC.routed_status "HEAD" ranked "" request) = HolbuildHttp.Response 200 andalso length (!asked) = 6);
val _ = asked := [];
fun unavailable url = (asked := !asked @ [url]; HolbuildHttp.Response 503);
val _ = ignore (RC.routed_status "PUT" ranked "" unavailable);
val _ = assert "writes retain two-node bound during joins" (length (!asked) = 2);
val _ = D.joined := Time.- (Time.now (), Time.fromSeconds 61);
val _ = asked := [];
val _ = ignore (RC.routed_status "GET" ranked "" request);
val _ = assert "steady-state misses retain two-node bound" (length (!asked) = 2);
val _ = asked := [];
fun two_retired url = (asked := !asked @ [url];
  HolbuildHttp.Response (if url = former then 200 else if url = List.nth (ranked, 2) then 404 else 503));
val _ = assert "stale readers bypass concurrent drained listeners on transport errors"
  (#2 (RC.routed_status "GET" ranked "" two_retired) = HolbuildHttp.Response 200 andalso length (!asked) = 6);
val _ = D.attempted := Time.zeroTime;
val _ = RC.write_text (dir ^ "/body") "invalid";
val _ = assert "bad snapshot retains last complete ring" (D.urls defaults = nodes);
val _ = D.succeeded := Time.- (Time.now (), Time.fromSeconds 61);
val _ = assert "stale discovery falls back to permanent pair" (D.urls defaults = defaults);
val _ = D.attempted := Time.zeroTime;
val _ = RC.write_text (dir ^ "/body") snapshot;
val _ = assert "recovery from permanent fallback starts join grace" (D.urls defaults = nodes andalso D.joining ());
val _ = D.attempted := Time.zeroTime;
val _ = RC.write_text (dir ^ "/body") (header ^ String.concatWith "\n" (List.take (identities, 2)));
val _ = assert "scale-in withdraws burst members" (D.urls defaults = defaults);
val _ = print "cache discovery passed\n";
