#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# Steps naming metis get twice the tactic timeout, or --heavy-tactic-timeout,
# which reaches a remote worker through one spec line.

tmpdir=$(make_temp_dir)
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
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
name = "metis-timeout"

[build]
members = ["src"]
tactic_timeout = 1.0
TOML

# Steps naming metis get 2 s, twice the project's 1 s timeout.
cat > "$project/src/MetisScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Metis";
fun sleep_tac seconds g = (OS.Process.sleep (Time.fromReal seconds); ACCEPT_TAC TRUTH g);
structure X = struct
  fun metis_tac _ = sleep_tac 1.4;
  val METIS_TAC = metis_tac;
  val Z3_TAC = ALL_TAC;
end;
structure Nested = struct structure M = X; end;
(* Other work in the same opaque leaf shares the longer budget. *)
Theorem mixed: T
Proof
  (fn g => (sleep_tac 1.4 g; bossLib.metis_tac [] g))
QED
open X;
Theorem bare: T
Proof
  metis_tac []
QED
Theorem qualified: T
Proof
  X.metis_tac []
QED
Theorem reexported: T
Proof
  Nested.M.METIS_TAC []
QED
(* An SMT call anywhere in the step leaves it untimed, metis or not. *)
Theorem smt_wins: T
Proof
  (fn g => (ignore X.metis_tac; ignore X.Z3_TAC; sleep_tac 3.0 g))
QED
val _ = export_theory();
SML
(cd "$project" && "$HOLBUILD_BIN" build MetisTheory) > "$tmpdir/metis.log" 2>&1 ||
  { cat "$tmpdir/metis.log" >&2; exit 1; }
require_file "$project/.holbuild/obj/src/MetisTheory.dat"
require_grep 'proof_timeout=1.0' "$project/.holbuild/dep/metis-timeout/src/MetisScript.sml.key"

# write_slow TACTIC [THEORY]: THEORY (default Slow) proves T with TACTIC.
write_slow() {
  local theory=${2:-Slow}
  cat > "$project/src/${theory}Script.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "$theory";
fun sleep_tac seconds g = (OS.Process.sleep (Time.fromReal seconds); ACCEPT_TAC TRUTH g);
val slow_tac = sleep_tac 1.4;
val metis_tac_slow = slow_tac;
structure X = struct fun metis_tac _ = ALL_TAC; end;
Theorem slow: T
Proof
  $1
QED
val _ = export_theory();
SML
}
# check_timeout NAME LIMIT TACTIC [OPTION...]: proving T with TACTIC fails
# after LIMIT seconds.
check_timeout() {
  local name=$1 limit=$2
  write_slow "$3"
  if (cd "$project" && "$HOLBUILD_BIN" build --no-cache --force=full --skip-checkpoints "${@:4}" SlowTheory) > "$tmpdir/$name.log" 2>&1; then
    echo "step escaped its ${limit}s budget: $name" >&2
    exit 1
  fi
  require_grep "tactic timed out after ${limit}s while building SlowTheory" "$tmpdir/$name.log"
}
# check_passes NAME TACTIC [OPTION...]: proving T with TACTIC builds.
check_passes() {
  local name=$1
  write_slow "$2"
  (cd "$project" && "$HOLBUILD_BIN" build --no-cache --force=full --skip-checkpoints "${@:3}" SlowTheory) > "$tmpdir/$name.log" 2>&1 ||
    { echo "step failed its budget: $name" >&2; cat "$tmpdir/$name.log" >&2; exit 1; }
}
over_budget='(fn g => (X.metis_tac [] g; sleep_tac 3.0 g))'
check_timeout over_budget 2.0 "$over_budget"
# The heavy budget follows the tactic timeout, or the option overrides it.
check_timeout scaled 1.0 '(fn g => (X.metis_tac [] g; slow_tac g))' --tactic-timeout 0.5
check_passes heavy_option "$over_budget" --heavy-tactic-timeout 4
check_passes heavy_untimed "$over_budget" --heavy-tactic-timeout=0
check_timeout heavy_lower 0.5 '(fn g => (X.metis_tac [] g; slow_tac g))' --heavy-tactic-timeout 0.5
# Strings, comments, HOL terms and longer identifiers must not extend a budget,
# and a metis call in a later planned step must not extend the earlier step's.
check_timeout ordinary 1.0 'slow_tac'
check_timeout string 1.0 '(fn g => (ignore "X.metis_tac"; slow_tac g))'
check_timeout comment 1.0 '(fn g => ((* metis_tac *) slow_tac g))'
check_timeout quotation 1.0 '(fn g => (ignore ``metis_tac:bool``; slow_tac g))'
check_timeout identifier 1.0 'metis_tac_slow'
check_timeout separate 1.0 'slow_tac >> X.metis_tac []'
# The option doesn't extend ordinary steps, nor does 0 untime them.
check_timeout ordinary_heavy_option 1.0 'slow_tac' --heavy-tactic-timeout 4
check_timeout ordinary_heavy_untimed 1.0 'slow_tac' --heavy-tactic-timeout=0
# A tactic timeout whose double overflows leaves metis steps untimed.
check_passes huge_timeout "$over_budget" --tactic-timeout 1e308

