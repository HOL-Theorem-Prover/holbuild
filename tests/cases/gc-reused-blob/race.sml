(* A build reuses a blob older than the GC cutoff between GC's snapshot of the
   live manifests and its blob sweep, then writes a manifest referencing it. *)
val _ = OS.FileSys.chDir (valOf (OS.Process.getEnv "HOLBUILD_ROOT"));
use "sml/holbuild-script.sml";
val root = valOf (OS.Process.getEnv "HOLBUILD_CACHE");
val hash = valOf (OS.Process.getEnv "BLOB_HASH");
val src = valOf (OS.Process.getEnv "BLOB_SRC");
val cutoff = HolbuildCache.retention_cutoff HolbuildCache.default_retention_days;
val paths = HolbuildCache.children (HolbuildCache.blobs_dir root);
val candidates = HolbuildCache.stale_blob_candidates cutoff paths;
val (candidates, _) = HolbuildCache.collect_live_actions cutoff root candidates;
val _ =
  case HolbuildCache.publish_blob root {hash = hash, src = src} of
      HolbuildCacheBackend.AlreadyPresent => ()
    | _ => raise Fail "expected publish_blob to reuse the cached blob";
val _ = HolbuildCache.put_action root HolbuildCacheBackend.PutIfAbsentOrSame
          {key = "reuser", text = "holbuild-cache-action-v2\nblob dat " ^ hash ^ "\n"};
val _ = HolbuildCache.sweep_blobs cutoff candidates paths;
val _ = print (if HolbuildCache.has_blob root hash then "blob-kept\n" else "blob-swept\n");

(* Reusing an existing action also refreshes its blobs before the final sweep. *)
val blob = HolbuildCache.blob_path root hash;
val _ = OS.FileSys.setTime (blob, SOME (Time.- (cutoff, Time.fromSeconds 1)));
val candidates = HolbuildCache.stale_blob_candidates cutoff paths;
val _ = HolbuildCache.touch_action root "reuser";
val _ =
  if Time.< (OS.FileSys.modTime blob, cutoff) then raise Fail "touch_action left its blob stale"
  else ();
val _ = HolbuildCache.sweep_blobs cutoff candidates paths;
val _ = print (if HolbuildCache.has_blob root hash then "touched-blob-kept\n" else "touched-blob-swept\n");
