#!/usr/bin/env bash
set -euo pipefail

# HOLBUILD_TIMING_SOURCE_LOADS=1 makes a HOL process time the source files its
# loader evaluates and the holbuild runtime files it uses, and report them at
# exit; without it nothing is printed.  On the fleet the flag rides the action
# spec as an option, which changes neither the action's key nor anything else.

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

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

# Stand-in theories B -> A and a library ProbeLib, in HOL's .hol/objs.  ProbeLib
# sleeps 0.2 s itself and uses a runtime file that sleeps 0.3 s more: ProbeLib's
# total includes the runtime file's time, its self time does not.  B's .dat is
# large enough that the loader shares the heap after it: theory time, not self.
mods=$tmpdir/mods
objs=$mods/.hol/objs
mkdir -p "$objs"
for name in ATheory BTheory ProbeLib; do : > "$objs/$name.ui"; done
echo "$mods/ATheory.sml" > "$objs/ATheory.uo"
printf 'ATheory\n%s\n' "$mods/BTheory.sml" > "$objs/BTheory.uo"
echo "$mods/ProbeLib.sml" > "$objs/ProbeLib.uo"
echo 'val _ = ();' > "$objs/ATheory.sml"
echo 'val _ = ();' > "$objs/BTheory.sml"
truncate -s 64M "$objs/BTheory.dat"
echo 'val _ = OS.Process.sleep (Time.fromMilliseconds 300);' > "$tmpdir/rt_step.sml"
cat > "$mods/ProbeLib.sml" <<SML
val _ = OS.Process.sleep (Time.fromMilliseconds 200);
val _ = HolbuildRuntime.use "$tmpdir/rt_step.sml";
SML

# row LOG KIND NAME FIELD: FIELD of the source-load row for KIND NAME.
row() {
  awk -v kind="kind=$2" -v name="name=$3" -v field="$4=" '
    $1 == "holbuild" && $2 == "source-load" && $4 == kind && $5 == name {
      for (i = 6; i <= NF; i++) if (index($i, field) == 1) print substr($i, length(field) + 1) }' "$1"
}

# run_load MODE PRELUDE BODY [VAR=VALUE...]: a HOL process that compiles the
# runtime and runs BODY; its output goes to $tmpdir/MODE.log.
run_load() {
  local mode=$1 prelude=$2 body=$3
  shift 3
  cat > "$tmpdir/$mode.sml" <<SML
$prelude
use "$HOLBUILD_ROOT/sml/holbuild_runtime.sml";
val _ = Meta.loadPath := "$mods" :: !Meta.loadPath;
$body
SML
  env "$@" "$HOLDIR/bin/hol" run --noconfig --holstate "$HOLDIR/bin/hol.state" "$tmpdir/$mode.sml" \
    > "$tmpdir/$mode.log" 2>&1 || { cat "$tmpdir/$mode.log" >&2; exit 1; }
}

check_timed() {
  local mode=$1 log=$tmpdir/$1.log
  fail() { echo "$mode: $1" >&2; cat "$log" >&2; exit 1; }
  [[ "$(row "$log" theory '*' n)" == 2 ]] || fail "both theories are not counted once each"
  [[ "$(row "$log" runtime rt_step.sml n)" == 1 ]] || fail "no runtime row for the runtime file"
  [[ "$(row "$log" library project:ProbeLib.sml n)" == 1 ]] || fail "no library row for ProbeLib"
  grep -q '^holbuild source-load ctx=probe-ctx ' "$log" || fail "rows do not carry the context"
  local lib_total lib_self rt_total
  lib_total=$(row "$log" library project:ProbeLib.sml total_us)
  lib_self=$(row "$log" library project:ProbeLib.sml self_us)
  rt_total=$(row "$log" runtime rt_step.sml total_us)
  (( rt_total >= 250000 && lib_total == lib_self + rt_total && lib_self >= 150000 )) ||
    fail "ProbeLib's self time ($lib_self us) is not its total ($lib_total us) less the runtime file's ($rt_total us)"
  grep -qx "holbuild hol-phases srclib=$((lib_self / 1000)) srclibn=1 srcrt=$((rt_total / 1000)) srcrtn=1 srcthy=[0-9]* srcthyn=2" "$log" ||
    fail "no hol-phases line with the kinds' self times and counts"
  [[ "$(grep -c '^holbuild hol-phases ' "$log")" == 1 ]] || fail "more than one report"
  (( $(row "$log" theory '*' self_us) < $(row "$log" theory '*' total_us) )) ||
    fail "the heap share after B counts as theory self time"
}

# B, then the runtime compiled again (as a load ahead's second preload does),
# then ProbeLib: one table across both.
loads='val _ = HolbuildRuntime.load "BTheory";
use "'"$HOLBUILD_ROOT"'/sml/holbuild_runtime.sml";
val _ = HolbuildRuntime.load "ProbeLib";'

