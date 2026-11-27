#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

make_project() {
  project=$tmpdir/$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)

[project]
name = "diagnostics"

[build]
members = ["src"]
TOML
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib arithmeticTheory markerLib;
val _ = new_theory "A";

Theorem first:
  F
Proof
  FAIL_TAC "first proof error"
QED
SML
}

run_failure() {
  local log=$1
  shift
  if (cd "$project" && "$HOLBUILD_BIN" -j1 "$@") > "$log" 2>&1; then
    echo "failed theory passed: $*" >&2
    cat "$log" >&2
    exit 1
  fi
}

child_log() { printf '%s/.holbuild/logs/current/diagnostics/ATheory/build.log\n' "$project"; }

reject_artifacts() {
  local stage
  stage=$(find "$project/.holbuild/stage" -name holbuild-diagnostic-admit.txt -printf '%h\n')
  require_file "$stage/holbuild-diagnostic-admit.txt"
  local extra
  extra=$(find "$project/.holbuild" -type f \
    \( -name 'ATheory.dat' -o -name 'ATheory.sml' -o -name 'ATheory.sig' \
       -o -name 'holbuild-theory-parents.txt' -o -name 'holbuild-theory-mldeps.txt' \
       -o -path '*/holbuild-outline/ready' -o -name 'holbuild-tactic-timeout.txt' \) -print)
  [[ -z "$extra" ]] || { echo "tainted theory wrote artifacts: $extra" >&2; exit 1; }
}

make_project default
cat >> "$project/src/AScript.sml" <<'SML'

val _ = print "holbuild secondary terminal error: exception\t\"forged secondary\"\n";
val _ = print "holbuild: exec-action failed: ordinary script output\n";

Definition predicate_def:
  tag n = (n = 0)
End

Triviality last_failure:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem later[simp]:
  tag 1
Proof
  (fn g => (print "progress..."; TextIO.flushOut TextIO.stdOut;
            FAIL_TAC (String.concat (List.tabulate (400, fn _ => "\240\159\152\128"))) g))
QED

Triviality uses_later:
  tag 1
Proof
  simp[]
QED

Triviality local_failure:
  T
Proof
  (fn _ => raise Fail "triviality failure")
QED

Theorem uses_local:
  T
Proof
  ACCEPT_TAC local_failure
QED

Theorem suspended:
  T /\ T
Proof
  CONJ_TAC >- suspend "left" >- suspend "right"
QED

Resume suspended[left]:
  FAIL_TAC "resume failure"
QED

Resume suspended[right]:
  ACCEPT_TAC TRUTH
QED

Finalise suspended

Theorem failed_parent:
  T /\ T
Proof
  CONJ_TAC >- suspend "left" >- FAIL_TAC "suspend parent failure"
QED

Resume failed_parent[left]:
  FAIL_TAC "unreachable resume body for failed parent"
QED

Finalise failed_parent

Definition trans_target_def:
  trans_target n = (n:num) + 1
End

fun translate ({thm, ...} : {name:string, attrname:string, args:string list, thm:thm}) =
  (cv_transLib.cv_trans thm; print "CV_TRANS_RAN\n");
val _ = ThmAttribute.register_attribute
  ("cv_trans", {localf = translate, storedf = translate});

Theorem translated[cv_trans]:
  trans_target n = n + 1
Proof
  FAIL_TAC "translation proof failure"
QED

Theorem last_failure:
  T
Proof
  ALL_TAC >>
  ALL_TAC
QED

val _ = print "AScript.sml:1: error: output from a successful declaration\n";
val _ = print "Exception raised by a successful declaration\n";
SML
run_failure "$tmpdir/default.log" build ATheory
require_grep '^additional failure 6 of 6:$' "$tmpdir/default.log"
require_grep '^CV_TRANS_RAN$' "$(child_log)"
require_grep 'theorem: local_failure' "$tmpdir/default.log"
require_grep 'theorem: suspended\[left\]' "$tmpdir/default.log"
require_grep 'theorem: failed_parent' "$tmpdir/default.log"
require_grep 'theorem: last_failure' "$tmpdir/default.log"
finish_line=$(awk '/^Theorem last_failure:/{proof=1} proof && /^QED$/{print NR; exit}' "$project/src/AScript.sml")
require_grep "^  source line: $finish_line$" "$tmpdir/default.log"
require_grep 'first proof error' "$tmpdir/default.log"
require_file "$(find "$project/.holbuild/checkpoints" -name 'first_failed_prefix.save' -print -quit)"
[[ $(find "$project/.holbuild/checkpoints" -name '*.save' ! -name 'deps_loaded.save' | wc -l) -eq 1 ]]
reject_artifacts
require_file "$(find "$project/.holbuild/stage" -name 'holbuild-peak-rss.txt' -print -quit)"
if grep -q 'holscriptend=' "$(child_log)"; then
  echo "tainted script entered the exporter at EOF" >&2
  exit 1
