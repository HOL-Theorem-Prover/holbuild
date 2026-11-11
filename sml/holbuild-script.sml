structure HolbuildRuntimePaths =
struct
  val compile_source_root = OS.FileSys.getDir ()
  val compile_datadir = OS.Process.getEnv "HOLBUILD_COMPILE_DATADIR"
  val resolved_root = ref NONE

  fun executable_path () =
    OS.FileSys.fullPath "/proc/self/exe"
    handle OS.SysErr _ =>
      let
        val name = CommandLine.name ()
        val path = Option.getOpt (OS.Process.getEnv "PATH", "")
        fun executable dir =
          let val file = OS.Path.concat (if dir = "" then "." else dir, name)
          in OS.FileSys.access (file, [OS.FileSys.A_EXEC]) end
          handle OS.SysErr _ => false
      in
        OS.FileSys.fullPath
          (if OS.Path.dir name <> "" then name
           else case List.find executable (String.fields (fn c => c = #":") path) of
                    SOME dir => OS.Path.concat (if dir = "" then "." else dir, name)
                  | NONE => name)
      end

  (* Exported executables retain compile-time values; resolve data only when run. *)
  fun runtime_root () =
    case !resolved_root of
        SOME root => root
      | NONE =>
        let
          fun has_runtime root =
            OS.FileSys.access (OS.Path.concat (root, "sml/holbuild_runtime.sml"),
                               [OS.FileSys.A_READ])
            handle OS.SysErr _ => false
          val root =
            (let val prefix = OS.Path.concat (OS.Path.dir (executable_path ()), "..")
             in case List.find has_runtime
                       ([OS.Path.concat (prefix, "share/holbuild"), prefix] @
                        (case compile_datadir of SOME dir => [dir] | NONE => [])) of
                    SOME dir => OS.FileSys.fullPath dir
                  | NONE => compile_source_root
             end handle OS.SysErr _ => compile_source_root)
        in
          resolved_root := SOME root;
          root
        end
end

fun path_join (a, b) = OS.Path.concat(a, b);

val vendored_hol_source = path_join(HolbuildRuntimePaths.compile_source_root, "vendor/hol");

fun use_hol rel = use (path_join(vendored_hol_source, rel));

use_hol("tools-poly/poly/Binarymap.sig");
use_hol("tools-poly/poly/Binarymap.sml");
use_hol("tools-poly/poly/Binaryset.sig");
use_hol("tools-poly/poly/Binaryset.sml");
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
use_hol("src/portableML/Redblackmap.sig");
use_hol("src/portableML/Redblackmap.sml");

use "sml/sha256.sml";

use "sml/spawn.sml";
use "sml/temp_path.sml";
use "sml/hash.sml";
use "sml/process_group.sml";
use "sml/remove_tree.sml";
use "sml/stat_cache.sml";
use "sml/version.sml";
use "sml/diagnostic_limits.sml";
use "sml/suggest.sml";
use "sml/hol_toolchain_config.sml";
use "sml/builtin_manifests.sml";
use "sml/hol_source_manifest.sml";
use "sml/cache_config.sml";
use "sml/offline.sml";
use "sml/http.sml";
use "sml/remote_cache_config.sml";
use "sml/cache_discovery.sml";
use "sml/file_lock.sml";
use "sml/git_cache.sml";
use "sml/cache_backend.sml";
use "sml/analyser/analysis_protocol.sml";
use "sml/theory_cache_manifest.sml";
use "sml/fs_cache_backend.sml";
use "sml/cache_transfer.sml";
use "sml/status.sml";
use "sml/machine_memory.sml";
use "sml/remote_cache.sml";
use "sml/tar_archive.sml";
use "sml/toolchain_archive.sml";
use "sml/action_sandbox.sml";
use "sml/hol_shared_cache.sml";
use "sml/manifest_util.sml";
use "sml/cache_archive.sml";
use "sml/package_definition.sml";
use "sml/package_provenance.sml";
use "sml/local_config.sml";
use "sml/project.sml";
use "sml/project_graph.sml";
use "sml/toolchain.sml";
use "sml/generators.sml";
use "sml/package_prepare.sml";
use "sml/source_index.sml";
use "sml/names.sml";
use "sml/package_component.sml";
use "sml/dependencies.sml";
use "sml/component_provider.sml";
use "sml/build_plan.sml";
use "sml/package_snapshot.sml";
use "sml/plan_record.sml";
use "sml/theory_checkpoints.sml";
use "sml/checkpoint_store.sml";
use "sml/theory_diagnostics.sml";
use "sml/project_lock.sml";
use "sml/theory_spans.sml";
use "sml/cache.sml";
use "sml/tactic_timeout_policy.sml";
use "sml/build_exec.sml";
use "sml/proof_ir_types.sml";
use "sml/watch.sml";
use "sml/remote_exec.sml";
use "sml/commands.sml";
use "sml/complete.sml";

fun main () =
  case CommandLine.arguments () of
      "__complete" :: words => HolbuildComplete.main words
    | args => HolbuildCommands.main args
