#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"
project=$tmpdir/project
mkdir -p "$project/src"
write_schema2_prelude > "$project/holproject.toml"
cat >> "$project/holproject.toml" <<'TOML'
[project]
name = "theory-modules"
[build]
members = ["src"]
TOML
cat > "$project/src/ALoadEvents.sml" <<'SML'
structure ALoadEvents = struct
  val loads = ref []
  val _ = Theory.register_hook
    ("module-events", fn TheoryDelta.TheoryLoaded s => loads := s :: !loads
                       | _ => ())
end
SML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Datatype:
  module_type = ModuleValue
End
Definition module_value_def:
  module_value = ModuleValue
End
val _ = export_theory ();
SML
for name in B C; do
  cat > "$project/src/${name}Script.sml" <<SML
open HolKernel Parse boolLib bossLib ATheory;
val _ = new_theory "$name";
val _ = save_thm ("imported", module_value_def);
val _ = export_theory ();
SML
done
cat > "$project/src/DScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib ALoadEvents BTheory CTheory;
val _ =
  let
    val ty = Type.mk_thy_type {Thy = "A", Tyop = "module_type", Args = []}
    val tm = Term.mk_thy_const {Thy = "A", Name = "module_value", Ty = ty}
    val th = DB.fetch "A" "module_value_def"
    val own_loads = List.filter (fn s => List.exists (fn n => n = s)
                                  ["A", "B", "C"]) (rev (!ALoadEvents.loads))
  in
    if not (Theory.uptodate_thm th andalso aconv (lhs (concl th)) tm) then
      raise Fail "module loading changed kernel identity"
    else if not (aconv (concl BTheory.imported) (concl CTheory.imported)) then
      raise Fail "diamond parents disagree"
    else if own_loads <> ["A", "B", "C"] then
      raise Fail ("library hooks: " ^ String.concatWith "," own_loads)
    else ()
  end;
val _ =
  case #lookupStruct PolyML.globalNameSpace "TheoryModules" of
      NONE =>
        let
          fun sub (ns : PolyML.NameSpace.nameSpace) name =
            Option.map PolyML.NameSpace.Structures.contents (#lookupStruct ns name)
          val meta = sub PolyML.globalNameSpace "Meta"
          val save = Option.mapPartial (fn ns => sub ns "SaveState")
                       (sub PolyML.globalNameSpace "PolyML")
          fun has ns name = Option.isSome (#lookupVal ns name)
          val supported =
            (case meta of NONE => false
             | SOME ns => has ns "configureTheoryModuleCache") andalso
            (case save of NONE => false
             | SOME ns => List.all (has ns)
                 ["showHierarchyWithIds", "saveDependentModuleBasic"]) andalso
            OS.FileSys.access
              (OS.Path.concat (Systeml.HOLDIR, "tools-poly/poly/theory_modules.ML"),
               [OS.FileSys.A_READ])
        in
          if supported then raise Fail "module cache was not configured"
          else print "module-cache unsupported\n"
        end
    | SOME _ => CompilerSpecific.quietbind
        (String.concat
          ["val _ = let val {hits,misses,writes} = TheoryModules.statistics() ",
           "in print (\"module-cache hits=\" ^ Int.toString hits ^ ",
           "\" misses=\" ^ Int.toString misses ^ \"\\n\") end"]);
val _ = new_theory "D";
val _ = save_thm ("imported", BTheory.imported);
val _ = export_theory ();
SML

build() {
  (cd "$project" && HOLBUILD_ECHO_CHILD_LOGS=1 \
    "$HOLBUILD_BIN" --cache-dir ../cache -j1 build --skip-checkpoints DTheory) > "$1" 2>&1 ||
    { cat "$1" >&2; return 1; }
}
rebuild() {
  printf '\n' >> "$project/src/DScript.sml"
  build "$1"
  for ext in dat sig sml; do
    cmp "$tmpdir/DTheory.$ext" "$project/.holbuild/obj/src/DTheory.$ext"
  done
}

build "$tmpdir/initial.log"
for ext in dat sig sml; do
  cp "$project/.holbuild/obj/src/DTheory.$ext" "$tmpdir/DTheory.$ext"
done
log=$project/.holbuild/logs/current/theory-modules/DTheory/build.log
if grep -q 'module-cache unsupported' "$log"; then
  echo 'source loader checked; compiled initializers unsupported by this toolchain'
  exit 0
fi
require_grep 'module-cache hits=3 misses=0' "$log"
module_cache=$HOLBUILD_CACHE/theory-modules
test -n "$(find "$module_cache" -name '*.ref' -print -quit)"

rm -rf "$module_cache"
rebuild "$tmpdir/cold.log"
require_grep 'module-cache hits=0 misses=3' "$log"
rebuild "$tmpdir/warm.log"
require_grep 'module-cache hits=3 misses=0' "$log"

find "$module_cache" -name '*.pmo' -delete
rebuild "$tmpdir/missing.log"
require_grep 'module-cache hits=0 misses=3' "$log"
while IFS= read -r payload; do
  printf 'corrupt' > "$payload"
done < <(find "$module_cache" -name '*.pmo')
rebuild "$tmpdir/corrupt.log"
require_grep 'module-cache hits=0 misses=3' "$log"
