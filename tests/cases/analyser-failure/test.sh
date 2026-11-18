#!/usr/bin/env bash
set -euo pipefail

_HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
export HOLBUILD_CACHE=$tmpdir/cache
mkdir -p "$HOLBUILD_CACHE" "$tmpdir/bin" "$tmpdir/group/child" "$tmpdir/root" "$tmpdir/checkpoints" "$tmpdir/toolchain/analyser/bin"

cat > "$tmpdir/bin/analyser" <<'HELPER'
#!/bin/sh
set -eu
state=$(dirname "$(dirname "$0")")
request= response= minheap=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request) request=$2; shift 2 ;;
    --response) response=$2; shift 2 ;;
    --minheap) minheap=$2; shift 2 ;;
    *) exit 79 ;;
  esac
done
[ "$minheap" = 128 ] || exit 79
[ -f "$request" ]
# Stale output from a previous attempt must never reach a retry.
[ ! -e "$response" ] || exit 78
printf '%s\n' "$(dirname "$request")" >> "$state/attempts"
printf 'helper stdout\n'
printf 'helper stderr\n' >&2
mode=$(cat "$state/mode")
case "$mode" in
  transient)
    if [ "$(wc -l < "$state/attempts")" -eq 1 ]; then
      printf 'stale response\n' > "$response"
      exit 137
    fi ;;
  killed) exit 137 ;;
  child-signal) kill -KILL $$ ;;
  signal) kill -KILL "$PPID"; sleep 2; exit 1 ;;
  parser) printf 'version 1\nok\nbegin-file 1\nparse-error bad-source\nend-file 1\nend\n' > "$response"; exit 0 ;;
  failure) exit 2 ;;
  pressure)
    printf 'oom 8\noom_kill 5\n' > "$state/group/memory.events"
    exit 2 ;;
  wait)
    touch "$state/ready"
    while :; do sleep 1; done ;;
esac
printf 'version 1\nok\nbegin-file 1\nend-file 1\nend\n' > "$response"
HELPER
chmod +x "$tmpdir/bin/analyser"
cat > "$tmpdir/toolchain/analyser/bin/analyser" <<'HELPER'
#!/bin/sh
printf 'confined failure\n' >&2
exit 137
HELPER
chmod +x "$tmpdir/toolchain/analyser/bin/analyser"

cat > "$tmpdir/test.sml" <<'SML'
val root = valOf (OS.Process.getEnv "HOLBUILD_ROOT");
val tmp = valOf (OS.Process.getEnv "ANALYSER_FAILURE_TEST_TMP");
val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

(* Count launches without replacing the real process or sandbox runners. *)
structure RealProcessGroup = HolbuildProcessGroup;
structure HolbuildProcessGroup =
struct
  open RealProcessGroup
  val launches = ref 0
  fun run_shell_output_cancellable token script =
    (launches := !launches + 1; RealProcessGroup.run_shell_output_cancellable token script)
end;
use "sml/dependencies.sml";
use "sml/theory_spans.sml";
structure D = HolbuildDependencies;
structure G = HolbuildProcessGroup;

