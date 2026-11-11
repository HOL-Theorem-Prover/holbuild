(* Each cache write counts towards the next automatic GC, and the count
   reaches the journal when flushed. *)
val _ = OS.FileSys.chDir (valOf (OS.Process.getEnv "HOLBUILD_ROOT"));
use "sml/holbuild-script.sml";
val root = valOf (OS.Process.getEnv "HOLBUILD_CACHE");
val src = valOf (OS.Process.getEnv "BLOB_SRC");
val hash = valOf (OS.Process.getEnv "BLOB_HASH");
val _ = HolbuildCache.ensure_layout root;
val _ = HolbuildCache.publish_blob root {hash = hash, src = src};
val _ = HolbuildCache.publish_blob root {hash = hash, src = src};
val _ = HolbuildCache.put_action root HolbuildCacheBackend.PutIfAbsentOrSame
          {key = "k", text = "holbuild-cache-action-v2\nblob dat " ^ hash ^ "\n"};
val _ = print ("pending=" ^ Position.toString (HolbuildCache.growth_since_gc root) ^ "\n");
val _ = HolbuildFSCacheBackend.flush_growth ();
val _ = print ("flushed=" ^ Position.toString (HolbuildCache.growth_since_gc root) ^ "\n");
