#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# exec-action --share-heaps: a worker whose local heap, checkpoints and store
# are gone resumes from the heap and checkpoints an earlier run published,
# and builds the same outputs as a cold worker does.

tmpdir=$(make_temp_dir)
server_pids=()
other_fs=""
cleanup() {
  [[ -z "$other_fs" ]] || rm -rf "$other_fs"
  for pid in ${server_pids[@]+"${server_pids[@]}"}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

# Two remote caches: the sharing worker's, and a cold worker's to compare.
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
server_pids+=("$server_pid")
shared_url=$remote_url
start_remote_cache_server "$tmpdir/remote-cold" "$tmpdir/server-cold"
server_pids+=("$server_pid")
cold_url=$remote_url
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "share"

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

# write_t FIRST THIRD [FOURTH [FIFTH]]: theory T, its first theorem's
# statement and its later theorems' proofs varied.  A theorem's context
# checkpoint is the state after it.
write_t() {
  cat > "$project/src/TScript.sml" <<SML
Theory T
Ancestors A

Theorem t1:
  $1
Proof
  simp[]
QED

Theorem t2:
  T /\\ T
Proof
  ACCEPT_TAC (CONJ a_thm a_thm)
QED

Theorem t3:
  T /\\ (1 = 1)
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >> $2
QED

Theorem t4:
  T
Proof
  ${3:-simp[]}
QED

Theorem t5:
  T
Proof
  ${4:-simp[]}
QED
SML
}

# worker NAME URL CACHE [OPTION...]: exec-action of T's current spec on the
# cache root CACHE; the record goes to $tmpdir/NAME.result.
worker() {
  local name=$1 url=$2 cache=$3 spec=$4
  shift 4
  link_hol_toolchain_cache "$cache"
  set +e
  HOLBUILD_CACHE=$cache "$HOLBUILD_BIN" --remote-cache "$url" exec-action "$spec" \
    --cache-limit-gb 1000 --result "$tmpdir/$name.result" "$@" > "$tmpdir/$name.log" 2>&1
  worker_status=$?
  set -e
}

expect() {
  local name=$1 code=$2
  shift 2
  if [[ "$worker_status" != "$code" ]]; then
    echo "worker $name exited $worker_status, wanted $code" >&2
    cat "$tmpdir/$name.log" "$tmpdir/$name.result" >&2 || true
    exit 1
  fi
  for line in "$@"; do
    grep -qxF -- "$line" "$tmpdir/$name.result" || {
      echo "worker $name result lacks '$line':" >&2
      cat "$tmpdir/$name.result" "$tmpdir/$name.log" >&2
      exit 1
    }
  done
}

field() { awk -v want="$2" -v col="$3" '$1 == "action" && $5 == want { print $col }' "$1"; }

shared=$tmpdir/worker-shared
cold=$tmpdir/worker-cold

# export VERSION: T's spec in both remote caches, and A built in both.
export_t() {
  local version=$1 url
  for url in "$shared_url" "$cold_url"; do
    (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$url" action-spec --upload TTheory) \
      > "$tmpdir/batch-$version-${url##*:}.txt"
  done
  batch=$tmpdir/batch-$version-${shared_url##*:}.txt
  spec_t=$(field "$batch" share:TTheory 4)
  ac_t=$(field "$batch" share:TTheory 3)
  spec_a=$(field "$batch" share:ATheory 4)
  if [[ -n "$spec_a" ]]; then
    worker "a-shared-$version" "$shared_url" "$shared" "$spec_a" --share-heaps
    expect "a-shared-$version" 0 "status=built"
    worker "a-cold-$version" "$cold_url" "$cold" "$spec_a"
    expect "a-cold-$version" 0 "status=built"
  fi
  [[ -n "$spec_t" ]] || { cat "$batch" >&2; exit 1; }
}

# cold VERSION CODE: T built from scratch on the cold remote.
cold() {
  rm -rf "$cold/checkpoints"
  worker "cold-$1" "$cold_url" "$cold" "$spec_t"
  expect "cold-$1" "$2"
}

# same_outputs VERSION: both remotes hold the same entry for T.
same_outputs() {
  cmp "$tmpdir/remote/ac/$ac_t" "$tmpdir/remote-cold/ac/$ac_t" || {
    echo "version $1: the sharing worker's outputs differ from a cold build's" >&2
    exit 1
  }
}

# Only the remote cache holds what an earlier run shared.
forget_local() { rm -rf "$shared/checkpoints" "$shared/checkpoint-store"; }

# resumed VERSION FROM KIND: the sharing worker restored a KIND checkpoint,
# resumed from it as FROM, and kept it.
resumed() {
  require_grep "restored shared $3" "$tmpdir/$1.log"
  require_grep "from: $2" "$tmpdir/$1.log"
  if grep -q "discarding" "$tmpdir/$1.log"; then
    echo "version $1: the build discarded the restored state" >&2
    cat "$tmpdir/$1.log" >&2
    exit 1
  fi
}

write_t "T" "simp[]"
export_t v1
# The dependency shares its checkpoints by default, before the target runs.
[[ -d "$shared/checkpoint-store" ]] || { echo "the dependency A shared no heap" >&2; exit 1; }
requests=$tmpdir/server/requests.log
before_v1=$(wc -l < "$requests")
worker v1 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v1 0 "status=built"
# With no heap published yet, the worker's restore, before its first upload,
# looked for no checkpoint on it.
tail -n +"$((before_v1 + 1))" "$requests" | awk '$1 == "PUT" { exit } $1 == "GET" { print $2 }' | grep '^/ac/' \
  | sort -u | while read -r path; do
  if [[ -f "$tmpdir/remote$path" ]] && grep -q "holbuild-shared-checkpoint-v1" "$tmpdir/remote$path"; then
    echo "v1 looked for the checkpoint $path before any heap was shared" >&2
    exit 1
  fi
done
[[ -d "$shared/checkpoint-store" ]] || { echo "v1 added nothing to the store" >&2; exit 1; }
[[ ! -e "$shared/checkpoints" ]] || { echo "the private checkpoint tree outlived the action" >&2; exit 1; }

# An edit of the first theorem resumes from the shared heap alone.
write_t "T \\/ F" "simp[]"
export_t v2
cold v2 0
forget_local
worker v2 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v2 0 "status=built"
resumed v2 "deps-loaded checkpoint" "deps-loaded heap"
same_outputs v2

# An edit of a late theorem resumes from the context after the one before.
write_t "T \\/ F" "REFL_TAC"
export_t v3
cold v3 0
forget_local
worker v3 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v3 0 "status=built"
resumed v3 "theorem-context checkpoint after t2" "theorem_context checkpoint"
same_outputs v3

# A failed proof shares its failed prefix, and the fixed proof resumes from it.
write_t "T \\/ F" "FAIL_TAC \"seeded failure\""
export_t v4
worker v4 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v4 1 "status=failed" "failure=proof"
require_grep "seeded failure" "$tmpdir/v4.log"
# A resume that gets past the shared failed prefix and fails later shares
# the later prefix in its place, and the next resume starts from that.
restored_steps() {
  sed -n 's/.*restoring proof-ir prefix with \([0-9]*\) successful leaf steps.*/\1/p' "$tmpdir/$1.log" | tail -1
}
write_t "T \\/ F" "ALL_TAC >> FAIL_TAC \"later failure\""
export_t v4a
forget_local
worker v4a "$shared_url" "$shared" "$spec_t" --share-heaps
expect v4a 1 "status=failed" "failure=proof"
require_grep "later failure" "$tmpdir/v4a.log"
resumed v4a "failed-prefix checkpoint in t3" "failed_prefix checkpoint"
forget_local
worker v4b "$shared_url" "$shared" "$spec_t" --share-heaps
expect v4b 1 "status=failed" "failure=proof"
resumed v4b "failed-prefix checkpoint in t3" "failed_prefix checkpoint"
v4a_steps=$(restored_steps v4a)
v4b_steps=$(restored_steps v4b)
[[ -n "$v4a_steps" && -n "$v4b_steps" && "$v4b_steps" -gt "$v4a_steps" ]] || {
  echo "the resume after a later failure restored $v4b_steps steps, the one before $v4a_steps" >&2
  cat "$tmpdir/v4b.log" >&2
  exit 1
}

write_t "T \\/ F" "rw[]"
export_t v5
cold v5 0
forget_local
worker v5 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v5 0 "status=built"
resumed v5 "failed-prefix checkpoint in t3" "failed_prefix checkpoint"
same_outputs v5

# A resume from a failed prefix saves no context for its theorem, so an
# edit of the next theorem resumes from the failed prefix again, though the
# proof it records no longer fails.
write_t "T \\/ F" "rw[]" "ACCEPT_TAC TRUTH"
export_t v6
cold v6 0
forget_local
worker v6 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v6 0 "status=built"
resumed v6 "failed-prefix checkpoint in t3" "failed_prefix checkpoint"
same_outputs v6

# The contexts saved after that resume, children of the failed prefix, were
# shared too.
write_t "T \\/ F" "rw[]" "ACCEPT_TAC TRUTH" "ACCEPT_TAC TRUTH"
export_t v7
cold v7 0
forget_local
worker v7 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v7 0 "status=built"
resumed v7 "theorem-context checkpoint after t4" "theorem_context checkpoint"
same_outputs v7

# The cache loses the heap's blob but keeps the entries naming it: the
# worker loads cold, replaces the entries, and the next edit resumes again.
heap_blob=$(find "$shared/checkpoint-store" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
[[ -f "$tmpdir/remote/cas/$heap_blob" ]] || { echo "no heap blob $heap_blob in the cache" >&2; exit 1; }
rm "$tmpdir/remote/cas/$heap_blob"
write_t "T \\/ F" "rw[]" "ACCEPT_TAC TRUTH" "rw[]"
export_t v8
cold v8 0
forget_local
worker v8 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v8 0 "status=built"
require_grep "the cache lost blob $heap_blob" "$tmpdir/v8.log"
same_outputs v8
write_t "T \\/ F" "rw[]" "ACCEPT_TAC TRUTH" "REWRITE_TAC []"
export_t v9
cold v9 0
forget_local
before_v9=$(wc -l < "$requests")
worker v9 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v9 0 "status=built"
resumed v9 "theorem-context checkpoint after t4" "theorem_context checkpoint"
same_outputs v9

# The worker keeps the sources it fetched: running the spec again fetches
# none of them.
source_get="GET /cas/$(sha256sum "$project/src/TScript.sml" | cut -d' ' -f1)"
before_again=$(wc -l < "$requests")
worker v9-again "$shared_url" "$shared" "$spec_t" --share-heaps
expect v9-again 0 "status=cached"
tail -n +"$((before_v9 + 1))" "$requests" | head -n "$((before_again - before_v9))" | grep -qxF "$source_get" \
  || { echo "v9 fetched no source" >&2; exit 1; }
if tail -n +"$((before_again + 1))" "$requests" | grep -qxF "$source_get"; then
  echo "running the spec again fetched its source again" >&2
  exit 1
fi

# A store on another file system than the action's checkpoints, as a store
# on its own mount is: states are copied into private writable files, and
# the worker still resumes from them.
if [[ -d /dev/shm && -w /dev/shm && $(stat -c %d /dev/shm) != $(stat -c %d "$tmpdir") ]]; then
  other_fs=$(mktemp -d /dev/shm/holbuild-share-heaps.XXXXXX)
  write_t "T \\/ F" "rw[]" "ACCEPT_TAC TRUTH" "MATCH_ACCEPT_TAC TRUTH"
  export_t v10
  cold v10 0
  forget_local
  mkdir -p "$shared"
  ln -s "$other_fs" "$shared/checkpoint-store"
  worker v10 "$shared_url" "$shared" "$spec_t" --share-heaps
  expect v10 0 "status=built"
  if grep -q 'linking its states symbolically' "$tmpdir/v10.log"; then
    echo 'sandboxed worker exposed linked checkpoint store states' >&2
    exit 1
  fi
  resumed v10 "theorem-context checkpoint after t4" "theorem_context checkpoint"
  same_outputs v10
else
  echo "skipping the cross-file-system store: no /dev/shm on another file system"
fi


# Older clients can explicitly disable theorem saves. Their dependency heap
# must still be shared and reusable after a proof edit.
cat > "$project/src/LegacyScript.sml" <<'SML'
Theory Legacy
Ancestors A
Theorem legacy_thm:
  T
Proof
  ACCEPT_TAC a_thm
QED
SML
export_legacy() {
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$shared_url" action-spec --upload LegacyTheory) > "$tmpdir/legacy.batch"
  spec_legacy=$(field "$tmpdir/legacy.batch" share:LegacyTheory 4)
  sed '/^action-text$/i option theorem-checkpoints=false' "$project/.holbuild/action-specs/$spec_legacy" > "$tmpdir/legacy.spec"
  spec_legacy=$(sha256sum "$tmpdir/legacy.spec" | cut -d' ' -f1)
  curl -fsS -X PUT --data-binary "@$tmpdir/legacy.spec" "$shared_url/cas/$spec_legacy"
}
legacy=$tmpdir/worker-legacy
export_legacy
worker legacy1 "$shared_url" "$legacy" "$spec_legacy" --share-heaps
expect legacy1 0 "status=built"
[[ -d "$legacy/checkpoint-store" ]] || { echo "old spec shared no dependency heap" >&2; exit 1; }
sed -i 's/ACCEPT_TAC a_thm/MATCH_ACCEPT_TAC a_thm/' "$project/src/LegacyScript.sml"
export_legacy
rm -rf "$legacy/checkpoint-store"
worker legacy2 "$shared_url" "$legacy" "$spec_legacy" --share-heaps
expect legacy2 0 "status=built"
resumed legacy2 "deps-loaded checkpoint" "deps-loaded heap"

# Interrupt a dependency, not the requested target, after completed saves.
# A fresh worker must resume those saves without ever caching a built result
# for the interrupted action.
cat > "$project/src/InterruptedScript.sml" <<'SML'
Theory Interrupted
Ancestors A
Theorem completed:
  T
Proof
  ACCEPT_TAC a_thm
QED
Definition completed_def:
  completed_value = T
End
Theorem uncommitted:
  T
Proof
  simp[]
QED
val _ = (print "checkpoint-cancel-ready\n"; TextIO.flushOut TextIO.stdOut;
         OS.Process.sleep (Time.fromSeconds 120))
Theorem unfinished:
  completed_value
Proof
  simp[completed_def]
QED
SML
cat > "$project/src/ConsumerScript.sml" <<'SML'
Theory Consumer
Ancestors Interrupted
SML
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$shared_url" action-spec --upload ConsumerTheory) > "$tmpdir/cancel.batch"
spec_interrupt=$(field "$tmpdir/cancel.batch" share:InterruptedTheory 4)
key_interrupt=$(field "$tmpdir/cancel.batch" share:InterruptedTheory 3)
interrupted=$tmpdir/worker-interrupted
link_hol_toolchain_cache "$interrupted"
python3 - "$HOLBUILD_BIN" "$shared_url" "$spec_interrupt" "$interrupted" "$tmpdir" <<'PYTEST'
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

binary, url, spec, cache, temp = sys.argv[1:]
# The suite timing wrapper is a shell; signal the driver itself.
binary = os.environ.get("REAL_HOLBUILD_BIN", binary)
root = Path(cache)
with open(f"{temp}/interrupted.log", "w") as log:
    process = subprocess.Popen(
        [binary, "--remote-cache", url, "exec-action", spec, "--share-heaps",
         "--cache-limit-gb", "1000", "--result", f"{temp}/interrupted.result"],
        env={**os.environ, "HOLBUILD_CACHE": cache}, stdout=log, stderr=log,
    )
    try:
        deadline = time.monotonic() + 90
        while not any("checkpoint-cancel-ready" in p.read_text(errors="replace")
                      for p in root.glob("action/.holbuild/stage/**/holbuild-build.log")):
            if process.poll() is not None or time.monotonic() >= deadline:
                raise AssertionError("HOL never reached the interruption point")
            time.sleep(0.05)
        assert list(root.glob("checkpoints/**/*_context.save.ok")), "no completed theorem save"
        # Model a save interrupted before its atomic .ok commit. It is a
        # real candidate, but neither its partial bytes nor .ok.tmp may publish.
        incomplete = next(root.glob("checkpoints/**/uncommitted_context.save"))
        ok = Path(str(incomplete) + ".ok")
        ok.rename(str(ok) + ".tmp")
        partial = b"interrupted-checkpoint-save"
        incomplete.write_bytes(partial)
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=15) != 0, "interrupted action succeeded"
        assert not (Path(temp) / "remote/cas" / hashlib.sha256(partial).hexdigest()).exists()
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
PYTEST
require_grep '^status=failed$' "$tmpdir/interrupted.result"
require_grep '^failure=unavailable$' "$tmpdir/interrupted.result"
[[ ! -e "$tmpdir/remote/ac/$key_interrupt" ]] || { echo "interrupted action published a built result" >&2; exit 1; }
[[ ! -e "$interrupted/checkpoints" ]] || { echo "interrupted action kept private checkpoints" >&2; exit 1; }
sed -i 's/OS.Process.sleep (Time.fromSeconds 120)/()/' "$project/src/InterruptedScript.sml"
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$shared_url" action-spec --upload ConsumerTheory) > "$tmpdir/resume.batch"
spec_interrupt=$(field "$tmpdir/resume.batch" share:InterruptedTheory 4)
worker interrupted-resume "$shared_url" "$tmpdir/worker-resumed" "$spec_interrupt" --share-heaps
expect interrupted-resume 0 "status=built"
require_grep 'restored shared .* checkpoint' "$tmpdir/interrupted-resume.log"
require_grep 'checkpoint after completed' "$tmpdir/interrupted-resume.log"
