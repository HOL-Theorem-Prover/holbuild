#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
holbuild_pid=""
holder_pid=""
cleanup() {
  if [[ -n "$holbuild_pid" ]]; then
    kill -KILL "$holbuild_pid" 2>/dev/null || true
  fi
  if [[ -n "$holder_pid" ]]; then
    kill "$holder_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

gib=$((1024 * 1024 * 1024))

# A meminfo with plenty available, except where the test exercises the
# MemAvailable check, so that the rest depends on the reservations alone, not
# on how much memory the test machine has free.
printf 'MemTotal:        67108864 kB\nMemAvailable:    67108864 kB\n' > "$tmpdir/plenty"
export HOLBUILD_TEST_MEMINFO=$tmpdir/plenty
# Likewise no cgroup limits, except where the test exercises them.
export HOLBUILD_TEST_CGROUP=
events=$tmpdir/events.log
: > "$events"

# make_project NAME SECONDS THEORY... writes a project whose theories log
# START/END around a sleep, so the test can see which children overlapped.
make_project() {
  local name=$1 seconds=$2
  shift 2
  local project=$tmpdir/$name theory
  mkdir -p "$project/src"
  {
    write_schema2_prelude
    cat <<TOML

[project]
name = "$name"

[build]
members = ["src"]
TOML
  } > "$project/holproject.toml"
  for theory in "$@"; do
    cat > "$project/src/${theory}Script.sml" <<SML
open HolKernel Parse boolLib bossLib;
fun append msg =
  let val out = TextIO.openAppend "$events"
  in TextIO.output(out, msg ^ "\\n"); TextIO.closeOut out end;
val _ = append "START $theory";
val _ = OS.Process.system "ls -l /proc/self/fd 2>/dev/null | grep -q lease- && touch $tmpdir/$theory.held";
val _ = OS.Process.system "sleep $seconds";
val _ = append "END $theory";
val _ = new_theory "$theory";
val _ = export_theory();
SML
  done
}

# Fails if any START sees a set of running children that the predicate
# rejects.
check_overlaps() {
  local predicate=$1
  awk -v predicate="$predicate" '
    function running_set(    t, s) { s = ""; for (t in running) s = s " " t; return s " " }
    /^START / { running[$2] = 1; n++; set = running_set()
                if (predicate == "single" && n > 1) bad = bad "\n" set
                if (predicate == "no-b-with-a" && set ~ / B[0-9]* / && set ~ / A[0-9]* /) bad = bad "\n" set }
    /^END / { delete running[$2]; n-- }
    END { if (bad != "") { print "over-admitted:" bad > "/dev/stderr"; exit 1 } }
  ' "$events" || { cat "$events" >&2; exit 1; }
}

# holbuild_in DIR ARGS... runs holbuild from DIR, where its .holbuild state lives.
holbuild_in() {
  (cd "$1" && shift && exec "$HOLBUILD_BIN" "$@")
}

# Leases outlive their child by the parent watcher's few hundred
# milliseconds, and are removed by the next scan; none may still be held.
require_no_live_leases() {
  local dir=$1 lease
  for _ in $(seq 1 50); do
    lease=""
    for lease in "$dir"/lease-*; do
      [[ -e "$lease" ]] || { lease=""; break; }
      flock -n "$lease" true || break
      lease=""
    done
    [[ -z "$lease" ]] && return 0
    sleep 0.1
  done
  echo "lease still held: $lease" >&2
  exit 1
}

# --machine-max-mem only means something for a shared directory.
if "$HOLBUILD_BIN" --machine-max-mem 1024 build > "$tmpdir/no-dir.out" 2>&1; then
  echo "--machine-max-mem without --cooperate-dir succeeded" >&2
  exit 1
fi
require_grep 'machine-max-mem requires --cooperate-dir' "$tmpdir/no-dir.out"

if "$HOLBUILD_BIN" --child-charge 1024 build > "$tmpdir/no-dir-charge.out" 2>&1; then
  echo "--child-charge without --cooperate-dir succeeded" >&2
  exit 1
fi
require_grep 'child-charge requires --cooperate-dir' "$tmpdir/no-dir-charge.out"
if "$HOLBUILD_BIN" --cooperate-dir= --max-heap 1024 build > "$tmpdir/empty-dir.out" 2>&1; then
  echo "an empty --cooperate-dir succeeded" >&2
  exit 1
fi
require_grep 'cooperate-dir requires DIR' "$tmpdir/empty-dir.out"

# Two processes, a budget for one child: children never overlap, and the
# second waits visibly.  No --max-heap is needed.
coop=$tmpdir/coop
make_project p1 2 P1a P1b
make_project p2 2 P2a P2b
holbuild_in "$tmpdir/p1" --cooperate-dir "$coop" --machine-max-mem 3072 --child-charge 2048 -j2 \
  build --skip-checkpoints --skip-proof-steps > "$tmpdir/p1.out" 2>&1 &
p1_pid=$!
holbuild_in "$tmpdir/p2" --cooperate-dir "$coop" --machine-max-mem 3072 --child-charge 2048 -j2 \
  build --skip-checkpoints --skip-proof-steps > "$tmpdir/p2.out" 2>&1 &
p2_pid=$!
wait "$p1_pid" || { cat "$tmpdir/p1.out" >&2; exit 1; }
wait "$p2_pid" || { cat "$tmpdir/p2.out" >&2; exit 1; }
check_overlaps single
cat "$tmpdir/p1.out" "$tmpdir/p2.out" > "$tmpdir/both.out"
require_grep 'waiting for machine memory: needs 2048 MiB, 2048 MiB of 3072 MiB reserved' "$tmpdir/both.out"
[[ "$(cat "$coop/budget")" == "$((3 * gib))" ]] || { echo "unexpected budget: $(cat "$coop/budget")" >&2; exit 1; }
require_no_live_leases "$coop"
if [[ -d /proc/self/fd ]]; then
  require_file "$tmpdir/P1a.held"
fi

# A different explicit budget conflicts with the recorded one.
if holbuild_in "$tmpdir/p1" --cooperate-dir "$coop" --machine-max-mem 4096 --max-heap 1024 \
     build --force P1aTheory > "$tmpdir/conflict.out" 2>&1; then
  echo "conflicting --machine-max-mem succeeded" >&2
  exit 1
fi
require_grep '^holbuild: --machine-max-mem 4096 (4294967296 bytes) conflicts with 3221225472 bytes in' "$tmpdir/conflict.out"

# The default budget leaves a quarter of MemTotal out, at most 30 GiB: 256 GiB
# gives 226 GiB.  It is computed afresh, not written to DIR/budget, so the
# same DIR on 64 GiB then gives 48 GiB.
printf 'MemTotal:        268435456 kB\nMemAvailable:    268435456 kB\n' > "$tmpdir/large"
if HOLBUILD_TEST_MEMINFO=$tmpdir/large holbuild_in "$tmpdir/p1" --cooperate-dir "$tmpdir/large-coop" \
     --child-charge $((240 * 1024)) build --force P1aTheory > "$tmpdir/large.out" 2>&1; then
  echo "charge above the default budget succeeded" >&2
  exit 1
fi
require_grep "exceeds the machine budget of $((226 * 1024)) MiB" "$tmpdir/large.out"
require_no_file "$tmpdir/large-coop/budget"
if holbuild_in "$tmpdir/p1" --cooperate-dir "$tmpdir/large-coop" \
     --child-charge $((240 * 1024)) build --force P1aTheory > "$tmpdir/resized.out" 2>&1; then
  echo "charge above the default budget succeeded" >&2
  exit 1
fi
require_grep "exceeds the machine budget of $((48 * 1024)) MiB" "$tmpdir/resized.out"

# Heterogeneous charges in a 4 GiB budget: two 2 GiB children fit together, a
# 3 GiB child fits with neither.  The charge is --child-charge, not --max-heap,
# which alone exceeds the budget.
: > "$events"
hetero=$tmpdir/hetero
make_project pa 3 A1 A2
make_project pb 3 B1
holbuild_in "$tmpdir/pa" --cooperate-dir "$hetero" --machine-max-mem 4096 --max-heap 8192 --child-charge 2048 -j2 \
  build --skip-checkpoints --skip-proof-steps > "$tmpdir/pa.out" 2>&1 &
pa_pid=$!
holbuild_in "$tmpdir/pb" --cooperate-dir "$hetero" --machine-max-mem 4096 --child-charge 3072 \
  build --skip-checkpoints --skip-proof-steps > "$tmpdir/pb.out" 2>&1 &
pb_pid=$!
wait "$pa_pid" || { cat "$tmpdir/pa.out" >&2; exit 1; }
wait "$pb_pid" || { cat "$tmpdir/pb.out" >&2; exit 1; }
check_overlaps no-b-with-a
awk '/^START A/ { n++; if (n > max) max = n } /^END A/ { n-- } END { exit !(max == 2) }' "$events" || {
  echo "the two 2 GiB children never ran together" >&2
  cat "$events" >&2
  exit 1
}
require_no_live_leases "$hetero"

# A child larger than the whole budget fails at once instead of waiting.
make_project big 0 Big
if (cd "$tmpdir/big" && timeout 60 "$HOLBUILD_BIN" --cooperate-dir "$hetero" --child-charge 8192 build) \
     > "$tmpdir/big.out" 2>&1; then
  echo "reservation larger than the budget succeeded" >&2
  exit 1
fi
require_grep 'reservation of 8192 MiB .* exceeds the machine budget of 4096 MiB' "$tmpdir/big.out"
# The default charge is --max-heap, but at most 3072 MiB.
if (cd "$tmpdir/big" && timeout 60 "$HOLBUILD_BIN" --cooperate-dir "$tmpdir/small" --machine-max-mem 2048 \
      --max-heap 8192 build) > "$tmpdir/capped.out" 2>&1; then
  echo "default charge larger than the budget succeeded" >&2
  exit 1
fi
require_grep 'reservation of 3072 MiB .* exceeds the machine budget of 2048 MiB' "$tmpdir/capped.out"

# Where MemAvailable can't be read, the default charge is --max-heap plus
# 1 GiB, and one of --max-heap or --child-charge is required.
if (cd "$tmpdir/big" && HOLBUILD_TEST_MEMINFO=$tmpdir/no-meminfo timeout 60 "$HOLBUILD_BIN" \
      --cooperate-dir "$tmpdir/small" --max-heap 1536 build) > "$tmpdir/fallback.out" 2>&1; then
  echo "fallback charge larger than the budget succeeded" >&2
  exit 1
fi
require_grep 'reservation of 2560 MiB .* exceeds the machine budget of 2048 MiB' "$tmpdir/fallback.out"
if (cd "$tmpdir/big" && HOLBUILD_TEST_MEMINFO=$tmpdir/no-meminfo timeout 60 "$HOLBUILD_BIN" \
      --cooperate-dir "$tmpdir/small" build) > "$tmpdir/fallback-none.out" 2>&1; then
  echo "--cooperate-dir without MemAvailable, --max-heap or --child-charge succeeded" >&2
  exit 1
fi
require_grep 'requires --max-heap MB or --child-charge MB where MemAvailable cannot be read' "$tmpdir/fallback-none.out"
if (cd "$tmpdir/big" && HOLBUILD_TEST_MEMINFO=$tmpdir/no-meminfo timeout 60 "$HOLBUILD_BIN" \
      --cooperate-dir "$tmpdir/small" --child-charge 4096 build) > "$tmpdir/fallback-charge.out" 2>&1; then
  echo "explicit charge larger than the budget succeeded without MemAvailable" >&2
  exit 1
fi
require_grep 'reservation of 4096 MiB .* exceeds the machine budget of 2048 MiB' "$tmpdir/fallback-charge.out"

# With MemTotal 8 GiB, MemAvailable must cover the charge plus 2 GiB, even
# when the reservations fit, but only while some child holds a reservation:
# alone, Live starts with 2 GiB available.  The charge defaults to --max-heap
# below 3 GiB.
: > "$events"
write_meminfo() {
  printf 'MemTotal:        8388608 kB\nMemFree:          1 kB\nMemAvailable:    %s kB\n' "$1" \
    > "$tmpdir/meminfo.new"
  mv "$tmpdir/meminfo.new" "$tmpdir/meminfo"
}
write_meminfo $((2048 * 1024))
make_project live 0 Live
(cd "$tmpdir/live" && HOLBUILD_TEST_MEMINFO=$tmpdir/meminfo timeout 60 "$HOLBUILD_BIN" \
  --cooperate-dir "$tmpdir/live-coop" --machine-max-mem 4096 --max-heap 1024 \
  build --skip-checkpoints --skip-proof-steps) > "$tmpdir/live-alone.out" 2>&1 || {
  echo "a child with no reservation held waited on MemAvailable" >&2
  cat "$tmpdir/live-alone.out" >&2
  exit 1
}
require_grep '^START Live' "$events"

# While Hold's 2 GiB child is starting, its charge counts against
# MemAvailable: 4 GiB available would cover Live2's 1 GiB plus 2 GiB on its
# own, but not after the 2 GiB still to come.
: > "$events"
make_project hold 15 Hold
holbuild_in "$tmpdir/hold" --cooperate-dir "$tmpdir/live-coop" --child-charge 2048 \
  build --skip-checkpoints --skip-proof-steps > "$tmpdir/hold.out" 2>&1 &
hold_pid=$!
for _ in $(seq 1 600); do
  grep -q '^START Hold' "$events" && break
  sleep 0.1
done
grep -q '^START Hold' "$events" || { echo "Hold did not start" >&2; cat "$tmpdir/hold.out" >&2; exit 1; }
write_meminfo $((4096 * 1024))
make_project live2 0 Live2
(cd "$tmpdir/live2" && HOLBUILD_TEST_MEMINFO=$tmpdir/meminfo exec "$HOLBUILD_BIN" \
  --cooperate-dir "$tmpdir/live-coop" --max-heap 1024 \
  build --skip-checkpoints --skip-proof-steps) > "$tmpdir/live.out" 2>&1 &
holbuild_pid=$!
for _ in $(seq 1 600); do
  grep -q 'waiting for machine memory' "$tmpdir/live.out" && break
  sleep 0.1
done
require_grep 'waiting for machine memory: needs 1024 MiB, MemAvailable is 4096 MiB less 2048 MiB for children starting, below the charge plus 2048 MiB kept free' "$tmpdir/live.out"
sleep 2
if grep -q '^START Live2' "$events"; then
  echo "child started while MemAvailable was short" >&2
  exit 1
fi
write_meminfo $((5120 * 1024))
wait "$holbuild_pid" || { cat "$tmpdir/live.out" >&2; exit 1; }
holbuild_pid=""
require_grep '^START Live2' "$events"
if sed -n '/^START Live2/q;p' "$events" | grep -q '^END Hold'; then
  echo "Live2 started only after Hold ended" >&2
  cat "$events" >&2
  exit 1
fi
wait "$hold_pid" || { cat "$tmpdir/hold.out" >&2; exit 1; }

# A budget above the default lowers the margin to what it leaves out of
# MemTotal: with 7 GiB of 8, Live3's 1 GiB plus 1 GiB fits in the 4 GiB
# available less Hold2's 2 GiB still starting, where the reserve would be 2 GiB.
: > "$events"
make_project hold2 10 Hold2
holbuild_in "$tmpdir/hold2" --cooperate-dir "$tmpdir/high-coop" --machine-max-mem 7168 \
  --child-charge 2048 build --skip-checkpoints --skip-proof-steps > "$tmpdir/hold2.out" 2>&1 &
hold_pid=$!
for _ in $(seq 1 600); do
  grep -q '^START Hold2' "$events" && break
  sleep 0.1
done
grep -q '^START Hold2' "$events" || { echo "Hold2 did not start" >&2; cat "$tmpdir/hold2.out" >&2; exit 1; }
write_meminfo $((4096 * 1024))
make_project live3 0 Live3
(cd "$tmpdir/live3" && HOLBUILD_TEST_MEMINFO=$tmpdir/meminfo timeout 60 "$HOLBUILD_BIN" \
  --cooperate-dir "$tmpdir/high-coop" --max-heap 1024 \
  build --skip-checkpoints --skip-proof-steps) > "$tmpdir/live3.out" 2>&1 || {
  cat "$tmpdir/live3.out" >&2
  exit 1
}
require_grep '^START Live3' "$events"
if sed -n '/^START Live3/q;p' "$events" | grep -q '^END Hold2'; then
  echo "Live3 waited for Hold2 under a budget above the default" >&2
  cat "$events" >&2
  exit 1
fi
wait "$hold_pid" || { cat "$tmpdir/hold2.out" >&2; exit 1; }

# A cgroup limit binds whether or not DIR holds a reservation: a stand-in
# step group (no memory files: its parent doesn't enable the controller for
# it) in a job group (no limit of its own) inside a scope limited to 8 GiB,
# with 7.5 GiB used, holds back a 1 GiB child even alone.  The scope's inactive
# page cache counts as free: once 1 GiB of it shows up, the child starts.
cgroup=$tmpdir/cgroup
mkdir -p "$cgroup/scope/job/step"
write_group() {
  local dir=$1 max=$2 current=$3 inactive=$4
  printf '%s\n' "$max" > "$dir/memory.max.new"
  printf '%s\n' "$current" > "$dir/memory.current.new"
  printf 'anon %s\nfile %s\ninactive_file %s\n' "$current" "$inactive" "$inactive" > "$dir/memory.stat.new"
  mv "$dir/memory.max.new" "$dir/memory.max"
  mv "$dir/memory.current.new" "$dir/memory.current"
  mv "$dir/memory.stat.new" "$dir/memory.stat"
}
write_group "$cgroup/scope/job" max $((7 * gib)) 0
write_group "$cgroup/scope" $((8 * gib)) $((15 * gib / 2)) 0
: > "$events"
make_project capped 0 Capped
(cd "$tmpdir/capped" && HOLBUILD_TEST_CGROUP=$cgroup/scope/job/step exec "$HOLBUILD_BIN" \
  --cooperate-dir "$tmpdir/cgroup-coop" --child-charge 1024 \
  build --skip-checkpoints --skip-proof-steps) > "$tmpdir/capped.out" 2>&1 &
holbuild_pid=$!
for _ in $(seq 1 600); do
  grep -q 'waiting for machine memory' "$tmpdir/capped.out" && break
  sleep 0.1
done
require_grep 'waiting for machine memory: needs 1024 MiB, cgroup memory headroom is 512 MiB, below the charge' "$tmpdir/capped.out"
sleep 2
if grep -q '^START Capped' "$events"; then
  echo "child started past the cgroup limit with no reservation held" >&2
  exit 1
fi
write_group "$cgroup/scope" $((8 * gib)) $((15 * gib / 2)) $((gib))
wait "$holbuild_pid" || { cat "$tmpdir/capped.out" >&2; exit 1; }
holbuild_pid=""
require_grep '^END Capped' "$events"
require_no_live_leases "$tmpdir/cgroup-coop"

# The HOL session of run and check waits the same way.
printf 'val _ = TextIO.print "SESSION RAN\\n";\n' > "$tmpdir/capped/probe.sml"
for command in "run probe.sml" "check CappedTheory"; do
  out=$tmpdir/session-${command%% *}.out
  write_group "$cgroup/scope" $((8 * gib)) $((15 * gib / 2)) 0
  # shellcheck disable=SC2086
  (cd "$tmpdir/capped" && HOLBUILD_TEST_CGROUP=$cgroup/scope/job/step exec "$HOLBUILD_BIN" \
    --cooperate-dir "$tmpdir/cgroup-coop" --child-charge 1024 $command) > "$out" 2>&1 &
  holbuild_pid=$!
  for _ in $(seq 1 600); do
    grep -q 'waiting for machine memory' "$out" && break
    sleep 0.1
  done
  require_grep 'waiting for machine memory: needs 1024 MiB, cgroup memory headroom is 512 MiB' "$out"
  sleep 2
  if ! kill -0 "$holbuild_pid" 2>/dev/null; then
    echo "holbuild $command did not wait for the cgroup's headroom" >&2
    cat "$out" >&2
    exit 1
  fi
  write_group "$cgroup/scope" $((8 * gib)) $((15 * gib / 2)) $((gib))
  # check reports the theory's kernel bypasses (its OS.Process.system calls)
  # as findings and exits 1, so its session is known to have run by them.
  wait "$holbuild_pid" || true
  holbuild_pid=""
done
require_grep 'SESSION RAN' "$tmpdir/session-run.out"
require_grep 'CappedTheory: 2 findings' "$tmpdir/session-check.out"
require_no_live_leases "$tmpdir/cgroup-coop"

# With no limit anywhere ("max"), however much the groups use, a child starts.
write_group "$cgroup/scope" max $((1024 * gib)) 0
: > "$events"
(cd "$tmpdir/capped" && HOLBUILD_TEST_CGROUP=$cgroup/scope/job/step timeout 60 "$HOLBUILD_BIN" \
  --cooperate-dir "$tmpdir/cgroup-coop" --child-charge 1024 \
  build --force --skip-checkpoints --skip-proof-steps) > "$tmpdir/uncapped.out" 2>&1 || {
  echo "a child waited with no cgroup limit" >&2
  cat "$tmpdir/uncapped.out" >&2
  exit 1
}
require_grep '^END Capped' "$events"

# A child larger than the least limit fails at once instead of waiting.
write_group "$cgroup/scope/job" $((2 * gib)) 0 0
if (cd "$tmpdir/capped" && HOLBUILD_TEST_CGROUP=$cgroup/scope/job/step timeout 60 "$HOLBUILD_BIN" \
      --cooperate-dir "$tmpdir/cgroup-coop" --child-charge 3072 build --force) > "$tmpdir/over-limit.out" 2>&1; then
  echo "reservation larger than the cgroup limit succeeded" >&2
  exit 1
fi
require_grep 'reservation of 3072 MiB .* exceeds the cgroup memory limit of 2048 MiB' "$tmpdir/over-limit.out"

# With --fail-fast, a worker still waiting for memory gives up instead of
# starting its child once the failed child's reservation frees up.  Fail and
# Q compete for a one-child budget, and Other waits on Q, so some worker is
# waiting whichever starts first.  Pipelining is off: a failed pipelined
# build runs again without it.
: > "$events"
make_project failing 0 Q
cat > "$tmpdir/failing/src/FailScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
fun append msg =
  let val out = TextIO.openAppend "$events"
  in TextIO.output(out, msg ^ "\\n"); TextIO.closeOut out end;
val _ = append "START Fail";
val _ = OS.Process.system "sleep 4";
val _ = append "FAILED Fail";
val _ = raise Fail "planned failure";
SML
cat > "$tmpdir/failing/src/OtherScript.sml" <<SML
open HolKernel Parse boolLib bossLib QTheory;
val out = TextIO.openAppend "$events";
val _ = (TextIO.output (out, "START Other\\n"); TextIO.closeOut out);
val _ = new_theory "Other";
val _ = export_theory();
SML
if HOLBUILD_PIPELINE=off holbuild_in "$tmpdir/failing" --cooperate-dir "$tmpdir/failing-coop" --machine-max-mem 3072 -j2 \
     build --fail-fast --skip-checkpoints --skip-proof-steps > "$tmpdir/failing.out" 2>&1; then
  echo "build with a failing theory succeeded" >&2
  exit 1
fi
require_grep '^FAILED Fail' "$events"
if sed -n '/^FAILED Fail/,$p' "$events" | grep -q '^START'; then
  echo "a waiting child started after the build failed" >&2
  cat "$events" >&2
  exit 1
fi
require_no_live_leases "$tmpdir/failing-coop"

# A killed parent's reservation is released once its child group is gone,
# without any timeout, and the next scan removes the stale lease.  The budget
# fits one child at the default 3 GiB charge, so Next running at all shows that
# Slow's group is gone.
: > "$events"
stale=$tmpdir/stale
make_project slow 30 Slow
make_project next 0 Next
(cd "$tmpdir/slow" && exec "$HOLBUILD_BIN" --cooperate-dir "$stale" --machine-max-mem 3072 \
  build --skip-checkpoints --skip-proof-steps) > "$tmpdir/slow.out" 2>&1 &
holbuild_pid=$!
for _ in $(seq 1 600); do
  grep -q '^START Slow' "$events" && break
  sleep 0.1
done
grep -q '^START Slow' "$events" || { echo "slow child did not start" >&2; cat "$tmpdir/slow.out" >&2; exit 1; }
kill_pid=$holbuild_pid
if ps -o args= -p "$holbuild_pid" 2>/dev/null | grep -q 'holbuild-wrapper'; then
  child_pid=$(pgrep -P "$holbuild_pid" | head -n1 || true)
  [[ -n "$child_pid" ]] && kill_pid=$child_pid
fi
kill -KILL "$kill_pid"
wait "$holbuild_pid" 2>/dev/null || true
holbuild_pid=""
killed_leases=$(compgen -G "$stale/lease-*" || true)
[[ -n "$killed_leases" ]] || { echo "killed parent left no lease to reclaim" >&2; exit 1; }
start_seconds=$SECONDS
(cd "$tmpdir/next" && timeout 25 "$HOLBUILD_BIN" --cooperate-dir "$stale" \
  build --skip-checkpoints --skip-proof-steps) > "$tmpdir/next.out" 2>&1 || {
  echo "build after a killed parent did not get its reservation within 25 s" >&2
  cat "$tmpdir/next.out" >&2
  exit 1
}
require_grep '^END Next' "$events"
for lease in $killed_leases; do
  require_no_file "$lease"
done
require_no_live_leases "$stale"
echo "reclaimed after $((SECONDS - start_seconds)) s"

# A held DIR/lock makes a child wait, with a report every 30 s, for as long as
# it is held: past the minute after which holbuild used to give up.  The
# holder releases it once the build has reported a wait of a minute or more.
: > "$events"
busy=$tmpdir/busy
mkdir -p "$busy"
: > "$busy/lock"
make_project locked 0 Locked
flock "$busy/lock" bash -c '
  for _ in $(seq 1 300); do
    grep -q "waiting [6-9][0-9]s for machine-memory lock" "$1" 2>/dev/null && exit 0
    sleep 1
  done' _ "$tmpdir/locked.out" &
holder_pid=$!
for _ in $(seq 1 100); do
  flock -n "$busy/lock" true || break
  sleep 0.1
done
(cd "$tmpdir/locked" && timeout 400 "$HOLBUILD_BIN" --cooperate-dir "$busy" --machine-max-mem 3072 \
  build --skip-checkpoints --skip-proof-steps) > "$tmpdir/locked.out" 2>&1 || {
  echo "build waiting on a held machine-memory lock failed" >&2
  cat "$tmpdir/locked.out" >&2
  exit 1
}
wait "$holder_pid"
holder_pid=""
require_grep "waiting [3-5][0-9]s for machine-memory lock $busy/lock" "$tmpdir/locked.out"
require_grep "waiting [6-9][0-9]s for machine-memory lock $busy/lock" "$tmpdir/locked.out"
require_grep '^END Locked' "$events"

# A lock held past HOLBUILD_COOPERATE_LOCK_TIMEOUT fails the build without
# starting the child; a timeout that isn't a whole number is an error.
: > "$events"
make_project timeout 0 Timeout
flock "$busy/lock" bash -c '
  for _ in $(seq 1 600); do
    [[ -e "$1" ]] && exit 0
    sleep 0.1
  done' _ "$tmpdir/release" &
holder_pid=$!
for _ in $(seq 1 100); do
  flock -n "$busy/lock" true || break
  sleep 0.1
done
if (cd "$tmpdir/timeout" && HOLBUILD_COOPERATE_LOCK_TIMEOUT=2 timeout 60 "$HOLBUILD_BIN" \
      --cooperate-dir "$busy" --machine-max-mem 3072 build --skip-checkpoints --skip-proof-steps) \
     > "$tmpdir/timeout.out" 2>&1; then
  echo "build succeeded while the machine-memory lock was held past its timeout" >&2
  exit 1
fi
touch "$tmpdir/release"
wait "$holder_pid"
holder_pid=""
require_grep "could not lock $busy/lock for 2s: another process holds it" "$tmpdir/timeout.out"
if grep -q '^START Timeout' "$events"; then
  echo "a child started while the machine-memory lock was held" >&2
  exit 1
fi
if (cd "$tmpdir/timeout" && HOLBUILD_COOPERATE_LOCK_TIMEOUT=-1 timeout 60 "$HOLBUILD_BIN" \
      --cooperate-dir "$busy" --machine-max-mem 3072 build --skip-checkpoints --skip-proof-steps) \
     > "$tmpdir/bad-timeout.out" 2>&1; then
  echo "a negative HOLBUILD_COOPERATE_LOCK_TIMEOUT was accepted" >&2
  exit 1
fi
require_grep 'HOLBUILD_COOPERATE_LOCK_TIMEOUT must be a whole number of seconds' "$tmpdir/bad-timeout.out"