loadplan_meta="structure Meta = struct val loadPlan = Meta.loadPlan val qquse = Meta.qquse val load = Meta.load val loadPath = Meta.loadPath end;"

# Off by default.
run_load off "" "$loads"
if grep -q '^holbuild \(source-load\|hol-phases\)' "$tmpdir/off.log"; then
  echo "source loads were reported without HOLBUILD_TIMING_SOURCE_LOADS" >&2; cat "$tmpdir/off.log" >&2; exit 1
fi
# On, with this HOL's own loader and with a Meta that has loadPlan but no
# moduleSourceLoader (HOL before theory modules).
run_load current "" "$loads" HOLBUILD_TIMING_SOURCE_LOADS=1 HOLBUILD_SOURCE_LOAD_CONTEXT=probe-ctx
check_timed current
run_load loadplan "$loadplan_meta" "$loads" HOLBUILD_TIMING_SOURCE_LOADS=1 HOLBUILD_SOURCE_LOAD_CONTEXT=probe-ctx
check_timed loadplan
# A timed process that loads nothing (a child resumed from a heap, say) still
# reports, with its context.
run_load empty "" "" HOLBUILD_TIMING_SOURCE_LOADS=1 HOLBUILD_SOURCE_LOAD_CONTEXT=probe-ctx
grep -qx 'holbuild hol-phases srclib=0 srclibn=0 srcrt=0 srcrtn=0 srcthy=0 srcthyn=0' "$tmpdir/empty.log" &&
  grep -qx 'holbuild source-load ctx=probe-ctx kind=none name=- n=0 total_us=0 self_us=0' "$tmpdir/empty.log" || {
  echo "a timed process that loaded nothing did not report" >&2; cat "$tmpdir/empty.log" >&2; exit 1; }

# A local build labels each theory child by how it started: cold, from the
# failed-prefix checkpoint, then from the dependency heap.  L's first child
# loads K, writing K's module where HOL has theory modules; a later cold
# child loads K from it.
use_case_cache "$tmpdir/cache"
local_project=$tmpdir/local
mkdir -p "$local_project/src"
cat > "$local_project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "local"

[build]
members = ["src"]
TOML
for name in K K2; do
  cat > "$local_project/src/${name}Script.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "$name";
Theorem ${name}_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML
done
cat > "$local_project/src/LScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib KTheory;
val _ = new_theory "L";
Theorem passes:
  T
Proof
  ACCEPT_TAC TRUTH
QED
Theorem fails:
  T
Proof
  FAIL_TAC "seed failure"
QED
val _ = export_theory();
SML
child_log=$local_project/.holbuild/logs/current/local/LTheory/build.log
# local_build NAME CTX [OPTION...]: a timed build whose child reports CTX.
local_build() {
  local name=$1 ctx=$2
  shift 2
  (cd "$local_project" && HOLBUILD_TIMING_SOURCE_LOADS=1 "$HOLBUILD_BIN" build "$@" LTheory) > "$tmpdir/$name.log" 2>&1 || true
  set -- "$name" "$ctx"
  grep -q "^holbuild source-load ctx=$2 " "$child_log" || {
    echo "$1: the child did not report ctx=$2:" >&2; cat "$tmpdir/$1.log" "$child_log" >&2; exit 1; }
}
local_build seed target-cold
sed -i 's/FAIL_TAC "seed failure"/ACCEPT_TAC TRUTH/' "$local_project/src/LScript.sml"
local_build resume target-prefix
require_grep "from: failed-prefix checkpoint" "$tmpdir/resume.log"
sed -i 's/^val _ = new_theory "L";$/val _ = new_theory "L"; val edited = ();/' "$local_project/src/LScript.sml"
local_build edit target-deps
# Without proof steps the script runs plain, with no proof runtime: it
# reports all the same.
sed -i 's/ val edited = ();$/ val edited = 1;/' "$local_project/src/LScript.sml"
local_build plain target-deps --skip-proof-steps
# A new ancestor: a cold child, which loads K from its module.
sed -i 's/ KTheory;$/ KTheory K2Theory;/' "$local_project/src/LScript.sml"
local_build ancestor target-cold
hits=$(sed -n 's/^holbuild hol-phases holmodhitn=\([0-9]*\) .*/\1/p' "$child_log")
if [[ "${HOLBUILD_TEST_REQUIRE_THEORY_MODULES:-}" == 1 && "${hits:-0}" -lt 1 ]]; then
  echo "L's child loaded no theory from its module:" >&2; cat "$child_log" >&2; exit 1
fi
theories=$(awk '$1 == "holbuild" && $2 == "source-load" && $4 == "kind=theory" { sub("n=", "", $6); print $6 }' "$child_log")
(( ${theories:-0} >= ${hits:-0} && ${theories:-0} >= 1 )) || {
  echo "L's theory loads (${theories:-none}) do not count its module hits (${hits:-0}):" >&2; cat "$child_log" >&2; exit 1; }

