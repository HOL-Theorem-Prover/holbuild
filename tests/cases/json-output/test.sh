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
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"

cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "json-output"

[build]
members = ["src"]
TOML

cat > "$project/src/JScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "J";
Theorem j_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML

json_stdout=$tmpdir/json.stdout
json_stderr=$tmpdir/json.stderr
(cd "$project" && "$HOLBUILD_BIN" --json build JTheory) > "$json_stdout" 2> "$json_stderr"
require_file "$project/.holbuild/obj/src/JTheory.dat"
if [[ -s "$json_stderr" ]]; then
  echo "json mode wrote to stderr" >&2
  cat "$json_stderr" >&2
  exit 1
fi

python3 - "$json_stdout" <<'PY'
import json
import sys

path = sys.argv[1]
lines = [line.rstrip('\n') for line in open(path, encoding='utf-8') if line.strip()]
if not lines:
    raise SystemExit('no json output')
events = []
for line in lines:
    if not line.startswith('{'):
        raise SystemExit(f'non-json output: {line!r}')
    events.append(json.loads(line))
if not any(e.get('event') == 'node_finished' and e.get('target') == 'JTheory' and e.get('outcome') == 'built' for e in events):
    raise SystemExit('missing JTheory built node_finished event')
started = [e for e in events if e.get('event') == 'node_started' and e.get('target') == 'JTheory']
finished = [e for e in events if e.get('event') == 'node_finished' and e.get('target') == 'JTheory']
if not started or not finished or started[-1].get('key') != finished[-1].get('key'):
    raise SystemExit('node start/finish keys do not correlate')
for event in started + finished:
    key = event.get('key', '')
    if '\x00' in key or '\\u0000' in key:
        raise SystemExit(f'node key exposes internal NUL-delimited action key: {key!r}')
    if not key.startswith(event.get('target', '') + '#'):
        raise SystemExit(f'node key does not include display target: {key!r}')
    if event.get('package') != 'json-output' or event.get('source') != 'src/JScript.sml':
        raise SystemExit(f'node event lost source metadata: {event!r}')
if not any(e.get('event') == 'build_finished' and isinstance(e.get('elapsed_ms'), int) for e in events):
    raise SystemExit('missing build_finished elapsed event')
if any('\\u0000' in line or '\x1b' in line or '\r' in line for line in lines):
    raise SystemExit('internal keys or status redraw escaped into json output')
PY

if grep -q "JTheory built" "$json_stdout"; then
  echo "plain status output escaped into json mode" >&2
  exit 1
fi

bad_project=$tmpdir/bad-project
mkdir -p "$bad_project/src"
cp "$project/holproject.toml" "$bad_project/holproject.toml"
python3 - <<PY
from pathlib import Path
long_goal = "p" * 5000
Path("$bad_project/src/BadScript.sml").write_text(f'''open HolKernel Parse boolLib bossLib;
val _ = new_theory "Bad";
Theorem bad_thm:
  {long_goal}
Proof
  FAIL_TAC "json failure"
QED
val _ = export_theory();
''')
PY

fail_stdout=$tmpdir/fail.stdout
fail_stderr=$tmpdir/fail.stderr
if (cd "$bad_project" && "$HOLBUILD_BIN" --json build BadTheory) > "$fail_stdout" 2> "$fail_stderr"; then
  echo "expected json failure build to fail" >&2
  exit 1
fi
if [[ -s "$fail_stderr" ]]; then
  echo "json failure mode wrote to stderr" >&2
  cat "$fail_stderr" >&2
  exit 1
fi

python3 - "$fail_stdout" "$bad_project" <<'PY'
import json
import sys
from pathlib import Path

path = sys.argv[1]
project = Path(sys.argv[2])
events = []
for line in open(path, encoding='utf-8'):
    line = line.rstrip('\n')
    if not line:
        continue
    if not line.startswith('{'):
        raise SystemExit(f'non-json failure output: {line!r}')
    events.append(json.loads(line))
if any('log' in event or 'debug_artifacts' in event for event in events):
    raise SystemExit(f'json mode should not expose retained debug artifact paths: {events!r}')
errors = [e for e in events if e.get('event') == 'error']
if not errors:
    raise SystemExit('missing structured error event')
message = '\n'.join(e.get('message', '') for e in errors)
if 'failed tactic top input goal:' not in message:
    raise SystemExit('structured error did not include top-goal context')
if 'json failure' not in message:
    raise SystemExit('structured error lost failure detail')
