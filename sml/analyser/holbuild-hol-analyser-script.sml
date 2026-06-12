fun compile_holdir () =
  case OS.Process.getEnv "HOLBUILD_HOLDIR" of
      SOME h => h
    | NONE =>
      case OS.Process.getEnv "HOLDIR" of
          SOME h => h
        | NONE => raise Fail "set HOLBUILD_HOLDIR or HOLDIR when compiling holbuild-hol-analyser";

fun analyser_src () =
  case OS.Process.getEnv "HOLBUILD_ANALYSER_SRC" of
      SOME h => h
    | NONE => raise Fail "set HOLBUILD_ANALYSER_SRC when compiling holbuild-hol-analyser";

val compile_time_holdir = compile_holdir ();
val source_dir = analyser_src ();
val source_root = OS.Path.dir (OS.Path.dir source_dir);

fun path_join (a, b) = OS.Path.concat(a, b);
fun use_hol rel = use (path_join(compile_time_holdir, rel));
fun use_src rel = use (path_join(source_dir, rel));
fun use_root rel = use (path_join(source_root, rel));

fun load_poly_hol_context () =
  let val origdir = OS.FileSys.getDir ()
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

use_hol("tools/Holmake/deps/Holdep_tokens.sig");
use_hol("tools/Holmake/deps/Holdep_tokens.sml");
use_hol("tools/Holmake/deps/Holdep.sig");
use_hol("tools/Holmake/deps/Holdep.sml");

use_hol("src/portableML/poly/SHA1_ML.sig");
use_hol("src/portableML/poly/w64-SHA1.ML");
use_root "sml/hash.sml";
use_root "sml/proof_ir_types.sml";
use_root "sml/proof_ir.sml";

use_src "analysis_protocol.sml";
use_src "dependency_extract.sml";
use_src "theory_span_extract.sml";
use_src "proof_ir_extract.sml";
use_src "analyser_main.sml";

fun main () = OS.Process.exit (HolbuildAnalyserMain.main (CommandLine.arguments()))
