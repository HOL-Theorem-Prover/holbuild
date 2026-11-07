#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT

cat > "$tmpdir/test.sml" <<'SML'
val root = valOf (OS.Process.getEnv "HOLBUILD_ROOT");
val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

(* Advance the clock without sleeping or changing the production cooldown. *)
val clock = ref Time.zeroTime;
structure Time = struct open Time fun now () = !clock end;
use "sml/remote_cache.sml";

fun assert message condition = if condition then () else raise Fail message;
fun advance seconds = clock := Time.+ (!clock, Time.fromSeconds seconds);
val requests = ref 0;
fun request result () = (requests := !requests + 1; result);
fun send result = HolbuildRemoteCache.send "GET" "stub" "" (request result);
val failed = HolbuildHttp.Failed "stub connection refused";
val missing = HolbuildHttp.Response 404;
val _ = send failed;
val _ = send failed;
val _ = send missing;
val _ = send failed;
val _ = send failed;
val _ = assert "an HTTP miss resets consecutive failures" (not (HolbuildRemoteCache.disabled ()));

(* Hold a request across the trip: its late response must not reopen it. *)
val mutex = Mutex.mutex ();
val changed = ConditionVar.conditionVar ();
val started = ref false;
val released = ref false;
val done = ref false;
fun gated_request result () =
  (Mutex.lock mutex;
   requests := !requests + 1;
   started := true;
   ConditionVar.broadcast changed;
   while not (!released) do ConditionVar.wait (changed, mutex);
   Mutex.unlock mutex;
   result);
fun start_gated result =
  (started := false; released := false; done := false;
   ignore (Thread.fork (fn () =>
     (ignore (HolbuildRemoteCache.send "GET" "stub" "" (gated_request result));
      Mutex.lock mutex;
      done := true;
      ConditionVar.broadcast changed;
      Mutex.unlock mutex), []));
   Mutex.lock mutex;
   while not (!started) do ConditionVar.wait (changed, mutex);
   Mutex.unlock mutex);
fun finish_gated () =
  (Mutex.lock mutex;
   released := true;
   ConditionVar.broadcast changed;
   while not (!done) do ConditionVar.wait (changed, mutex);
   Mutex.unlock mutex);
val _ = start_gated missing;
val _ = send failed;
val _ = finish_gated ();
val _ = assert "late success leaves the breaker tripped" (HolbuildRemoteCache.disabled ());
val before_skip = !requests;
val _ = assert "requests skip during cooldown" (send missing = NONE);
val _ = advance 59;
val _ = assert "cooldown lasts 60 seconds" (send missing = NONE andalso !requests = before_skip);
val _ = advance 1;
(* Repeated outer checks must not consume the probe. *)
val _ = assert "cooldown expires" (not (HolbuildRemoteCache.disabled ()));
val _ = assert "disabled does not reserve a probe" (not (HolbuildRemoteCache.disabled ()));
val _ = start_gated failed;
val before_burst = !requests;

(* All callers at the cooldown boundary skip while the single probe runs. *)
val remaining = ref 32;
val unexpected = ref false;
val _ = List.tabulate (32, fn _ => Thread.fork (fn () =>
  let val result = send missing in
    Mutex.lock mutex;
    if result = NONE then () else unexpected := true;
    remaining := !remaining - 1;
    ConditionVar.broadcast changed;
    Mutex.unlock mutex
  end, []));
val _ = Mutex.lock mutex;
val _ = while !remaining > 0 do ConditionVar.wait (changed, mutex);
val _ = Mutex.unlock mutex;
val _ = assert "only one concurrent probe" (not (!unexpected) andalso !requests = before_burst);
val _ = finish_gated ();
val _ = assert "failed probe starts a fresh cooldown" (send missing = NONE);
val _ = advance 59;
val _ = assert "retry also waits 60 seconds" (send missing = NONE);
val _ = advance 1;
val _ = assert "an HTTP error recovers transport" (send (HolbuildHttp.Response 503) = SOME (HolbuildHttp.Response 503));
val _ = assert "cache reopens" (not (HolbuildRemoteCache.disabled ()));
val _ = assert "normal requests resume" (send missing = SOME missing);

(* An exception must release the probe as a failure, not wedge it forever. *)
val _ = send failed;
val _ = send failed;
val _ = send failed;
val _ = advance 60;
exception RequestError;
val _ = ((ignore (HolbuildRemoteCache.send "GET" "stub" "" (fn () => raise RequestError));
          raise Fail "request exception was lost") handle RequestError => ());
val _ = assert "exception starts cooldown" (send missing = NONE);
val _ = advance 60;
val _ = assert "probe recovers after exception" (send missing = SOME missing);
val _ = print "remote cache cooldown passed\n";
SML
poly --script "$tmpdir/test.sml" > "$tmpdir/test.log" 2>&1 || {
  cat "$tmpdir/test.log" >&2
  exit 1
}
require_grep 'remote cache cooldown passed' "$tmpdir/test.log"
[[ $(grep -c 'remote cache disabled for 60 seconds after 3 requests in a row failed' "$tmpdir/test.log") == 2 ]]
[[ $(grep -c 'remote cache disabled for 60 seconds after a recovery probe failed' "$tmpdir/test.log") == 2 ]]
[[ $(grep -c 'remote cache available again' "$tmpdir/test.log") == 2 ]]
