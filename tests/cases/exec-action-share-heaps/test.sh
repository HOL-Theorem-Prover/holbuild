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
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server" "$tmpdir/control"
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

# export VERSION [OPTION...]: T's spec in both remote caches, and A built in both.
export_t() {
  local version=$1 url
  shift
  for url in "$shared_url" "$cold_url"; do
    (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$url" action-spec --upload "$@" TTheory) \
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

# heap_line VERSION WHAT: the deps heap's key and result in the worker's
# lookup or publish line, which the worker prints once.
heap_line() {
  local found
  found=$(sed -n "s/^holbuild shared-heap $2 theory=share:[^ ]* heap=\([0-9a-f]\{64\}\) result=\([a-z-]*\)\( checkpoints=[0-9]*\)\?\$/\1 \2/p" \
            "$tmpdir/$1.log")
  [[ $(printf '%s\n' "$found" | grep -c .) == 1 ]] || {
    echo "version $1: not one shared-heap $2 line:" >&2; cat "$tmpdir/$1.log" >&2; exit 1; }
  echo "$found"
}

# resumed VERSION FROM KIND: the sharing worker restored a KIND checkpoint,
# resumed from it as FROM, and kept it.
resumed() {
  require_grep "restored shared $3" "$tmpdir/$1.log"
  require_grep "from: $2" "$tmpdir/$1.log"
  if grep -qE "discarding|not resuming from" "$tmpdir/$1.log"; then
    echo "version $1: the build discarded the restored state" >&2
    cat "$tmpdir/$1.log" >&2
    exit 1
  fi
}

write_t "T" "simp[]"
export_t v1
# The dependency, which isn't a target, passed and so shared nothing.
if grep -qlx "holbuild-shared-heap-v1" "$tmpdir"/remote/ac/* 2>/dev/null; then
  echo "the dependency A shared a heap" >&2; exit 1
fi
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
# The worker's log names the heap it looked up and published, under the key
# the cache holds it at, so a later miss joins to the publish.
read -r heap_v1 lookup_v1 < <(heap_line v1 lookup)
read -r published_key published_v1 < <(heap_line v1 publish)
[[ "$lookup_v1 $published_v1 $published_key" == "miss published $heap_v1" ]] || {
  echo "v1 logged lookup $lookup_v1 and publish $published_v1 of $published_key, not a miss and a publish of $heap_v1" >&2
  exit 1; }
require_grep '^holbuild-shared-heap-v1$' \
  "$tmpdir/remote/ac/$(printf 'holbuild-remote-ac-v1\n%s\n' "$heap_v1" | sha256sum | cut -d' ' -f1)"
# A dependency that passed, not a target, publishes nothing, and says so.
grep -qE '^holbuild shared-heap publish theory=share:[^ ]* heap=[0-9a-f]{64} result=non-target checkpoints=0$' \
  "$tmpdir/a-shared-v1.log" || { echo "A logged no non-target publish:" >&2; cat "$tmpdir/a-shared-v1.log" >&2; exit 1; }
[[ ! -e "$shared/checkpoints" ]] || { echo "the private checkpoint tree outlived the action" >&2; exit 1; }
# It counts the checkpoint entries it published.
checkpoints_v1=$(sed -n 's/^holbuild shared-heap publish .* checkpoints=\([0-9]*\)$/\1/p' "$tmpdir/v1.log")
[[ "$checkpoints_v1" -gt 0 &&
   "$checkpoints_v1" == "$(grep -lx 'holbuild-shared-checkpoint-v1' "$tmpdir"/remote/ac/* | wc -l)" ]] || {
  echo "v1 logged checkpoints=$checkpoints_v1, not the checkpoint entries the cache holds" >&2; exit 1; }

# An edit of the first theorem resumes from the shared heap alone.
write_t "T \\/ F" "simp[]"
export_t v2
cold v2 0
forget_local
HOLBUILD_CACHE_TRACE=1 worker v2 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v2 0 "status=built"
resumed v2 "deps-loaded checkpoint" "deps-loaded heap"
[[ "$(heap_line v2 lookup)" == "$heap_v1 hit" ]] || { echo "v2 logged no hit on the heap v1 published" >&2; exit 1; }
# The restore took its blobs zstd-encoded and decoded them itself.
require_grep "remote cache decode .* zstd threads=4" "$tmpdir/v2.log"
if grep -q "remote cache decode .* \(identity\|fallback\)" "$tmpdir/v2.log"; then
  echo "v2 fetched a blob without decoding it in parallel:" >&2
  grep "remote cache decode" "$tmpdir/v2.log" >&2
  exit 1
fi
# None of the published checkpoints is on the edited script's prefix, and
# the index says so without a probe of each.
require_grep "shared checkpoint index lists 0 of" "$tmpdir/v2.log"
same_outputs v2

# An edit of a late theorem resumes from the context after the one before.
write_t "T \\/ F" "REFL_TAC"
export_t v3
cold v3 0
forget_local
worker v3 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v3 0 "status=built"
resumed v3 "theorem-context checkpoint after t2" "theorem_context checkpoint"
require_grep "shared checkpoint index lists [1-9][0-9]* of" "$tmpdir/v3.log"
same_outputs v3
# With an empty store the restore fetched the heap and its chain, and says so.
for step in rstprobe rstplace rstfetch rstfetchn rstfetchkb rstheap rstheapkb rstindexn resctxn resboundary; do
  grep -qE "^phase-ms=(.*,)?$step:[0-9]+(,|\$)" "$tmpdir/v3.result" || {
    echo "v3's record lacks restore step $step:" >&2; cat "$tmpdir/v3.result" >&2; exit 1; }
done
if grep -qE "^phase-ms=(.*,)?rsthitn:" "$tmpdir/v3.result"; then
  echo "v3 counted store hits in an empty store:" >&2; cat "$tmpdir/v3.result" >&2; exit 1
fi

# The index of the checkpoints published on each heap: a restore probes only
# the checkpoints it lists, and probes every candidate without one.
index_entries() { grep -lx "holbuild-shared-checkpoint-index-v1" "$tmpdir"/remote/ac/* || true; }
# index_entry KEY...: an index entry listing just KEYS.
index_entry() {
  local manifest
  manifest="holbuild-shared-checkpoint-index-v1"$'\n'
  for key in "$@"; do manifest+="checkpoint=$key"$'\n'; done
  printf 'holbuild-remote-cache-action-v2\nmanifest-sha256 %s\nmanifest-size %s\nmanifest-text-v1\n%s' \
    "$(printf '%s' "$manifest" | sha256sum | cut -d' ' -f1)" "${#manifest}" "$manifest"
}
# set_index KEY...: every index lists just KEYS.
set_index() {
  local path
  for path in $(index_entries); do index_entry "$@" > "$path"; done
}
# drop_checkpoint THEOREM: the cache loses every entry of THEOREM's context.
drop_checkpoint() {
  local path
  for path in $(grep -l "^blob=[0-9a-f]* leaf .*/$1_context\.save$" "$tmpdir"/remote/ac/*); do rm "$path"; done
}
[[ -n "$(index_entries)" ]] || { echo "no shared checkpoint index was published" >&2; exit 1; }

# Without an index the late edit still resumes from the latest checkpoint,
# and its publish writes the index again.
rm $(index_entries)
write_t "T \\/ F" "REFL_TAC" "ACCEPT_TAC TRUTH"
export_t v3a
forget_local
worker v3a "$shared_url" "$shared" "$spec_t" --share-heaps
expect v3a 0 "status=built"
resumed v3a "theorem-context checkpoint after t3" "theorem_context checkpoint"
require_grep "no shared checkpoint index: probing all" "$tmpdir/v3a.log"
[[ -n "$(index_entries)" ]] || { echo "v3a published no shared checkpoint index" >&2; exit 1; }

# A listed checkpoint whose entry is gone is passed over for the next one.
drop_checkpoint t4
write_t "T \\/ F" "REFL_TAC" "ACCEPT_TAC TRUTH" "ACCEPT_TAC TRUTH"
export_t v3b
forget_local
worker v3b "$shared_url" "$shared" "$spec_t" --share-heaps
expect v3b 0 "status=built"
resumed v3b "theorem-context checkpoint after t3" "theorem_context checkpoint"

# A published checkpoint the index doesn't list isn't probed: the edit
# resumes from the heap, and its publish lists the checkpoints again.
set_index
write_t "T \\/ F" "REFL_TAC" "ACCEPT_TAC TRUTH" "REWRITE_TAC []"
export_t v3c
forget_local
worker v3c "$shared_url" "$shared" "$spec_t" --share-heaps
expect v3c 0 "status=built"
resumed v3c "deps-loaded checkpoint" "deps-loaded heap"
require_grep "shared checkpoint index lists 0 of" "$tmpdir/v3c.log"
write_t "T \\/ F" "REFL_TAC" "ACCEPT_TAC TRUTH" "MATCH_ACCEPT_TAC TRUTH"
export_t v3d
forget_local
worker v3d "$shared_url" "$shared" "$spec_t" --share-heaps
expect v3d 0 "status=built"
resumed v3d "theorem-context checkpoint after t4" "theorem_context checkpoint"

# A cache in front of the store may still serve an index from before the
# store's was replaced: the restore asks it to check its copy, and resumes
# from a checkpoint the store's index lists.  The publish asks again (the
# copy is stale again by then), so its index keeps the checkpoints the edit
# didn't use.
rm -f "$tmpdir/control/no-cache-gets"
for path in $(index_entries); do
  index_entry > "$tmpdir/control/ac-stale-${path##*/}"
  index_entry > "$tmpdir/control/ac-stale-next-${path##*/}"
  grep '^checkpoint=' "$path" > "$tmpdir/v3e-before-${path##*/}"
done
write_t "T \\/ F" "REFL_TAC" "ACCEPT_TAC TRUTH" "REWRITE_TAC [TRUTH]"
export_t v3e
forget_local
worker v3e "$shared_url" "$shared" "$spec_t" --share-heaps
expect v3e 0 "status=built"
resumed v3e "theorem-context checkpoint after t4" "theorem_context checkpoint"
for path in $(index_entries); do
  [[ -s "$tmpdir/v3e-before-${path##*/}" ]] || { echo "v3d published an empty index" >&2; exit 1; }
  if grep -vxFf "$path" "$tmpdir/v3e-before-${path##*/}"; then
    echo "v3e's index dropped the checkpoints above" >&2; exit 1
  fi
  [[ "$(grep -cx "${path##*/}" "$tmpdir/control/no-cache-gets")" -ge 2 ]] || {
    echo "v3e's restore and publish didn't both ask the cache to check its copy of the index" >&2; exit 1; }
done

# Checkpoint entries the cache refuses aren't counted as published.
echo "holbuild-shared-checkpoint-v1" > "$tmpdir/control/ac-put-reject-text"
write_t "F \\/ T" "REFL_TAC"
export_t v3f
forget_local
worker v3f "$shared_url" "$shared" "$spec_t" --share-heaps
rm "$tmpdir/control/ac-put-reject-text"
expect v3f 0 "status=built"
grep -qE '^holbuild shared-heap publish theory=share:[^ ]* heap=[0-9a-f]{64} result=[a-z-]+ checkpoints=0$' \
  "$tmpdir/v3f.log" || { echo "v3f counted refused checkpoint entries:" >&2; cat "$tmpdir/v3f.log" >&2; exit 1; }

# A failed proof shares its failed prefix, and the fixed proof resumes from it.
write_t "T \\/ F" "FAIL_TAC \"seeded failure\""
export_t v4
touch "$tmpdir/before-v4"
worker v4 "$shared_url" "$shared" "$spec_t" --share-heaps
expect v4 1 "status=failed" "failure=proof"
require_grep "seeded failure" "$tmpdir/v4.log"
# A failed action shares its checkpoints before its result, which the next
# build may follow at once; a passing one after it.  The theory modules are
# written after the result either way.
grep -qE "^phase-ms=(.*,)?share:[0-9]+(,|\$)" "$tmpdir/v4.result" || {
  echo "v4 didn't share its checkpoints before its result:" >&2; cat "$tmpdir/v4.result" >&2; exit 1; }
if grep -qE "^phase-ms=(.*,)?share:" "$tmpdir/v3.result"; then
  echo "v3 shared its checkpoints before its result:" >&2; cat "$tmpdir/v3.result" >&2; exit 1
fi
# Its failed prefix and index entries reached the cache before the result
# was written.
shared_entries() {
  find "$tmpdir/remote/ac" -type f -newer "$1" -print0 |
    xargs -0r grep -lE "^(kind=failed_prefix|holbuild-shared-checkpoint-index-v1)\$" || true
}
failed_prefix_entry() {
  local path
  for path in "$tmpdir"/remote/ac/*; do
    if grep -qx "holbuild-shared-checkpoint-v1" "$path" &&
       grep -qx "kind=failed_prefix" "$path"; then
      printf '%s\n' "$path"
      return
    fi
  done
}
[[ -n "$(shared_entries "$tmpdir/before-v4")" ]] || {
  echo "v4 published no failed prefix" >&2; exit 1; }
[[ -z "$(shared_entries "$tmpdir/v4.result")" ]] || {
  echo "v4 published its failed prefix after its result:" >&2; shared_entries "$tmpdir/v4.result" >&2; exit 1; }
# Its record counts the checkpoint entries it published.
grep -qE "^phase-ms=(.*,)?pubckptn:[1-9][0-9]*(,|\$)" "$tmpdir/v4.result" || {
  echo "v4's record counts no published checkpoint:" >&2; cat "$tmpdir/v4.result" >&2; exit 1; }
require_grep "exec-action after the result (ms): .* modules_ms=" "$tmpdir/v4.log"
# Keep the old manifest in a simulated front cache while the worker advances
# the same failed-prefix key in the remote store.  The next stale copy keeps
# the setup active for the following restore as well.
failed_prefix=$(failed_prefix_entry)
[[ -n "$failed_prefix" ]] || { echo "v4 published no failed-prefix manifest" >&2; exit 1; }
failed_prefix_key=${failed_prefix##*/}
cp "$failed_prefix" "$tmpdir/control/ac-stale-$failed_prefix_key"
cp "$failed_prefix" "$tmpdir/control/ac-stale-next-$failed_prefix_key"
rm -f "$tmpdir/control/no-cache-gets"
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
[[ "$(grep -cx "$failed_prefix_key" "$tmpdir/control/no-cache-gets")" -ge 1 ]] || {
  echo "v4a did not revalidate the failed-prefix manifest" >&2; exit 1; }
# A failed action's record still has the HOL child's phases and the resume.
for step in resfpn resstepn resboundary holload holsalvage holrewind holleaves holtactics holprint holsave resbyten; do
  grep -qE "^phase-ms=(.*,)?$step:[0-9]+(,|\$)" "$tmpdir/v4a.result" || {
    echo "v4a's record lacks phase $step:" >&2; cat "$tmpdir/v4a.result" >&2; exit 1; }
done
# v4 ran "CONJ_TAC >- ACCEPT_TAC TRUTH" before failing, and v4a's tactic
# still starts with it: no byte before its end changed.
tactic=$(grep -bo 'CONJ_TAC >- ACCEPT_TAC TRUTH >> ALL_TAC' "$project/src/TScript.sml" | cut -d: -f1)
grep -qE "^phase-ms=(.*,)?resbyten:$((tactic + 28))(,|\$)" "$tmpdir/v4a.result" || {
  echo "v4a's resbyten is not $((tactic + 28)):" >&2; cat "$tmpdir/v4a.result" >&2; exit 1; }
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
[[ "$(grep -cx "$failed_prefix_key" "$tmpdir/control/no-cache-gets")" -ge 2 ]] || {
  echo "v4b did not revalidate the advanced failed-prefix manifest" >&2; exit 1; }

# A spec of build --no-checkpoint-saves: the worker resumes from the shared
# failed prefix, and shares nothing, neither the later prefix a failure past
# it would nor the contexts after it of a pass, nor, on a miss, the failed
# prefix and contexts of a run from the deps heap.
shared_state() { grep -lE '^holbuild-shared-' "$tmpdir"/remote/ac/* | sort | xargs sha256sum; }
for version in v4c v4d v4e; do
  case "$version" in
    v4c) write_t "T \\/ F" "ALL_TAC >> ALL_TAC >> FAIL_TAC \"unshared failure\"" ;;
    v4d) write_t "T \\/ F" "ALL_TAC >> rw[]" ;;
    v4e) write_t "F \\/ T" "FAIL_TAC \"missed failure\"" ;;
  esac
  export_t "$version" --no-checkpoint-saves
  grep -qx "option no-checkpoint-saves=true" "$project/.holbuild/action-specs/$spec_t" || {
    echo "$version: the spec doesn't carry --no-checkpoint-saves" >&2; exit 1; }
  before=$(shared_state)
  forget_local
  worker "$version" "$shared_url" "$shared" "$spec_t" --share-heaps
  case "$version" in
    v4c)
      expect v4c 1 "status=failed" "failure=proof"
      require_grep "unshared failure" "$tmpdir/v4c.log"
      resumed v4c "failed-prefix checkpoint in t3" "failed_prefix checkpoint" ;;
    v4d)
      expect v4d 0 "status=built"
      resumed v4d "failed-prefix checkpoint in t3" "failed_prefix checkpoint" ;;
    v4e)
      expect v4e 1 "status=failed" "failure=proof"
      require_grep "missed failure" "$tmpdir/v4e.log"
      resumed v4e "deps-loaded checkpoint" "deps-loaded heap" ;;
  esac
  # The worker's checkpoint tree is private to the action.
  [[ ! -e "$shared/checkpoints" ]] || { echo "$version: the private checkpoint tree outlived the action" >&2; exit 1; }
  [[ "$(shared_state)" = "$before" ]] || {
    echo "$version: a worker under --no-checkpoint-saves shared checkpoints:" >&2
    diff <(printf '%s\n' "$before") <(shared_state) >&2 || true
    exit 1
  }
done

# With no shared heap to restore (the cold remote has none), a sharing worker
# under the flag runs from a fresh preload and still shares nothing, where it
# would share its deps heap, contexts and failed prefix.
rm -rf "$cold/checkpoints"
worker v4f "$cold_url" "$cold" "$spec_t" --share-heaps
expect v4f 1 "status=failed" "failure=proof"
require_grep "missed failure" "$tmpdir/v4f.log"
! grep -q "restored shared" "$tmpdir/v4f.log" || { cat "$tmpdir/v4f.log" >&2; echo "v4f restored shared state" >&2; exit 1; }
if grep -qlE '^holbuild-shared-' "$tmpdir"/remote-cold/ac/*; then
  echo "v4f: a worker under --no-checkpoint-saves shared checkpoints with no shared heap to restore" >&2
  exit 1
fi

# An edit after the stale-manifest advance still rewinds to the divergence
# point represented by the shared failed prefix.
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

# That context's restored spine holds t3's failed prefix, yet a later
# theorem that fails still saves its own failed prefix beside it.
write_t "T \\/ F" "rw[]" "ACCEPT_TAC TRUTH" "FAIL_TAC \"after the context\""
export_t v7f
forget_local
worker v7f "$shared_url" "$shared" "$spec_t" --share-heaps
expect v7f 1 "status=failed" "failure=proof"
require_grep "after the context" "$tmpdir/v7f.log"
resumed v7f "theorem-context checkpoint after t4" "theorem_context checkpoint"
if grep -q "Permission denied" "$tmpdir/v7f.log"; then
  echo "v7f could not save its failed prefix" >&2
  cat "$tmpdir/v7f.log" >&2
  exit 1
fi

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
# on its own mount is: states are linked symbolically, and the worker still
# resumes from them.
if [[ -d /dev/shm && -w /dev/shm && $(stat -c %d /dev/shm) != $(stat -c %d "$tmpdir") ]]; then
  other_fs=$(mktemp -d /dev/shm/holbuild-share-heaps.XXXXXX)
  write_t "T \\/ F" "rw[]" "ACCEPT_TAC TRUTH" "(MATCH_ACCEPT_TAC TRUTH)"
  export_t v10
  cold v10 0
  forget_local
  mkdir -p "$shared"
  ln -s "$other_fs" "$shared/checkpoint-store"
  worker v10 "$shared_url" "$shared" "$spec_t" --share-heaps
  expect v10 0 "status=built"
  require_grep 'linking its states symbolically' "$tmpdir/v10.log"
  resumed v10 "theorem-context checkpoint after t4" "theorem_context checkpoint"
  for state in "$other_fs"/*/*; do
    [[ $(sha256sum "$state" | cut -d' ' -f1) == "$(basename "$state")" ]] || { echo "store state changed: $state" >&2; exit 1; }
  done
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

# Interrupt a target after completed saves (a dependency saves none while its
# proofs pass).  A fresh worker must resume those saves without ever caching a
# built result for the interrupted action.
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
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$shared_url" action-spec --upload InterruptedTheory) > "$tmpdir/cancel.batch"
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
# The log so far is uploaded, for the client to see how far the action got.
interrupted_log=$(sed -n 's/^log=\([^ ]*\) .*/\1/p' "$tmpdir/interrupted.result")
[[ -n "$interrupted_log" ]] || { echo "interrupted action uploaded no log" >&2; cat "$tmpdir/interrupted.result" >&2; exit 1; }
require_grep 'checkpoint-cancel-ready' "$tmpdir/remote/cas/$interrupted_log"
require_grep 'exec-action failed: interrupted' "$tmpdir/remote/cas/$interrupted_log"
[[ ! -e "$tmpdir/remote/ac/$key_interrupt" ]] || { echo "interrupted action published a built result" >&2; exit 1; }
[[ ! -e "$interrupted/checkpoints" ]] || { echo "interrupted action kept private checkpoints" >&2; exit 1; }
sed -i 's/OS.Process.sleep (Time.fromSeconds 120)/()/' "$project/src/InterruptedScript.sml"
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$shared_url" action-spec --upload InterruptedTheory) > "$tmpdir/resume.batch"
spec_interrupt=$(field "$tmpdir/resume.batch" share:InterruptedTheory 4)
# A replacement worker uses the same canonical paths but has no local store.
rm -rf "$interrupted/checkpoint-store"
worker interrupted-resume "$shared_url" "$interrupted" "$spec_interrupt" --share-heaps
expect interrupted-resume 0 "status=built"
require_grep 'restored shared .* checkpoint' "$tmpdir/interrupted-resume.log"
require_grep 'checkpoint after completed' "$tmpdir/interrupted-resume.log"

# A theory with declared outputs replays its whole script, so it saves every
# theorem context again: the worker restores only the dependency heap, never a
# context it would save over.
write_x() {
  cat > "$project/src/XScript.sml" <<SML
fun holbuild_extra_outputs (_ : string list) = ()
val _ = holbuild_extra_outputs ["results/X.out"]
val _ = let val out = TextIO.openOut "results/X.out" in TextIO.output (out, "x\\n"); TextIO.closeOut out end
Theory X
Ancestors A
Theorem x1:
  T
Proof
  ACCEPT_TAC a_thm
QED
Theorem x2:
  T
Proof
  $1
QED
SML
}
export_x() {
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$shared_url" action-spec --upload XTheory) > "$tmpdir/x-$1.batch"
  spec_x=$(field "$tmpdir/x-$1.batch" share:XTheory 4)
}
write_x "simp[]"
export_x 1
worker x1 "$shared_url" "$shared" "$spec_x" --share-heaps
expect x1 0 "status=built"
write_x "ACCEPT_TAC TRUTH"
export_x 2
forget_local
worker x2 "$shared_url" "$shared" "$spec_x" --share-heaps
expect x2 0 "status=built"
require_grep "restored shared deps-loaded heap" "$tmpdir/x2.log"
x2_log=$(sed -n 's/^log=\([^ ]*\) .*/\1/p' "$tmpdir/x2.result")
if grep -q "dropping checkpoint\|restored shared theorem_context" "$tmpdir/x2.log" "$tmpdir/remote/cas/$x2_log"; then
  echo "the extra-output theory resumed into restored contexts" >&2
  cat "$tmpdir/x2.log" "$tmpdir/remote/cas/$x2_log" >&2
  exit 1
fi

# A holbuild whose runtime changed only in what a theory loads after its
# dependency heap still restores the heap an earlier release shared; a change
# to what is compiled into the heap misses it.  Spec and worker both come from
# a copy of the binary with its own runtime tree.
patched=$tmpdir/patched-runtime
mkdir -p "$patched/bin" "$patched/share/holbuild"
cp "${REAL_HOLBUILD_BIN:-$HOLBUILD_BIN}" "$patched/bin/holbuild"
cp -R "$SCRIPT_DIR/../../../sml" "$patched/share/holbuild/"
# Checkpoints above the heap hold the runtime, so a change to it misses
# them.  A fresh theory P, whose only failed prefix is the one seeded here
# under the old runtime, shows it for failed prefixes; T's edit of t5, which
# resumed after t4 under the old runtime (v9), for theorem contexts.
write_p() {
  cat > "$project/src/PScript.sml" <<SML
Theory P
Ancestors A
Theorem p1:
  T
Proof
  simp[]
QED
Theorem p2:
  T /\\ (1 = 1)
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >> $1
QED
SML
}
# run_p BIN NAME TACTIC: export P's spec with BIN and run it, after
# forgetting the local checkpoints.
run_p() {
  local bin=$1 name=$2
  write_p "$3"
  (cd "$project" && "$bin" --remote-cache "$shared_url" action-spec --upload PTheory) > "$tmpdir/$name.batch"
  spec_p=$(field "$tmpdir/$name.batch" share:PTheory 4)
  forget_local
  HOLBUILD_BIN=$bin worker "$name" "$shared_url" "$shared" "$spec_p" --share-heaps
}
run_p "$HOLBUILD_BIN" p-seed "FAIL_TAC \"before the runtime change\""
expect p-seed 1 "status=failed" "failure=proof"
run_p "$HOLBUILD_BIN" p-seed2 "ALL_TAC >> FAIL_TAC \"still before the runtime change\""
expect p-seed2 1 "status=failed" "failure=proof"
resumed p-seed2 "failed-prefix checkpoint in p2" "failed_prefix checkpoint"
printf '\n(* changed after the heap *)\n' >> "$patched/share/holbuild/sml/proof_runtime.sml"
run_p "$patched/bin/holbuild" p-runtime "ALL_TAC >> rw[]"
expect p-runtime 0 "status=built"
resumed p-runtime "deps-loaded checkpoint" "deps-loaded heap"
write_t "T \\/ F" "rw[]" "ACCEPT_TAC TRUTH" "ASM_REWRITE_TAC []"
HOLBUILD_BIN=$patched/bin/holbuild export_t t-runtime
forget_local
HOLBUILD_BIN=$patched/bin/holbuild worker t-runtime "$shared_url" "$shared" "$spec_t" --share-heaps
expect t-runtime 0 "status=built"
resumed t-runtime "deps-loaded checkpoint" "deps-loaded heap"
write_x "REWRITE_TAC []"
HOLBUILD_BIN=$patched/bin/holbuild export_x 3
forget_local
HOLBUILD_BIN=$patched/bin/holbuild worker x3 "$shared_url" "$shared" "$spec_x" --share-heaps
expect x3 0 "status=built"
require_grep "restored shared deps-loaded heap" "$tmpdir/x3.log"
require_grep "from: deps-loaded checkpoint" "$tmpdir/x3.log"
printf '\n(* changed in the heap *)\n' >> "$patched/share/holbuild/sml/checkpoint_save_runtime.sml"
write_x "MATCH_ACCEPT_TAC TRUTH"
HOLBUILD_BIN=$patched/bin/holbuild export_x 4
forget_local
HOLBUILD_BIN=$patched/bin/holbuild worker x4 "$shared_url" "$shared" "$spec_x" --share-heaps
expect x4 0 "status=built"
if grep -q "restored shared deps-loaded heap" "$tmpdir/x4.log"; then
  echo "a changed heap runtime restored the old shared deps heap" >&2
  cat "$tmpdir/x4.log" >&2
  exit 1
fi

# A non-target theory has no dependency heap, so its failed prefix uses the
# standalone key.  Exercise the same stale-manifest race on that path.
write_u() {
  cat > "$project/src/UScript.sml" <<SML
Theory U
Ancestors bool

Theorem u1:
  T
Proof
  simp[]
QED

Theorem u2:
  T /\\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >> $1
QED
SML
}
cat > "$project/src/VScript.sml" <<'SML'
Theory V
Ancestors U

Theorem v:
  T
Proof
  ACCEPT_TAC TRUTH
QED
SML
export_u() {
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$shared_url" action-spec --upload VTheory) \
    > "$tmpdir/u-$1.batch"
  spec_u=$(field "$tmpdir/u-$1.batch" share:UTheory 4)
  [[ -n "$spec_u" ]] || { cat "$tmpdir/u-$1.batch" >&2; exit 1; }
}
standalone_entry() {
  local path
  for path in "$tmpdir"/remote/ac/*; do
    if grep -qx "holbuild-shared-failed-prefix-v1" "$path" &&
       grep -qx "kind=failed_prefix" "$path"; then
      printf '%s\n' "$path"
      return
    fi
  done
}
write_u 'FAIL_TAC "standalone seeded failure"'
export_u seed
forget_local
worker u-seed "$shared_url" "$shared" "$spec_u" --share-heaps
expect u-seed 1 "status=failed" "failure=proof"
standalone=$(standalone_entry)
[[ -n "$standalone" ]] || { echo "u-seed published no standalone failed prefix" >&2; exit 1; }
standalone_key=${standalone##*/}
cp "$standalone" "$tmpdir/control/ac-stale-$standalone_key"
cp "$standalone" "$tmpdir/control/ac-stale-next-$standalone_key"
rm -f "$tmpdir/control/no-cache-gets"

write_u 'ALL_TAC >> FAIL_TAC "standalone later failure"'
export_u advance
forget_local
worker u-advance "$shared_url" "$shared" "$spec_u" --share-heaps
expect u-advance 1 "status=failed" "failure=proof"
resumed u-advance "failed-prefix checkpoint in u2" "standalone failed_prefix checkpoint"
[[ "$(grep -cx "$standalone_key" "$tmpdir/control/no-cache-gets")" -ge 1 ]] || {
  echo "u-advance did not revalidate the standalone failed-prefix manifest" >&2; exit 1; }

forget_local
worker u-repeat "$shared_url" "$shared" "$spec_u" --share-heaps
expect u-repeat 1 "status=failed" "failure=proof"
resumed u-repeat "failed-prefix checkpoint in u2" "standalone failed_prefix checkpoint"
u_advance_steps=$(restored_steps u-advance)
u_repeat_steps=$(restored_steps u-repeat)
[[ -n "$u_advance_steps" && -n "$u_repeat_steps" && "$u_repeat_steps" -gt "$u_advance_steps" ]] || {
  echo "u-repeat restored $u_repeat_steps steps, the stale u-advance prefix had $u_advance_steps" >&2
  cat "$tmpdir/u-repeat.log" >&2
  exit 1
}
[[ "$(grep -cx "$standalone_key" "$tmpdir/control/no-cache-gets")" -ge 2 ]] || {
  echo "u-repeat did not revalidate the advanced standalone failed-prefix manifest" >&2; exit 1; }
