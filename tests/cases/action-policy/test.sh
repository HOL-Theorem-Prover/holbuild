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

make_theory_project() {
  local project=$1
  local action_stanza=$2
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "$(basename "$project")"

[build]
members = ["src"]

$action_stanza
TOML
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
}

metadata_key() {
  grep '^input_key=' "$1/.holbuild/dep/$(basename "$1")/src/AScript.sml.key" | cut -d= -f2
}

extra_project="$tmpdir/extra_policy"
make_theory_project "$extra_project" '[actions.ATheory]
extra_deps = ["extra.txt"]'
echo one > "$extra_project/extra.txt"
(cd "$extra_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/extra1.log" 2>&1
key1=$(metadata_key "$extra_project")
(cd "$extra_project" && "$HOLBUILD_BIN" --verbose build ATheory) > "$tmpdir/extra2.log" 2>&1
require_grep "ATheory is up to date" "$tmpdir/extra2.log"
echo two > "$extra_project/extra.txt"
(cd "$extra_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/extra3.log" 2>&1
key2=$(metadata_key "$extra_project")
if [[ "$key1" == "$key2" ]]; then
  echo "extra dependency edit did not change action key" >&2
  exit 1
fi
if grep -q "ATheory is up to date" "$tmpdir/extra3.log"; then
  echo "extra dependency edit was incorrectly treated as up to date" >&2
  exit 1
fi
require_grep "extra_dep=extra.txt@" "$extra_project/.holbuild/dep/extra_policy/src/AScript.sml.key"

compat_project="$tmpdir/extra_inputs_compat"
make_theory_project "$compat_project" '[actions.ATheory]
extra_inputs = ["extra.txt"]'
echo compat > "$compat_project/extra.txt"
(cd "$compat_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/compat.log" 2>&1
require_grep "extra_dep=extra.txt@" "$compat_project/.holbuild/dep/extra_inputs_compat/src/AScript.sml.key"

source_extra_project="$tmpdir/source_extra_policy"
mkdir -p "$source_extra_project/src" "$source_extra_project/data"
cat > "$source_extra_project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "source_extra_policy"

[build]
members = ["src"]
TOML
echo one > "$source_extra_project/data/message.txt"
cat > "$source_extra_project/src/AScript.sml" <<'SML'
fun holbuild_extra_deps (_ : string list) = ()
val _ = holbuild_extra_deps ["../data/message.txt"]
val input = TextIO.openIn "../data/message.txt"
val message = TextIO.inputAll input before TextIO.closeIn input
val _ = if size message > 0 then () else raise Fail "empty message"
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
(cd "$source_extra_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/source-extra1.log" 2>&1
source_key1=$(metadata_key "$source_extra_project")
require_grep "source_extra_dep=../data/message.txt@" "$source_extra_project/.holbuild/dep/source_extra_policy/src/AScript.sml.key"
echo two > "$source_extra_project/data/message.txt"
(cd "$source_extra_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/source-extra2.log" 2>&1
source_key2=$(metadata_key "$source_extra_project")
if [[ "$source_key1" == "$source_key2" ]]; then
  echo "source extra dependency edit did not change action key" >&2
  exit 1
fi
if grep -q "ATheory is up to date" "$tmpdir/source-extra2.log"; then
  echo "source extra dependency edit was incorrectly treated as up to date" >&2
  exit 1
fi

always_project="$tmpdir/always_policy"
make_theory_project "$always_project" '[actions.ATheory]
always_reexecute = true'
(cd "$always_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/always1.log" 2>&1
(cd "$always_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/always2.log" 2>&1
if grep -q "ATheory is up to date" "$tmpdir/always2.log"; then
  echo "always_reexecute action was skipped" >&2
  exit 1
fi
require_file "$always_project/.holbuild/obj/src/ATheory.dat"

no_cache_project="$tmpdir/no_cache_policy"
make_theory_project "$no_cache_project" '[actions.ATheory]
cache = false'
(cd "$no_cache_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/no_cache1.log" 2>&1
rm -rf "$no_cache_project/.holbuild"
(cd "$no_cache_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/no_cache2.log" 2>&1
if grep -q "restored from cache" "$tmpdir/no_cache2.log"; then
  echo "cache=false action restored from cache" >&2
  exit 1
fi
require_file "$no_cache_project/.holbuild/obj/src/ATheory.dat"

unknown_project="$tmpdir/unknown_policy"
make_theory_project "$unknown_project" '[actions.MissingTheory]
cache = false'
if (cd "$unknown_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/unknown.log" 2>&1; then
  echo "unknown action policy target was accepted" >&2
  exit 1
fi
require_grep "action policy references unknown target unknown_policy:MissingTheory" "$tmpdir/unknown.log"

missing_dep_project="$tmpdir/missing_declared_dep"
make_theory_project "$missing_dep_project" '[actions.ATheory]
deps = ["Missing"]'
if (cd "$missing_dep_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/missing-dep.log" 2>&1; then
  echo "unresolved action dependency was accepted" >&2
  exit 1
fi
require_grep "unresolved action dependency Missing" "$tmpdir/missing-dep.log"