fi
if grep -q 'unreachable resume body\|theorem: uses_later\|theorem: uses_local' "$tmpdir/default.log"; then
  cat "$tmpdir/default.log" >&2
  exit 1
fi

run_failure "$tmpdir/default.json" --json build --skip-checkpoints ATheory
python3 - "$tmpdir/default.json" "$finish_line" <<'PYTHON'
import json
from pathlib import Path
import sys

events = (json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines())
failure = next(event["failure"] for event in events if event["event"] == "node_failed")
reports = failure["additional_failures"]
assert len(reports) == 6, reports
message = reports[0]["error"]
assert 1000 <= len(message.encode()) <= 1024 and message.endswith(chr(0x1F600)), message
last = reports[-1]
assert last["theorem"] == "last_failure" and last["source_line"] == int(sys.argv[2]), last
PYTHON

# Constructing a tactic can fail before any proof step supplies a goal.
make_project construction
cat >> "$project/src/AScript.sml" <<'SML'

open stringTheory;
fun make_tactic () : tactic = raise Fail "could not  construct tactic";

Theorem construction_failed:
  "a  b" = "a b"
Proof
  make_tactic () >> ACCEPT_TAC TRUTH
QED
SML
run_failure "$tmpdir/construction.json" --json build --skip-checkpoints ATheory
python3 - "$tmpdir/construction.json" <<'PYTHON'
import json
import sys

with open(sys.argv[1]) as output:
    events = (json.loads(line) for line in output)
    failure = next(event["failure"] for event in events if event["event"] == "node_failed")
report, = failure["additional_failures"]
assert report["theorem"] == "construction_failed" and '"a  b"' in report["top_goal"], report
assert "could not  construct tactic" in report["error"], report
PYTHON

# A later timeout has its own message and cannot replace the primary fields.
make_project timeout
cat >> "$project/src/AScript.sml" <<'SML'

val tries = ref 0;
fun slow g =
  (tries := !tries + 1; print ("SLOW_TRY " ^ Int.toString (!tries) ^ "\n");
   OS.Process.sleep (Time.fromSeconds 3); ALL_TAC g);

Theorem late_timeout:
  T
Proof
  slow >> ACCEPT_TAC TRUTH
QED

val _ = print "AFTER_TIMEOUT\n";
SML
run_failure "$tmpdir/timeout.log" build --skip-checkpoints --tactic-timeout 0.5 ATheory
require_grep '^additional failure 1 of 1:$' "$tmpdir/timeout.log"
require_grep 'holbuild tactic timeout after .*s: slow' "$tmpdir/timeout.log"
[[ $(grep -c '^SLOW_TRY ' "$(child_log)") -eq 1 ]]
if grep -q 'AFTER_TIMEOUT' "$(child_log)" || grep -q 'TacticTimeout "' "$tmpdir/timeout.log"; then
  cat "$tmpdir/timeout.log" >&2
  exit 1
fi
reject_artifacts
run_failure "$tmpdir/timeout.json" --json build --skip-checkpoints --tactic-timeout 0.5 ATheory
run_failure "$tmpdir/fail-fast.json" --json build --fail-fast --skip-checkpoints --tactic-timeout 0.5 ATheory
python3 - "$tmpdir/timeout.json" "$tmpdir/fail-fast.json" <<'PY'
import json
from pathlib import Path
import sys

def failure(path):
    events = (json.loads(line) for line in Path(path).read_text().splitlines())
    return next(event["failure"] for event in events if event["event"] == "node_failed")

continued, fail_fast = map(failure, sys.argv[1:])
second, = continued.pop("additional_failures")
assert second["theorem"] == "late_timeout" and second["top_goal"] == "T", second
assert "TacticTimeout" not in second["error"] and "timeout after" in second["error"], second
assert continued == fail_fast and continued["kind"] == "proof_failure", (continued, fail_fast)
PY