fun assert name condition = if condition then () else raise Fail name;
fun path name = OS.Path.concat (tmp, name);
fun write name text = D.write_file (path name) text;
fun read name = D.read_all (path name);
fun exists name = OS.FileSys.access (path name, []) handle OS.SysErr _ => false;
fun lines name = String.tokens (fn c => c = #"\n") (read name);
fun contains text part = String.isSubstring part text;
fun reset mode = (write "mode" mode; write "attempts" ""; G.launches := 0);
fun run () = D.run_analyser {analyser = path "bin/analyser", request = "test request\n", capture_stderr = true};
fun count n = assert ("expected " ^ Int.toString n ^ " attempts") (length (lines "attempts") = n);
fun unique [] = true
  | unique (x :: xs) = not (List.exists (fn y => x = y) xs) andalso unique xs;
fun cleaned () = List.app (fn dir => assert "attempt directory removed"
  (not (OS.FileSys.access (dir, []) handle OS.SysErr _ => false))) (lines "attempts");
fun no_tokens () = assert "cancellation tokens released" (null (!G.cancellation_tokens));
val _ = reset "success";
val successful = run ();
val _ = assert "success response" (isSome (#response successful));
val _ = count 1;
val _ = cleaned ();
val _ = reset "transient";
val recovered = run ();
val _ = assert "transient kill recovered" (isSome (#response recovered));
val _ = count 2;
val _ = assert "retry has fresh state" (unique (lines "attempts"));
val _ = assert "stdout preserved" (#output recovered = "helper stdout\nhelper stdout\n");
val _ = assert "stderr preserved on success" (#stderr recovered = "helper stderr\n");
val _ = cleaned ();
val _ = no_tokens ();

val _ = reset "killed";
val failed = run ();
val _ = count 3;
val _ = assert "failed response ignored" (#response failed = NONE);
val _ = assert "shell 137 decoded without asserting signal" (contains (D.analyser_failure failed) "exit status 137");
val _ = assert "cause unknown" (contains (D.analyser_failure failed) "kill cause unknown");
val _ = assert "failure stderr retained" (contains (D.analyser_failure failed) "helper stderr");
val _ = assert "all retries have fresh state" (unique (lines "attempts"));
val _ = cleaned ();

val _ = reset "child-signal";
val child_signalled = run ();
val _ = count 3;
val _ = assert "child signal mapped to shell status"
  (contains (D.analyser_failure child_signalled) "exit status 137" andalso
   contains (#stderr child_signalled) "helper stderr");
val _ = cleaned ();

val direct = G.run_shell_output "kill -KILL $$";
val _ = assert "direct signal decoded" (contains (D.analyser_status (#status direct)) "signal 9 (SIGKILL)");
val _ = assert "direct kill retryable" (D.analyser_killed (#status direct));
val _ = reset "signal";
val signalled = run ();
val _ = count 3;
val _ = assert "direct kill failure retained" (contains (D.analyser_failure signalled) "signal 9 (SIGKILL)");
val _ = cleaned ();

val _ = reset "failure";
val failed = run ();
val _ = count 1;
val _ = assert "parser exit not retried" (contains (D.analyser_failure failed) "exit status 2");
val (_, dependency_failure) = D.analyse_files (path "bin/analyser") [("1", "AScript.sml")];
val _ = (D.outcome_value dependency_failure; raise Fail "dependency failure accepted")
  handle D.Error text => assert "dependency diagnostics" (contains text "exit status 2" andalso contains text "helper stderr");
val _ = D.set_analyser {path = path "bin/analyser", identity = "test"};
val _ = (HolbuildTheorySpans.run ["boundaries"] "AScript.sml"; raise Fail "span failure accepted")
  handle HolbuildTheoryCheckpoints.Error text => assert "span diagnostics"
    (contains text "AScript.sml" andalso contains text "exit status 2" andalso contains text "helper stderr");
val _ = reset "parser";
val (_, parser_failure) = D.analyse_files (path "bin/analyser") [("1", "AScript.sml")];
val _ = (D.outcome_value parser_failure; raise Fail "parser error accepted")
  handle D.Error text => assert "parser error retained" (contains text "parse-error");
val _ = count 1;

(* The runner starts with no cgroup support, also covering non-Linux hosts. *)
val _ = assert "absent cgroups supported" (contains (#pressure failed) "unavailable");
val _ = write "group/memory.events" "oom 7\noom_kill 3\n";
val setenv = Foreign.buildCall3
  (Foreign.getSymbol (Foreign.loadExecutable ()) "setenv",
   (Foreign.cString, Foreign.cString, Foreign.cInt), Foreign.cInt);
val _ = setenv ("HOLBUILD_TEST_CGROUP", path "group/child", 1);
val _ = reset "pressure";
val pressured = run ();
val _ = count 1;
val _ = assert "ancestor counters and deltas" (contains (#pressure pressured) "oom=7->8 (delta 1)" andalso
  contains (#pressure pressured) "oom_kill=3->5 (delta 2)");
val _ = assert "shared pressure is not attribution" (contains (#pressure pressured) "not victim attribution");
val _ = write "group/memory.events" "oom invalid\noom_kill -3\n";
val _ = assert "malformed optional counters ignored" (null (HolbuildMachineMemory.cgroup_memory_events ()));
val _ = setenv ("HOLBUILD_TEST_CGROUP", "", 1);

(* Sandbox validation stays real; the launch counter is in the trusted parent. *)
val _ = if OS.Process.getEnv "ANALYSER_FAILURE_TEST_SANDBOX" = SOME "1" then
  let
    val _ = G.launches := 0
    val _ = HolbuildActionSandbox.enable (path "root", path "checkpoints")
    val _ = HolbuildActionSandbox.poly_executable := "/usr/bin/true"
    val result = D.run_analyser {analyser = path "toolchain/analyser/bin/analyser", request = "test", capture_stderr = true}
    val _ = HolbuildActionSandbox.disable ()
  in
    assert "sandbox failure not retried" (!G.launches = 1 andalso #response result = NONE);
    assert "sandbox stderr preserved" (contains (#stderr result) "confined failure")
  end else ();

fun await label predicate =
  let val deadline = Time.+ (Time.now (), Time.fromSeconds 15)
      fun loop () = if predicate () then () else if Time.>= (Time.now (), deadline)
                   then raise Fail ("waiting for " ^ label)
                   else (OS.Process.sleep (Time.fromReal 0.01); loop ())
  in loop () end;
fun cancelled_run cancel =
  let
    val _ = reset "wait"
    val _ = if exists "ready" then OS.FileSys.remove (path "ready") else ()
    val done = ref NONE
    val worker = Thread.fork (fn () =>
      ((run (); done := SOME "returned") handle Thread.Interrupt => done := SOME "cancelled"
        | e => done := SOME (General.exnMessage e)), [])
    val _ = await "helper ready" (fn () => exists "ready")
    val _ = cancel worker
    val _ = await "caller cancellation" (fn () => isSome (!done))
    val _ = assert "caller cancellation propagated" (!done = SOME "cancelled")
    val _ = count 1
  in no_tokens (); cleaned () end;
val _ = cancelled_run G.kill_thread_children;
val _ = cancelled_run (fn _ => G.cleanup_active_children ());

(* Deterministic childless gaps: cancel the token before the next launch.
   No sleep or race is needed to exercise the setup/backoff window. *)
fun gap cancel =
  ((G.with_cancellation_token (fn token =>
      (cancel (Thread.self ());
       G.run_shell_output_cancellable token ("touch " ^ HolbuildHash.quote (path "unexpected"));
       raise Fail "cancelled token launched a child"));
    raise Fail "gap cancellation returned")
   handle Thread.Interrupt => ());
val _ = gap G.kill_thread_children;
val _ = gap (fn _ => G.cleanup_active_children ());
val _ = assert "no launch after gap cancellation" (not (exists "unexpected"));
val _ = no_tokens ();
val _ = G.with_cancellation_token (fn token =>
  assert "new scope works after prior cancellation"
    (OS.Process.isSuccess (#status (G.run_shell_output_cancellable token "true"))));

val _ = print "analyser failure tests passed\n";
SML

sandbox=0
[[ $(uname -s) != Linux ]] || sandbox=1
ANALYSER_FAILURE_TEST_TMP="$tmpdir" ANALYSER_FAILURE_TEST_SANDBOX=$sandbox HOLBUILD_TEST_CGROUP= \
  "${HOLBUILD_POLY:-poly}" --error-exit --gcthreads=1 < "$tmpdir/test.sml" > "$tmpdir/test.log" 2>&1 || {
    tail -100 "$tmpdir/test.log" >&2
    exit 1
  }
require_grep 'analyser failure tests passed' "$tmpdir/test.log"