# The fleet: action-spec under the flag adds one option to the spec, and a
# worker without the flag in its environment times T's child from it.
control=$tmpdir/control
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server" "$control"
project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "timing"

[build]
members = ["src"]
TOML
# write_theory NAME ANCESTOR THEOREM
write_theory() {
  cat > "$project/src/$1Script.sml" <<SML
Theory $1
Ancestors $2

Theorem $3:
  T
Proof
  simp[]
QED
SML
}
write_theory A bool a_thm
write_theory T A t_v1

field() { awk -v want="$2" -v col="$3" '$1 == "action" && $5 == want { print $col }' "$1"; }

# worker NAME SPEC: exec-action of SPEC on its own cache root; the record goes
# to $tmpdir/NAME.result and HOL's log to $tmpdir/NAME.hol.
worker() {
  local name=$1 spec=$2 cache=$tmpdir/worker-$1
  link_hol_toolchain_cache "$cache"
  HOLBUILD_CACHE=$cache env -u HOLBUILD_TIMING_SOURCE_LOADS "$HOLBUILD_BIN" --remote-cache "$remote_url" \
    exec-action "$spec" --cache-limit-gb 1000 --result "$tmpdir/$name.result" > "$tmpdir/$name.log" 2>&1 || {
    cat "$tmpdir/$name.log" "$tmpdir/$name.result" >&2; exit 1; }
  local log_sha
  log_sha=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$tmpdir/$name.result")
  [[ -n "$log_sha" ]] || { echo "worker $name uploaded no log" >&2; exit 1; }
  curl -fsS "$remote_url/cas/$log_sha" > "$tmpdir/$name.hol"
}

(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload TTheory) > "$tmpdir/plain.txt"
(cd "$project" && HOLBUILD_TIMING_SOURCE_LOADS=1 "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload TTheory) \
  > "$tmpdir/timed.txt"
specs=$project/.holbuild/action-specs
plain_t=$(field "$tmpdir/plain.txt" timing:TTheory 4)
timed_t=$(field "$tmpdir/timed.txt" timing:TTheory 4)
timed_a=$(field "$tmpdir/timed.txt" timing:ATheory 4)
[[ -n "$plain_t" && -n "$timed_t" && -n "$timed_a" ]] || { cat "$tmpdir/plain.txt" "$tmpdir/timed.txt" >&2; exit 1; }
if diff "$specs/$plain_t" "$specs/$timed_t" > "$tmpdir/spec.diff"; then
  echo "the flag did not reach the spec" >&2; exit 1
fi
[[ "$(grep -c '^[<>]' "$tmpdir/spec.diff")" == 1 ]] && grep -qx '> option source-load-timing=true' "$tmpdir/spec.diff" || {
  echo "the flag changed more of the spec than its option:" >&2; cat "$tmpdir/spec.diff" >&2; exit 1; }
[[ "$(field "$tmpdir/plain.txt" timing:TTheory 3)" == "$(field "$tmpdir/timed.txt" timing:TTheory 3)" ]] || {
  echo "the flag changed the action's input key" >&2; exit 1; }

# A spec without the option times nothing.
worker a "$timed_a"
worker plain "$plain_t"
if grep -q '^holbuild source-load' "$tmpdir/plain.hol" || grep -q 'srclib' "$tmpdir/plain.result"; then
  echo "a spec without the option timed source loads" >&2; exit 1
fi

# T is cached now: a new version of it is a new action.
write_theory T A t_v2
(cd "$project" && HOLBUILD_TIMING_SOURCE_LOADS=1 "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload TTheory) \
  > "$tmpdir/timed2.txt"
timed_t=$(field "$tmpdir/timed2.txt" timing:TTheory 4)
worker t "$timed_t"
grep -qE '^holbuild source-load ctx=target-cold kind=theory name=\* n=[1-9]' "$tmpdir/t.hol" || {
  echo "T's child did not report its theory loads as a target's cold start:" >&2; cat "$tmpdir/t.hol" >&2; exit 1; }
grep -qE '^holbuild source-load ctx=target-cold kind=runtime ' "$tmpdir/t.hol" || {
  echo "T's child did not report its runtime files:" >&2; cat "$tmpdir/t.hol" >&2; exit 1; }
for phase in srclib srclibn srcrt srcthy srcthyn; do
  grep -qE "^phase-ms=(.*,)?$phase:[0-9]+(,|\$)" "$tmpdir/t.result" || {
    echo "T's record lacks phase $phase:" >&2; cat "$tmpdir/t.result" >&2; exit 1; }
done
grep -qE '^phase-ms=(.*,)?srcrtn:[1-9]' "$tmpdir/t.result" || {
  echo "T's record counts no runtime file:" >&2; cat "$tmpdir/t.result" >&2; exit 1; }

printf 'source-load timing is off by default, splits nested from self time, and rides the action spec\n'
