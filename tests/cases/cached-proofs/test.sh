#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

# A <- B.  build --cached-proofs reuses a recorded proof of an unchanged
# theorem, also below an edit in its own script, only while every theorem
# it depended on, and the definitions those mention, are as recorded.
project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "cached"

[build]
members = ["src"]
TOML

# write_a EDIT L1 F T1: EDIT goes above t1; L1 is l1's statement, F the
# definition of f, T1 t1's statement.
write_a() {
  cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Definition f_def:
  f = ${3:-(1:num)}
End
Theorem l1:
  ${2:-f = 1}
Proof
  simp[f_def]
QED
$1
Theorem t1:
  ${4:-f + 1 = 2}
Proof
  simp[l1]
QED
Theorem t2[local]:
  f + 2 = 3
Proof
  simp[l1]
QED
Theorem t3:
  f + 3 = 4
Proof
  simp[t2]
QED
Datatype:
  colour = Red | Green
End
Theorem t4:
  Red <> Green
Proof
  simp[]
QED
val _ = export_theory();
SML
}
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib ATheory;
val _ = new_theory "B";
Theorem b1:
  f + 1 = 2
Proof
  simp[t1]
QED
val _ = export_theory();
SML
# A constant from a raw kernel primitive leaves its theory uncertified.
write_p() {
  cat > "$project/src/PScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "P";
val g_def = Thm.prim_specification ["g"] (prove (\`\`?g:num. g = 1\`\`, EXISTS_TAC \`\`1:num\`\` THEN REFL_TAC));
val _ = Parse.add_const "g";
$1
Theorem p1:
  g + 0 = 1
Proof
  simp[g_def]
QED
val _ = export_theory();
SML
}
write_p ""
# So does a definition hook installed by the theory itself.
write_q() {
  cat > "$project/src/QScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Q";
val _ = let val (d, p) = !Definition.new_definition_hook
        in Definition.new_definition_hook := (d, fn x => p x) end;
val h_def = new_definition ("h_def", \`\`h = (1:num)\`\`);
$1
Theorem q1:
  h + 0 = 1
Proof
  simp[h_def]
QED
val _ = export_theory();
SML
}
write_q ""
# A hook a library installed before the theory started keeps the kernel's
# defining theorem, which a proof can use with no saved dependency.
cat > "$project/src/stashLib.sml" <<'SML'
structure stashLib =
struct
open HolKernel boolLib
val kept = ref ([] : thm list)
val _ = let val (d, p) = !Definition.new_definition_hook
        in Definition.new_definition_hook := (d, fn (V, th) => (kept := th :: !kept; p (V, th))) end
end
SML
write_r() {
  cat > "$project/src/RScript.sml" <<SML
open HolKernel Parse boolLib bossLib stashLib;
val _ = new_theory "R";
val k_def = new_definition ("k_def", \`\`k = ($2:num)\`\`);
$1
Theorem r1:
  k + 0 = 1
Proof
  simp[hd (!stashLib.kept)]
QED
val _ = export_theory();
SML
}
write_r "" 1

build() {
  local log=$1
  shift
  sleep 1.1
  (cd "$project" && "$HOLBUILD_BIN" build "$@" BTheory PTheory QTheory RTheory) > "$log" 2>&1 ||
    { cat "$log" >&2; exit 1; }
}
theory_log() { cat "$project"/.holbuild/logs/current/*/"$1"/build.log; }
require_reused() {
  theory_log "$1" | grep -q "holbuild reused the cached proof of $2\$" ||
    { echo "$1 did not reuse the proof of $2" >&2; theory_log "$1" >&2; exit 1; }
}
require_not_reused() {
  if theory_log "$1" | grep -q "holbuild reused the cached proof of $2\$"; then
    echo "$1 reused the proof of $2" >&2; theory_log "$1" >&2; exit 1
  fi
}
obj=$project/.holbuild/obj/src

write_a ""
build "$tmpdir/first.log" --cached-proofs
require_not_reused ATheory t1

# An edit above t1 runs every theorem below it again; each reuses its record.
write_a $'Theorem extra:\n  (2:num) = 2\nProof\n  simp[]\nQED'
build "$tmpdir/edit.log" --cached-proofs
for thm in t1 t2 t3 t4; do require_reused ATheory $thm; done
require_not_reused ATheory extra
require_reused BTheory b1
cached_a=$(sha256sum < "$obj/ATheory.dat")
cached_b=$(sha256sum < "$obj/BTheory.dat")

# The raw primitive's theory is rebuilt by the edit below, and reuses nothing.
write_p $'Theorem p0:\n  (2:num) = 2\nProof\n  simp[]\nQED'
build "$tmpdir/raw.log" --cached-proofs
require_grep "PTheory built" "$tmpdir/raw.log"
require_not_reused PTheory p1
write_q $'Theorem q0:\n  (2:num) = 2\nProof\n  simp[]\nQED'
build "$tmpdir/hook.log" --cached-proofs
require_grep "QTheory built" "$tmpdir/hook.log"
require_not_reused QTheory q1
write_r $'Theorem r0:\n  (2:num) = 2\nProof\n  simp[]\nQED' 1
build "$tmpdir/stash.log" --cached-proofs
require_reused RTheory r1

# A build without the flag doesn't take the cached build's outputs, cache
# entries or checkpoints: it replays every proof, and the outputs are the
# same bytes.
build "$tmpdir/default.log"
require_grep "ATheory built" "$tmpdir/default.log"
require_grep "BTheory built" "$tmpdir/default.log"
if grep -q "theorem checkpoint after" "$tmpdir/default.log"; then
  echo "the default build resumed from a cached build's checkpoint" >&2; cat "$tmpdir/default.log" >&2; exit 1
fi
require_not_reused ATheory t1
[[ "$(sha256sum < "$obj/ATheory.dat")" == "$cached_a" ]] ||
  { echo "ATheory.dat differs between the cached and the replayed build" >&2; exit 1; }
[[ "$(sha256sum < "$obj/BTheory.dat")" == "$cached_b" ]] ||
  { echo "BTheory.dat differs between the cached and the replayed build" >&2; exit 1; }

# A stricter step timeout than the records ran under replays.
write_a $'Theorem extra:\n  (3:num) = 3\nProof\n  simp[]\nQED'
build "$tmpdir/timeout.log" --cached-proofs --tactic-timeout 1
require_not_reused ATheory t1
build "$tmpdir/timeout-relaxed.log" --cached-proofs --tactic-timeout 1 --force
require_reused ATheory t1

# A restated lemma of the same script replays the theorems that used it.
write_a "" "f = 1 /\\ T"
build "$tmpdir/lemma.log" --cached-proofs
require_not_reused ATheory t1
require_not_reused ATheory t2

# A restated theorem of the ancestor replays the theorems that used it.
write_a "" "f = 1" "(1:num)" "f + 1 = 2 /\\ T"
build "$tmpdir/ancestor.log" --cached-proofs
require_reused ATheory t2
require_not_reused BTheory b1

# A redefined constant replays the theorems whose proofs used its old
# definition, so a proof that no longer holds fails.
write_a "" "f = 1" "(2:num)" "f + 1 = 2 /\\ T"
sleep 1.1
if (cd "$project" && "$HOLBUILD_BIN" build --cached-proofs ATheory) > "$tmpdir/redefined.log" 2>&1; then
  echo "the build reused proofs about the old definition of f" >&2; cat "$tmpdir/redefined.log" >&2; exit 1
fi
require_grep "l1" "$tmpdir/redefined.log"
require_not_reused ATheory l1

# Redefining a constant whose kernel definition a proof used directly
# misses that proof too.
write_r "" 2
sleep 1.1
if (cd "$project" && "$HOLBUILD_BIN" build --cached-proofs RTheory) > "$tmpdir/stash-redefined.log" 2>&1; then
  echo "the build reused a proof about the old definition of k" >&2; cat "$tmpdir/stash-redefined.log" >&2; exit 1
fi
require_grep "r1" "$tmpdir/stash-redefined.log"
require_not_reused RTheory r1
