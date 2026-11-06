#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A frontier batch large enough to split goes to several analyser processes
# under -j. Each source's dependencies differ, so results merged under the
# wrong file would change the plan: a -j4 plan must match the -j1 plan, with
# the same dependency caches, and a failing process must fail planning as it
# does with one process.

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT

hol=$tmpdir/hol
fakebin=$tmpdir/fakebin
build_count=$tmpdir/build-count
: > "$build_count"
write_fake_hol "$hol"
hol_rev=$(init_git_repo "$hol")
write_fake_poly "$fakebin"
# The fake analyser reports as loads the words of a source's "(* loads: *)"
# line, logs how many files each process got, and fails on a source marked
# "(* analyser-fail *)".
cat > "$fakebin/polyc" <<'SH'
#!/usr/bin/env sh
set -eu
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ]
cat > "$out" <<'ANALYSER'
#!/usr/bin/env sh
set -eu
if [ "${1:-}" = --version ]; then
  printf 'holbuild-hol-analyser holbuild-hol-analyser-v2\n'
  exit 0
fi
request=
response=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request) request=$2; shift 2 ;;
    --response) response=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$request" ]
[ -n "$response" ]
files=$(grep -c '^file ' "$request")
# With HOLBUILD_TEST_ANALYSER_PEERS=N, a process given more than one file
# waits until N such processes have started, so the log shows whether they
# overlapped.
overlap=
if [ -n "${HOLBUILD_TEST_ANALYSER_PEERS:-}" ] && [ "$files" -gt 1 ]; then
  touch "$HOLBUILD_TEST_ANALYSER_LOG.peers.$$"
  overlap=" serial"
  for _ in $(seq 1 100); do
    if [ "$(ls "$HOLBUILD_TEST_ANALYSER_LOG".peers.* | wc -l)" -ge "$HOLBUILD_TEST_ANALYSER_PEERS" ]; then
      overlap=" overlapped"
      break
    fi
    sleep 0.1
  done
fi
printf '%s%s\n' "$files" "$overlap" >> "$HOLBUILD_TEST_ANALYSER_LOG"
{
  printf 'version 1\nok\n'
  while read -r keyword id path _rest; do
    [ "$keyword" = file ] || continue
    if grep -q 'analyser-fail' "$path"; then
      printf 'fake analyser failure\n' >&2
      exit 1
    fi
    printf 'begin-file %s\n' "$id"
    sed -n 's/^(\* loads: \(.*\) \*)$/\1/p' "$path" | tr ' ' '\n' |
      while read -r dep; do [ -z "$dep" ] || printf 'load %s\n' "$dep"; done
    printf 'end-file %s\n' "$id"
  done < "$request"
  printf 'end\n'
} > "$response"
ANALYSER
chmod +x "$out"
SH
chmod +x "$fakebin/polyc"

unset HOLDIR HOLBUILD_HOLDIR HOLBUILD_REMOTE_CACHE_URL
export HOLBUILD_CACHE=$tmpdir/cache
export HOLBUILD_POLY=$fakebin/poly
export HOLBUILD_POLYC=$fakebin/polyc
export HOLBUILD_TEST_BUILD_COUNT=$build_count

# Top loads T1..T40, one frontier of 40 sources; T21..T40 each load the
# theory 20 below them, and every source names its own dependencies.
write_project() {
  local project=$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "parallel-analyser-test"

[dependencies.hol]
git = "$hol"
rev = "$hol_rev"

[build]
members = ["src"]
TOML
  local loads=""
  for i in $(seq 1 40); do
    loads="$loads T${i}Theory"
    local own=""
    if [ "$i" -gt 20 ]; then own="(* loads: T$((i - 20))Theory *)"; fi
    cat > "$project/src/T${i}Script.sml" <<SML
$own
open HolKernel Parse boolLib bossLib;
val _ = new_theory "T$i";
val _ = export_theory();
SML
  done
  cat > "$project/src/TopScript.sml" <<SML
(* loads:$loads *)
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Top";
val _ = export_theory();
SML
}