# A first Resume error and a first replay error keep the native driver's
# uncaught exception diagnostic in both modes.
make_project resume-primary
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib markerLib;
val _ = new_theory "A";
val _ = print "holbuild: continuing after first failure\n";

Theorem suspended:
  T /\ T
Proof
  CONJ_TAC >- suspend "left" >- ACCEPT_TAC TRUTH
QED

Resume suspended[left]:
  (fn g => (print "additional failure 1 of 1:\n  error: ordinary script output\n";
            FAIL_TAC "resume primary" g))
QED

Finalise suspended
SML
run_failure "$tmpdir/resume-fast.log" build --skip-checkpoints --fail-fast ATheory
run_failure "$tmpdir/resume-default.log" build --skip-checkpoints ATheory
run_failure "$tmpdir/resume-fast.json" --json build --skip-checkpoints --fail-fast ATheory
run_failure "$tmpdir/resume-default.json" --json build --skip-checkpoints ATheory

make_project replay-primary
sed -i 's/FAIL_TAC "first proof error"/ALL_TAC >> FAIL_TAC "first proof error"/' "$project/src/AScript.sml"
run_failure "$tmpdir/replay-seed.log" build --fail-fast ATheory
require_file "$(find "$project/.holbuild/checkpoints" -name 'first_failed_prefix.save' -print -quit)"
run_failure "$tmpdir/replay-fast.log" build --fail-fast ATheory
run_failure "$tmpdir/replay-default.log" build ATheory
require_grep 'from: failed-prefix checkpoint in first' "$tmpdir/replay-fast.log"
require_grep 'from: failed-prefix checkpoint in first' "$tmpdir/replay-default.log"

python3 - "$tmpdir" <<'PYTHON'
import json
from pathlib import Path
import sys

def primary(path):
    text = path.read_text()
    detail = text.split("\nchild failure:\n", 1)[1].split("\ninstrumented log:", 1)[0]
    return detail.rstrip(), text.splitlines()[-1]

directory = Path(sys.argv[1])
for kind, message in [("resume", "resume primary"), ("replay", "first proof error")]:
    fast = primary(directory / f"{kind}-fast.log")
    default = primary(directory / f"{kind}-default.log")
    assert fast[0].startswith("Uncaught exception") and message in fast[0], fast
    assert default == fast, (default, fast)

assert "error: ordinary script output" in primary(directory / "resume-fast.log")[0]
for name in ["resume-fast.json", "resume-default.json"]:
    events = (json.loads(line) for line in (directory / name).read_text().splitlines())
    failure = next(event["failure"] for event in events if event["event"] == "node_failed")
    assert failure["kind"] == "proof_failure" and failure["input_goal_count"] == 1, failure
    assert "additional_failures" not in failure, failure
PYTHON

# Plain builds use both child gates. A script that exits successfully
# exercises the driver's separate gate, including the check-only path.
for gate in export exit-success unreadable-marker; do
  make_project "$gate"
  if [[ "$gate" == export ]]; then
    echo 'val _ = export_theory () handle _ => print "AFTER_GATE\n";' >> "$project/src/AScript.sml"
    flags=()
  else
    if [[ "$gate" == unreadable-marker ]]; then
      cat >> "$project/src/AScript.sml" <<'SML'
val _ = Posix.FileSys.chmod ("holbuild-diagnostic-admit.txt", Posix.FileSys.S.flags []);
val _ = print "MARKER_UNREADABLE\n";
SML
    fi
    echo 'val _ = OS.Process.exit OS.Process.success;' >> "$project/src/AScript.sml"
    flags=(--check-only)
  fi
  echo 'val _ = print "AFTER_GATE\n";' >> "$project/src/AScript.sml"
  run_failure "$tmpdir/$gate.log" build "${flags[@]}" ATheory
  require_grep 'first proof error' "$tmpdir/$gate.log"
  if [[ "$gate" == unreadable-marker ]]; then
    require_grep '^MARKER_UNREADABLE$' "$(child_log)"
  fi
  reject_artifacts
  if grep -q 'AFTER_GATE\|holscriptend=' "$(child_log)"; then
    cat "$(child_log)" >&2
    exit 1
  fi
done

