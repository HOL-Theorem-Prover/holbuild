#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
server_pid=
cleanup() { [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true; rm -rf "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

# A <- B <- C, and C also loads the library Util, which loads A.  An edit to A
# moves every input key below it; dependents are reused only when nothing
# they load from A changed.
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
name = "cutoff"

[build]
members = ["src"]
TOML

write_a() {
  local tactic=$1 result=$2 extra=${3:-}
  cat > "$project/src/AScript.sml" <<SML
fun holbuild_extra_outputs (_ : string list) = ()
val _ = holbuild_extra_outputs ["A.out"]
val _ = let val out = TextIO.openOut "A.out"
        in TextIO.output(out, "$result\n"); TextIO.closeOut out end
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
$extra
Theorem a_thm:
  T
Proof
  $tactic
QED
val _ = export_theory();
SML
}
write_a "ACCEPT_TAC TRUTH" "one"
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib ATheory;
val _ = new_theory "B";
Theorem b_thm:
  T
Proof
  ACCEPT_TAC a_thm
QED
val _ = export_theory();
SML
cat > "$project/src/Util.sml" <<'SML'
structure Util = struct val thm = ATheory.a_thm end
SML
write_c() {
  local tactic=$1
  cat > "$project/src/CScript.sml" <<SML
open HolKernel Parse boolLib bossLib BTheory Util;
val _ = new_theory "C";
Theorem c_thm:
  T
Proof
  ACCEPT_TAC Util.thm
QED
Theorem c2_thm:
  T
Proof
  $tactic
QED
val _ = export_theory();
SML
}
write_c "ACCEPT_TAC b_thm"

dep=$project/.holbuild/dep/cutoff/src
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
deps_loaded() {
  find "$project/.holbuild/checkpoints" -path '*CScript*' -name deps_loaded.save
}

build "$tmpdir/build0.log"
a_dat=$project/.holbuild/obj/src/ATheory.dat
a_dat_hash=$(sha256sum "$a_dat")
b_key=$(grep '^input_key=' "$dep/BScript.sml.key")
c_context=$(grep '^dependency_context_key=' "$dep/CScript.sml.key")
c_deps_loaded=$(deps_loaded)
[[ -n "$c_deps_loaded" ]] || { echo "C saved no deps_loaded checkpoint" >&2; exit 1; }
c_deps_loaded_stamp=$(stat -c '%i %Y' "$c_deps_loaded")

# A proof-only edit leaves A's outputs as they were, so B and C are reused,
# and Util, whose load manifest only names its unchanged source, too.
write_a "ALL_TAC >> ACCEPT_TAC TRUTH" "one"
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
HOLBUILD_REMOTE_CACHE_URL=$remote_url build "$tmpdir/proof-edit.log"
[[ "$(sha256sum "$a_dat")" == "$a_dat_hash" ]] || { echo "proof edit changed ATheory.dat" >&2; exit 1; }
require_grep "ATheory built" "$tmpdir/proof-edit.log"
require_cutoff BTheory "$tmpdir/proof-edit.log"
require_cutoff CTheory "$tmpdir/proof-edit.log"
[[ "$(grep '^input_key=' "$dep/BScript.sml.key")" != "$b_key" ]] ||
  { echo "B's metadata kept its old input key" >&2; exit 1; }
# A configured remote cache gets the reused theories' entries under their
# new keys, as it would from a rebuild.
b_remote_ac=$(printf 'holbuild-remote-ac-v1\n%s\n' "$(sed -n 's/^input_key=//p' "$dep/BScript.sml.key")" |
               sha256sum | cut -d' ' -f1)
require_file "$tmpdir/remote/ac/$b_remote_ac"
# The cache entries of the reused theories are aliased to their new keys,
# so commands that read the cache by current key find them.
(cd "$project" && "$HOLBUILD_BIN" export -o "$tmpdir/cutoff.hbx" CTheory) > "$tmpdir/export.log" 2>&1 ||
  { cat "$tmpdir/export.log" >&2; exit 1; }
# The new keys are recorded, so the next build is a plain up-to-date check.
build "$tmpdir/noop.log"
if grep -q "built\|early cutoff" "$tmpdir/noop.log"; then
  echo "the build after early cutoff did work" >&2
  cat "$tmpdir/noop.log" >&2
  exit 1
fi

# A third output-neutral variant of A, so every input key below it differs
# from the first build's, together with an edit to C: C rebuilds, but from
# the dependency context it saved in the first build.
write_a "ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH" "one"
write_c "ALL_TAC >> ACCEPT_TAC b_thm"
build "$tmpdir/downstream-edit.log"
require_cutoff BTheory "$tmpdir/downstream-edit.log"
require_grep "CTheory built" "$tmpdir/downstream-edit.log"
[[ "$(grep '^input_key=' "$dep/BScript.sml.key")" != "$b_key" ]] ||
  { echo "B's input key is the first build's again" >&2; exit 1; }
[[ "$(grep '^dependency_context_key=' "$dep/CScript.sml.key")" == "$c_context" ]] ||
  { echo "C's dependency context key moved after an output-neutral edit" >&2; exit 1; }
[[ "$(deps_loaded)" == "$c_deps_loaded" && "$(stat -c '%i %Y' "$c_deps_loaded")" == "$c_deps_loaded_stamp" ]] ||
  { echo "C's deps_loaded checkpoint was not kept" >&2; exit 1; }

# A changed extra output: B and C load it, so they rebuild.
write_a "ACCEPT_TAC TRUTH" "two"
build "$tmpdir/extra-output.log"
[[ "$(sha256sum "$a_dat")" == "$a_dat_hash" ]] || { echo "extra-output edit changed ATheory.dat" >&2; exit 1; }
require_no_cutoff BTheory "$tmpdir/extra-output.log"
require_no_cutoff CTheory "$tmpdir/extra-output.log"
require_grep "BTheory built" "$tmpdir/extra-output.log"

# A new ML dependency of A changes what loading ATheory loads.
write_a "ACCEPT_TAC TRUTH" "two" 'val _ = Theory.add_ML_dependency "pairLib";'
build "$tmpdir/mldep.log"
require_no_cutoff BTheory "$tmpdir/mldep.log"
require_grep "BTheory built" "$tmpdir/mldep.log"

# A new theorem changes ATheory.dat.
write_a "ACCEPT_TAC TRUTH" "two" 'val _ = Theory.add_ML_dependency "pairLib";
Theorem a2_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED'
build "$tmpdir/output-edit.log"
require_no_cutoff BTheory "$tmpdir/output-edit.log"
require_grep "BTheory built" "$tmpdir/output-edit.log"
require_grep "CTheory built" "$tmpdir/output-edit.log"

# An edit to the library changes what C loads even though Util's load
# manifest stays the same.
printf 'structure Util = struct val thm = ATheory.a_thm val n = 1 end\n' > "$project/src/Util.sml"
build "$tmpdir/library-edit.log"
require_no_cutoff CTheory "$tmpdir/library-edit.log"
require_grep "CTheory built" "$tmpdir/library-edit.log"
