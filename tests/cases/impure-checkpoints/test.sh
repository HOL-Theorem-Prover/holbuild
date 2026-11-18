#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# An impure theory re-executes on every build, so it must not resume from the
# checkpoints of an earlier run: a value its script computes at run time (here
# the clock) has to be recomputed, also when it comes before a termination
# definition whose checkpoint a later build would otherwise resume from.

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "impure_checkpoints"

[build]
members = ["src"]

[actions.StampTheory]
impure = true
TOML
cat > "$project/src/StampScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Stamp";

val stamp_n = LargeInt.toString (Time.toNanoseconds (Time.now ()));
val stamp_def = new_definition ("stamp_def",
  mk_eq (mk_var ("stamp", numSyntax.num),
         numSyntax.mk_numeral (Arbnum.fromString stamp_n)));

Definition nl_def:
  nl n (s:num list) = if LENGTH s <= n then n else nl (n+1) s
Termination
  WF_REL_TAC `measure (λ(n,s). LENGTH s - n)`
End

Theorem nl_thm:
  nl n s = if LENGTH s <= n then n else nl (n+1) s
Proof
  simp[Once nl_def]
QED

val _ = print ("STAMP " ^ term_to_string (concl stamp_def) ^ "\n");
val _ = export_theory();
SML

stamp_of() {
  grep -h '^STAMP ' "$project/.holbuild/logs/current/impure_checkpoints/StampTheory/build.log"
}

(cd "$project" && "$HOLBUILD_BIN" build StampTheory) > "$tmpdir/build1.log" 2>&1
require_grep "StampTheory built" "$tmpdir/build1.log"
stamp1=$(stamp_of)
(cd "$project" && "$HOLBUILD_BIN" build StampTheory) > "$tmpdir/build2.log" 2>&1
require_grep "StampTheory built" "$tmpdir/build2.log"
stamp2=$(stamp_of)
if [[ -z "$stamp1" || "$stamp1" == "$stamp2" ]]; then
  echo "impure theory restored run-time values from a checkpoint: '$stamp1' vs '$stamp2'" >&2
  exit 1
fi
