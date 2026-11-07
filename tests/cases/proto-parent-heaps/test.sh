#!/usr/bin/env bash
# PROTOTYPE smoke test: A <- B <- {C, D} <- E.  B has two children, so
# C, D (and E, via C's chain) start from B's parent heap.  Outputs must equal a
# build with no parent heaps.
set -euo pipefail
HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
unset HOLBUILD_REMOTE_CACHE_URL
tmpdir=$(make_temp_dir)
trap 'rm -rf "$tmpdir"' EXIT
p=$tmpdir/project
mkdir -p "$p/src"
cat > "$p/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "proto-parent-heaps"

[build]
members = ["src"]
TOML
th() { local n=$1; shift; { echo "open HolKernel Parse boolLib bossLib $*;"; echo "val _ = new_theory \"$n\";"; echo "Theorem ${n}_t: T"; echo "Proof"; echo "  simp[]"; echo "QED"; echo "val _ = export_theory();"; } > "$p/src/${n}Script.sml"; }
th A
th B ATheory
th C BTheory
th D BTheory wordsLib
th E CTheory DTheory
link_hol_toolchain_cache "$tmpdir/cache"
(cd "$p" && HOLBUILD_CACHE="$tmpdir/cache" "$HOLBUILD_BIN" build --no-cache ETheory) > "$tmpdir/warm.log" 2>&1 || { cat "$tmpdir/warm.log"; exit 1; }
cat "$tmpdir/warm.log" | grep holbuild-proto
for t in A B C D E; do cp "$p/.holbuild/obj/src/${t}Theory.dat" "$tmpdir/$t.warm.dat"; cp "$p/.holbuild/obj/src/${t}Theory.uo" "$tmpdir/$t.warm.uo"; done
ls "$p/.holbuild/parent-heaps"
rm -rf "$p/.holbuild/parent-heaps" "$p/.holbuild/checkpoints"
# B now has one child in the selection, so no heap is built: a cold build.
(cd "$p" && HOLBUILD_CACHE="$tmpdir/cache" "$HOLBUILD_BIN" build --no-cache --force=project CTheory) > "$tmpdir/cold.log" 2>&1 || { cat "$tmpdir/cold.log"; exit 1; }
grep holbuild-proto "$tmpdir/cold.log"
for t in A B C; do cmp "$p/.holbuild/obj/src/${t}Theory.dat" "$tmpdir/$t.warm.dat"; cmp "$p/.holbuild/obj/src/${t}Theory.uo" "$tmpdir/$t.warm.uo"; done
cat "$p/.holbuild/obj/src/ETheory.uo"
# keep-going: F fails, G depends on F, E must still build.
printf 'open HolKernel Parse boolLib bossLib ATheory;\nval _ = new_theory "F";\nTheorem F_t: F\nProof\n  simp[]\nQED\nval _ = export_theory();\n' > "$p/src/FScript.sml"
th G FTheory
echo "(* touch *)" >> "$p/src/EScript.sml"
if (cd "$p" && HOLBUILD_PROTO_KEEP_GOING=1 HOLBUILD_CACHE="$tmpdir/cache" "$HOLBUILD_BIN" build --no-cache -j2 GTheory ETheory) > "$tmpdir/kg.log" 2>&1; then cat "$tmpdir/kg.log"; exit 1; fi
grep -v "starts from" "$tmpdir/kg.log" | tail -40
grep -q "ETheory starts from" "$tmpdir/kg.log"; [ "$p/.holbuild/obj/src/ETheory.dat" -nt "$p/src/EScript.sml" ]; ! grep -q "GTheory starts from" "$tmpdir/kg.log"
echo PROTO-OK
