val _ = OS.FileSys.chDir (valOf (OS.Process.getEnv "HOLBUILD_ROOT"));
use "sml/holbuild-script.sml";
structure D = HolbuildCacheDiscovery;
structure RC = HolbuildRemoteCache;
fun assert message ok = if ok then () else raise Fail message;
val dir = valOf (OS.Process.getEnv "DISCOVERY_DIR");
val defaults = ["https://ci:password@a.example", "https://ci:password@b.example"];
(* Discovered members must resolve here; permanent ones are kept even when they don't. *)
val identities = ["https://a.example", "https://b.example"] @
  map (fn port => "https://localhost:" ^ port) ["4403", "4404", "4405", "4406"];
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
  ((ignore (D.parse defaults (D.allowed defaults) (snapshot ^ "https://attacker.example\n")); false)
   handle D.Error _ => true);
val _ = assert "reject API credentials"
  ((ignore (D.parse defaults (D.allowed defaults) (header ^ String.concatWith "\n" nodes)); false)
   handle D.Error _ => true);
val _ = assert "reject missing permanent member"
  ((ignore (D.parse defaults (D.allowed defaults) (header ^ String.concatWith "\n" (tl identities))); false)
   handle D.Error _ => true);
fun refused f = (ignore (f ()); false) handle D.Error _ => true;
val _ = assert "credentials never reach a plain-HTTP endpoint"
  (refused (fn () => D.check_plain_http defaults "http://g.example"));
val plain = ["http://a.example"];
val _ = assert "a credential-free pool may use plain HTTP"
  (D.check_plain_http plain "http://g.example" = "http://g.example");
val _ = HolbuildRemoteCacheConfig.set_local_curl_config (SOME (dir ^ "/cache.curl"));
val _ = assert "a cache curl config counts as credentials"
  (refused (fn () => D.check_plain_http plain "http://g.example") andalso refused (fn () => D.allowed plain));
val _ = HolbuildRemoteCacheConfig.set_local_curl_config NONE;
val _ = assert "plain-HTTP permanent nodes with credentials disable discovery"
  (refused (fn () => D.allowed ["http://ci:password@a.example"]));
val digest = HolbuildHash.string_sha256 "join-window";
val ranked = RC.ranked_urls cache digest;
val former = List.last ranked;
val asked = ref ([] : string list);
val asked_mutex = Mutex.mutex ();
fun note url = (Mutex.lock asked_mutex; asked := !asked @ [url]; Mutex.unlock asked_mutex);
fun request url = (note url;
  HolbuildHttp.Response (if url = former then 200 else 404));
(* A GET asks the node its probe found the entry on again, for the body. *)
val _ = assert "reads reach a node below rank two"
  (#2 (RC.routed_status "GET" ranked "" request) = HolbuildHttp.Response 200 andalso length (!asked) = 7);
val _ = asked := [];
val _ = assert "HEAD reaches a node below rank two"
  (#2 (RC.routed_status "HEAD" ranked "" request) = HolbuildHttp.Response 200 andalso length (!asked) = 6);
val _ = asked := [];
fun unavailable url = (note url; HolbuildHttp.Response 503);
val _ = ignore (RC.routed_status "PUT" ranked "" unavailable);
val _ = assert "writes retain two-node bound" (length (!asked) = 2);
val _ = asked := [];
fun unresolved url = (note url;
  if url = List.nth (ranked, 2) then HolbuildHttp.Response 201 else HolbuildHttp.Failed "Couldn't resolve host name");
val _ = assert "writes pass nodes that never answered"
  (#2 (RC.routed_status "PUT" ranked "" unresolved) = HolbuildHttp.Response 201 andalso length (!asked) = 3);
val _ = asked := [];
fun answered url = (note url;
  if url = hd ranked then HolbuildHttp.Failed "Couldn't resolve host name" else HolbuildHttp.Response 503);
val _ = ignore (RC.routed_status "PUT" ranked "" answered);
val _ = assert "writes stop at two nodes once one answered" (length (!asked) = 2);
val _ = asked := [];
fun missing url = (note url; HolbuildHttp.Response 404);
val _ = assert "a miss asks every node"
  (#2 (RC.routed_status "GET" ranked "" missing) = HolbuildHttp.Response 404 andalso length (!asked) = 6);
val _ = asked := [];
fun two_retired url = (note url;
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
val _ = assert "recovery from permanent fallback restores the ring" (D.urls defaults = nodes);
val _ = D.attempted := Time.zeroTime;
val _ = RC.write_text (dir ^ "/body") (header ^ String.concatWith "\n" (List.take (identities, 2)));
val _ = assert "scale-in withdraws burst members" (D.urls defaults = defaults);
val _ = D.attempted := Time.zeroTime;
val _ = RC.write_text (dir ^ "/body") (snapshot ^ "https://g.invalid\n");
val _ = assert "a member whose name does not resolve is left out" (D.urls defaults = nodes);
val _ = print "cache discovery passed\n";