for terminal in static dynamic-static dynamic-try dynamic-choice dynamic-repeat parse exception interrupt termination; do
  make_project "$terminal"
  cat >> "$project/src/AScript.sml" <<'SML'
val _ = print "AScript.sml:1: error: output from a successful declaration\n";
val _ = print "Exception raised by a successful declaration\n";
SML
  case "$terminal" in
    static) echo 'val _ : int = true;' >> "$project/src/AScript.sml"; error='incompatible types' ;;
    exception) echo 'val _ = raise Fail "terminal declaration";' >> "$project/src/AScript.sml"; error='terminal declaration' ;;
    dynamic-*)
      case "$terminal" in
        dynamic-static) tactic='compile_invalid_ml' ;;
        dynamic-try) tactic='TRY compile_invalid_ml >> ACCEPT_TAC TRUTH' ;;
        dynamic-choice) tactic='compile_invalid_ml ORELSE ACCEPT_TAC TRUTH' ;;
        dynamic-repeat) tactic='REPEAT compile_invalid_ml >> ACCEPT_TAC TRUTH' ;;
      esac
      cat >> "$project/src/AScript.sml" <<SML
fun compile_invalid_ml g =
  let val input = TextIO.openString "val _ : int = true;"
  in PolyML.compiler (fn () => TextIO.input1 input, []) (); ALL_TAC g end;

Theorem compiles_invalid_ml:
  T /\ T
Proof
  CONJ_TAC >>
  $tactic
QED
SML
      error='Static Errors'
      dynamic_line=$(awk '/^  (TRY |REPEAT )?compile_invalid_ml/{print NR; exit}' "$project/src/AScript.sml") ;;
    interrupt)
      cat >> "$project/src/AScript.sml" <<'SML'
val overflow_tac : tactic = fn _ => raise Interrupt;

Theorem interrupted:
  T
Proof
  overflow_tac >> ACCEPT_TAC TRUTH
QED
SML
      error='interrupted by Poly/ML' ;;
    parse) echo 'Theorem malformed: T Proof simp[] QED' >> "$project/src/AScript.sml"; error='parse error:' ;;
    termination)
      cat >> "$project/src/AScript.sml" <<'SML'
Theorem countdown_def:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Definition countdown_def:
  countdown n = if n = 0 then 0 else countdown (n - 1)
Termination
  qexists_tac `measure I` >> FAIL_TAC "termination stopped"
End
SML
      error='termination stopped'
      termination_line=$(awk '/FAIL_TAC "termination stopped"/{print NR; exit}' "$project/src/AScript.sml") ;;
  esac
  echo 'val _ = print "AFTER_TERMINAL\n";' >> "$project/src/AScript.sml"
  run_failure "$tmpdir/$terminal.log" build ATheory
  require_grep '^theorem: first (line 4)$' "$tmpdir/$terminal.log"
  require_grep '^additional failure 1 of 1:$' "$tmpdir/$terminal.log"
  require_grep "  error: .*$error" "$tmpdir/$terminal.log"
  if sed -n '/^additional failure /,/^instrumented log:/p' "$tmpdir/$terminal.log" |
      grep -qE 'by a successful declaration|output from a successful declaration'; then
    cat "$tmpdir/$terminal.log" >&2
    exit 1
  fi
  if [[ "$terminal" == termination ]]; then
    require_grep "^  source line: $termination_line$" "$tmpdir/$terminal.log"
  elif [[ "$terminal" == dynamic-* ]]; then
    require_grep "^  source line: $dynamic_line$" "$tmpdir/$terminal.log"
    require_grep '^  top goal: T$' "$tmpdir/$terminal.log"
  fi
  if grep -q '^AFTER_TERMINAL$' "$(child_log)"; then
    cat "$(child_log)" >&2
    exit 1
  fi
done

# Machine-readable command summaries describe only the primary error.
make_project command-summary
cat >> "$project/src/AScript.sml" <<'SML'

Theorem malformed: T Proof simp[] QED
val _ = print "AFTER_TERMINAL\n";
SML
if (cd "$project" && HOLBUILD_COMMAND_RECORD="$tmpdir/command.json" exec env \
      HOLBUILD_COMMAND_RECORD_PID="$BASHPID" "${REAL_HOLBUILD_BIN:-$HOLBUILD_BIN}" build ATheory) \
    > "$tmpdir/command.log" 2>&1; then
  echo "proof with an additional parse error passed" >&2
  exit 1
