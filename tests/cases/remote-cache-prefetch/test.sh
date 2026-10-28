#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
gate=$tmpdir/gate
consumer_pid=

cleanup() {
  if [[ -n "$consumer_pid" ]]; then
    touch "$gate/release"
    kill "$consumer_pid" 2>/dev/null || true
    wait "$consumer_pid" 2>/dev/null || true
  fi
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

# Gate is never cached and, when HOLBUILD_TEST_PREFETCH_GATE names a directory,
# blocks its build until that directory holds a release file.  Its children
# can only be restored after it finishes, so any of their entries that reach
# the local cache meanwhile were prefetched.
write_project() {
  local project=$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "remote-cache-prefetch-test"

[build]
members = ["src"]

[actions.GateTheory]
cache = false
TOML
  cat > "$project/src/GateScript.sml" <<'SML'
Theory Gate
Ancestors bool

val _ =
  case OS.Process.getEnv "HOLBUILD_TEST_PREFETCH_GATE" of
      NONE => ()
    | SOME dir =>
        let
          fun wait () =
            if OS.FileSys.access (dir ^ "/release", []) then ()
            else (OS.Process.sleep (Time.fromMilliseconds 10); wait ())
        in
          TextIO.closeOut (TextIO.openOut (dir ^ "/started"));
          wait ()
        end

Theorem gate_thm:
  T
Proof
  simp[]
QED
SML
  local child
  for child in Late Broken Absent; do
    cat > "$project/src/${child}Script.sml" <<SML
Theory $child
Ancestors Gate

Theorem ${child,,}_thm:
  T
Proof
  simp[]
QED
SML
  done
}

wait_for_file() {
  local path=$1
  local attempt
  for ((attempt = 0; attempt < 6000; attempt++)); do
    [[ -f "$path" ]] && return
    sleep 0.01
  done
  echo "timed out waiting for $path" >&2
  return 1
}

theory_key() {
  local theory=$1
  awk -F '\t' -v theory="$theory" '$1 ~ theory { print $2 }' "$tmpdir/keys"
}

remote_action_path() {
  python3 - "$remote_root" "$1" <<'PY'
import hashlib
import sys

root, key = sys.argv[1:]
print(f"{root}/ac/" + hashlib.sha256(f"holbuild-remote-ac-v1\n{key}\n".encode()).hexdigest())
PY
}

# Overwrites the remote CAS object holding the entry's .dat output.
corrupt_remote_dat_blob() {
  python3 - "$remote_root" "$1" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
header, manifest = pathlib.Path(sys.argv[2]).read_text().split("manifest-text-v1\n", 1)
dat = next(line.split()[2] for line in manifest.splitlines() if line.startswith("blob dat "))
sha256 = next(line.split()[2] for line in header.splitlines()
              if line.startswith("blob ") and line.split()[1] == dat)
(root / "cas" / sha256).write_text("corrupt\n")
PY
}

remote_root=$tmpdir/remote
start_remote_cache_server "$remote_root" "$tmpdir/server"

publisher=$tmpdir/publisher
publisher_cache=$tmpdir/publisher-cache
write_project "$publisher"
link_hol_toolchain_cache "$publisher_cache"
(cd "$publisher" && HOLBUILD_CACHE="$publisher_cache" HOLBUILD_CACHE_TRACE=1 \
  HOLBUILD_DUMP_KEYS="$tmpdir/keys" \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build LateTheory BrokenTheory AbsentTheory) \
  > "$tmpdir/publisher.log" 2>&1
require_grep "LateTheory built" "$tmpdir/publisher.log"

late_key=$(theory_key LateScript)
broken_key=$(theory_key BrokenScript)
absent_key=$(theory_key AbsentScript)
[[ -n "$late_key" && -n "$broken_key" && -n "$absent_key" ]] || {
  echo "missing theory keys in key dump" >&2
  cat "$tmpdir/keys" >&2
  exit 1
}
corrupt_remote_dat_blob "$(remote_action_path "$broken_key")"
rm "$(remote_action_path "$absent_key")"

consumer=$tmpdir/consumer
consumer_cache=$tmpdir/consumer-cache
write_project "$consumer"
link_hol_toolchain_cache "$consumer_cache"
mkdir -p "$gate"
consumer_log=$tmpdir/consumer.log
(cd "$consumer" && HOLBUILD_CACHE="$consumer_cache" HOLBUILD_CACHE_TRACE=1 \
  HOLBUILD_TEST_PREFETCH_GATE="$gate" \
  exec "$HOLBUILD_BIN" --remote-cache "$remote_url" --prefetch-concurrency 1 -j1 build --skip-checkpoints BrokenTheory AbsentTheory LateTheory) \
  > "$consumer_log" 2>&1 &
consumer_pid=$!

wait_for_file "$gate/started" || {
  cat "$consumer_log" >&2
  exit 1
}
wait_for_file "$consumer_cache/actions/$late_key/manifest" || {
  cat "$consumer_log" >&2
  exit 1
}
touch "$gate/release"
if ! wait "$consumer_pid"; then
  consumer_pid=
  cat "$consumer_log" >&2
  exit 1
fi
consumer_pid=

require_grep "remote cache prefetch threads: 1$" "$consumer_log"
require_grep "remote cache prefetched: $late_key" "$consumer_log"
require_grep "LateTheory restored from cache" "$consumer_log"
require_grep "BrokenTheory built" "$consumer_log"
require_grep "AbsentTheory built" "$consumer_log"
# The check below needs these entries usable on the remote again.
require_grep "remote cache published: $broken_key" "$consumer_log"
require_grep "remote cache published: $absent_key" "$consumer_log"
# The failed prefetch is silent; only the demand restore reports the entry.
warnings=$(grep -c "remote cache entry unusable for $broken_key" "$consumer_log" || true)
if [[ "$warnings" != 1 ]]; then
  echo "expected one unusable-entry warning for BrokenTheory, found $warnings" >&2
  cat "$consumer_log" >&2
  exit 1
fi

# Theories whose metadata already records their key are not prefetched, even
# when their entries are gone from the local cache.  Gate (rebuilt) and Late
# lose their metadata; with one prefetch thread walking Broken, Absent, Late,
# Late's entry reaching the local cache means the others were passed over.
metadata=$consumer/.holbuild/dep/remote-cache-prefetch-test/src
rm "$metadata/GateScript.sml.key" "$metadata/LateScript.sml.key"
rm -rf "$consumer_cache/actions" "$gate"
mkdir -p "$gate"
consumer_log=$tmpdir/up-to-date.log
(cd "$consumer" && HOLBUILD_CACHE="$consumer_cache" HOLBUILD_CACHE_TRACE=1 \
  HOLBUILD_TEST_PREFETCH_GATE="$gate" \
  exec "$HOLBUILD_BIN" --remote-cache "$remote_url" --prefetch-concurrency=1 -j1 build --skip-checkpoints BrokenTheory AbsentTheory LateTheory) \
  > "$consumer_log" 2>&1 &
consumer_pid=$!
wait_for_file "$gate/started" || {
  cat "$consumer_log" >&2
  exit 1
}
wait_for_file "$consumer_cache/actions/$late_key/manifest" || {
  cat "$consumer_log" >&2
  exit 1
}
touch "$gate/release"
if ! wait "$consumer_pid"; then
  consumer_pid=
  cat "$consumer_log" >&2
  exit 1
fi
consumer_pid=
require_grep "remote cache prefetch threads: 1$" "$consumer_log"
require_grep "LateTheory restored from cache" "$consumer_log"
if grep -q "remote cache prefetched: \($broken_key\|$absent_key\)" "$consumer_log"; then
  echo "up-to-date theories were prefetched" >&2
  cat "$consumer_log" >&2
  exit 1
fi

for spelling in "--prefetch-concurrency 0" "--prefetch-concurrency=0" "--prefetch-concurrency many"; do
  # shellcheck disable=SC2086
  if (cd "$consumer" && "$HOLBUILD_BIN" $spelling build LateTheory) > "$tmpdir/rejected.out" 2>&1; then
    echo "holbuild accepted $spelling" >&2
    exit 1
  fi
  require_grep '^holbuild: --prefetch-concurrency must be a positive integer$' "$tmpdir/rejected.out"
done
