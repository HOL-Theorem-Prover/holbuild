val root = valOf (OS.Process.getEnv "HOLBUILD_ROOT");
val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";
structure BE = HolbuildBuildExec;
structure RC = HolbuildRemoteCache;
fun env name = valOf (OS.Process.getEnv name);
fun assert message ok = if ok then () else raise Fail message;
val dir = env "PUBLISH_DIR";
val url = env "PUBLISH_URL";
val failing = env "PUBLISH_FAIL" = "1";
val tree = dir ^ "/checkpoints";
val store = dir ^ "/store";
val deps = tree ^ "/deps.save";
val base = dir ^ "/base.save";
val count = if failing then 24 else 451;
fun path i = tree ^ "/c" ^ Int.toString i ^ ".save";
fun sidecar i = BE.checkpoint_ok_text "theorem_context"
  [("proof_timeout", "none"), ("test", "checkpoint-" ^ Int.toString i)];
val _ = BE.ensure_dir tree;
val _ = PolyML.SaveState.saveState base;
fun save p = PolyML.SaveState.saveChild (p, length (PolyML.SaveState.showHierarchy ()));
val _ = save deps;
val _ = BE.write_text (deps ^ ".ok") (BE.deps_checkpoint_ok_text "deps");
val _ = List.app (fn i => (save (path i); BE.write_text (path i ^ ".ok") (sidecar i)))
                 (List.tabulate (count, fn i => i + 1));
(* An interrupted final save is neither uploaded nor advertised. *)
val partial = "partial-uncommitted-save";
val _ = BE.remove_file (path count ^ ".ok");
val _ = BE.write_text (path count ^ ".ok.tmp") "not committed";
val _ = BE.write_text (path count) partial;
fun candidate i : BE.shared_candidate =
  {kind = "theorem_context", key = Int.toString i, boundary = i,
   path = path i, sidecars = [".ok"], accepts = fn () => true};
val candidates = rev (List.tabulate (count, fn i => candidate (i + 1)));
val ctx : BE.shared_context =
  {store = store, checkpoint_root = tree, heap_key = "heap", base_state = base,
   deps_key = "deps", deps_loaded = deps, requested_timeout = NONE,
   candidates = candidates @ [candidate 1]};
val heap = HolbuildHash.file_sha256 deps;
val bad = HolbuildHash.file_sha256 (path 12 ^ ".ok");
val cache = RC.remote url;
val _ = HolbuildRemoteCacheConfig.set_url url;
val _ = RC.fail_closed := true;
val _ = assert "heap upload" (RC.publish_hashed_blob cache {hash = heap, src = deps} = HolbuildCacheBackend.Published);
val _ = ignore (RC.publish_action cache
  {key = "heap", text = BE.shared_manifest "holbuild-shared-heap-v1" NONE [("heap", heap, "")]});
(* Reproduce has_blob=true for a blob a previous restore found missing. *)
val _ = if failing then RC.remember_blob cache {sha256 = bad, size = Position.toString (OS.FileSys.fileSize (path 12 ^ ".ok"))} else ();
fun checkpoint name =
  let
    fun wait () = if BE.file_exists (dir ^ "/" ^ name ^ ".release") then ()
                  else (OS.Process.sleep (Time.fromMilliseconds 10); wait ());
  in BE.write_text (dir ^ "/" ^ name ^ ".ready") "ready"; wait () end;
val _ = checkpoint "publish";
val _ = BE.publish_shared_checkpoints cache ctx
  {heap = SOME heap, files = [], stale = [], missing = if failing then [bad] else []};
(* An edit can request the next action immediately after publication. Do
   this before repeat publication or repair, with no local files or store. *)
fun restore_latest () =
  let
    val _ = BE.remove_tree tree
    val _ = BE.remove_tree store
    val restored = BE.restore_shared_checkpoints (RC.remote url) ctx
    val latest = if failing then 11 else count - 1
  in
    assert "restored latest complete candidate"
      (List.exists (fn (p, _) => p = path latest) (#files restored));
    assert "restored heap" (#heap restored = SOME heap)
  end;
val _ = restore_latest ();
val _ = checkpoint "published";
(* Existing manifests skip all uploads. *)
val _ = if failing then () else BE.publish_shared_checkpoints cache ctx
  {heap = SOME heap, files = [], stale = [], missing = []};
val _ = checkpoint "repeated";
val _ = if failing then () else
  let
    (* A present manifest names a lost CAS blob; a different, missing
       manifest still needs that blob. Probes must not poison has_blob. *)
    val sha = HolbuildHash.file_sha256 (path 5 ^ ".ok")
    val key = BE.shared_checkpoint_key "heap" "theorem_context" "6"
    val _ = BE.remove_file (dir ^ "/remote/cas/" ^ sha)
    val _ = BE.remove_file (dir ^ "/remote/ac/" ^ RC.remote_action_key key)
    val fresh = RC.remote url
    val _ = RC.remember_blob fresh {sha256 = heap, size = Position.toString (OS.FileSys.fileSize deps)}
    val _ = BE.publish_shared_checkpoints fresh ctx {heap = SOME heap, files = [], stale = [], missing = []}
  in assert "un-restored manifests must not hide a missing blob" (BE.file_exists (dir ^ "/remote/cas/" ^ sha)) end;
val _ = checkpoint "repaired";
val _ = restore_latest ();
val _ = print "shared checkpoint publication passed\n";
