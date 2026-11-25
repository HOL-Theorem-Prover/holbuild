#!/usr/bin/env bash
set -euo pipefail

# HolbuildRuntime.load shares the heap's common data around a theory whose
# .dat is large, and before one that brings the .dat loaded since the last
# share to 128 MiB, on either loader HOL may have, and loads in the same
# order.  A chain of stand-in theories F -> E -> D -> C -> B -> A with sparse
# .dat files, B's at 64 MiB and D's to F's at 48 MiB; each theory prints the
# bytes of .dat loaded since the last share, and each share prints "share".

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"
: "$HOLBUILD_BIN"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

# HOL's file system keeps a directory's manifests and theory files in its
# .hol/objs.
mods=$tmpdir/mods
objs=$mods/.hol/objs
mkdir -p "$objs"
theory() {
  local name=$1 parent=$2
  : > "$objs/${name}Theory.ui"
  { [[ -z $parent ]] || echo "${parent}Theory"; echo "$mods/${name}Theory.sml"; } > "$objs/${name}Theory.uo"
  echo "val _ = print (\"$name \" ^ Position.toString (!HolbuildRuntime.unshared_dat_bytes) ^ \"\\n\");" \
    > "$objs/${name}Theory.sml"
}
theory A ""
theory B A
theory C B
theory D C
theory E D
theory F E
head -c 1000 /dev/zero > "$objs/ATheory.dat"
truncate -s 64M "$objs/BTheory.dat"
head -c 1000 /dev/zero > "$objs/CTheory.dat"
truncate -s 48M "$objs/DTheory.dat" "$objs/ETheory.dat" "$objs/FTheory.dat"

run_load() {
  local mode=$1 prelude=$2
  cat > "$tmpdir/$mode.sml" <<SML
structure PolyML = struct open PolyML
  fun shareCommonData x = (TextIO.print "share\\n"; PolyML.shareCommonData x) end;
$prelude
use "$HOLBUILD_ROOT/sml/bounded_output.sml";
use "$HOLBUILD_ROOT/sml/holbuild_runtime.sml";
val _ = Meta.loadPath := "$mods" :: !Meta.loadPath;
val _ = HolbuildRuntime.load "FTheory";
val _ = print ("end " ^ Position.toString (!HolbuildRuntime.unshared_dat_bytes) ^ "\n");
SML
  "$HOLDIR/bin/hol" run --noconfig --holstate "$HOLDIR/bin/hol.state" "$tmpdir/$mode.sml" \
    > "$tmpdir/$mode.log" 2>&1 || { cat "$tmpdir/$mode.log" >&2; exit 1; }
  # A's bytes are shared before B and B's after it; C's, D's and E's before
  # F, whose own stay unshared.
  expected=$'A 0\nshare\nB 0\nshare\nC 0\nD 1000\nE 50332648\nshare\nF 0\nend 50331648'
  if [[ $(grep -E '^(share$|[A-F] |end )' "$tmpdir/$mode.log") != "$expected" ]]; then
    echo "$mode: unexpected load order or sharing" >&2
    cat "$tmpdir/$mode.log" >&2
    exit 1
  fi
}

# This HOL's own loader.
run_load current ""
# A HOL whose Meta has loadPlan but no moduleSourceLoader (HOL before theory
# modules): a Meta without it stands in.
run_load loadplan "structure Meta = struct val loadPlan = Meta.loadPlan val qquse = Meta.qquse val load = Meta.load val loadPath = Meta.loadPath end;"

printf 'preload shares around large theory data on both loaders\n'
