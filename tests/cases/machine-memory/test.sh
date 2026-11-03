#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
holbuild_pid=""
cleanup() {
  if [[ -n "$holbuild_pid" ]]; then
    kill -KILL "$holbuild_pid" 2>/dev/null || true
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
if "$HOLBUILD_BIN" --machine-max-cpus 1 build > "$tmpdir/no-dir-cpus.out" 2>&1; then
  echo "--machine-max-cpus without --cooperate-dir succeeded" >&2
  exit 1
fi
require_grep 'machine-max-cpus requires --cooperate-dir' "$tmpdir/no-dir-cpus.out"

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
# Without --machine-max-cpus the CPU budget is the live processor count, never
# written down.
require_no_file "$coop/cpus"
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

# Two processes, memory for many children but a CPU budget of one: children
# never overlap, and the second waits visibly for a CPU slot.
: > "$events"
cpus=$tmpdir/cpus
make_project c1 2 C1a C1b
make_project c2 2 C2a C2b
holbuild_in "$tmpdir/c1" --cooperate-dir "$cpus" --machine-max-cpus 1 --child-charge 1024 -j2 \
  build --skip-checkpoints --skip-proof-steps > "$tmpdir/c1.out" 2>&1 &
c1_pid=$!
holbuild_in "$tmpdir/c2" --cooperate-dir "$cpus" --machine-max-cpus 1 --child-charge 1024 -j2 \
  build --skip-checkpoints --skip-proof-steps > "$tmpdir/c2.out" 2>&1 &
c2_pid=$!
wait "$c1_pid" || { cat "$tmpdir/c1.out" >&2; exit 1; }
wait "$c2_pid" || { cat "$tmpdir/c2.out" >&2; exit 1; }
check_overlaps single
cat "$tmpdir/c1.out" "$tmpdir/c2.out" > "$tmpdir/cpus.out"
require_grep 'waiting for machine memory: needs 1024 MiB, 1 of 1 CPU slots in use in' "$tmpdir/cpus.out"
[[ "$(cat "$cpus/cpus")" == 1 ]] || { echo "unexpected CPU budget: $(cat "$cpus/cpus")" >&2; exit 1; }
require_no_live_leases "$cpus"
if holbuild_in "$tmpdir/c1" --cooperate-dir "$cpus" --machine-max-cpus 2 --child-charge 1024 \
     build --force C1aTheory > "$tmpdir/cpus-conflict.out" 2>&1; then
  echo "conflicting --machine-max-cpus succeeded" >&2
  exit 1
fi
require_grep '^holbuild: --machine-max-cpus 2 conflicts with 1 in' "$tmpdir/cpus-conflict.out"

# A CPU budget of zero would admit nothing: it fails at once.
zero_cpus=$tmpdir/zero-cpus
mkdir -p "$zero_cpus"
echo 0 > "$zero_cpus/cpus"
if (cd "$tmpdir/c1" && timeout 60 "$HOLBUILD_BIN" --cooperate-dir "$zero_cpus" --child-charge 1024 \
      build --force C1aTheory) > "$tmpdir/zero-cpus.out" 2>&1; then
  echo "a zero CPU budget succeeded" >&2
  exit 1
fi
require_grep 'zero-cpus/cpus: the processor count must be positive' "$tmpdir/zero-cpus.out"

# The HOL process of run reserves too.  While a build holds the only CPU slot,
# run waits, and says so on stderr, out of the script's output.
if [[ -d /proc/self/fd ]]; then
  cat > "$tmpdir/held.sml" <<SML
val _ = OS.Process.system "ls -l /proc/self/fd 2>/dev/null | grep -q lease- && touch $tmpdir/run.held";
SML
  : > "$events"
  make_project c3 4 C3a
  holbuild_in "$tmpdir/c3" --cooperate-dir "$cpus" --child-charge 1024 \
    build --skip-checkpoints --skip-proof-steps > "$tmpdir/c3.out" 2>&1 &
  c3_pid=$!
  for _ in $(seq 1 600); do
    grep -q '^START C3a' "$events" && break
    sleep 0.1
  done
  require_grep '^START C3a' "$events"
  holbuild_in "$tmpdir/c1" --cooperate-dir "$cpus" --child-charge 1024 run "$tmpdir/held.sml" \
    > "$tmpdir/run.out" 2> "$tmpdir/run.err" || {
    cat "$tmpdir/run.out" "$tmpdir/run.err" >&2
    exit 1
  }
  wait "$c3_pid" || { cat "$tmpdir/c3.out" >&2; exit 1; }
  require_file "$tmpdir/run.held"
  require_grep 'waiting for machine memory: needs 1024 MiB, 1 of 1 CPU slots in use in' "$tmpdir/run.err"
  if grep -q 'waiting for machine memory' "$tmpdir/run.out"; then
    echo "run's wait notice went to stdout" >&2
    exit 1
  fi
  require_no_live_leases "$cpus"
fi

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

# When a node fails, a worker still waiting for memory gives up instead of
# starting its child once the failed child's reservation frees up.  Fail and
# Q compete for a one-child budget, and Other waits on Q, so some worker is
# waiting whichever starts first.
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
if holbuild_in "$tmpdir/failing" --cooperate-dir "$tmpdir/failing-coop" --machine-max-mem 3072 -j2 \
     build --skip-checkpoints --skip-proof-steps > "$tmpdir/failing.out" 2>&1; then
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
