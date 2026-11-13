#!/usr/bin/env bash
# When the worker starts a theory-module writer: never for a HOL without
# the module helper, nor once a writer found the toolchain can't write
# modules, nor when the store has every module the action wants.  A fake
# HOL stands in for the writer: it counts its runs and leaves the files
# named in $tmpdir/writes in its output directory.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$ROOT/tests/lib.sh"
tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
mkdir -p "$tmpdir/cache" "$tmpdir/root/src" "$tmpdir/root/.holbuild"

sha() { sha1sum "$1" | cut -d' ' -f1; }
for hol in hol1 hol2; do
  mkdir -p "$tmpdir/$hol/bin" "$tmpdir/$hol/sigobj" "$tmpdir/$hol/tools-poly/poly"
  : > "$tmpdir/$hol/bin/hol.state"
  : > "$tmpdir/$hol/sigobj/boolTheory.uo"
  printf 'bool theory\n' > "$tmpdir/$hol/sigobj/boolTheory.dat"
  cat > "$tmpdir/$hol/bin/hol" <<SH
#!/usr/bin/env bash
echo run >> "$tmpdir/$hol.runs"
cp "\${@: -1}" "$tmpdir/$hol.script"
while read -r file; do : > "$tmpdir/cache/theory-modules-writer/\$file"; done < "$tmpdir/writes"
SH
  chmod +x "$tmpdir/$hol/bin/hol"
done
bool_sha=$(sha "$tmpdir/hol1/sigobj/boolTheory.dat")
printf '(("bool" . "%s"))\n' "$bool_sha" > "$tmpdir/root/src/ATheory.dat"
a_sha=$(sha "$tmpdir/root/src/ATheory.dat")
printf '(("A" . "%s") ("bool" . "%s"))\n' "$a_sha" "$bool_sha" > "$tmpdir/root/src/BTheory.dat"
b_sha=$(sha "$tmpdir/root/src/BTheory.dat")

cat > "$tmpdir/writer.sml" <<SML
use "sml/holbuild-script.sml";
structure E = HolbuildBuildExec;
fun check message condition = if condition then () else raise Fail message;
fun exists path = OS.FileSys.access (path, []);
fun runs hol =
  let val path = "$tmpdir/" ^ hol ^ ".runs"
  in if exists path then length (String.tokens Char.isSpace (E.read_text path)) else 0 end;
fun writes files = E.write_text "$tmpdir/writes" (String.concat (map (fn f => f ^ "\n") files));
fun dep name = {target = "p:" ^ name ^ "Theory", stem = "src/" ^ name ^ "Theory", key = ""};
val wanted = {deps = [dep "A", dep "B"], loads = [E.LoadTheory "boolTheory"]};
fun tc hol = {holdir = "$tmpdir/" ^ hol, maxheap = NONE,
              kernel_variant = HolbuildToolchain.StandardKernel};
fun fill hol = E.fill_module_store "$tmpdir/cache" "$tmpdir/root" (tc hol) wanted;
fun store hol = E.module_store ("$tmpdir/" ^ hol);
fun stored hol file = exists (OS.Path.concat (store hol, file));
val a = "ab12-A-$a_sha.pmo";
val b = "ab12-B-$b_sha.pmo";
fun script_has hol text = String.isSubstring text (E.read_text ("$tmpdir/" ^ hol ^ ".script"));

(* A HOL without the module helper. *)
val _ = writes [a, b];
val _ = fill "hol1";
val _ = check "a writer ran for a HOL without the module helper" (runs "hol1" = 0);
val _ = check "a HOL without the module helper got a store" (not (exists (store "hol1")));

(* The first writer also records the base state's theories. *)
val _ = E.write_text "$tmpdir/hol1/tools-poly/poly/theory_modules.ML" "";
val _ = writes [a, b, "base-theories", "ab12-C-$b_sha.pmo", "other"];
val _ = fill "hol1";
val _ = check "no writer ran for an empty store" (runs "hol1" = 1);
val _ = check "the writer was not asked for the base theories" (script_has "hol1" "TheoryReader.is_canonical");
val _ = check "the writer was not given the action's theories"
          (script_has "hol1" "ATheory.sml" andalso script_has "hol1" "BTheory.sml");
val _ = check "a module or the base theories were not stored"
          (List.all (stored "hol1") [a, b, "base-theories"]);
val _ = check "an unwanted file was stored"
          (not (stored "hol1" "ab12-C-$b_sha.pmo") andalso not (stored "hol1" "other"));

(* Every module stored: bool is a base theory. *)
val _ = E.write_text (OS.Path.concat (store "hol1", "base-theories")) "min\nbool\n";
val _ = fill "hol1";
val _ = check "a writer ran for a filled store" (runs "hol1" = 1);

(* A module missing: the writer runs, without asking for the base theories again. *)
val _ = OS.FileSys.remove (OS.Path.concat (store "hol1", b));
val _ = writes [b, "base-theories"];
val _ = E.write_text (OS.Path.concat (store "hol1", "base-theories")) "bool\n";
val _ = fill "hol1";
val _ = check "no writer ran for a partial store" (runs "hol1" = 2);
val _ = check "the missing module was not stored" (stored "hol1" b);
val _ = check "the base theories were asked for again" (not (script_has "hol1" "TheoryReader.is_canonical"));
val _ = check "the base theories were replaced"
          (E.read_text (OS.Path.concat (store "hol1", "base-theories")) = "bool\n");

(* A toolchain that can't write modules is not asked again. *)
val _ = E.write_text "$tmpdir/hol2/tools-poly/poly/theory_modules.ML" "";
val _ = writes ["unsupported"];
val _ = fill "hol2";
val _ = check "the unsupported marker was not stored" (runs "hol2" = 1 andalso stored "hol2" "unsupported");
val _ = fill "hol2";
val _ = check "a writer ran for an unsupported toolchain" (runs "hol2" = 1);
SML
(cd "$ROOT" && HOLBUILD_CACHE="$tmpdir/cache" \
  "${HOLBUILD_POLY:-poly}" -q --error-exit --script "$tmpdir/writer.sml")
