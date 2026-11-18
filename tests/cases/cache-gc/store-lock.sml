val _ = OS.FileSys.chDir (valOf (OS.Process.getEnv "HOLBUILD_ROOT"));
use "sml/holbuild-script.sml";
val refused =
  (HolbuildBuildExec.gc_checkpoint_store 0; false)
  handle HolbuildCache.Error msg => String.isPrefix "cache gc already running" msg;
val _ = if refused then print "store-lock-refused\n"
        else raise Fail "checkpoint-store GC ignored a held sweep lock";
