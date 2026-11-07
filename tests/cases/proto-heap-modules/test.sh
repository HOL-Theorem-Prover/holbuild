#!/usr/bin/env bash
# PROTOTYPE check (holbuild#321): does a child that starts from a parent
# heap reuse compiled theory initializers for the ancestors it still loads?
# A <- B <- {C, D}; A <- Y; X <- {B, Y}.  B has three children, so X starts from
# B's heap and still loads Y.
set -euo pipefail
HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
unset HOLBUILD_REMOTE_CACHE_URL
tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"
p=$tmpdir/project
mkdir -p "$p/src"
write_schema2_prelude > "$p/holproject.toml"
printf '[project]\nname = "proto-heap-modules"\n[build]\nmembers = ["src"]\n' >> "$p/holproject.toml"
th() { local n=$1; shift; { echo "open HolKernel Parse boolLib bossLib $*;"; echo "val _ = new_theory \"$n\";"; echo "Theorem ${n}_t: T"; echo "Proof"; echo "  simp[]"; echo "QED"; echo "val _ = export_theory();"; } > "$p/src/${n}Script.sml"; }
th A; th B ATheory; th C BTheory; th D BTheory; th Y ATheory
cat > "$p/src/XScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib BTheory YTheory;
val _ =
  case #lookupStruct PolyML.globalNameSpace "TheoryModules" of
      NONE => print "module-cache unsupported\n"
    | SOME _ => CompilerSpecific.quietbind
        (String.concat
          ["val _ = let val {hits,misses,writes} = TheoryModules.statistics() ",
           "in print (\"module-cache hits=\" ^ Int.toString hits ^ ",
           "\" misses=\" ^ Int.toString misses ^ \"\\n\") end"]);
val _ = print ("hierarchy " ^ String.concatWith " " (PolyML.SaveState.showHierarchy ()) ^ "\n");
val _ = new_theory "X";
val _ = export_theory ();
SML
b() { (cd "$p" && HOLBUILD_ECHO_CHILD_LOGS=1 "$HOLBUILD_BIN" --cache-dir ../cache -j2 build --skip-checkpoints "$@") > "$tmpdir/b.log" 2>&1 || { cat "$tmpdir/b.log"; exit 1; }; grep "module-cache\|hierarchy\|XTheory starts\|built parent heap" "$tmpdir/b.log" | sed "s|$tmpdir||g"; }
echo "== first build (produces initializers; heap B built)"; b CTheory DTheory XTheory
for e in dat sig sml; do cp "$p/.holbuild/obj/src/XTheory.$e" "$tmpdir/X.$e"; done
echo "== rebuild X from B's heap"; echo "(* t1 *)" >> "$p/src/XScript.sml"; b CTheory DTheory XTheory
echo "== rebuild X cold (no heaps; X alone, so B has one dependent)"; rm -rf "$p/.holbuild/parent-heaps"; echo "(* t2 *)" >> "$p/src/XScript.sml"; b XTheory
for e in dat sig sml; do cmp "$p/.holbuild/obj/src/XTheory.$e" "$tmpdir/X.$e" && echo "X.$e identical"; done