if 'instrumented log:' in message or 'child log:' in message:
    raise SystemExit(f'structured error exposed a log path: {message!r}')
failed = [e for e in events if e.get('event') == 'node_failed' and e.get('target') == 'BadTheory']
if not failed:
    raise SystemExit('missing node_failed event')
for event in failed:
    if event.get('package') != 'json-output' or event.get('source') != 'src/BadScript.sml':
        raise SystemExit(f'node_failed lost source metadata: {event!r}')
    if '\x00' in event.get('key', '') or '\\u0000' in event.get('key', ''):
        raise SystemExit(f'node_failed key exposes internal NUL key: {event!r}')
    failure = event.get('failure')
    if not isinstance(failure, dict):
        raise SystemExit(f'node_failed missing failure object: {event!r}')
    if failure.get('kind') != 'proof_failure':
        raise SystemExit(f'unexpected failure kind: {failure!r}')
    if failure.get('theorem') != 'bad_thm':
        raise SystemExit(f'failure lost theorem name: {failure!r}')
    if failure.get('source_file') != 'src/BadScript.sml' or not isinstance(failure.get('source_line'), int):
        raise SystemExit(f'failure lost source location: {failure!r}')
    if 'FAIL_TAC "json failure"' not in failure.get('plan_position', ''):
        raise SystemExit(f'failure lost plan position: {failure!r}')
    if failure.get('input_goal_count') != 1:
        raise SystemExit(f'failure lost input goal count: {failure!r}')
    if failure.get('top_goal_truncated') is not True:
        raise SystemExit(f'failure did not report top-goal truncation: {failure!r}')
    if failure.get('top_goal_preview_bytes') != 4096 or failure.get('evidence_mode') != 'preview_only':
        raise SystemExit(f'failure lost bounded evidence metadata: {failure!r}')
for subdir in ['logs', 'stage']:
    root = project / '.holbuild' / subdir
    if root.exists() and any(root.rglob('*')):
        raise SystemExit(f'json mode left stateful {subdir} files under {root}')
PY

retain_stdout=$tmpdir/retain.stdout
retain_stderr=$tmpdir/retain.stderr
if (cd "$bad_project" && "$HOLBUILD_BIN" --json build --retain-debug-artifacts BadTheory) > "$retain_stdout" 2> "$retain_stderr"; then
  echo "expected retained json failure build to fail" >&2
  exit 1
fi
if [[ -s "$retain_stderr" ]]; then
  echo "retained json failure mode wrote to stderr" >&2
  cat "$retain_stderr" >&2
  exit 1
fi

python3 - "$retain_stdout" "$bad_project" <<'PY'
import json
import sys
from pathlib import Path

path = sys.argv[1]
project = Path(sys.argv[2])
events = [json.loads(line) for line in open(path, encoding='utf-8') if line.strip()]
if any('log' in event for event in events):
    raise SystemExit(f'retained json should not restore top-level log fields: {events!r}')
failed = [e for e in events if e.get('event') == 'node_failed' and e.get('target') == 'BadTheory']
errors = [e for e in events if e.get('event') == 'error']
if not failed or not errors:
    raise SystemExit(f'missing retained failure/error events: {events!r}')
for event in failed + errors:
    artifacts = event.get('debug_artifacts')
    if not isinstance(artifacts, dict) or not artifacts.get('log'):
        raise SystemExit(f'retained failure missing debug_artifacts.log: {event!r}')
    log = project / artifacts['log'] if not Path(artifacts['log']).is_absolute() else Path(artifacts['log'])
    if not log.is_file():
        raise SystemExit(f'debug_artifacts.log does not exist: {log}')
    text = log.read_text(encoding='utf-8', errors='replace')
    if 'json failure' not in text or 'p' * 5000 not in text:
        raise SystemExit('retained debug log lost full failure context')
message = '\n'.join(e.get('message', '') for e in errors)
if 'instrumented log:' in message or 'child log:' in message:
    raise SystemExit(f'retained json message exposed legacy log text: {message!r}')
stage = project / '.holbuild' / 'stage'
if stage.exists() and any(stage.rglob('*')):
    raise SystemExit(f'retained debug artifacts should not retain stage files under {stage}')
PY

trace_stdout=$tmpdir/trace.stdout
trace_stderr=$tmpdir/trace.stderr
if (cd "$project" && "$HOLBUILD_BIN" --json build --goalfrag-trace JTheory) > "$trace_stdout" 2> "$trace_stderr"; then
  echo "expected json trace stub to reject --goalfrag-trace" >&2
  exit 1
