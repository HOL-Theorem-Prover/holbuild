#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# The re-submit record's fast path in shadow mode: a remote check of one
# named theory computes the action the record says it would send, compares
# it and the outcome with the full path's, and says in the command summary
# what matched or why it declined.

tmpdir=$(make_temp_dir)
cleanup() {
  for pid in ${server_pid:-} ${coordinator_pid:-} ${landed_pid:-}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
use_case_cache "$tmpdir/cache"

# Stand-in workers: run each action with exec-action, in order, until one
# fails; a theory named in fail-missing ("THEORY blob SHA256") is first
# reported missing that blob, once.
state=$tmpdir/coordinator
mkdir -p "$state" "$tmpdir/worker-cwd"
link_hol_toolchain_cache "$tmpdir/worker-cache"
cat > "$tmpdir/run-batch" <<SH
#!/usr/bin/env bash
set -eu
cd "$tmpdir/worker-cwd"
awk '\$1 == "action" { print \$2, \$4, \$5 }' "\$1" | while read -r key spec theory; do
  if [[ -e "$state/fail-missing" && "\$(cut -d' ' -f1 "$state/fail-missing")" == "\$theory" ]]; then
    cut -d' ' -f2- "$state/fail-missing" > "$state/missing"
    rm "$state/fail-missing"
    exit 1
  fi
  status=0
  HOLBUILD_CACHE="$tmpdir/worker-cache" "$HOLBUILD_BIN" --remote-cache "$remote_url" \
    exec-action "\$spec" --cache-limit-gb 1000 --result "$tmpdir/worker.result" >> "$tmpdir/worker.log" 2>&1 || status=\$?
  cp "$tmpdir/worker.result" "$state/result-\$key"
  [[ \$status -eq 0 ]] || exit 1
done
SH
chmod +x "$tmpdir/run-batch"
python3 "$SCRIPT_DIR/../../fixtures/remote_exec_coordinator.py" \
  "$state/port" "$state" "$tmpdir/run-batch" &
coordinator_pid=$!
for _ in {1..100}; do
  [[ -s "$state/port" ]] && break
  sleep 0.01
done
coordinator="http://127.0.0.1:$(< "$state/port")"
export HOLBUILD_TEST_RETRY_DELAYS=0,0,0,0

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rr"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Theorem a_thm:
  T
Proof
  simp[]
QED
SML
# write_b STAMP [ANCESTORS [TACTIC]]: an edit of B's proof alone.
write_b() {
  cat > "$project/src/BScript.sml" <<SML
Theory B
Ancestors ${2:-A}

Theorem b_thm:
  T
Proof
  ${3:-ACCEPT_TAC a_thm} (* $1 *)
QED
SML
}

# check NAME EXPECTED-EXIT [BUILD-ARGS...]: a remote check of BTheory, its
# output in NAME.log and its command summary in NAME.json; it runs the binary
# itself, not the suite's timing wrapper, for its own PID's record.
check() {
  local name=$1 code=$2 status=0
  shift 2
  (cd "$project" && HOLBUILD_COMMAND_RECORD="$tmpdir/$name.json" exec env HOLBUILD_COMMAND_RECORD_PID=$BASHPID \
     "${REAL_HOLBUILD_BIN:-$HOLBUILD_BIN}" --remote-cache "$remote_url" build --remote-exec "$coordinator" --remote-only "$@" BTheory) \
    > "$tmpdir/$name.log" 2>&1 || status=$?
  if [[ $status -ne $code ]]; then
    echo "$name exited $status, wanted $code" >&2
    cat "$tmpdir/$name.log" >&2
    exit 1
  fi
}

# shadow NAME KEY=VALUE...: the summary's resubmit_shadow holds each pair;
# fields.F names a compared field, and reason~TEXT a reason starting so.
shadow() {
  python3 - "$tmpdir/$1.json" "${@:2}" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
shadow = record.get("resubmit_shadow")
for pair in sys.argv[2:]:
    if "~" in pair:
        key, want = pair.split("~", 1)
        got = (shadow or {}).get(key)
        ok = isinstance(got, str) and got.startswith(want)
    else:
        key, want = pair.split("=", 1)
        got = shadow
        for part in key.split("."):
            got = (got or {}).get(part)
        ok = str(got) == want
    if not ok:
        sys.exit(f"{sys.argv[1]}: resubmit_shadow {key} is {got!r}, wanted {want!r}: {json.dumps(shadow)}")
PY
}

# Rewrites one item of the re-submit record: on line TAG, in field FIELD,
# the item starting PREFIX gets the value VALUE.
spoil_record() {
  python3 - "$project/.holbuild/resubmit" "$@" <<'PY'
import os, sys
directory, tag, field, prefix, value = sys.argv[1:]
[name] = os.listdir(directory)
path = os.path.join(directory, name)
lines = open(path).read().split("\n")
for i, line in enumerate(lines):
    if line.startswith(tag):
        fields = line[1:].split("\x01")
        items = fields[int(field)].split("\x02")
        items = [prefix + value if item.startswith(prefix) else item for item in items]
        assert any(item == prefix + value for item in items), (line, prefix)
        fields[int(field)] = "\x02".join(items)
        lines[i] = tag + "\x01".join(fields)
open(path, "w").write("\n".join(lines))
PY
}

all_fields=(fields.action_bytes=match fields.verdict=match fields.diagnostics=match fields.exit_status=match fields.json_events=match)

# The first check sends A and B, of which no record is written; the second
# sends B alone and writes the record the third uses.
write_b 0
check first 0
shadow first state=declined "reason=no re-submit record" matches=0
[[ ! -d "$project/.holbuild/resubmit" ]] || { echo "record written for a batch of two" >&2; exit 1; }
write_b 1
check second 0
shadow second state=declined "reason=no re-submit record"
[[ -n $(ls "$project/.holbuild/resubmit") ]] || { echo "no re-submit record" >&2; exit 1; }
echo "PASS record written for a batch of the target alone"

write_b 2
check match 0
shadow match state=compared matches=5 mismatches=0 "${all_fields[@]}"
write_b 3 A 'FAIL_TAC "edit 3"'
check match-fail 1
shadow match-fail state=compared matches=5 mismatches=0 "${all_fields[@]}"
echo "PASS fast path matches the full path on a pass and a failure"

# Each outcome field, spoiled on the fast side, is counted as a mismatch.
write_b 4
HOLBUILD_TEST_RESUBMIT_SHADOW_PERTURB=verdict,diagnostics,exit_status,json_events check perturbed 0
shadow perturbed state=compared matches=1 mismatches=4 fields.action_bytes=match fields.verdict=mismatch \
  fields.diagnostics=mismatch fields.exit_status=mismatch fields.json_events=mismatch
# A stale record field makes the action differ.
spoil_record p 2 '' "$(printf '0%.0s' {1..64})"
write_b 5
check stale-spec 0
shadow stale-spec state=compared matches=0 mismatches=1 fields.action_bytes=mismatch "detail~action_bytes: spec differ"
echo "PASS each kind of mismatch is counted"

# Declines, each with its reason.
spoil_record I 0 action-toolchain= other
write_b 6
check toolchain-key 0
shadow toolchain-key state=declined "reason=the action toolchain key changed" matches=0
spoil_record I 0 runtime= other
write_b 7
check runtime 0
shadow runtime state=declined "reason=the runtime identity changed"
write_b 8
check option 0 -j1
shadow option state=declined "reason=the execution options changed"
write_b 9
check reset 0
shadow reset state=declined "reason=the execution options changed"
write_b 10
check reset-done 0
shadow reset-done state=compared mismatches=0
write_b 11
HOLBUILD_TIMING_SOURCE_LOADS=1 check timing 0
shadow timing state=declined "reason=the execution options changed"
write_b 12
check timing-reset 0
shadow timing-reset state=declined "reason=the execution options changed"

sed -i 's/simp\[\]/simp[] (* A edited *)/' "$project/src/AScript.sml"
write_b 13
check cone-stat 0
shadow cone-stat state=declined "reason~file changed: " "reason~file changed: $project/src/AScript.sml"
cat > "$project/src/CScript.sml" <<'SML'
Theory C
Ancestors bool
SML
# Past the racy window, so the next record holds src's stat, not its listing.
sleep 2
write_b 14
check new-file 0
shadow new-file state=declined "reason=files added, removed or renamed in $project/src"
# A change of mode leaves the directory's stat alone.
chmod 000 "$project/src/CScript.sml"
write_b 14u
check unreadable 0
shadow unreadable state=declined "reason=a source became unreadable in $project/src"
chmod 644 "$project/src/CScript.sml"
write_b 14r
check readable 0
shadow readable state=declined "reason=an unreadable entry became readable in $project/src"
write_b 15 'A bool'
check deps 0
shadow deps state=declined "reason=the script's dependency facts changed"
write_b 16 'A bool'
check deps-done 0
shadow deps-done state=compared mismatches=0

echo "rr:BTheory blob $(printf 'f%.0s' {1..64})" > "$state/fail-missing"
write_b 17 'A bool'
check missing 0
shadow missing state=declined "reason=the batch came back for missing inputs" fields.action_bytes=match
require_grep "resubmitting" "$tmpdir/missing.log"

# An edit landing after the batch ran, before the check reads its answer.
gate=$tmpdir/followed-gate
mkfifo "$gate"
write_b 18 'A bool'
HOLBUILD_TEST_RESUBMIT_FOLLOWED_GATE=$gate check landed 0 &
landed_pid=$!
for _ in {1..600}; do
  grep -q "remote rr:BTheory: done" "$tmpdir/landed.log" 2>/dev/null && break
  sleep 0.1
done
require_grep "remote rr:BTheory: done" "$tmpdir/landed.log"
write_b 19 'A bool'
# The client opens the gate only if the fast path was ready; don't hang if not.
timeout 60 bash -c 'echo go > "$1"' _ "$gate" || { echo "the check never reached the gate" >&2; exit 1; }
wait "$landed_pid"
shadow landed state=declined "reason=an edit landed while the check ran" fields.action_bytes=match \
  fields.verdict=mismatch fields.diagnostics=mismatch fields.exit_status=mismatch fields.json_events=mismatch
echo "PASS fast path declines on each change it can't take"

# A full path that sends no action (the script is back to a version the
# cache holds) differs from the fast path's.
write_b 16 'A bool'
check cached 0
shadow cached state=compared matches=0 mismatches=1 fields.action_bytes=mismatch "detail~action_bytes: the full path"
echo "PASS a full path that sends no action is counted as a mismatch"
