structure HolbuildRuntimePaths =
struct
  val source_root = OS.FileSys.getDir ()
end

fun path_join (a, b) = OS.Path.concat(a, b);

val vendored_hol_source = path_join(HolbuildRuntimePaths.source_root, "vendor/hol");

fun use_hol rel = use (path_join(vendored_hol_source, rel));

use_hol("tools-poly/poly/Binarymap.sig");
use_hol("tools-poly/poly/Binarymap.sml");
use_hol("tools/Holmake/toml/TOMLvalue_dtype.sml");
use_hol("tools/Holmake/toml/TOMLvalue.sig");
use_hol("tools/Holmake/toml/TOMLvalue.sml");
use_hol("tools/Holmake/toml/TOMLerror.sml");
use_hol("tools/Holmake/toml/parseTOMLUtil.sml");
use_hol("tools/Holmake/toml/parseTOMLFunctor.sml");
use_hol("tools/Holmake/toml/parseTOML.sml");
use_hol("tools/Holmake/toml/TOML.sig");
use_hol("tools/Holmake/toml/TOML.sml");
use_hol("tools/Holmake/util/terminal_primitives.sig");
use_hol("tools/Holmake/util/poly-terminal-prims.ML");
use_hol("src/portableML/poly/SHA1_ML.sig");
use_hol("src/portableML/poly/w64-SHA1.ML");
use_hol("src/portableML/poly/ConcIsaLib.sml");
use_hol("src/portableML/Redblackset.sig");
use_hol("src/portableML/Redblackset.sml");

use "vendor/sml-sha256/lib/from-string.sig";
use "vendor/sml-sha256/lib/from-string.sml";
use "vendor/sml-sha256/lib/bytestring.sig";
use "vendor/sml-sha256/lib/bytestring.sml";
use "vendor/sml-sha256/lib/convert-word.sml";
use "vendor/sml-sha256/lib/susp.sig";
use "vendor/sml-sha256/lib/susp.sml";
use "vendor/sml-sha256/lib/stream.sig";
use "vendor/sml-sha256/lib/stream.sml";
use "vendor/sml-sha256/lib/sha256.sig";
use "vendor/sml-sha256/lib/sha256.sml";

use "sml/hash.sml";
use "sml/version.sml";
use "sml/builtin_manifests.sml";
use "sml/cache_config.sml";
use "sml/git_cache.sml";
use "sml/file_lock.sml";
use "sml/cache_backend.sml";
use "sml/fs_cache_backend.sml";
use "sml/cache_transfer.sml";
use "sml/cache_archive.sml";
use "sml/hol_shared_cache.sml";
use "sml/project.sml";
use "sml/toolchain.sml";
use "sml/status.sml";
use "sml/generators.sml";
use "sml/source_index.sml";
use "sml/analyser/analysis_protocol.sml";
use "sml/dependencies.sml";
use "sml/build_plan.sml";
use "sml/checkpoint_save_runtime.sml";
use "sml/theory_checkpoints.sml";
use "sml/checkpoint_store.sml";
use "sml/theory_diagnostics.sml";
use "sml/project_lock.sml";
use "sml/theory_spans.sml";
use "sml/cache.sml";
use "sml/build_exec.sml";
use "sml/tactic_timeout_policy.sml";
use "sml/proof_ir_types.sml";
use "sml/watch.sml";
use "sml/commands.sml";

fun main () = HolbuildCommands.main (CommandLine.arguments())