fi
if [[ -s "$trace_stderr" ]]; then
  echo "json trace rejection wrote to stderr" >&2
  cat "$trace_stderr" >&2
  exit 1
fi
python3 - "$trace_stdout" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8') if line.strip()]
message = '\n'.join(e.get('message', '') for e in events if e.get('event') == 'error')
if 'structured proof_trace events' not in message:
    raise SystemExit(f'json trace rejection did not explain proof_trace stub: {message!r}')
PY

gen_fail_project=$tmpdir/gen-fail-project
mkdir -p "$gen_fail_project"
cat > "$gen_fail_project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "json-generator-failure"

[build]
members = []

[[generate]]
name = "bad-gen"
command = ["python3", "-c", "import sys; print('generator boom'); sys.exit(7)"]
outputs = ["gen/out.txt"]
TOML

gen_fail_stdout=$tmpdir/gen-fail.stdout
gen_fail_stderr=$tmpdir/gen-fail.stderr
if (cd "$gen_fail_project" && "$HOLBUILD_BIN" --json build) > "$gen_fail_stdout" 2> "$gen_fail_stderr"; then
  echo "expected json generator failure to fail" >&2
  exit 1
fi
if [[ -s "$gen_fail_stderr" ]]; then
  echo "json generator failure wrote to stderr" >&2
  cat "$gen_fail_stderr" >&2
  exit 1
fi

python3 - "$gen_fail_stdout" "$gen_fail_project" <<'PY'
import json
import sys
from pathlib import Path

path = sys.argv[1]
project = Path(sys.argv[2])
events = []
for line in open(path, encoding='utf-8'):
    line = line.rstrip('\n')
    if not line:
        continue
    if not line.startswith('{'):
        raise SystemExit(f'non-json generator failure output: {line!r}')
    events.append(json.loads(line))
if any('log' in event or 'debug_artifacts' in event for event in events):
    raise SystemExit(f'json generator failure exposed a debug artifact path: {events!r}')
message = '\n'.join(e.get('message', '') for e in events if e.get('event') == 'error')
if 'generator bad-gen failed' not in message or 'generator boom' not in message:
    raise SystemExit(f'json generator failure lost message/output: {message!r}')
if '.log' in message or 'log:' in message:
    raise SystemExit(f'json generator failure exposed log text/path: {message!r}')
holbuild = project / '.holbuild'
if holbuild.exists() and any(holbuild.rglob('*.log')):
    raise SystemExit(f'json generator failure left log files under {holbuild}')
PY

gen_retain_stdout=$tmpdir/gen-retain.stdout
gen_retain_stderr=$tmpdir/gen-retain.stderr
if (cd "$gen_fail_project" && "$HOLBUILD_BIN" --json build --retain-debug-artifacts) > "$gen_retain_stdout" 2> "$gen_retain_stderr"; then
  echo "expected retained json generator failure to fail" >&2
  exit 1
fi
if [[ -s "$gen_retain_stderr" ]]; then
  echo "retained json generator failure wrote to stderr" >&2
  cat "$gen_retain_stderr" >&2
  exit 1
fi

python3 - "$gen_retain_stdout" "$gen_fail_project" <<'PY'
import json
import sys
from pathlib import Path

path = sys.argv[1]
project = Path(sys.argv[2])
events = [json.loads(line) for line in open(path, encoding='utf-8') if line.strip()]
errors = [e for e in events if e.get('event') == 'error']
if not errors:
    raise SystemExit(f'missing retained generator error event: {events!r}')
for event in errors:
    if 'log' in event:
        raise SystemExit(f'retained generator error restored top-level log: {event!r}')
    artifacts = event.get('debug_artifacts')
    if not isinstance(artifacts, dict) or not artifacts.get('log'):
        raise SystemExit(f'retained generator error missing debug_artifacts.log: {event!r}')
    log = project / artifacts['log'] if not Path(artifacts['log']).is_absolute() else Path(artifacts['log'])
    if not log.is_file():
        raise SystemExit(f'generator debug_artifacts.log does not exist: {log}')
    text = log.read_text(encoding='utf-8', errors='replace')
    if 'generator boom' not in text:
        raise SystemExit(f'generator debug log lost output: {text!r}')
message = '\n'.join(e.get('message', '') for e in errors)
if 'generator bad-gen failed' not in message or 'generator boom' not in message:
    raise SystemExit(f'retained generator failure lost bounded message/output: {message!r}')
PY
