#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

cat > "$tmpdir/spawn-test.sml" <<'SML'
val root =
  case OS.Process.getEnv "HOLBUILD_ROOT" of
      SOME path => path
    | NONE => raise Fail "HOLBUILD_ROOT not set";

val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

fun fail message = (TextIO.output (TextIO.stdErr, message ^ "\n");
                    OS.Process.exit OS.Process.failure)
fun assert message condition = if condition then () else fail message

fun run program args stderr = HolbuildSpawn.run {program = program, args = args, stderr = stderr}
fun sh script stderr = run "sh" ["-c", script] stderr

val echo = run "echo" ["one", "two words"] HolbuildSpawn.Inherit
val _ = assert "echo succeeds" (HolbuildSpawn.succeeded echo)
val _ = assert "arguments are passed unsplit" (#output echo = "one two words\n")

val merged = sh "echo out; echo err >&2" HolbuildSpawn.Merge
val _ = assert "Merge captures stderr" (#output merged = "out\nerr\n")

val discarded = sh "echo out; echo err >&2" HolbuildSpawn.Discard
val _ = assert "Discard drops stderr" (#output discarded = "out\n")

val exit3 = sh "exit 3" HolbuildSpawn.Inherit
val _ = assert "exit status is reported" (#status exit3 = Posix.Process.W_EXITSTATUS 0w3)

val missing = run "holbuild-spawn-test-no-such-program" [] HolbuildSpawn.Inherit
val _ = assert "a missing program reports 127" (#status missing = Posix.Process.W_EXITSTATUS 0w127)

(* Poly/ML blocks signals in ML threads; the child must not inherit that. *)
val killed = sh "kill -TERM $$; sleep 5; exit 0" HolbuildSpawn.Inherit
val _ = assert "child receives signals"
               (#status killed = Posix.Process.W_SIGNALED Posix.Signal.term)

(* The child sees only stdin, stdout and stderr: no pipe end leaks into it. *)
val fds = sh "for fd in 3 4 5 6 7 8 9; do if { true >&$fd; } 2>/dev/null; then echo $fd; fi; done"
             HolbuildSpawn.Inherit
val _ = assert ("no extra descriptors are inherited: " ^ #output fds) (#output fds = "")

val big = sh "head -c 1000000 /dev/zero | tr '\\000' x" HolbuildSpawn.Inherit
val _ = assert "large output is read completely" (size (#output big) = 1000000)

val _ = print "spawn tests passed\n"
SML

"${HOLBUILD_POLY:-poly}" < "$tmpdir/spawn-test.sml" > "$tmpdir/spawn-test.log" 2>&1 || {
  cat "$tmpdir/spawn-test.log" >&2
  exit 1
}

grep -q "spawn tests passed" "$tmpdir/spawn-test.log" || {
  cat "$tmpdir/spawn-test.log" >&2
  exit 1
}
