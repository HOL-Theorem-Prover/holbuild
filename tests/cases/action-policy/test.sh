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

make_theory_project() {
  local project=$1
  local action_stanza=$2
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

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
minimum_version = "0.10.0"

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

# Manifest inputs are staged at their script-relative paths, so the script can
# read them the way it would read source-declared ones, and inputs reached
# through ../ stay inside the action's stage.
manifest_stage_project="$tmpdir/manifest_stage_policy"
mkdir -p "$manifest_stage_project/src/a" "$manifest_stage_project/data"
cat > "$manifest_stage_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "manifest_stage_policy"

[build]
members = ["src"]

[actions.ATheory]
extra_deps = ["src/a/side.txt", "data/message.txt"]
TOML
echo side > "$manifest_stage_project/src/a/side.txt"
echo message > "$manifest_stage_project/data/message.txt"
cat > "$manifest_stage_project/src/a/AScript.sml" <<'SML'
fun read_input path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end
val _ = if read_input "side.txt" = "side\n" then () else raise Fail "bad side.txt"
val _ = if read_input "../../data/message.txt" = "message\n" then () else raise Fail "bad message.txt"
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
(cd "$manifest_stage_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/manifest-stage.log" 2>&1
require_file "$manifest_stage_project/.holbuild/obj/src/a/ATheory.dat"
if [[ -e "$manifest_stage_project/.holbuild/data" || -e "$manifest_stage_project/.holbuild/stage/data" ]]; then
  echo "manifest extra input was staged outside the action's stage" >&2
  exit 1
fi

# Staged inputs must not replace holbuild's own staged files: an input naming
# the script's directory still runs the instrumented script (the tactic
# timeout fires), and globs skip holbuild's state under .holbuild/.
manifest_dir_project="$tmpdir/manifest_dir_policy"
mkdir -p "$manifest_dir_project/src" "$manifest_dir_project/.holbuild"
cat > "$manifest_dir_project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "manifest_dir_policy"

[build]
members = ["src"]
tactic_timeout = 0.1

[actions.ATheory]
extra_inputs = ["src", "*.txt"]
TOML
echo stray > "$manifest_dir_project/.holbuild/stray.txt"
cat > "$manifest_dir_project/src/AScript.sml" <<'SML'
val _ = if OS.FileSys.access ("../.holbuild", []) then raise Fail ".holbuild was staged" else ();
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
fun slow_tac g = (OS.Process.sleep (Time.fromReal 0.5); ACCEPT_TAC TRUTH g);
Theorem a_thm:
  T
Proof
  slow_tac
QED
val _ = export_theory();
SML
if (cd "$manifest_dir_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/manifest-dir.log" 2>&1; then
  echo "staged extra input replaced the instrumented script" >&2
  cat "$tmpdir/manifest-dir.log" >&2
  exit 1
fi
require_grep "tactic timed out after 0.1s while building ATheory" "$tmpdir/manifest-dir.log"

# Nor does holbuild's state under .holbuild/ change the action key.
glob_project="$tmpdir/glob_policy"
make_theory_project "$glob_project" '[actions.ATheory]
extra_deps = ["*.txt"]'
echo one > "$glob_project/extra.txt"
(cd "$glob_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/glob1.log" 2>&1
echo stray > "$glob_project/.holbuild/stray.txt"
(cd "$glob_project" && "$HOLBUILD_BIN" --verbose build ATheory) > "$tmpdir/glob2.log" 2>&1
require_grep "ATheory is up to date" "$tmpdir/glob2.log"

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
cat >> "$unknown_project/holproject.toml" <<'TOML'
[[generate]]
name = "must-not-run"
command = ["sh", "-c", "printf x >> generator-ran"]
outputs = ["src/Generated.sml"]
TOML
if (cd "$unknown_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/unknown.log" 2>&1; then
  echo "unknown action policy target was accepted" >&2
  exit 1
fi
require_grep "action policy references unknown target unknown_policy:MissingTheory" "$tmpdir/unknown.log"
if [[ -e "$unknown_project/generator-ran" ]]; then
  echo "unknown action policy target ran a generator before validation" >&2
  exit 1
fi

outside_member_project="$tmpdir/outside_member_policy"
make_theory_project "$outside_member_project" '[actions.Generated]
cache = false'
cat >> "$outside_member_project/holproject.toml" <<'TOML'
[[generate]]
name = "must-not-run-outside-member"
command = ["sh", "-c", "printf x >> generator-ran"]
outputs = ["gen/Generated.sml"]
TOML
if (cd "$outside_member_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/outside-member.log" 2>&1; then
  echo "action policy for generator output outside build.members was accepted" >&2
  exit 1
fi
require_grep "action policy references unknown target outside_member_policy:Generated" "$tmpdir/outside-member.log"
if [[ -e "$outside_member_project/generator-ran" ]]; then
  echo "action policy for generator output outside build.members ran a generator before validation" >&2
  exit 1
fi

missing_dep_project="$tmpdir/missing_declared_dep"
make_theory_project "$missing_dep_project" '[actions.ATheory]
deps = ["Missing"]'
if (cd "$missing_dep_project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/missing-dep.log" 2>&1; then
  echo "unresolved action dependency was accepted" >&2
  exit 1
fi
require_grep "unresolved action dependency Missing" "$tmpdir/missing-dep.log"
