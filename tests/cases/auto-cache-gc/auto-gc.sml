val _ = OS.FileSys.chDir (valOf (OS.Process.getEnv "HOLBUILD_ROOT"));
use "sml/holbuild-script.sml";
val threshold = valOf (Position.fromString (valOf (OS.Process.getEnv "AUTO_GC_THRESHOLD")));
val _ = HolbuildBuildExec.auto_cache_gc threshold;
val _ = print "auto-gc-returned\n";
