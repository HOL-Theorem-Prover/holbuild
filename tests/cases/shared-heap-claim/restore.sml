val root = valOf (OS.Process.getEnv "HOLBUILD_ROOT");
val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";
structure BE = HolbuildBuildExec;
structure RC = HolbuildRemoteCache;
fun env name = valOf (OS.Process.getEnv name);
val dir = env "PUBLISH_DIR";
val url = env "CLAIM_URL";
val heap_key = env "HEAP_KEY";
val _ = HolbuildRemoteCacheConfig.set_url url;
val _ = RC.fail_closed := true;
val remote = RC.remote url;
fun write result = BE.write_text (dir ^ "/result") result;
val _ =
  case OS.Process.getEnv "WAIT_SECONDS" of
      SOME seconds =>
        (* The wait alone, with a deadline the test can afford. *)
        write (case BE.await_shared_heap remote heap_key
                      (Time.+ (Time.now (), Time.fromSeconds (valOf (LargeInt.fromString seconds)))) of
                   SOME _ => "heap"
                 | NONE => "none")
    | NONE =>
        let
          val tree = dir ^ "/checkpoints"
          val _ = BE.ensure_dir tree
          val ctx : BE.shared_context =
            {store = dir ^ "/store", checkpoint_root = tree, heap_key = heap_key, index_key = "index", standalone_key = "standalone",
             base_state = OS.FileSys.fullPath (env "BASE_STATE"), deps_key = "deps",
             deps_loaded = tree ^ "/deps.save", requested_timeout = NONE, candidates = []}
          val _ = BE.restore_steps := []
          val {heap, ...} = BE.restore_shared_checkpoints remote ctx false
          val waited = List.exists (fn (name, _) => name = "rstwait") (!BE.restore_steps)
        in
          write (getOpt (heap, "none") ^ (if waited then " waited" else ""))
        end;
