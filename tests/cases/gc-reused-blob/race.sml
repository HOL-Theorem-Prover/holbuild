(* A build reuses a blob older than the GC cutoff between GC's snapshot of the
   live manifests and its blob sweep, then writes a manifest referencing it. *)
val _ = OS.FileSys.chDir (valOf (OS.Process.getEnv "HOLBUILD_ROOT"));
use "sml/holbuild-script.sml";
val root = valOf (OS.Process.getEnv "HOLBUILD_CACHE");
val hash = valOf (OS.Process.getEnv "BLOB_HASH");
val src = valOf (OS.Process.getEnv "BLOB_SRC");
val cutoff = HolbuildCache.retention_cutoff HolbuildCache.default_retention_days;
val (live, _) = HolbuildCache.collect_live_actions cutoff (HolbuildCache.actions_dir root);
val _ =
  case HolbuildCache.publish_blob root {hash = hash, src = src} of
      HolbuildCacheBackend.AlreadyPresent => ()
    | _ => raise Fail "expected publish_blob to reuse the cached blob";
val _ = HolbuildCache.put_action root HolbuildCacheBackend.PutIfAbsentOrSame
          {key = "reuser", text = "holbuild-cache-action-v2\nblob dat " ^ hash ^ "\n"};
val _ = HolbuildCache.sweep_blobs cutoff live (HolbuildCache.blobs_dir root);
val _ = print (if HolbuildCache.has_blob root hash then "blob-kept\n" else "blob-swept\n");
