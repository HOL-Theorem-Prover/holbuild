#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# build --check-only gives a target the verdict a plain build would, and
# writes no outputs: none installed, none cached, here or by a remote
# worker.  What the target loads is built and cached as usual, and a
# failed proof still saves its prefix, which the next check resumes from.

tmpdir=$(make_temp_dir)
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "checkonly"

[build]
members = ["src"]
TOML

cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Theorem a:
  T
Proof
  ACCEPT_TAC TRUTH
QED
SML

# write_t STEP [PARENT]: theory T, on A (or PARENT), whose second theorem's
# last step is STEP.
write_t() {
  cat > "$project/src/TScript.sml" <<SML
Theory T
Ancestors ${2:-A}

Theorem t1:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem t2:
  T /\\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >> $1
QED
SML
}

obj=$project/.holbuild/obj/src
t_outputs=("$obj/TTheory.dat" "$obj/TTheory.sig" "$obj/TTheory.sml")
checkpoints=$project/.holbuild/checkpoints
saves() { find "$checkpoints" -path "*/$1Script.sml*" -name '*.save' 2>/dev/null | sort; }
# entries: the local cache's action entries, one file per line.
entries() { find "$HOLBUILD_CACHE/actions" -type f 2>/dev/null | sort; }
build() {
  local name=$1
  shift
  set +e
  (cd "$project" && "$HOLBUILD_BIN" build "$@") > "$tmpdir/$name.log" 2>&1
  build_status=$?
  set -e
}
expect_build() {
  if [[ "$build_status" != "$2" ]]; then
    echo "build $1 exited $build_status, wanted $2" >&2
    cat "$tmpdir/$1.log" >&2
    exit 1
  fi
}
no_t_outputs() {
  for output in "${t_outputs[@]}"; do
    if [[ -e "$output" ]]; then echo "$1: check-only wrote $output" >&2; exit 1; fi
  done
}

# A first check builds A in full and checks T alone.
write_t "ACCEPT_TAC TRUTH"
build first --check-only TTheory
expect_build first 0
[[ -f "$obj/ATheory.dat" ]] || { echo "the dependency A was not built" >&2; exit 1; }
no_t_outputs first
a_entries=$(entries)
[[ -n "$a_entries" ]] || { echo "the dependency A was not cached" >&2; exit 1; }

# The same check again builds T again: it left nothing to find.
build again --check-only TTheory
expect_build again 0
no_t_outputs again
[[ "$(entries)" == "$a_entries" ]] || { echo "check-only cached T" >&2; entries >&2; exit 1; }

# A failing proof fails the check as it fails a build, and saves its prefix.
write_t 'FAIL_TAC "seeded failure"'
build fail --check-only TTheory
expect_build fail 1
require_grep "seeded failure" "$tmpdir/fail.log"
grep -q '_failed_prefix\.save$' <<< "$(saves T)" || { echo "the failed check saved no prefix" >&2; saves T >&2; exit 1; }
no_t_outputs fail
build fail-plain TTheory
expect_build fail-plain 1
require_grep "seeded failure" "$tmpdir/fail-plain.log"

# The fixed proof resumes from the prefix and passes; T still has no outputs.
write_t "ALL_TAC >> ACCEPT_TAC TRUTH"
build fixed --check-only TTheory
expect_build fixed 0
require_grep "from: failed-prefix checkpoint in t2" "$tmpdir/fixed.log"
no_t_outputs fixed
[[ "$(entries)" == "$a_entries" ]] || { echo "check-only cached T" >&2; entries >&2; exit 1; }

# A plain build then builds T, and check-only leaves its outputs as they are,
# up to date or not.
build plain TTheory
expect_build plain 0
t_dat=$(sha256sum "$obj/TTheory.dat")
t_metadata=$(find "$project/.holbuild" -name 'TScript.sml.key' -exec sha256sum {} + | sort)
build up-to-date --check-only TTheory
expect_build up-to-date 0
write_t 'FAIL_TAC "after a build"'
build fail-built --check-only TTheory
expect_build fail-built 1
require_grep "after a build" "$tmpdir/fail-built.log"
write_t "ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH"
build pass-built --check-only TTheory
expect_build pass-built 0
[[ "$(sha256sum "$obj/TTheory.dat")" == "$t_dat" ]] || { echo "check-only replaced T's outputs" >&2; exit 1; }
[[ "$(find "$project/.holbuild" -name 'TScript.sml.key' -exec sha256sum {} + | sort)" == "$t_metadata" ]] ||
  { echo "check-only changed T's metadata" >&2; exit 1; }

