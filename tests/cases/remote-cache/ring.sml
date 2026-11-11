val root = valOf (OS.Process.getEnv "HOLBUILD_ROOT");
val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";
structure RC = HolbuildRemoteCache;
structure CB = HolbuildCacheBackend;
fun env name = valOf (OS.Process.getEnv name);
val dir = env "RING_DIR";
val one = env "RING_ONE";
val two = env "RING_TWO";
val three = env "RING_THREE";
fun assert message ok = if ok then () else raise Fail message;
val cache = RC.remote (one ^ "///, " ^ two ^ "/ " ^ one);
val reversed = RC.remote (two ^ "," ^ one);
val _ = assert "normalize ring" (RC.base_url cache = one ^ "," ^ two);
fun authenticated url = "http://user:pass@" ^ String.extract (url, 7, NONE);
val auth_cache = RC.remote (authenticated one ^ "," ^ authenticated two ^ "," ^ one);
val _ = assert "identity deduplicates credentials" (RC.base_url auth_cache = authenticated one ^ "," ^ authenticated two);
val _ = assert "IPv6 and path userinfo"
  (HolbuildRemoteCacheConfig.node_identity "http://user:p@ss@[::1]:8080/path@name" = "http://[::1]:8080/path@name");
val _ = assert "query userinfo remains outside authority"
  (HolbuildRemoteCacheConfig.node_identity "http://host?name@value" = "http://host?name@value");
val _ = HolbuildRemoteCacheConfig.set_url (RC.base_url cache);
val _ = if env "RING_TRANSPORT" = "libcurl" then HolbuildRemoteCacheConfig.setup_client () else ();
val _ = assert "requested HTTP transport"
  (HolbuildRemoteCacheConfig.uses_libcurl () = (env "RING_TRANSPORT" = "libcurl"));
val _ = RC.fail_closed := true;
fun node_dir node = dir ^ (if node = one then "/one" else if node = two then "/two" else "/three");
fun control node name = node_dir node ^ "/control/" ^ name;
fun stored node kind digest = node_dir node ^ "/store/" ^ kind ^ "/" ^ digest;
fun put node name text = RC.write_text (control node name) text;
fun clear node name = RC.remove_file (control node name);
val src = dir ^ "/source";
val dst = dir ^ "/download";
fun fetch remote digest = RC.fetch_unlisted_blob remote {hash = digest, dst = dst};
fun publish remote digest = RC.put_blob remote {hash = digest, src = src};

