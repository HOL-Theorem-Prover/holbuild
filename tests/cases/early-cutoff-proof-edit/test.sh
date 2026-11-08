#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

# A <- B <- C.  A proof-only edit of A changes ATheory.dat (the theorems'
# source locations and dependency records) but not its digest, so B and C
# are reused and still load; a statement change rebuilds them.
project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "cutoff"

[build]
members = ["src"]
TOML

# write_a PREFIX PROOF STATEMENT [PRECEDENCE] [NOTE]: PREFIX goes before
# a_thm, which states STATEMENT and is proved by PROOF.  The datatype
# registers theorems as theory data, whose records the digest normalizes
# too, and the fixity a precedence, which is a bare integer there.  A note
# is theory data of a codec of A's own, stored as a bare string-table index
# like GrammarAncestry's theory names; holbuild can't tell such an index
# from an integer, so it hashes a theory with data it doesn't know as written.
write_a() {
  local note=""
  if [[ -n "${5:-}" ]]; then
    note=$(cat <<SML
val (write_note, _) =
  Theory.LoadableThyData.new {
    thydataty = "note", merge = op @, terms = Lib.K [], strings = (fn l => l),
    pp = String.concatWith ", ",
    read = fn {strings, ...} => HOLsexp.list_decode (Option.map strings o HOLsexp.int_decode),
    write = fn {strings, ...} => HOLsexp.list_encode (HOLsexp.Integer o strings)
  };
val _ = Theory.LoadableThyData.set_theory_data {thydataty = "note", data = write_note ["$5"]};
SML
)
  fi
  cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Datatype:
  color = Red | Green
End
val _ = set_fixity "myop" (Infixl ${4:-500});
$note
Theorem helper1:
  (1:num) + 1 = 2
Proof
  simp[]
QED
Theorem helper2:
  (1:num) + 1 = 2
Proof
  decide_tac
QED
$1
Theorem a_thm:
  $3
Proof
  $2
QED
val _ = export_theory();
SML
}
write_a "" "ACCEPT_TAC helper1" "(1:num) + 1 = 2"
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib ATheory;
val _ = new_theory "B";
Theorem b_thm:
  (1:num) + 1 = 2
Proof
  simp[a_thm]
QED
val _ = export_theory();
SML
cat > "$project/src/CScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib BTheory;
val _ = new_theory "C";
Theorem c_thm:
  (1:num) + 1 = 2
Proof
  simp[b_thm]
QED
val _ = export_theory();
SML

build() {
  local log=$1
  sleep 1.1
  (cd "$project" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" build CTheory) > "$log" 2>&1 ||
    { cat "$log" >&2; exit 1; }
}
require_cutoff() {
  require_grep "early cutoff: $1 " "$2"
}
require_no_cutoff() {
  if grep -q "early cutoff: $1 " "$2"; then
    echo "$1 reused its outputs after a change it loads" >&2
    cat "$2" >&2
    exit 1
  fi
}
obj=$project/.holbuild/obj/src
a_hash_literal() { sed -n 's/^ *hash = "\([0-9a-f]*\)",$/\1/p' "$obj/ATheory.sml"; }

build "$tmpdir/build0.log"
a_dat_hash=$(sha256sum "$obj/ATheory.dat")
a_literal=$(a_hash_literal)
[[ ${#a_literal} -eq 40 ]] || { echo "no hash literal in ATheory.sml" >&2; exit 1; }
[[ "$a_literal" != "$(sha1sum "$obj/ATheory.dat" | cut -d' ' -f1)" ]] ||
  { echo "ATheory.sml's hash is the SHA-1 of ATheory.dat, not its digest" >&2; exit 1; }
c_dat_hash=$(sha256sum "$obj/CTheory.dat")

# The edit moves a_thm three lines down and proves it from helper2, with
# simp's own dependencies, so its location and dependency record change.
write_a $'(* a comment\n   of three\n   lines *)' "simp[helper2]" "(1:num) + 1 = 2"
build "$tmpdir/proof-edit.log"
[[ "$(sha256sum "$obj/ATheory.dat")" != "$a_dat_hash" ]] || { echo "the proof edit left ATheory.dat unchanged" >&2; exit 1; }
[[ "$(a_hash_literal)" == "$a_literal" ]] || { echo "the proof edit changed ATheory's digest" >&2; exit 1; }
require_grep "ATheory built" "$tmpdir/proof-edit.log"
require_cutoff BTheory "$tmpdir/proof-edit.log"
require_cutoff CTheory "$tmpdir/proof-edit.log"
[[ "$(sha256sum "$obj/CTheory.dat")" == "$c_dat_hash" ]] || { echo "CTheory.dat was rewritten" >&2; exit 1; }

# The kept C loads on the rebuilt A under plain HOL, whose link_parents
# compares the parent hashes B's and C's .dat record with the literals in
# ATheory.sml and BTheory.sml, and under holbuild run.
cat > "$tmpdir/load.sml" <<SML
load "$obj/CTheory";
val _ = CTheory.c_thm;
val _ = print "CTheory loaded\n";
SML
"$HOLDIR/bin/hol" run --noconfig --holstate "$HOLDIR/bin/hol.state" "$tmpdir/load.sml" \
  > "$tmpdir/plain-load.log" 2>&1 || { cat "$tmpdir/plain-load.log" >&2; exit 1; }
require_grep "CTheory loaded" "$tmpdir/plain-load.log"
cat > "$project/run.sml" <<'SML'
val _ = load "CTheory";
val _ = CTheory.c_thm;
val _ = print "CTheory loaded\n";
SML
(cd "$project" && "$HOLBUILD_BIN" run --from CTheory run.sml) > "$tmpdir/run-load.log" 2>&1 ||
  { cat "$tmpdir/run-load.log" >&2; exit 1; }
require_grep "CTheory loaded" "$tmpdir/run-load.log"

# A precedence change, an integer among the theory data, rebuilds B.
write_a $'(* a comment\n   of three\n   lines *)' "simp[helper2]" "(1:num) + 1 = 2" 501
build "$tmpdir/precedence-edit.log"
require_no_cutoff BTheory "$tmpdir/precedence-edit.log"
require_grep "BTheory built" "$tmpdir/precedence-edit.log"

# Data of a codec holbuild doesn't know keeps A hashed as written, so a
# change to the note, which the data stores as a string-table index,
# rebuilds B.
write_a $'(* a comment\n   of three\n   lines *)' "simp[helper2]" "(1:num) + 1 = 2" 501 note
build "$tmpdir/note.log"
grep -q "ATheory.dat as written: theory data note" "$project"/.holbuild/logs/current/*/ATheory/build.log ||
  { echo "ATheory's build log has no warning that it is hashed as written" >&2
    cat "$project"/.holbuild/logs/current/*/ATheory/build.log >&2; exit 1; }
write_a $'(* a comment\n   of three\n   lines *)' "simp[helper2]" "(1:num) + 1 = 2" 501 other
build "$tmpdir/note-edit.log"
require_no_cutoff BTheory "$tmpdir/note-edit.log"
require_grep "BTheory built" "$tmpdir/note-edit.log"

# A statement change in A rebuilds B and C.
write_a $'(* a comment\n   of three\n   lines *)' "simp[]" "(2:num) + 2 = 4"
build "$tmpdir/statement-edit.log"
require_no_cutoff BTheory "$tmpdir/statement-edit.log"
require_no_cutoff CTheory "$tmpdir/statement-edit.log"
require_grep "BTheory built" "$tmpdir/statement-edit.log"
require_grep "CTheory built" "$tmpdir/statement-edit.log"
