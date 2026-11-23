#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# exec-action reports `unavailable` when the remote cache gives no answer, 429
# or 5xx: fetching the spec, publishing the result or reading it back.  The
# coordinator retries that without counting the attempt.  A remote entry
# with different outputs is still a `publish` failure.

tmpdir=$(make_temp_dir)
cleanup() {
  local pid
  for pid in "${server_pid:-}" "${second_pid:-}"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

remote_root=$tmpdir/remote
control=$tmpdir/control
start_remote_cache_server "$remote_root" "$tmpdir/server" "$control"
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "worker"

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
cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors A

Theorem b_thm:
  T
Proof
  simp[]
QED
SML

(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload ATheory) > "$tmpdir/batch.txt"
spec=$(awk '$1 == "action" && $5 == "worker:ATheory" { print $4 }' "$tmpdir/batch.txt")
ac=$(awk '$1 == "action" && $5 == "worker:ATheory" { print $3 }' "$tmpdir/batch.txt")
[[ -n "$spec" && -n "$ac" ]] || { cat "$tmpdir/batch.txt" >&2; exit 1; }

# exec-action asks a cache of one node again for 90 s before it gives up;
# these cases want its answer at once.  The cache's restarts are below.
export HOLBUILD_TEST_CACHE_RETRY_DELAYS=

# worker NAME [URL]: exec-action in NAME's own cache root, against URL
# (default: the stub cache); the record goes to $tmpdir/NAME.result.
worker() {
  local name=$1 url=${2:-$remote_url}
  local cache=$tmpdir/worker-$name
  link_hol_toolchain_cache "$cache"
  mkdir -p "$tmpdir/cwd-$name"
  set +e
  (cd "$tmpdir/cwd-$name" &&
     HOLBUILD_CACHE=$cache "$HOLBUILD_BIN" --remote-cache "$url" exec-action "$spec" \
       --cache-limit-gb 1000 --result "$tmpdir/$name.result") > "$tmpdir/$name.log" 2>&1
  worker_status=$?
  set -e
}

# expect NAME EXIT FAILURE MESSAGE: the worker's exit code, its failure, and
# a line of its log.  Nothing calls a cache outage a conflict.
expect() {
  local name=$1 code=$2 failure=$3 message=$4
  if [[ "$worker_status" != "$code" ]] || ! grep -qx "failure=$failure" "$tmpdir/$name.result"; then
    echo "worker $name exited $worker_status, wanted $code and failure=$failure" >&2
    cat "$tmpdir/$name.result" "$tmpdir/$name.log" >&2 || true
    exit 1
  fi
  require_grep "$message" "$tmpdir/$name.log"
  if grep -qi conflict "$tmpdir/$name.log"; then
    echo "worker $name calls the failure a conflict" >&2
    cat "$tmpdir/$name.log" >&2
    exit 1
  fi
}

# Fetching the spec: a 503, a 429, and no answer at all.
echo 503 > "$control/get-status"
worker spec-503
expect spec-503 3 unavailable "remote cache server error: HTTP 503 for GET"
echo 429 > "$control/get-status"
worker spec-429
expect spec-429 3 unavailable "remote cache server error: HTTP 429 for GET"
rm "$control/get-status"
worker no-answer http://127.0.0.1:1
expect no-answer 3 unavailable "no answer from the remote cache to GET"

# Publishing: the worker builds, then the cache fails the blob PUTs.
echo 500 > "$control/cas-put-status"
worker w
expect w 3 unavailable "remote cache server error: HTTP 500 for PUT"
rm "$control/cas-put-status"
[[ ! -e "$remote_root/ac/$ac" ]] || { echo "the entry was published" >&2; exit 1; }

# The worker now holds the entry locally and publishes it again; the cache
# fails the action PUT, then the read-back of the action.
echo 429 > "$control/ac-put-status"
worker w
expect w 3 unavailable "remote cache server error: HTTP 429 for PUT"
rm "$control/ac-put-status"
echo 500 > "$control/ac-get-status"
worker w
expect w 3 unavailable "remote cache server error: HTTP 500 for GET"
rm "$control/ac-get-status"

# Waits up to 30 s for a line matching $1 in the file $2.
await_line() {
  local i
  for i in $(seq 300); do
    grep -q "$1" "$2" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# With the cache back, the same worker publishes it, though the cache
# answers its action PUT 429 until the worker has said it will ask again.
echo 429 > "$control/ac-put-status"
rm -f "$tmpdir/w.log"
(await_line "answered HTTP 429; retrying" "$tmpdir/w.log"; rm "$control/ac-put-status") &
HOLBUILD_TEST_CACHE_RETRY_DELAYS=2,2,2,2,2 worker w
grep -qx 'status=cached' "$tmpdir/w.result" || { cat "$tmpdir/w.result" "$tmpdir/w.log" >&2; exit 1; }
require_grep "remote cache PUT .* answered HTTP 429; retrying in 2 s" "$tmpdir/w.log"
require_file "$remote_root/ac/$ac"

# The cache's daemon is replaced, stopped before the new one listens on its
# port: a worker that starts meanwhile is refused until then, and goes on.
port=${remote_url##*:}
kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
HOLBUILD_TEST_CACHE_RETRY_DELAYS=2,2,2,2,2 worker swap &
swap_pid=$!
await_line "got no answer: .*; retrying" "$tmpdir/swap.log"
start_remote_cache_server "$remote_root" "$tmpdir/server-restarted" "$control" "$port"
wait "$swap_pid"
if ! grep -qx 'status=cached' "$tmpdir/swap.result"; then
  echo "the worker didn't ride out the cache's restart" >&2
  cat "$tmpdir/swap.result" "$tmpdir/swap.log" >&2 || true
  exit 1
fi
require_grep "remote cache GET .* got no answer: .*; retrying in 2 s" "$tmpdir/swap.log"

# Two builds of one action can record different proof dependencies, as when
# their proofs took different paths.  The .dat files then differ only in what
# the digest in the .sml leaves out.  dep_only_resident TIMEOUT makes the
# remote's entry such a build's, with proof-timeout TIMEOUT, from the worker's
# entry the remote held.
cp "$remote_root/ac/$ac" "$tmpdir/own-entry"
dep_only_resident() {
  python3 - "$remote_root" "$ac" "$tmpdir/own-entry" "$1" <<'PY'
import hashlib, pathlib, re, sys
root, ac, own, timeout = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
head, manifest = pathlib.Path(own).read_text().split("manifest-text-v1\n", 1)
old = re.search(r"^blob dat (\S+)$", manifest, re.M).group(1)
dat = (root / "cas" / old).read_text()
# a_thm's record: ((own theory, index) (bool, theorem)) "DISK_THM"; add bool
# theorem 0 as a dependency.
record = re.search(r'\(\(\(\d+ \d+\) \((\d+) (\d+)\)\) "DISK_THM"\)', dat)
if record is None or record.group(2) == "0":
    sys.exit("a_thm has no dependency record to change")
dat = dat[:record.end(1)] + " 0" + dat[record.end(1):]
data = dat.encode()
new = hashlib.sha256(data).hexdigest()
(root / "cas" / new).write_bytes(data)
manifest = manifest.replace(f"blob dat {old}\n", f"blob dat {new}\n")
manifest = re.sub(r"^proof-timeout=.*$", f"proof-timeout={timeout}", manifest, flags=re.M)
out = []
for line in head.split("\n"):
    if line.startswith("manifest-sha256 "):
        line = "manifest-sha256 " + hashlib.sha256(manifest.encode()).hexdigest()
    elif line.startswith("manifest-size "):
        line = "manifest-size " + str(len(manifest.encode()))
    elif line.startswith(f"blob {old} "):
        line = f"blob {new} {len(data)}"
    out.append(line)
(root / "ac" / ac).write_text("\n".join(out) + "manifest-text-v1\n" + manifest)
PY
}
# A worker that lost the race to publish keeps the remote's entry ...
dep_only_resident 2.5
cp "$remote_root/ac/$ac" "$tmpdir/dep-resident"
worker w
grep -qx 'status=cached' "$tmpdir/w.result" || { cat "$tmpdir/w.result" "$tmpdir/w.log" >&2; exit 1; }
cmp "$remote_root/ac/$ac" "$tmpdir/dep-resident"
# ... and replaces it when its timeout contract is weaker, as from a build
# without proof steps.
dep_only_resident none
worker w
grep -qx 'status=cached' "$tmpdir/w.result" || { cat "$tmpdir/w.result" "$tmpdir/w.log" >&2; exit 1; }
[[ $(sed -n '/^manifest-text-v1$/,$p' "$remote_root/ac/$ac") == $(sed -n '/^manifest-text-v1$/,$p' "$tmpdir/own-entry") ]] ||
  { echo "the weaker entry was not replaced" >&2; cat "$remote_root/ac/$ac" "$tmpdir/w.log" >&2; exit 1; }

# dead_node RANK: an unreachable node that ranks RANK (primary or backup)
# beside the stub cache for A's entry.
dead_node() {
  python3 - "$remote_url" "$ac" "$1" <<'PYCODE'
import hashlib, sys
healthy, digest, rank = sys.argv[1:]
score = lambda node: hashlib.sha256(f"{node}:{digest}".encode()).hexdigest()
for i in range(10000):
    node = f"http://127.0.0.1:1/{i}"
    if (score(node) > score(healthy)) == (rank == "primary"):
        print(node)
        break
else:
    raise SystemExit("could not choose dead primary")
PYCODE
}

# A new action must build and publish with either the primary or backup down.
# Its optional cache lookups and pre-PUT check see one transport failure and 404.
for rank in primary backup; do
  down=$(dead_node "$rank")
  rm "$remote_root/ac/$ac"
  worker "ring-$rank" "$down,$remote_url"
  if [[ "$worker_status" != 0 ]]; then
    cat "$tmpdir/ring-$rank.result" "$tmpdir/ring-$rank.log" >&2
    exit 1
  fi
  require_file "$remote_root/ac/$ac"
done

# Hydrating a dependency: B's worker fetches A's entry, and the cache
# answers 500 for it.  That is not a missing input.
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload BTheory) > "$tmpdir/batch-b.txt"
spec_a=$spec
spec=$(awk '$1 == "action" && $5 == "worker:BTheory" { print $4 }' "$tmpdir/batch-b.txt")
[[ -n "$spec" ]] || { cat "$tmpdir/batch-b.txt" >&2; exit 1; }
echo 500 > "$control/ac-get-status-$ac"
worker b
expect b 3 unavailable "remote cache server error: HTTP 500 for GET .*/ac/$ac"
# Nor is a 404 from one node while the other, which may hold the entry,
# gives no answer, whichever ranks first.
echo 404 > "$control/ac-get-status-$ac"
for rank in primary backup; do
  worker "b-ring-$rank" "$(dead_node "$rank"),$remote_url"
  expect "b-ring-$rank" 3 unavailable "no answer from the remote cache to GET .*/ac/$ac"
done
rm "$control/ac-get-status-$ac"
# Nor is an internal error restoring it: w holds A's entry but not its .dat,
# and the cache refuses that blob.
a_input=$(sed -n 's/^input_key=//p' "$remote_root/ac/$ac")
dat=$(sed -n 's/^blob dat //p' "$tmpdir/worker-w/actions/$a_input/manifest")
[[ -n "$dat" ]] || { echo "w holds no entry for A" >&2; exit 1; }
rm "$tmpdir/worker-w/blobs/$dat"
echo 403 > "$control/cas-get-status-$dat"
worker w
expect w 3 internal "cannot fetch blob $dat"
rm "$control/cas-get-status-$dat"
spec=$spec_a

# A traced rerun must return its new log even though the theory outputs are
# already published. An outage during that upload retries the action.
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --trace-steps --upload ATheory) > "$tmpdir/batch-traced.txt"
spec=$(awk '$1 == "action" && $5 == "worker:ATheory" { print $4 }' "$tmpdir/batch-traced.txt")
[[ -n "$spec" ]] || { cat "$tmpdir/batch-traced.txt" >&2; exit 1; }
printf 'holbuild proof-ir before theorem=a_thm ' > "$control/cas-put-reject-text"
worker traced-log
expect traced-log 3 unavailable "could not upload the required build log"
require_grep '^status=failed$' "$tmpdir/traced-log.result"
rm "$control/cas-put-reject-text"
worker traced-log
[[ "$worker_status" == 0 ]] || { cat "$tmpdir/traced-log.log" >&2; exit 1; }
require_grep '^status=built$' "$tmpdir/traced-log.result"
require_grep '^log=[0-9a-f]* ' "$tmpdir/traced-log.result"
spec=$spec_a

# sig_entry PATH TEXT TIMEOUT: writes at PATH the worker's own entry for A
# with the .sig blob TEXT, which the cache holds only if the case put it
# there, and proof-timeout TIMEOUT.
cp "$remote_root/ac/$ac" "$tmpdir/own-a-entry"
sig_entry() {
  python3 - "$tmpdir/own-a-entry" "$1" "$2" "$3" <<'PY'
import hashlib, re, sys
own, path, text, timeout = sys.argv[1:]
data = text.encode()
sig = hashlib.sha256(data).hexdigest()
head, manifest = open(own).read().split("manifest-text-v1\n", 1)
old = re.search(r"^blob sig (\S+)$", manifest, re.M)
if old is None:
    sys.exit("the entry has no sig blob")
manifest = manifest.replace(f"blob sig {old.group(1)}\n", f"blob sig {sig}\n")
manifest = re.sub(r"^proof-timeout=.*$", "proof-timeout=" + timeout, manifest, flags=re.M)
out = []
for line in head.split("\n"):
    if line.startswith("manifest-sha256 "):
        line = "manifest-sha256 " + hashlib.sha256(manifest.encode()).hexdigest()
    elif line.startswith("manifest-size "):
        line = "manifest-size " + str(len(manifest.encode()))
    elif line.startswith(f"blob {old.group(1)} "):
        line = f"blob {sig} {len(data)}"
    out.append(line)
open(path, "w").write("\n".join(out) + "manifest-text-v1\n" + manifest)
PY
}
lost_text=$'lost signature\n' live_text=$'live signature\n'
lost_sig=$(printf '%s' "$lost_text" | sha256sum | cut -d' ' -f1)
printf '%s' "$live_text" > "$remote_root/cas/$(printf '%s' "$live_text" | sha256sum | cut -d' ' -f1)"
timeout=$(sed -n 's/^proof-timeout=//p' "$tmpdir/own-a-entry")

# lost_blob_built NAME: worker NAME built the action and replaced an entry
# whose blob the cache lost.
lost_blob_built() {
  if [[ "$worker_status" != 0 ]] || ! grep -qx "status=built" "$tmpdir/$1.result"; then
    echo "worker $1 did not replace an entry whose blob the cache lost" >&2
    cat "$tmpdir/$1.result" "$tmpdir/$1.log" >&2 || true
    exit 1
  fi
  require_grep "replacing remote cache entry .*: the cache no longer holds all of its blobs" "$tmpdir/$1.log"
}

# A remote entry with other outputs whose blob the cache lost restores
# nowhere, so it is no conflict: a worker that builds the action replaces it.
sig_entry "$remote_root/ac/$ac" "$lost_text" "$timeout"
worker lost-blob
lost_blob_built lost-blob
if grep -qx "blob sig $lost_sig" "$remote_root/ac/$ac"; then
  echo "the remote still holds the entry whose blob the cache lost" >&2
  exit 1
fi

# With two nodes, only the one whose entry lost a blob is replaced: the
# first ranked for A's entry holds the lost one, the other a restorable
# entry with other outputs, which stays.
main_pid=$server_pid main_url=$remote_url
start_remote_cache_server "$tmpdir/remote-two" "$tmpdir/server-two" "$tmpdir/control-two"
second_pid=$server_pid second_url=$remote_url
server_pid=$main_pid remote_url=$main_url
first=$(python3 - "$ac" "$remote_url" "$second_url" <<'PY'
import hashlib, sys
digest, *nodes = sys.argv[1:]
print(max(nodes, key=lambda node: hashlib.sha256(f"{node}:{digest}".encode()).hexdigest()))
PY
)
if [[ $first == "$remote_url" ]]; then
  lost_root=$remote_root lost_control=$control live_root=$tmpdir/remote-two
else
  lost_root=$tmpdir/remote-two lost_control=$tmpdir/control-two live_root=$remote_root
fi
mkdir -p "$tmpdir/remote-two/ac"
sig_entry "$lost_root/ac/$ac" "$lost_text" "$timeout"
sig_entry "$live_root/ac/$ac" "$live_text" "$timeout"
cp "$live_root/ac/$ac" "$tmpdir/live-entry"
# live_entry_kept: the other node's entry is unchanged.
live_entry_kept() {
  cmp "$live_root/ac/$ac" "$tmpdir/live-entry" ||
    { echo "the restorable entry on the other node was overwritten" >&2; exit 1; }
}
# A node refusing the write leaves the cache unavailable, not in conflict,
# and the write goes to no other node.
echo 507 > "$lost_control/ac-put-status"
worker lost-blob-refused "$remote_url,$second_url"
rm "$lost_control/ac-put-status"
expect lost-blob-refused 3 unavailable "could not replace remote cache entry .*, whose blobs the cache lost"
live_entry_kept
worker lost-blob-ring "$remote_url,$second_url"
lost_blob_built lost-blob-ring
if grep -qx "blob sig $lost_sig" "$lost_root/ac/$ac"; then
  echo "the node whose entry lost a blob still holds it" >&2
  exit 1
fi
live_entry_kept
kill "$second_pid"
wait "$second_pid" 2>/dev/null || true
second_pid=

# A remote entry with other outputs the cache holds is a real conflict: a
# worker that builds the action, here as the entry's timeout contract is
# weaker, reports `publish`.
sig_entry "$remote_root/ac/$ac" "$live_text" none
worker other
if [[ "$worker_status" != 3 ]] || ! grep -qx "failure=publish" "$tmpdir/other.result"; then
  echo "a conflicting entry was not reported as a publish failure" >&2
  cat "$tmpdir/other.result" "$tmpdir/other.log" >&2 || true
  exit 1
fi
require_grep "the remote cache holds different outputs for the action" "$tmpdir/other.log"
# It drops its own entry, so that a retry restores the remote's.
input_key=$(sed -n 's/^input_key=//p' "$remote_root/ac/$ac")
require_no_file "$tmpdir/worker-other/actions/$input_key/manifest"

# A build.log over 64 MiB goes up as its first 16 MiB, a line saying what
# was cut and its last 48 MiB.  When the cache refuses it, the action still
# succeeds and its record says why it has no log.
cat > "$project/src/BigScript.sml" <<'SML'
Theory Big
Ancestors bool

val _ =
  let
    val line = CharVector.tabulate (1023, fn _ => #"x") ^ "\n"
    fun lines 0 = () | lines n = (print line; lines (n - 1))
  in
    print "big-log-start\n"; lines (48 * 1024);
    print "big-log-middle\n"; lines (48 * 1024);
    print "big-log-end\n"
  end

Theorem big_thm:
  T
Proof
  simp[]
QED
SML
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload BigTheory) > "$tmpdir/batch-big.txt"
spec=$(awk '$1 == "action" && $5 == "worker:BigTheory" { print $4 }' "$tmpdir/batch-big.txt")
big_ac=$(awk '$1 == "action" && $5 == "worker:BigTheory" { print $3 }' "$tmpdir/batch-big.txt")
[[ -n "$spec" && -n "$big_ac" ]] || { cat "$tmpdir/batch-big.txt" >&2; exit 1; }
printf '[holbuild: truncated ' > "$control/cas-put-reject-text"
worker big-refused
rm "$control/cas-put-reject-text"
if [[ "$worker_status" != 0 ]] || ! grep -qx 'status=built' "$tmpdir/big-refused.result" ||
   grep -q '^log=' "$tmpdir/big-refused.result"; then
  echo "a refused log upload changed the action's result" >&2
  cat "$tmpdir/big-refused.result" "$tmpdir/big-refused.log" >&2
  exit 1
fi
require_grep '^detail=could not upload the action log: remote cache server error: HTTP 500 for PUT' \
  "$tmpdir/big-refused.result"
rm "$remote_root/ac/$big_ac"
worker big
[[ "$worker_status" == 0 ]] || { cat "$tmpdir/big.result" "$tmpdir/big.log" >&2; exit 1; }
read -r big_sha big_bytes < <(sed -n 's/^log=//p' "$tmpdir/big.result")
blob=$remote_root/cas/$big_sha
require_file "$blob"
[[ "$(stat -c %s "$blob")" == "$big_bytes" ]] || { echo "log= size $big_bytes, blob $(stat -c %s "$blob")" >&2; exit 1; }
python3 - "$blob" <<'PY'
import re, sys
data = open(sys.argv[1], "rb").read()
head, tail = 16 << 20, 48 << 20
m = re.match(rb"\n\.\.\. \[holbuild: truncated (\d+) bytes of (\d+)-byte build log\] \.\.\.\n", data[head:])
assert m, data[head:head + 200]
assert int(m[2]) - int(m[1]) == head + tail and len(data) == head + len(m[0]) + tail, (m[0], len(data))
assert b"big-log-start\n" in data[:head], "head missing"
assert b"big-log-end\n" in data[-tail:], data[-300:]
assert b"big-log-middle" not in data, "the middle was kept"
PY
