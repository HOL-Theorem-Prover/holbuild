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
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
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

# With the cache back, the same worker publishes it.
worker w
grep -qx 'status=cached' "$tmpdir/w.result" || { cat "$tmpdir/w.result" "$tmpdir/w.log" >&2; exit 1; }
require_file "$remote_root/ac/$ac"

# Hydrating a dependency: B's worker fetches A's entry, and the cache
# answers 500 for it.  That is not a missing input.
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload BTheory) > "$tmpdir/batch-b.txt"
spec_a=$spec
spec=$(awk '$1 == "action" && $5 == "worker:BTheory" { print $4 }' "$tmpdir/batch-b.txt")
[[ -n "$spec" ]] || { cat "$tmpdir/batch-b.txt" >&2; exit 1; }
echo 500 > "$control/ac-get-status-$ac"
worker b
expect b 3 unavailable "remote cache server error: HTTP 500 for GET .*/ac/$ac"
rm "$control/ac-get-status-$ac"
spec=$spec_a

# A traced rerun must return its new log even though the theory outputs are
# already published. An outage during that upload retries the action.
spec=$(python3 - "$remote_root/cas/$spec" "$remote_root/cas" <<'PYTHON'
import hashlib
import pathlib
import sys
source, cas = map(pathlib.Path, sys.argv[1:])
data = source.read_text().replace("\naction-text\n", "\noption trace-steps=true\naction-text\n").encode()
sha = hashlib.sha256(data).hexdigest()
(cas / sha).write_bytes(data)
print(sha)
PYTHON
)
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

# A remote entry with other outputs is a real conflict: a worker that builds
# the action reports `publish`.
python3 - "$remote_root/ac/$ac" <<'PY'
import hashlib, sys
path = sys.argv[1]
head, manifest = open(path).read().split("manifest-text-v1\n", 1)
lines = manifest.split("\n")
for i, line in enumerate(lines):
    if line.startswith("blob sig "):
        lines[i] = "blob sig " + hashlib.sha256(b"other signature\n").hexdigest()
        break
else:
    sys.exit("the entry has no sig blob")
manifest = "\n".join(lines)
out = []
for line in head.split("\n"):
    if line.startswith("manifest-sha256 "):
        line = "manifest-sha256 " + hashlib.sha256(manifest.encode()).hexdigest()
    elif line.startswith("manifest-size "):
        line = "manifest-size " + str(len(manifest.encode()))
    out.append(line)
open(path, "w").write("\n".join(out) + "manifest-text-v1\n" + manifest)
PY
worker other
if [[ "$worker_status" != 3 ]] || ! grep -qx "failure=publish" "$tmpdir/other.result"; then
  echo "a conflicting entry was not reported as a publish failure" >&2
  cat "$tmpdir/other.result" "$tmpdir/other.log" >&2 || true
  exit 1
fi
require_grep "the remote cache holds different outputs for the action" "$tmpdir/other.log"
