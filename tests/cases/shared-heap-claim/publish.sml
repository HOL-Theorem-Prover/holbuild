val root = valOf (OS.Process.getEnv "HOLBUILD_ROOT");
val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";
structure BE = HolbuildBuildExec;
structure RC = HolbuildRemoteCache;
fun env name = valOf (OS.Process.getEnv name);
fun assert message ok = if ok then () else raise Fail message;
val claim = BE.shared_heap_claim_text "other";
val active = BE.shared_heap_claim_active "me" 1000;
val _ = assert "a fresh claim by another worker holds the heap" (active (claim 1000));
val _ = assert "a worker's own claim doesn't hold it off" (not (BE.shared_heap_claim_active "other" 1000 (claim 1000)));
val _ = assert "a claim holds the heap until it lapses" (active (claim 701));
val _ = assert "a lapsed claim holds nothing" (not (active (claim 700)));
val _ = assert "a released claim holds nothing" (not (active (claim 0)));
val _ = assert "a claim up to a minute ahead holds the heap" (active (claim 1060));
val _ = assert "a claim further ahead holds nothing" (not (active (claim 1061)));
val upload = BE.shared_heap_claim_holds BE.shared_heap_upload_seconds "me" 1000;
val _ = assert "a claim within an upload's lifetime holds the heap for a restore" (upload (claim 876));
val _ = assert "a claim older than any live upload holds nothing for a restore" (not (upload (claim 875)));
val _ = assert "an unreadable claim holds nothing" (not (active "holbuild-shared-heap-claim-v1\nowner=other\ntime=soon\n"));
val dir = env "PUBLISH_DIR";
val url = env "CLAIM_URL";
val tree = dir ^ "/checkpoints";
val base = dir ^ "/base.save";
val deps = tree ^ "/deps.save";
val _ = BE.ensure_dir tree;
val _ = PolyML.SaveState.saveState base;
(* Saved after the base, so each publisher's heap has its own bytes. *)
val publisher = env "PUBLISHER";
val _ = PolyML.SaveState.saveChild (deps, length (PolyML.SaveState.showHierarchy ()));
val _ = BE.write_text (deps ^ ".ok") (BE.deps_checkpoint_ok_text "deps");
val ctx : BE.shared_context =
  {store = dir ^ "/store", checkpoint_root = tree, heap_key = env "HEAP_KEY", index_key = "index", standalone_key = "standalone", base_state = base,
   deps_key = "deps", deps_loaded = deps, requested_timeout = NONE, candidates = [], module_store = "", heap_only = false, modules = false};
val _ = HolbuildRemoteCacheConfig.set_url url;
val _ = RC.fail_closed := true;
val _ = BE.write_text (dir ^ "/heap.sha") (HolbuildHash.file_sha256 deps);
(* As if the preload had saved it, with no theory modules: a heap no
   capture saw isn't published. *)
val _ = BE.captured_deps_heap := SOME (HolbuildHash.file_sha256 deps);
val _ = BE.ensure_dir (tree ^ "/modules");
val _ = BE.captured_heap_modules := SOME {dir = tree ^ "/modules", modules = []};
val _ = BE.publish_shared_checkpoints (RC.remote url) ctx
  {heap = NONE, files = [], stale = [], missing = [], poisoned = NONE, entry = NONE} NONE;
