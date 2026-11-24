#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# exec-action --park --probe-preload answers park-probe requests in one HOL
# process that used the preload once and stands after the failing theorem's
# failure, its failing step's input goals at hand.  It moves on when a
# check fails in a later theorem, and is started again after a probe runs
# out of time.

tmpdir=$(make_temp_dir)
server_pid=""
park_pid=""
cleanup() {
  for pid in "$park_pid" "$server_pid"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "park"

[build]
members = ["src"]
TOML
# write_a STEP [LATER]: target's second conjunct gets STEP, later_thm LATER.
write_a() {
  cat > "$project/src/AScript.sml" <<SML
Theory A
Ancestors bool

Theorem first_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem target:
  T /\\ ~F
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >> $1
QED

Theorem later_thm:
  ~(F /\\ T)
Proof
  ${2:-REWRITE_TAC []}
QED
SML
}

field() { awk -v want="$2" -v col="$3" '$1 == "action" && $5 == want { print $col }' "$1"; }

# The preload counts its runs and leaves the process id where the test finds
# it; each probe counts the probes the process has run.
cat > "$tmpdir/preload.sml" <<'SML'
val probe_preloads = ref 0;
val probe_hits = ref 0;
val _ = probe_preloads := !probe_preloads + 1;
val _ = let val out = TextIO.openOut "probe.pid"
        in TextIO.output (out, LargeInt.toString (SysWord.toLargeInt (Posix.Process.pidToWord (Posix.ProcEnv.getpid ()))));
           TextIO.closeOut out end;
SML
cat > "$tmpdir/goal.sml" <<'SML'
val _ = Feedback.set_trace "Unicode" 0;
val _ = probe_hits := !probe_hits + 1;
val _ = print ("goal: " ^ Parse.term_to_string (#2 (hd (HolbuildProofRuntime.failed_goals ()))) ^ "\n");
val _ = print ("hits: " ^ Int.toString (!probe_hits) ^ " preloads: " ^ Int.toString (!probe_preloads) ^ "\n");
SML
cat > "$tmpdir/boom.sml" <<'SML'
val _ = raise Fail "probe boom";
SML
cat > "$tmpdir/spin.sml" <<'SML'
val _ = let fun spin n = spin (n + 1) in spin 0 end;
SML

write_a 'FAIL_TAC "first failure"'

socket=$tmpdir/park.sock
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload ATheory) > "$tmpdir/batch.txt"
spec=$(field "$tmpdir/batch.txt" park:ATheory 4)
[[ -n "$spec" ]] || { cat "$tmpdir/batch.txt" >&2; exit 1; }
link_hol_toolchain_cache "$tmpdir/park"
HOLBUILD_CACHE=$tmpdir/park "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$spec" \
  --share-heaps --cache-limit-gb 1000 --park "$socket" --probe-preload "$tmpdir/preload.sml" > "$tmpdir/park.log" 2>&1 &
park_pid=$!
for _ in $(seq 600); do
  grep -q "park: listening on" "$tmpdir/park.log" && break
  kill -0 "$park_pid" 2>/dev/null || { echo "the park server stopped" >&2; cat "$tmpdir/park.log" >&2; exit 1; }
  sleep 0.5
done
grep -q "park: listening on" "$tmpdir/park.log" || { echo "the park server never listened" >&2; cat "$tmpdir/park.log" >&2; exit 1; }

# probe NAME FILE SECONDS STATUS: park-probe of FILE must exit with STATUS.
probe() {
  local status=0
  "$HOLBUILD_BIN" park-probe "$socket" "$spec" "$3" "$2" > "$tmpdir/$1.out" 2> "$tmpdir/$1.err" || status=$?
  [[ "$status" == "$4" ]] || {
    echo "park-probe $1: wanted exit $4, got $status" >&2
    cat "$tmpdir/$1.out" "$tmpdir/$1.err" "$tmpdir/park.log" >&2
    find "$tmpdir/park" -name sibling.log -exec cat {} + >&2 || true
    exit 1
  }
}

probe first "$tmpdir/goal.sml" 120 0
require_grep "^goal: ~F$" "$tmpdir/first.out"
require_grep "^hits: 1 preloads: 1$" "$tmpdir/first.out"
probe second "$tmpdir/goal.sml" 120 0
require_grep "^hits: 2 preloads: 1$" "$tmpdir/second.out"
# A probe that raises answers error; the process stays.
probe boom "$tmpdir/boom.sml" 120 1
require_grep "probe boom" "$tmpdir/boom.err"
probe after-boom "$tmpdir/goal.sml" 120 0
require_grep "^hits: 3 preloads: 1$" "$tmpdir/after-boom.out"

# A check that fails in a later theorem moves the process on to it.
write_a 'REWRITE_TAC []' 'FAIL_TAC "later failure"'
status=0
"$HOLBUILD_BIN" park-check "$socket" "$spec" "$project/src/AScript.sml" > "$tmpdir/moved.out" 2> "$tmpdir/moved.err" || status=$?
[[ "$status" == 1 ]] || { echo "park-check moved: wanted exit 1, got $status" >&2; cat "$tmpdir/moved.err" "$tmpdir/park.log" >&2; exit 1; }
for _ in $(seq 120); do
  [[ "$(grep -c 'park: prepared' "$tmpdir/park.log")" -ge 2 ]] && break
  sleep 0.5
done
probe moved "$tmpdir/goal.sml" 120 0
require_grep "^goal: ~(F /\\\\ T)$" "$tmpdir/moved.out"
require_grep "^hits: 4 preloads: 1$" "$tmpdir/moved.out"

# A probe past its time ends the process; the next probe starts another.
pid_file=$(find "$tmpdir/park" -name probe.pid | head -n 1)
[[ -n "$pid_file" ]] || { echo "the preload left no process id" >&2; exit 1; }
first_pid=$(cat "$pid_file")
probe spin "$tmpdir/spin.sml" 3 2
require_grep "ran out of time" "$tmpdir/spin.err"
for _ in $(seq 20); do kill -0 "$first_pid" 2>/dev/null || break; sleep 0.25; done
if kill -0 "$first_pid" 2>/dev/null; then echo "the timed-out probe process still runs" >&2; exit 1; fi
probe restarted "$tmpdir/goal.sml" 120 0
require_grep "^goal: ~(F /\\\\ T)$" "$tmpdir/restarted.out"
require_grep "^hits: 1 preloads: 1$" "$tmpdir/restarted.out"

# The fixed script ends the server and the process with it.
second_pid=$(cat "$(find "$tmpdir/park" -name probe.pid | head -n 1)")
write_a 'REWRITE_TAC []'
status=0
"$HOLBUILD_BIN" park-check "$socket" "$spec" "$project/src/AScript.sml" > "$tmpdir/fixed.out" 2> "$tmpdir/fixed.err" || status=$?
[[ "$status" == 0 ]] || { echo "park-check fixed: wanted exit 0, got $status" >&2; cat "$tmpdir/fixed.err" "$tmpdir/park.log" >&2; exit 1; }
wait "$park_pid" || { echo "the park server failed" >&2; cat "$tmpdir/park.log" >&2; exit 1; }
park_pid=""
for _ in $(seq 20); do kill -0 "$second_pid" 2>/dev/null || break; sleep 0.25; done
if kill -0 "$second_pid" 2>/dev/null; then echo "the probe process outlived the server" >&2; exit 1; fi