# Metadata a build with output hashes wrote stays as it is too.
build hashes --emit-output-hashes TTheory
expect_build hashes 0
grep -rq 'output-sha256=' --include='TScript.sml.key' "$project/.holbuild" ||
  { echo "the build with output hashes recorded none" >&2; exit 1; }
t_metadata=$(find "$project/.holbuild" -name 'TScript.sml.key' -exec sha256sum {} + | sort)
build hashes-check --check-only TTheory
expect_build hashes-check 0
[[ "$(find "$project/.holbuild" -name 'TScript.sml.key' -exec sha256sum {} + | sort)" == "$t_metadata" ]] ||
  { echo "check-only rewrote metadata with output hashes" >&2; exit 1; }

# With T's outputs gone, its cache entry from the plain build, whose .dat
# records A's outputs as installed here, passes the check without a build,
# and installs nothing.
write_t "ALL_TAC >> ACCEPT_TAC TRUTH"
rm -f "${t_outputs[@]}"
find "$project/.holbuild" -name 'TScript.sml.key' -delete
build cached --check-only TTheory
expect_build cached 0
require_grep "TTheory restored" "$tmpdir/cached.log"
no_t_outputs cached
[[ -z $(find "$project/.holbuild" -name 'TScript.sml.key') ]] || { echo "check-only wrote T's metadata" >&2; exit 1; }

# A target another target depends on is built in full, in either order: A,
# changed, gets new outputs and a new cache entry; T still gets none.
for order in "ATheory TTheory" "TTheory ATheory"; do
  cat >> "$project/src/AScript.sml" <<SML

Theorem a_${order%% *}:
  T
Proof
  ACCEPT_TAC TRUTH
QED
SML
  a_dat=$(sha256sum "$obj/ATheory.dat")
  before=$(entries)
  # shellcheck disable=SC2086
  build "both-${order%% *}" --check-only $order
  expect_build "both-${order%% *}" 0
  [[ "$(sha256sum "$obj/ATheory.dat")" != "$a_dat" ]] || { echo "check-only of $order left A unbuilt" >&2; exit 1; }
  [[ "$(entries)" != "$before" ]] || { echo "check-only of $order cached no new entry of A" >&2; exit 1; }
  no_t_outputs "both-${order%% *}"
done

for flag in --emit-output-hashes --repl-on-failure; do
  build "reject$flag" --check-only "$flag" TTheory
  expect_build "reject$flag" 1
  require_grep "remove $flag" "$tmpdir/reject$flag.log"
done

