#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"
tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT

# Which paths in HOL's output exec-action takes for files the hydrate put in
# the action root, as HOL and Poly/ML word them.
cat > "$tmpdir/check.sml" <<'SML'
val _ = OS.FileSys.chDir (valOf (OS.Process.getEnv "HOLBUILD_ROOT"));
use "sml/holbuild-script.sml";

structure Resident = HolbuildActionResident;
val root = "/w/action";
val resident : Resident.t = Resident.empty ();
val _ = Resident.put resident "/w/action/src/fooTheory"
          (Resident.Theory {target = "src/fooTheory", key = "k", source = "s", parents = [], mldeps = [],
                            dat_hash = "d", dat_parents = [], dat_sha1 = "s1", hashes = []});
val _ = Resident.put resident "/w/action/lib/barLib.sml" (Resident.File "h");
fun check (text, expected) =
  if HolbuildBuildExec.lost_restored_file resident root text = expected then ()
  else (TextIO.output (TextIO.stdErr, "wrong answer for: " ^ text ^ "\n");
        OS.Process.exit OS.Process.failure);
val _ = List.app check
  [("Cannot find file /w/action/src/fooTheory.uo", true),
   (* HOL reads a theory's .ui and .uo at their .hol/objs copies. *)
   ("Cannot find file /w/action/src/.hol/objs/fooTheory.ui", true),
   (* An uncaught Fail quotes its message. *)
   ("Exception- Fail \"Cannot find file /w/action/src/fooTheory.uo\" raised", true),
   ("Exception- Fail \"Use: non-existent file /w/action/lib/barLib.sml\" raised", true),
   ("Use: non-existent file /w/action/lib/barLib.sml: gone", true),
   ("Cannot find file /w/action/src/bazTheory.uo", false),
   ("Cannot find file /w/action/src/.hol/objs/bazTheory.uo", false),
   ("Use: non-existent file /w/action/lib/other.sml:", false)];
val _ = OS.Process.exit OS.Process.success;
SML
"${HOLBUILD_POLY:-poly}" --script "$tmpdir/check.sml" > "$tmpdir/check.log" 2>&1 || {
  cat "$tmpdir/check.log" >&2
  exit 1
}
