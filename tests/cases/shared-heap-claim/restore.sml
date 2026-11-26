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
(* GATED: compiled, wait for the test's go, so a timed step doesn't include
   compiling holbuild.  A test that ends without a go leaves no process
   behind: the wait gives up after the test's own 300 s deadline. *)
val _ =
  case OS.Process.getEnv "GATED" of
      SOME _ =>
        let
          val deadline = Time.+ (Time.now (), Time.fromSeconds 300)
          fun await () =
            if OS.FileSys.access (dir ^ "/go", []) then ()
            else if Time.>= (Time.now (), deadline) then OS.Process.exit OS.Process.failure
            else (OS.Process.sleep (Time.fromMilliseconds 10); await ())
        in BE.write_text (dir ^ "/ready") ""; await () end
    | NONE => ();
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
             deps_loaded = tree ^ "/deps.save", requested_timeout = NONE, candidates = [], module_store = "", heap_only = false, modules = false}
          val _ = BE.restore_steps := []
          val {heap, ...} = BE.restore_shared_checkpoints remote ctx false (fn _ => {other_ids = [], lost = []}) (fn _ => false)
          val waited = List.exists (fn (name, _) => name = "rstwait") (!BE.restore_steps)
        in
          write (getOpt (heap, "none") ^ (if waited then " waited" else ""))
        end;
