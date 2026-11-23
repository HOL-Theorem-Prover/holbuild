#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A change to the theory digest (the hash literal of <T>Theory.sml) keeps the
# action keys, so an entry written before it stays resident.  When that entry
# has a weaker timeout contract, a build under a stronger one replaces it: in
# the remote cache from a worker, in a client's local cache from a local
# build or the remote's entry.

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
start_remote_cache_server "$remote_root" "$tmpdir/server"
use_case_cache "$tmpdir/cache"
export HOLBUILD_TEST_CACHE_RETRY_DELAYS=

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "digest"

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

(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload ATheory) > "$tmpdir/batch.txt"
spec=$(awk '$1 == "action" && $5 == "digest:ATheory" { print $4 }' "$tmpdir/batch.txt")
ac=$(awk '$1 == "action" && $5 == "digest:ATheory" { print $3 }' "$tmpdir/batch.txt")
[[ -n "$spec" && -n "$ac" ]] || { cat "$tmpdir/batch.txt" >&2; exit 1; }

# worker NAME: exec-action in NAME's own cache root; it must succeed.
worker() {
  local name=$1 cache=$tmpdir/worker-$1
  link_hol_toolchain_cache "$cache"
  mkdir -p "$tmpdir/cwd-$name"
  (cd "$tmpdir/cwd-$name" &&
     HOLBUILD_CACHE=$cache "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$spec" \
       --cache-limit-gb 1000 --result "$tmpdir/$name.result") > "$tmpdir/$name.log" 2>&1 ||
    { echo "worker $name failed" >&2; cat "$tmpdir/$name.result" "$tmpdir/$name.log" >&2 || true; exit 1; }
}

# The manifest of the remote's entry for A.
remote_manifest() { sed -n '/^manifest-text-v1$/,$p' "$remote_root/ac/$ac" | tail -n +2; }

worker w1
remote_manifest > "$tmpdir/strong-manifest"
grep -q '^proof-timeout=' "$tmpdir/strong-manifest"
! grep -qx 'proof-timeout=none' "$tmpdir/strong-manifest"

# The same build under the old digest and without a timeout: its .sml has
# another hash literal and its .dat another dependency record.
python3 - "$remote_root" "$ac" <<'PY'
import hashlib, pathlib, re, sys
root, ac = pathlib.Path(sys.argv[1]), sys.argv[2]
head, manifest = (root / "ac" / ac).read_text().split("manifest-text-v1\n", 1)
def rewrite(role, change):
    global manifest, head
    old = re.search(rf"^blob {role} (\S+)$", manifest, re.M).group(1)
    data = change((root / "cas" / old).read_text()).encode()
    new = hashlib.sha256(data).hexdigest()
    (root / "cas" / new).write_bytes(data)
    manifest = manifest.replace(f"blob {role} {old}\n", f"blob {role} {new}\n")
    head = re.sub(rf"^blob {old} \d+$", f"blob {new} {len(data)}", head, flags=re.M)
def sml(text):
    literal = re.search(r'hash = "([0-9a-f]{40})"', text)
    if literal is None:
        sys.exit("ATheory.sml has no hash literal")
    return text.replace(literal.group(1), hashlib.sha1(b"old digest").hexdigest())
def dat(text):
    # a_thm's record: ((own theory, index) (bool, theorem)) "DISK_THM"; add
    # bool theorem 0 as a dependency.
    record = re.search(r'\(\(\(\d+ \d+\) \((\d+) (\d+)\)\) "DISK_THM"\)', text)
    if record is None or record.group(2) == "0":
        sys.exit("a_thm has no dependency record to change")
    return text[:record.end(1)] + " 0" + text[record.end(1):]
rewrite("sml", sml)
rewrite("dat", dat)
manifest = re.sub(r"^proof-timeout=.*$", "proof-timeout=none", manifest, flags=re.M)
head = re.sub(r"^manifest-sha256 .*$", "manifest-sha256 " + hashlib.sha256(manifest.encode()).hexdigest(), head, flags=re.M)
head = re.sub(r"^manifest-size .*$", "manifest-size " + str(len(manifest.encode())), head, flags=re.M)
(root / "ac" / ac).write_text(head + "manifest-text-v1\n" + manifest)
PY
remote_manifest > "$tmpdir/weak-manifest"

# A client that waives the timeout contract copies the weak entry.
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" build \
   --allow-cache-timeout-discrepancy ATheory) > "$tmpdir/waived.log" 2>&1
require_grep "ATheory restored from cache" "$tmpdir/waived.log"
local_manifest=$(find "$HOLBUILD_CACHE/actions" -name manifest -print -quit)
cmp "$local_manifest" "$tmpdir/weak-manifest"

# A local build under the default contract replaces it.
rm -rf "$project/.holbuild"
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/local.log" 2>&1
require_grep "ATheory built" "$tmpdir/local.log"
if grep -q "cache entry already exists" "$tmpdir/local.log" || cmp -s "$local_manifest" "$tmpdir/weak-manifest"; then
  echo "the local build kept the weaker local entry" >&2
  cat "$tmpdir/local.log" "$local_manifest" >&2
  exit 1
fi

# A worker rebuilding under the stronger contract replaces the remote's.
worker w2
if ! diff "$tmpdir/strong-manifest" <(remote_manifest); then
  echo "the worker kept the weaker remote entry" >&2
  cat "$tmpdir/w2.log" >&2
  exit 1
fi

# A client still holding the weak entry restores the rebuilt one.
cp "$tmpdir/weak-manifest" "$local_manifest"
rm -rf "$project/.holbuild"
(cd "$project" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" --remote-cache "$remote_url" build ATheory) \
  > "$tmpdir/restore.log" 2>&1
require_grep "remote cache hydrated: " "$tmpdir/restore.log"
require_grep "ATheory restored from cache" "$tmpdir/restore.log"
cmp "$local_manifest" "$tmpdir/strong-manifest"