(* Expectations come from Python's hashlib against actual node URLs. *)
val vectors = String.tokens (fn c => c = #"\n") (RC.read_text (dir ^ "/vectors"));
fun check_vector line =
  let
    val [digest, primary, backup] = String.tokens Char.isSpace line
    val _ = assert "SML/Python ranking agrees" (RC.ranked_urls cache digest = [primary, backup])
    val _ = assert "credentials do not change rankings"
      (RC.ranked_urls auth_cache digest = map authenticated [primary, backup])
    val _ = assert "order independent" (RC.ranked_urls reversed digest = [primary, backup])
    val _ = RC.write_text src digest
    (* curl PUT takes arbitrary digest paths; publish a real digest below. *)
    val _ = assert "CAS primary PUT"
      (RC.curl_put_urls [] {urls = RC.cas_urls cache digest, src = src} = CB.Published)
    val _ = assert "CAS sharding" (RC.path_exists (stored primary "cas" digest) andalso
                                  not (RC.path_exists (stored backup "cas" digest)))
    val _ = assert "AC primary PUT"
      (RC.publish_action_metadata cache digest (RC.metadata_text digest []) = CB.Published)
    val ac = RC.remote_action_key digest
    val owner = hd (RC.ranked_urls cache ac)
    val _ = assert "AC sharding" (RC.path_exists (stored owner "ac" ac))
  in () end;
val _ = List.app check_vector vectors;

val text = "ring payload";
val digest = HolbuildHash.string_sha256 text;
val [primary, backup] = RC.ranked_urls cache digest;
val _ = RC.write_text src text;
val _ = RC.write_text (stored backup "cas" digest) text;
val _ = put backup "authorization" "Basic dXNlcjpwYXNz";
val _ = assert "request keeps inline credentials" (fetch auth_cache digest = CB.Hit);
val _ = clear backup "authorization";
val _ = assert "GET 404 handoff" (fetch cache digest = CB.Hit andalso RC.read_text dst = text);
val _ = assert "HEAD 404 handoff" (RC.blob_present cache digest andalso RC.blob_confirmed_present cache digest);
val key = "handoff-action";
val ac = RC.remote_action_key key;
val [ac_primary, ac_backup] = RC.ranked_urls cache ac;
val _ = RC.write_text (stored ac_backup "ac" ac) (RC.metadata_text text []);
val _ = assert "AC GET 404 handoff" (RC.get_action cache key = SOME text);
fun transient_case code =
  (put primary "get-status" code;
   put primary "head-status" code;
   put primary "cas-put-status" code;
   assert "GET transient fallback" (fetch cache digest = CB.Hit);
   assert "HEAD transient fallback" (RC.blob_present cache digest andalso RC.blob_confirmed_present cache digest);
   assert "PUT transient fallback" (publish cache digest = CB.Published);
   clear primary "get-status"; clear primary "head-status"; clear primary "cas-put-status";
   put ac_primary "get-status" code; put ac_primary "ac-put-status" code;
   assert "AC GET transient fallback" (RC.get_action cache key = SOME text);
   assert "AC PUT transient fallback" (RC.publish_action_metadata cache key (RC.metadata_text text []) = CB.Published);
   clear ac_primary "get-status"; clear ac_primary "ac-put-status");
val _ = List.app transient_case ["503", "429"];
val _ = put primary "get-status" "401";
val _ = assert "authorization error is not retried"
  (case fetch cache digest of CB.Corrupt _ => true | _ => false);
val _ = clear primary "get-status";
val _ = RC.remove_file (stored backup "cas" digest);
val _ = assert "both missing" (fetch cache digest = CB.Miss);
val _ = put primary "get-status" "503";
val _ = assert "transient plus missing is a miss" (fetch cache digest = CB.Miss);
val _ = put backup "get-status" "503";
val _ = assert "both transient reports backup"
  ((ignore (fetch auth_cache digest); false)
   handle RC.Unavailable message =>
     String.isSubstring (RC.redact_userinfo (authenticated backup) ^ "/cas/" ^ digest) message andalso
     not (String.isSubstring "user:pass" message));
val _ = clear primary "get-status";
val _ = assert "missing plus transient is a miss" (fetch cache digest = CB.Miss);
val _ = put backup "get-status" "403";
val _ = assert "backup authorization failure overrides miss and names backup"
  (case fetch auth_cache digest of
       CB.Corrupt message => String.isSubstring (RC.redact_userinfo (authenticated backup) ^ "/cas/" ^ digest) message andalso
                             not (String.isSubstring "user:pass" message)
     | _ => false);
val _ = clear backup "get-status";
val _ = put primary "head-status" "503";
val _ = assert "HEAD transient plus missing" (not (RC.blob_present cache digest));
val _ = clear primary "head-status";
val _ = put backup "head-status" "503";
val _ = assert "HEAD missing plus transient" (not (RC.blob_present cache digest));
val _ = clear backup "head-status";

val down = "http://127.0.0.1:1";
val degraded = RC.remote (down ^ "," ^ one);
fun down_digest i =
  let val text = "down " ^ Int.toString i
      val hash = HolbuildHash.string_sha256 text
  in if hd (RC.ranked_urls degraded hash) = down then (text, hash) else down_digest (i + 1) end;
val (down_text, down_hash) = down_digest 0;
val _ = RC.write_text src down_text;
(* More than three successful failovers must not trip the transport breaker. *)
val _ = List.app (fn _ => assert "PUT down-primary fallback" (publish degraded down_hash = CB.Published)) [1,2,3,4];
val _ = assert "GET down-primary fallback" (fetch degraded down_hash = CB.Hit andalso RC.read_text dst = down_text);
val _ = assert "HEAD down-primary fallback" (RC.blob_present degraded down_hash);
val _ = assert "healthy backup keeps ring enabled" (not (RC.disabled ()));

val replicas = RC.remote (one ^ "," ^ two ^ "," ^ three);
val theory_key = "replica-timeout-contract";
val theory_ac = RC.remote_action_key theory_key;
val [first, second, third] = RC.ranked_urls replicas theory_ac;
fun theory_manifest timeout =
  String.concatWith "\n"
    ["holbuild-cache-action-v4", "input_key=" ^ theory_key, "kind=theory",
     "proof-timeout=" ^ timeout, "load-metadata-v1",
     "blob sig " ^ digest, "blob sml " ^ digest, "blob dat " ^ digest, ""];
val blob = {sha256 = digest, size = Int.toString (size text)};
fun seed node manifest = RC.write_text (stored node "ac" theory_ac) (RC.metadata_text manifest [blob]);
fun manifest_at node = #manifest (RC.metadata_manifest (RC.read_text (stored node "ac" theory_ac)));
fun timed manifest = HolbuildBuildExec.manifest_timeout_satisfies false (SOME 10.0) manifest;
val _ = seed first (theory_manifest "none");
val _ = seed second (theory_manifest "none");
val _ = seed third (theory_manifest "10.0");
val _ = assert "two weak replicas do not hide a strict third"
  (RC.get_action_using timed replicas theory_key = SOME (theory_manifest "10.0"));
val _ = RC.remove_file (stored first "ac" theory_ac);
val _ = RC.remove_file (stored second "ac" theory_ac);
val _ = assert "a miss walks the whole ring" (RC.get_action replicas theory_key = SOME (theory_manifest "10.0"));
val _ = RC.remove_file (stored third "ac" theory_ac);
val _ = assert "missing everywhere is a miss" (RC.get_action replicas theory_key = NONE);

(* A preferred node takes writes and is read first; the rest keep rendezvous order. *)
val _ = HolbuildRemoteCacheConfig.set_preferred_urls (authenticated third);
val _ = assert "preferred node ranks first"
  (RC.ranked_urls replicas theory_ac = [third, first, second]);
val preferred_text = "written near";
val preferred_hash = HolbuildHash.string_sha256 preferred_text;
val _ = RC.write_text src preferred_text;
val _ = assert "PUT goes to the preferred node"
  (publish replicas preferred_hash = CB.Published andalso
   RC.path_exists (stored third "cas" preferred_hash) andalso
   not (RC.path_exists (stored first "cas" preferred_hash)) andalso
   not (RC.path_exists (stored second "cas" preferred_hash)));
val _ = HolbuildRemoteCacheConfig.set_preferred_urls (authenticated first ^ "," ^ authenticated second);
val _ = assert "a reader preferring other nodes still finds it"
  (fetch replicas preferred_hash = CB.Hit andalso RC.read_text dst = preferred_text);
val _ = HolbuildRemoteCacheConfig.set_preferred_urls "";
val _ = assert "no preference keeps rendezvous order"
  (RC.ranked_urls replicas theory_ac = [first, second, third]);

val _ = seed first (theory_manifest "10.0");
val _ = seed second (theory_manifest "none");
val _ = seed third (theory_manifest "2.5");
val _ = RC.remember_blob replicas blob;
fun publish_timed () = HolbuildBuildExec.put_remote_theory_action replicas CB.PutIfAbsentOrSame
  {key = theory_key, text = theory_manifest "10.0"};
val _ = assert "strict primary repairs weaker secondary" (publish_timed () = CB.AlreadyPresent);
val _ = assert "weak secondary strengthened" (manifest_at second = theory_manifest "10.0");
val _ = assert "stronger secondary preserved" (manifest_at third = theory_manifest "2.5");
val _ = RC.remove_file (stored second "ac" theory_ac);
val _ = publish_timed ();
val _ = assert "repair does not replicate absent entries" (not (RC.path_exists (stored second "ac" theory_ac)));
val different = theory_manifest "none" ^ "parent different\n";
val _ = seed second different;
val _ = assert "conflicting secondary does not fail primary" (publish_timed () = CB.AlreadyPresent);
val _ = assert "different secondary untouched" (manifest_at second = different);
val _ = seed second (theory_manifest "none");
val _ = put second "get-status" "503";
val _ = List.app (fn _ => assert "secondary outage does not fail publication" (publish_timed () = CB.AlreadyPresent)) [1,2,3,4];
val _ = clear second "get-status";
val _ = assert "secondary outages do not trip primary breaker" (not (RC.disabled ()));
val _ = assert "unavailable secondary untouched" (manifest_at second = theory_manifest "none");
val _ = put second "ac-put-status" "503";
val _ = assert "failed secondary repair does not fail primary" (publish_timed () = CB.AlreadyPresent);
val _ = clear second "ac-put-status";
val _ = assert "failed secondary repair leaves resident intact" (manifest_at second = theory_manifest "none");
val _ = seed second "malformed manifest";
val _ = assert "malformed secondary does not fail primary" (publish_timed () = CB.AlreadyPresent);
val _ = assert "malformed secondary untouched" (manifest_at second = "malformed manifest");
val _ = print "cache ring passed\n";