# A default spec has no heavy-tactic-timeout line; the option adds just that
# line, keeps the input key, and the worker gives metis steps its budget.
write_slow "$over_budget" Remote
field() { awk -v want="$2" -v col="$3" '$1 == "action" && $5 == want { print $col }' "$1"; }
export_slow() {
  local name=$1
  shift
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload "$@" RemoteTheory) \
    > "$tmpdir/batch-$name.txt"
  [[ -n "$(field "$tmpdir/batch-$name.txt" metis-timeout:RemoteTheory 4)" ]] || { cat "$tmpdir/batch-$name.txt" >&2; exit 1; }
}
worker() {
  local name=$1 cache=$tmpdir/worker-$1
  link_hol_toolchain_cache "$cache"
  HOLBUILD_CACHE=$cache "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action \
    "$(field "$tmpdir/batch-$name.txt" metis-timeout:RemoteTheory 4)" \
    --cache-limit-gb 1000 --result "$tmpdir/$name.result" > "$tmpdir/worker-$name.log" 2>&1 || true
  grep -qx "status=$2" "$tmpdir/$name.result" || {
    echo "worker on $name: wanted status=$2" >&2
    cat "$tmpdir/$name.result" "$tmpdir/worker-$name.log" >&2
    exit 1
  }
}
export_slow default
export_slow heavy --heavy-tactic-timeout 4
specs=$project/.holbuild/action-specs
diff "$specs/$(field "$tmpdir/batch-default.txt" metis-timeout:RemoteTheory 4)" \
     "$specs/$(field "$tmpdir/batch-heavy.txt" metis-timeout:RemoteTheory 4)" > "$tmpdir/spec.diff" && {
  echo "the spec does not carry --heavy-tactic-timeout" >&2; exit 1; }
[[ "$(grep -c '^[<>]' "$tmpdir/spec.diff")" == 1 ]] && grep -qx '> option heavy-tactic-timeout=4.0' "$tmpdir/spec.diff" || {
  echo "--heavy-tactic-timeout changed more of the spec than its option:" >&2; cat "$tmpdir/spec.diff" >&2; exit 1; }
[[ "$(field "$tmpdir/batch-default.txt" metis-timeout:RemoteTheory 3)" == "$(field "$tmpdir/batch-heavy.txt" metis-timeout:RemoteTheory 3)" ]] || {
  echo "--heavy-tactic-timeout changed the action's input key" >&2; exit 1; }
worker default failed
require_grep "tactic timed out after 2.0s" "$tmpdir/worker-default.log"
worker heavy built