plan() {
  local project=$1 jobs=$2 log=$3
  export HOLBUILD_TEST_ANALYSER_LOG=$log.analyser
  : > "$HOLBUILD_TEST_ANALYSER_LOG"
  (cd "$project" && HOLBUILD_TEST_ANALYSER_PEERS=${peers:-} \
     "$HOLBUILD_BIN" build --dry-run -j"$jobs" TopTheory) > "$log" 2> "$log.err"
}

write_project "$tmpdir/serial"
write_project "$tmpdir/parallel"
if ! plan "$tmpdir/serial" 1 "$tmpdir/serial.log"; then
  echo "planning with -j1 failed" >&2
  cat "$tmpdir/serial.log" "$tmpdir/serial.log.err" >&2
  exit 1
fi
if ! peers=4 plan "$tmpdir/parallel" 4 "$tmpdir/parallel.log"; then
  echo "planning with -j4 failed" >&2
  cat "$tmpdir/parallel.log" "$tmpdir/parallel.log.err" >&2
  exit 1
fi

# -j1 runs one process per frontier; -j4 splits the 40-source frontier.
if [ "$(sort -n "$tmpdir/serial.log.analyser" | tr '\n' ' ')" != "1 40 " ]; then
  echo "expected -j1 to analyse frontiers of 1 and 40 in one process each" >&2
  cat "$tmpdir/serial.log.analyser" >&2
  exit 1
fi
if [ "$(sort -n "$tmpdir/parallel.log.analyser" | tr '\n' ' ')" != "1 10 overlapped 10 overlapped 10 overlapped 10 overlapped " ]; then
  echo "expected -j4 to split the 40-source frontier over four concurrent processes" >&2
  cat "$tmpdir/parallel.log.analyser" >&2
  exit 1
fi

sed "s#$tmpdir/serial#PROJECT#g" "$tmpdir/serial.log" > "$tmpdir/serial.plan"
sed "s#$tmpdir/parallel#PROJECT#g" "$tmpdir/parallel.log" > "$tmpdir/parallel.plan"
if ! diff -u "$tmpdir/serial.plan" "$tmpdir/parallel.plan"; then
  echo "the -j4 plan differs from the -j1 plan" >&2
  exit 1
fi
if ! diff -r "$tmpdir/serial/.holbuild/obj" "$tmpdir/parallel/.holbuild/obj"; then
  echo "the -j4 dependency caches differ from the -j1 ones" >&2
  exit 1
fi
require_grep "load=T5Theory" "$tmpdir/parallel/.holbuild/obj/src/T25Script.uo.deps"

# A failing process fails planning with the error one process gives.
for kind in serial parallel; do
  rm -rf "$tmpdir/$kind/.holbuild"
  printf '(* analyser-fail *)\n' >> "$tmpdir/$kind/src/T33Script.sml"
done
if plan "$tmpdir/serial" 1 "$tmpdir/serial-fail.log"; then
  echo "planning with -j1 succeeded despite a failing analyser" >&2
  exit 1
fi
if plan "$tmpdir/parallel" 4 "$tmpdir/parallel-fail.log"; then
  echo "planning with -j4 succeeded despite a failing analyser" >&2
  exit 1
fi
require_grep "fake analyser failure" "$tmpdir/parallel-fail.log.err"
for out in log log.err; do
  if [ "$(grep -v 'fake analyser failure' "$tmpdir/serial-fail.$out")" != \
       "$(grep -v 'fake analyser failure' "$tmpdir/parallel-fail.$out")" ]; then
    echo "a failing -j4 analyser gives a different error from -j1" >&2
    diff -u "$tmpdir/serial-fail.$out" "$tmpdir/parallel-fail.$out" >&2 || true
    exit 1
  fi
done
require_grep "holbuild-hol-analyser failed" "$tmpdir/parallel-fail.log.err"
