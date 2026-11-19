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
val four = env "RING_FOUR";
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
fun node_dir node =
  dir ^ (if node = one then "/one" else if node = two then "/two" else if node = three then "/three" else "/four");
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
val _ = assert "request keeps inline credentials" (RC.required (fn () => fetch auth_cache digest) = CB.Hit);
val _ = clear backup "authorization";
val _ = assert "an optional GET ends at the primary's 404" (fetch cache digest = CB.Miss);
val _ = assert "an optional HEAD ends at the primary's 404" (not (RC.blob_present cache digest));
val _ = assert "GET 404 handoff" (RC.required (fn () => fetch cache digest) = CB.Hit andalso RC.read_text dst = text);
val _ = assert "HEAD 404 handoff"
  (RC.required (fn () => RC.blob_present cache digest));
val key = "handoff-action";
val ac = RC.remote_action_key key;
val [ac_primary, ac_backup] = RC.ranked_urls cache ac;
val _ = RC.write_text (stored ac_backup "ac" ac) (RC.metadata_text text []);
val _ = assert "AC GET 404 handoff" (RC.required (fn () => RC.get_action cache key) = SOME text);
fun transient_case code =
  (put primary "get-status" code;
   put primary "head-status" code;
   put primary "cas-put-status" code;
   assert "GET transient fallback" (fetch cache digest = CB.Hit);
   assert "HEAD transient fallback" (RC.blob_present cache digest);
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
fun unavailable f = (ignore (f ()); false) handle RC.Unavailable _ => true;
val _ = put primary "get-status" "503";
val _ = assert "transient plus missing is a miss" (fetch cache digest = CB.Miss);
val _ = assert "a required read of transient plus missing is unavailable"
  (unavailable (fn () => RC.required (fn () => fetch cache digest)));
val _ = assert "a required read ends with its thread" (fetch cache digest = CB.Miss);
val _ = put backup "get-status" "503";
val _ = assert "both transient reports backup"
  ((ignore (fetch auth_cache digest); false)
   handle RC.Unavailable message =>
     String.isSubstring (RC.redact_userinfo (authenticated backup) ^ "/cas/" ^ digest) message andalso
     not (String.isSubstring "user:pass" message));
val _ = clear primary "get-status";
val _ = assert "missing plus transient is a miss" (fetch cache digest = CB.Miss);
val _ = assert "a required read of missing plus transient is unavailable"
  (unavailable (fn () => RC.required (fn () => fetch cache digest)));
val _ = put backup "get-status" "403";
val _ = assert "an optional read never asks the backup after a 404" (fetch auth_cache digest = CB.Miss);
val _ = assert "backup authorization failure overrides miss and names backup"
  (case RC.required (fn () => fetch auth_cache digest) of
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
val _ = assert "an optional miss ends at the first node" (RC.get_action replicas theory_key = NONE);
val _ = assert "a required miss walks the whole ring"
  (RC.required (fn () => RC.get_action replicas theory_key) = SOME (theory_manifest "10.0"));
val _ = RC.remove_file (stored third "ac" theory_ac);
val _ = assert "missing everywhere is a miss" (RC.get_action replicas theory_key = NONE);

(* Past two 404s a read probes the rest of the ring with HEAD, then GETs
   only from the nodes whose probe found the entry, in rank order. *)
val quad = RC.remote (String.concatWith "," [one, two, three, four]);
fun requests node =
  String.tokens (fn c => c = #"\n") (RC.read_text (node_dir node ^ "/state/requests.log"));
fun asked_during f =
  let
    val nodes = RC.ranked_urls quad theory_ac
    val before = map (length o requests) nodes
    val result = f ()
  in
    (result, ListPair.map (fn (node, n) =>
       List.mapPartial (fn line => case String.tokens Char.isSpace line of
                                       [method, path] => if String.isSuffix theory_ac path then SOME method else NONE
                                     | _ => NONE)
                       (List.drop (requests node, n))) (nodes, before))
  end;
val [q1, _, q3, q4] = RC.ranked_urls quad theory_ac;
fun required f = RC.required f;
(* An optional read ends at the first plain 404: every node serves what the
   shared backing store holds, so it misses only an entry another node took
   moments ago.  A required read still walks the ring. *)
val _ = seed q4 (theory_manifest "10.0");
val _ = assert "an optional miss asks one node"
  (asked_during (fn () => RC.get_action quad theory_key) = (NONE, [["GET"], [], [], []]));
val _ = assert "a required read finds an entry only the last node holds"
  (asked_during (fn () => required (fn () => RC.get_action quad theory_key)) =
   (SOME (theory_manifest "10.0"), [["GET"], ["GET"], ["HEAD"], ["HEAD", "GET"]]));
val _ = seed q3 (theory_manifest "none");
val _ = assert "probes pass a weaker copy over for a stronger later one"
  (asked_during (fn () => required (fn () => RC.get_action_using timed quad theory_key)) =
   (SOME (theory_manifest "10.0"), [["GET"], ["GET"], ["HEAD", "GET"], ["HEAD", "GET"]]));
val _ = RC.remove_file (stored q3 "ac" theory_ac);
val _ = seed q1 (theory_manifest "none");
val _ = assert "an optional read past a weaker copy looks on for a stronger one"
  (asked_during (fn () => RC.get_action_using timed quad theory_key) =
   (SOME (theory_manifest "10.0"), [["GET"], ["GET"], ["GET"], ["HEAD", "GET"]]));
val _ = RC.remove_file (stored q1 "ac" theory_ac);
(* A client restoring what a remote batch reported done reads it as
   required, on whichever thread copies it. *)
val local_root = dir ^ "/local-cache";
val _ = List.app (fn node => RC.write_text (stored node "cas" digest) text) (RC.ranked_urls quad digest);
fun copy () = HolbuildBuildExec.copy_remote_cache_entry local_root (RC.base_url quad) theory_key;
val _ = assert "a client reads a key no batch reported done as optional"
  (asked_during copy = (false, [["GET"], [], [], []]));
(* The blobs a found entry names are read as required, as the entry can
   reach the store before them. *)
val _ = seed q1 (theory_manifest "10.0");
val _ = List.app (fn node => RC.remove_file (stored node "cas" digest)) (List.take (RC.ranked_urls quad digest, 3));
val _ = assert "a client restores an entry whose blob only the last node holds"
  (HolbuildBuildExec.copy_remote_cache_entry (dir ^ "/local-cache-2") (RC.base_url quad) theory_key andalso
   HolbuildCache.get_action (dir ^ "/local-cache-2") theory_key = SOME (theory_manifest "10.0"));
val _ = RC.remove_file (stored q1 "ac" theory_ac);
val _ = List.app (fn node => RC.write_text (stored node "cas" digest) text) (RC.ranked_urls quad digest);
val _ = HolbuildBuildExec.expect_remote_entry theory_key;
val _ = assert "a client reads a key a batch reported done as required"
  (#1 (asked_during copy) andalso
   HolbuildCache.get_action local_root theory_key = SOME (theory_manifest "10.0"));
(* A shared-checkpoint blob is read as required: the manifest naming it can
   reach the store before the blob does. *)
val blob_nodes = RC.ranked_urls quad digest;
val _ = List.app (fn node => RC.remove_file (stored node "cas" digest)) (List.take (blob_nodes, 3));
val placed = dir ^ "/placed-blob";
val _ = HolbuildBuildExec.place_shared_blob quad (dir ^ "/shared-store") "family"
          {sha = digest, dst = placed, save = false};
val _ = assert "a shared blob only the last node holds is placed" (RC.read_text placed = text);
val _ = RC.remove_file (stored q4 "ac" theory_ac);
val _ = assert "a required miss asks two nodes, then probes the rest"
  (asked_during (fn () => required (fn () => RC.get_action quad theory_key)) =
   (NONE, [["GET"], ["GET"], ["HEAD"], ["HEAD"]]));
val _ = put q1 "get-status" "503";
val _ = assert "an optional read goes past a failed node to the next one's 404"
  (asked_during (fn () => RC.get_action quad theory_key) = (NONE, [["GET"], ["GET"], [], []]));
val _ = clear q1 "get-status";
val _ = put q3 "head-status" "503";
val _ = assert "a required read with a probe's 503 beside 404s is unavailable"
  (unavailable (fn () => required (fn () => RC.get_action quad theory_key)));
val _ = seed q4 (theory_manifest "10.0");
val _ = assert "a probe's 503 does not hide a later hit"
  (#1 (asked_during (fn () => required (fn () => RC.get_action quad theory_key))) = SOME (theory_manifest "10.0"));
val _ = clear q3 "head-status";
val _ = RC.remove_file (stored q4 "ac" theory_ac);

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
val _ = assert "an optional reader preferring other nodes misses a fresh write"
  (fetch replicas preferred_hash = CB.Miss);
val _ = assert "a required reader preferring other nodes still finds it"
  (RC.required (fn () => fetch replicas preferred_hash) = CB.Hit andalso RC.read_text dst = preferred_text);
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

(* An entry replaced in place (a checkpoint index) goes to every node: a node
   answers from its own disk, so one still holding the old entry would serve
   it.  A node failing that write doesn't fail the publication or trip the
   breaker; ranked theory entries keep the single write. *)
val index_key = "replica-checkpoint-index";
val index_ac = RC.remote_action_key index_key;
fun index_text n = "holbuild-shared-checkpoint-index-v1\ncheckpoint=" ^ Int.toString n ^ "\n";
fun index_at node = #manifest (RC.metadata_manifest (RC.read_text (stored node "ac" index_ac)));
fun seed_index node text = RC.write_text (stored node "ac" index_ac) (RC.metadata_text text []);
val _ = List.app (fn node => seed_index node (index_text 1)) [first, second, third];
val _ = assert "replace everywhere publishes"
  (RC.replace_action_everywhere replicas {key = index_key, text = index_text 2} = CB.Published);
val _ = assert "replace everywhere refreshes every node"
  (List.all (fn node => index_at node = index_text 2) [first, second, third]);
val [index_first, index_second, index_third] = RC.ranked_urls replicas index_ac;
val _ = put index_third "ac-put-status" "503";
val _ = assert "a failed replica write does not fail the publication"
  (RC.replace_action_everywhere replicas {key = index_key, text = index_text 3} = CB.Published);
val _ = clear index_third "ac-put-status";
val _ = assert "the other nodes took it"
  (index_at index_first = index_text 3 andalso index_at index_second = index_text 3);
val _ = assert "the failed node keeps its entry" (index_at index_third = index_text 2);
(* A node that takes the write and never answers costs the refresh its
   short stall timeout, not the ordinary one. *)
val _ = put index_third "ac-put-hold" "";
val hold_timer = Timer.startRealTimer ();
val _ = RC.replace_action_everywhere replicas {key = index_key, text = index_text 7};
val hold_seconds = Time.toSeconds (Timer.checkRealTimer hold_timer);
val _ = clear index_third "ac-put-hold";
val _ = assert ("a stalled replica held the refresh " ^ LargeInt.toString hold_seconds ^ " s") (hold_seconds < 15);
(* Three nodes with no answer, which as primary writes would trip the
   breaker, are skipped by the refresh without counting. *)
val dead = RC.remote (one ^ ",http://127.0.0.1:1,http://127.0.0.1:2,http://127.0.0.1:3");
fun dead_key n =
  let val key = "replica-dead-" ^ Int.toString n
  in if hd (RC.ranked_urls dead (RC.remote_action_key key)) = one then key else dead_key (n + 1) end;
val _ = assert "unanswered replica writes do not fail the publication"
  (RC.replace_action_everywhere dead {key = dead_key 0, text = index_text 5} = CB.Published);
val _ = assert "unanswered replica writes do not trip the breaker" (not (RC.tripped ()));
val _ = List.app (fn node => seed_index node (index_text 1)) [first, second, third];
val _ = RC.refresh_replicas := false;
val _ = assert "an interrupted action's replacement writes one node"
  (RC.replace_action_everywhere replicas {key = index_key, text = index_text 6} = CB.Published andalso
   length (List.filter (fn node => index_at node = index_text 6) [first, second, third]) = 1);
val _ = RC.refresh_replicas := true;
val _ = List.app (fn node => seed_index node (index_text 1)) [first, second, third];
val _ = RC.replace_action_unconditionally replicas {key = index_key, text = index_text 4};
val _ = assert "a plain replacement writes one node"
  (length (List.filter (fn node => index_at node = index_text 4) [first, second, third]) = 1);
val _ = print "cache ring passed\n";
