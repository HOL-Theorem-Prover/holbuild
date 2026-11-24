#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# exec-action --park --probe-preload answers park-probe requests in one HOL
# process that used the preload once, in the context the failing theorem
# starts in, and stands after the failing theorem's
# failure, the goals it failed on at hand: a step's input goals, or those
# the proof's end left open.  It moves on when a check fails in a later
# theorem, and is started again after a probe runs out of time.  It sees the
# tool cache an earlier build of the theory's dependencies left.

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
# write_a STEP [LATER] [HEADER]: target's second conjunct gets STEP,
# later_thm LATER; HEADER runs before both.
write_a() {
  cat > "$project/src/AScript.sml" <<SML
Theory A
Ancestors bool
${3:-}

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
(* Bound only once the script's header has run. *)
val probe_theory = current_theory ();
val probe_tool =
  let val input = TextIO.openIn (OS.Path.concat (valOf (OS.Process.getEnv "HOLBUILD_TOOL_CACHE_DIR"), "seen"))
  in TextIO.inputAll input before TextIO.closeIn input end
  handle IO.Io _ => "nothing";
val _ = let val out = TextIO.openOut "probe.pid"
        in TextIO.output (out, LargeInt.toString (SysWord.toLargeInt (Posix.Process.pidToWord (Posix.ProcEnv.getpid ()))));
           TextIO.closeOut out end;
SML
cat > "$tmpdir/goal.sml" <<'SML'
val _ = Feedback.set_trace "Unicode" 0;
val _ = probe_hits := !probe_hits + 1;
val _ = print ("goal: " ^ Parse.term_to_string (#2 (hd (HolbuildProofRuntime.failed_goals ()))) ^ "\n");
val _ = print ("theory: " ^ probe_theory ^ "\n");
val _ = print ("goals: " ^ Int.toString (length (HolbuildProofRuntime.failed_goals ())) ^ "\n");
val _ = print ("tool: " ^ probe_tool ^ "\n");
val _ = print ("hits: " ^ Int.toString (!probe_hits) ^ " preloads: " ^ Int.toString (!probe_preloads) ^ "\n");
SML
cat > "$tmpdir/boom.sml" <<'SML'
val _ = raise Fail "probe boom";
SML
cat > "$tmpdir/spin.sml" <<'SML'
val _ = let fun spin n = spin (n + 1) in spin 0 end;
SML

# A build of another version of A, on the same dependencies, leaves its tool
# cache in the remote cache.
write_a 'FAIL_TAC "first failure"' '' 'val _ = let val out = TextIO.openOut (OS.Path.concat (valOf (OS.Process.getEnv "HOLBUILD_TOOL_CACHE_DIR"), "seen")) in TextIO.output (out, "earlier build"); TextIO.closeOut out end;'
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload --tool-cache probe ATheory) > "$tmpdir/batch-tool.txt"
tool_spec=$(field "$tmpdir/batch-tool.txt" park:ATheory 4)
[[ -n "$tool_spec" ]] || { cat "$tmpdir/batch-tool.txt" >&2; exit 1; }
link_hol_toolchain_cache "$tmpdir/tool"
status=0
HOLBUILD_CACHE=$tmpdir/tool "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$tool_spec" \
  --cache-limit-gb 1000 > "$tmpdir/tool.log" 2>&1 || status=$?
[[ "$status" == 1 ]] || { echo "the tool cache build: wanted exit 1, got $status" >&2; cat "$tmpdir/tool.log" >&2; exit 1; }

write_a 'FAIL_TAC "first failure"'

socket=$tmpdir/park.sock
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload --tool-cache probe ATheory) > "$tmpdir/batch.txt"
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
require_grep "^theory: A$" "$tmpdir/first.out"
require_grep "^tool: earlier build$" "$tmpdir/first.out"
probe second "$tmpdir/goal.sml" 120 0
require_grep "^hits: 2 preloads: 1$" "$tmpdir/second.out"
# A probe that raises answers error; the process stays.
probe boom "$tmpdir/boom.sml" 120 1
require_grep "probe boom" "$tmpdir/boom.err"
probe after-boom "$tmpdir/goal.sml" 120 0
require_grep "^hits: 3 preloads: 1$" "$tmpdir/after-boom.out"

# fails NAME PREPARED: park-check of the script fails, and the server has
# prepared PREPARED times.
fails() {
  local status=0
  "$HOLBUILD_BIN" park-check "$socket" "$spec" "$project/src/AScript.sml" > "$tmpdir/$1.out" 2> "$tmpdir/$1.err" || status=$?
  [[ "$status" == 1 ]] || { echo "park-check $1: wanted exit 1, got $status" >&2; cat "$tmpdir/$1.err" "$tmpdir/park.log" >&2; exit 1; }
  for _ in $(seq 120); do
    [[ "$(grep -c 'park: prepared' "$tmpdir/park.log")" -ge "$2" ]] && break
    sleep 0.5
  done
}

# A check that fails in a later theorem moves the process on to it.
write_a 'REWRITE_TAC []' 'FAIL_TAC "later failure"'
fails moved 2
probe moved "$tmpdir/goal.sml" 120 0
require_grep "^goal: ~(F /\\\\ T)$" "$tmpdir/moved.out"
require_grep "^goals: 1$" "$tmpdir/moved.out"
require_grep "^hits: 4 preloads: 1$" "$tmpdir/moved.out"

# A proof that ends with goals open fails on them.
write_a 'REWRITE_TAC []' 'ASM_CASES_TAC ``x:bool``'
fails ended 3
probe ended "$tmpdir/goal.sml" 120 0
require_grep "^goal: ~(F /\\\\ T)$" "$tmpdir/ended.out"
require_grep "^goals: 2$" "$tmpdir/ended.out"

# A proof with a step that doesn't compile fails on the theorem's goal.
write_a 'REWRITE_TAC []' 'REWRITE_TAC [no_such_theorem]'
fails static 4
probe static "$tmpdir/goal.sml" 120 0
require_grep "^goal: ~(F /\\\\ T)$" "$tmpdir/static.out"
require_grep "^goals: 1$" "$tmpdir/static.out"

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
