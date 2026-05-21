fun compile_holdir () =
  case OS.Process.getEnv "HOLBUILD_HOLDIR" of
      SOME h => h
    | NONE =>
      case OS.Process.getEnv "HOLDIR" of
          SOME h => h
        | NONE =>
          raise Fail "set HOLBUILD_HOLDIR or HOLDIR when compiling holbuild";

val compile_time_holdir = compile_holdir ();

structure HolbuildRuntimePaths =
struct
  val source_root = OS.FileSys.getDir ()
end

fun path_join (a, b) = OS.Path.concat(a, b);

fun use_hol rel = use (path_join(compile_time_holdir, rel));

fun load_poly_hol_context () =
  let
    val origdir = OS.FileSys.getDir ()
  in
    OS.FileSys.chDir (path_join(compile_time_holdir, "tools-poly"));
    use "poly/poly-init2.ML";
    OS.FileSys.chDir origdir
  end;

load_poly_hol_context ();
Meta.quiet_load := true;

fun quiet_holsource_use raw_file =
  let
    val file = holpathdb.subst_pathvars raw_file
    val reader = HOLSource.fileToReader {quietOpen = false, print = fn _ => ()} file
    fun line () = #line (#fileline reader ()) + 1
  in
    while not (#eof reader ()) do
      PolyML.compiler
        (#read reader,
         [PolyML.Compiler.CPFileName file,
          PolyML.Compiler.CPLineNo line,
          PolyML.Compiler.CPOutStream (fn _ => ())])
        ()
  end;

Meta.loadPlan quiet_holsource_use "TacticParse";

use_hol("tools/Holmake/toml/TOMLvalue_dtype.sml");
use_hol("tools/Holmake/toml/TOMLvalue.sig");
use_hol("tools/Holmake/toml/TOMLvalue.sml");
use_hol("tools/Holmake/toml/TOMLerror.sml");
use_hol("tools/Holmake/toml/parseTOMLUtil.sml");
use_hol("tools/Holmake/toml/parseTOMLFunctor.sml");
use_hol("tools/Holmake/toml/parseTOML.sml");
use_hol("tools/Holmake/deps/Holdep_tokens.sig");
use_hol("tools/Holmake/deps/Holdep_tokens.sml");
use_hol("tools/Holmake/deps/Holdep.sig");
use_hol("tools/Holmake/deps/Holdep.sml");
use_hol("tools/Holmake/toml/TOML.sig");
use_hol("tools/Holmake/toml/TOML.sml");
use_hol("tools/Holmake/util/terminal_primitives.sig");
use_hol("tools/Holmake/util/poly-terminal-prims.ML");
use_hol("src/portableML/poly/SHA1_ML.sig");
use_hol("src/portableML/poly/w64-SHA1.ML");

use "sml/hash.sml";
use "sml/builtin_manifests.sml";
use "sml/project.sml";
use "sml/toolchain.sml";
use "sml/status.sml";
use "sml/generators.sml";
use "sml/source_index.sml";
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
use "sml/goalfrag_plan.sml";
use "sml/proof_ir.sml";
use "sml/commands.sml";

fun main () = HolbuildCommands.main (CommandLine.arguments())
