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

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "invalidate"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open ATheory;
val _ = new_theory "B";
val b_thm = store_thm("b_thm", ``T``, ACCEPT_TAC ATheory.a_thm);
val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" build BTheory)

akey_before=$(grep '^input_key=' "$project/.holbuild/dep/invalidate/src/AScript.sml.key")
bkey_before=$(grep '^input_key=' "$project/.holbuild/dep/invalidate/src/BScript.sml.key")

printf '\n(* comment-only edit still invalidates v1 input key *)\n' >> "$project/src/AScript.sml"
rebuild_log=$tmpdir/rebuild.log
(cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$rebuild_log"

akey_after=$(grep '^input_key=' "$project/.holbuild/dep/invalidate/src/AScript.sml.key")
bkey_after=$(grep '^input_key=' "$project/.holbuild/dep/invalidate/src/BScript.sml.key")

[[ "$akey_before" != "$akey_after" ]] || { echo "A input key did not change" >&2; exit 1; }
[[ "$bkey_before" != "$bkey_after" ]] || { echo "B input key did not change after dependency key changed" >&2; exit 1; }
if grep -q "BTheory is up to date" "$rebuild_log"; then
  echo "dependent BTheory was incorrectly up to date" >&2
  exit 1
fi