# exec-action: the worker gives the verdict, and publishes nothing of T: no
# action entry, no early-cutoff pair, no deps heap.  A failure still shares
# its prefix.
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
url=$remote_url
worker_cache=$tmpdir/worker
field() { awk -v want="$2" -v col="$3" '$1 == "action" && $5 == want { print $col }' "$1"; }
# worker NAME [plain|keep]: runs T's check-only action (its plain one with
# plain) on a fresh worker cache (the last one with keep).
worker() {
  local name=$1 spec check=(--check-only)
  [[ ${2:-} == plain ]] && check=()
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$url" action-spec --upload "${check[@]}" TTheory) \
    > "$tmpdir/$name.batch"
  spec=$(field "$tmpdir/$name.batch" checkonly:TTheory 4)
  remote_key=$(field "$tmpdir/$name.batch" checkonly:TTheory 3)
  [[ -n "$spec" ]] || { cat "$tmpdir/$name.batch" >&2; exit 1; }
  if [[ ${2:-} != keep ]]; then
    rm -rf "$worker_cache"
    link_hol_toolchain_cache "$worker_cache"
  fi
  set +e
  HOLBUILD_CACHE=$worker_cache "$HOLBUILD_BIN" --remote-cache "$url" exec-action "$spec" --share-heaps \
    --cache-limit-gb 1000 --result "$tmpdir/$name.result" > "$tmpdir/$name.log" 2>&1
  worker_status=$?
  set -e
}
expect_worker() {
  local name=$1 code=$2
  shift 2
  if [[ "$worker_status" != "$code" ]]; then
    echo "worker $name exited $worker_status, wanted $code" >&2
    cat "$tmpdir/$name.log" "$tmpdir/$name.result" >&2 || true
    exit 1
  fi
  for line in "$@"; do
    grep -qxF -- "$line" "$tmpdir/$name.result" || {
      echo "worker $name result lacks '$line':" >&2; cat "$tmpdir/$name.result" >&2; exit 1; }
  done
}
published() { grep -lx "$1" "$tmpdir"/remote/ac/* 2>/dev/null || true; }
# hydrated NAME LIGHT INSTALLED: the worker's hydrate left LIGHT
# dependencies uninstalled, and installed INSTALLED (0: none).
hydrated() {
  local phases
  phases=$(sed -n 's/^phase-ms=//p' "$tmpdir/$1.result" | tr , '\n')
  grep -qx "hydlightn:$2" <<<"$phases" || {
    echo "worker $1 left not $2 dependencies uninstalled:" >&2; cat "$tmpdir/$1.result" >&2; exit 1; }
  if [[ $3 == 0 ]]; then
    ! grep -q "^hydinstn:[1-9]" <<<"$phases" || {
      echo "worker $1 installed a dependency:" >&2; cat "$tmpdir/$1.result" "$tmpdir/$1.log" >&2; exit 1; }
  else
    grep -qx "hydinstn:$3" <<<"$phases" || {
      echo "worker $1 installed not $3 dependencies:" >&2; cat "$tmpdir/$1.result" >&2; exit 1; }
  fi
}
# The module writer, which runs after a plain action's result where the
# toolchain can write theory modules (as in the theory-modules job), is never
# scheduled for a check-only one.
no_modules() {
  require_grep 'exec-action after the result (ms): .* modules_writer=none:unscheduled' "$tmpdir/$1.log"
  [[ -z $(find "$worker_cache" -name '*.pmo' 2>/dev/null) ]] || {
    echo "worker $1 wrote theory modules" >&2; find "$worker_cache" -name '*.pmo' >&2; exit 1; }
}
nothing_published() {
  if [[ -e "$tmpdir/remote/ac/$remote_key" ]]; then
    echo "worker $1 published T's entry" >&2; exit 1
  fi
  if [[ -n "$(published holbuild-early-cutoff-v1)$(published holbuild-shared-heap-v1)" ]]; then
    echo "worker $1 published an early-cutoff pair or a deps heap" >&2; exit 1
  fi
}

# A, which T loads, is in the remote cache, as a batch's client leaves it.
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$url" build --force-theory ATheory) > "$tmpdir/publish-a.log" 2>&1 ||
  { cat "$tmpdir/publish-a.log" >&2; exit 1; }

write_t "ALL_TAC >> ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH"
worker share-pass
grep -rqx "option check-only=true" "$tmpdir/remote" || { echo "no spec says check-only" >&2; exit 1; }
expect_worker share-pass 0 "status=built"
nothing_published share-pass
no_modules share-pass
# With no heap to resume from, HOL starts from a fresh preload, which loads
# A: it is installed first.
hydrated share-pass 1 1

write_t 'FAIL_TAC "remote failure"'
worker share-fail
expect_worker share-fail 1 "status=failed" "failure=proof"
require_grep "remote failure" "$tmpdir/share-fail.log"
nothing_published share-fail
no_modules share-fail
[[ -n "$(published holbuild-shared-failed-prefix-v1)" ]] || {
  echo "the failing check shared no failed prefix" >&2; cat "$tmpdir/share-fail.log" >&2; exit 1; }

# A check that resumes from the failed prefix, on a fresh host, installs no
# dependency: the heap has A loaded, and HOL reads no file of it.
write_t "ALL_TAC >> ACCEPT_TAC TRUTH"
worker resume-light
expect_worker resume-light 0 "status=built"
hydrated resume-light 1 0
nothing_published resume-light
write_t 'ALL_TAC >> FAIL_TAC "resumed failure"'
worker resume-light-fail
expect_worker resume-light-fail 1 "status=failed" "failure=proof"
require_grep "resumed failure" "$tmpdir/resume-light-fail.log"
hydrated resume-light-fail 1 0

# Theory modules a plain action published are fetched by none: a plain
# worker publishes A's module where the toolchain writes them, and a
# check-only one, on a fresh host, writes and fetches none.
write_t "ALL_TAC >> ACCEPT_TAC TRUTH >> ALL_TAC"
worker plain-modules plain
expect_worker plain-modules 0 "status=built"
if [[ ${HOLBUILD_TEST_REQUIRE_THEORY_MODULES:-0} == 1 ]]; then
  require_grep 'modules_published=[1-9]' "$tmpdir/plain-modules.log"
fi
write_t "ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH >> ALL_TAC"
worker share-modules
expect_worker share-modules 0 "status=built"
no_modules share-modules
# The plain action shared its deps heap, which the check resumes from.
hydrated share-modules 1 0

# A heap HOL can't resume from, found in the worker's store, is discarded,
# and the check goes on from a fresh preload, with A installed first.  As in
# tests/cases/shared-deps-heap, bytes 72-75 of the header hold the parent's
# time stamp, which Poly/ML checks when it loads the state.
rm -rf "$worker_cache/action" "$worker_cache/checkpoints"
heaps=$(find "$worker_cache/checkpoint-store" -type f -size +100k ! -name "*.pmo")
[[ -n "$heaps" ]] || { echo "the worker's store holds no heap" >&2; exit 1; }
for heap in $heaps; do
  cp "$heap" "$tmpdir/stale"
  printf '\xff\xff\xff\xff' | dd of="$tmpdir/stale" bs=1 seek=72 conv=notrunc status=none
  mv "$tmpdir/stale" "$heap"
done
write_t "ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH >> ALL_TAC >> ALL_TAC"
worker stale-heap keep
expect_worker stale-heap 0 "status=built"
require_grep 'discarding invalid checkpoint after HOL state load failure' "$tmpdir/stale-heap.log"
hydrated stale-heap 1 1

# A check that passes on the plain action's entry, without HOL, installs its
# dependencies first, which checks they fit their parents.
write_t "ALL_TAC >> ACCEPT_TAC TRUTH >> ALL_TAC"
worker cached-pass
expect_worker cached-pass 0 "status=cached"
hydrated cached-pass 1 1

# T on B, on A: A is a dependency T doesn't load directly.
cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors A

Theorem b:
  T
Proof
  ACCEPT_TAC TRUTH
QED
SML
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$url" build --force-theory BTheory) > "$tmpdir/publish-b.log" 2>&1 ||
  { cat "$tmpdir/publish-b.log" >&2; exit 1; }
write_t "ALL_TAC >> ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH" B
worker chain
expect_worker chain 0 "status=built"
hydrated chain 2 2

# On the same host, the copies the action root keeps are neither recorded
# again nor installed.
write_t "ALL_TAC >> ALL_TAC >> ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH" B
worker warm-kept keep
expect_worker warm-kept 0 "status=built"
hydrated warm-kept 0 0

# A kept copy of A missing its .dat is removed and recorded again.  Its local
# cache entry, which names a transient stage mldep, is one the light hydrate
# can't use: it is dropped, as a full restore drops it, so the retry restores
# A from the remote's entry.  A failed hydrate saves no records, so the retry
# keeps no copy: it records and installs both dependencies.
a_key=$(cd "$project" && "$HOLBUILD_BIN" build --dry-run ATheory | awk '/input_key:/ {print $2; exit}')
a_manifest=$worker_cache/actions/$a_key/manifest
require_file "$a_manifest"
printf 'mldep /stale/.holbuild/stage/%s/ATheory\n' "$a_key" >> "$a_manifest"
a_dat=$(find "$worker_cache/action" -name ATheory.dat)
[[ -n "$a_dat" ]] || { echo "the worker's action root holds no ATheory.dat" >&2; exit 1; }
rm -f $a_dat
write_t "ALL_TAC >> ALL_TAC >> ACCEPT_TAC TRUTH >> ALL_TAC >> ALL_TAC >> ALL_TAC" B
worker transient keep
expect_worker transient 3 "status=failed" "failure=input-missing" "missing=theory $a_key"
[[ ! -e "$a_manifest" ]] || { echo "the light hydrate kept A's unusable cache entry" >&2; exit 1; }
worker transient-retry keep
expect_worker transient-retry 0 "status=built"
hydrated transient-retry 2 2