fi
require_grep '^additional failure 1 of 1:$' "$tmpdir/command.log"
python3 - "$tmpdir/command.json" <<'PYTHON'
import json
import sys

with open(sys.argv[1]) as record:
    failure, = json.load(record)["failures"]
assert failure["kind"] == "proof_failure" and failure["theorem"] == "first", failure
assert "first proof error" in failure["error"] and "additional failure" not in failure["error"], failure
PYTHON

make_project count-cap
for n in {2..9}; do
  cat >> "$project/src/AScript.sml" <<SML
Theorem fails_$n:
  F
Proof
  NO_TAC
QED
SML
done
run_failure "$tmpdir/count-cap.log" build --skip-checkpoints ATheory
require_grep '^additional failure 7 of 7:$' "$tmpdir/count-cap.log"
if grep -q 'fails_9' "$(child_log)"; then
  cat "$(child_log)" >&2
  exit 1
fi

make_project time-cap
cat >> "$project/src/AScript.sml" <<'SML'

fun Z3_TAC g = (OS.Process.sleep (Time.fromSeconds 60); ALL_TAC g);

Theorem before_deadline:
  T
Proof
  Z3_TAC >> ACCEPT_TAC TRUTH
QED

val _ = print "AFTER_DEADLINE\n";
SML
run_failure "$tmpdir/time-cap.log" build --skip-checkpoints ATheory
require_grep 'holbuild tactic timeout after .*s: Z3_TAC' "$tmpdir/time-cap.log"
python3 - "$tmpdir/time-cap.log" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()
seconds = float(re.search(r"timeout after (\d+(\.\d+)?)s: Z3_TAC", text)[1])
assert 0 < seconds <= 10, text
PY
if grep -q '^AFTER_DEADLINE$' "$(child_log)"; then
  cat "$(child_log)" >&2
  exit 1
fi

# The opt-out travels with the spec. Both worker runs fail, so even after
# the continuation the remote cache contains no successful action result.
make_project worker
cat >> "$project/src/AScript.sml" <<'SML'

Theorem worker_second:
  T
Proof
  FAIL_TAC "second worker proof error"
QED

val _ = OS.Process.exit OS.Process.success;
SML
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server" "$tmpdir/control"
for mode in default fail-fast; do
  flags=()
  [[ "$mode" != fail-fast ]] || flags=(--fail-fast)
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload "${flags[@]}" ATheory) \
    > "$tmpdir/$mode.batch"
  spec=$(awk '$1 == "action" && $5 == "diagnostics:ATheory" { print $4 }' "$tmpdir/$mode.batch")
  spec_file=$project/.holbuild/action-specs/$spec
  if [[ "$mode" == fail-fast ]]; then
    require_grep '^option fail-fast=true$' "$spec_file"
  elif grep -q '^option fail-fast=' "$spec_file"; then
    cat "$spec_file" >&2
    exit 1
  fi
  worker=$tmpdir/worker-$mode
  link_hol_toolchain_cache "$worker/cache"
  result=$worker/result
  if (cd "$worker" && HOLBUILD_CACHE=$worker/cache \
    "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$spec" --cache-limit-gb 1000 --result "$result") \
    > "$worker/out" 2>&1; then
    echo "worker accepted failed theory ($mode)" >&2
    exit 1
  fi
  require_grep '^status=failed$' "$result"
  require_grep '^failure=proof$' "$result"
  log_sha=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$result")
  curl -fsS "$remote_url/cas/$log_sha" > "$worker/child.log"
  if [[ "$mode" == fail-fast ]]; then
    if grep -q 'second worker proof error\|continuing after first failure' "$worker/child.log"; then
      cat "$worker/child.log" >&2
      exit 1
    fi
  else
    require_grep '^additional failure 1 of 1:$' "$worker/child.log"
    require_grep 'second worker proof error' "$worker/child.log"
  fi
  input_key=$(sed -n 's/^input-key=//p' "$spec_file")
  action_entry=$(printf 'holbuild-remote-ac-v1\n%s\n' "$input_key" | sha256sum | cut -d' ' -f1)
  if [[ -e "$tmpdir/remote/ac/$action_entry" ]]; then
    echo "worker published a failed theory ($mode)" >&2
    exit 1
  fi
done
