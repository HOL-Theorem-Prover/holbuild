#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
server_pids=()
cleanup() {
  for pid in ${server_pids[@]+"${server_pids[@]}"}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

# With a Poly/ML that has saveChildWithModules, a deps_loaded checkpoint
# refers to the theory modules it loaded instead of copying them.  When one
# of them is gone, holbuild warns, drops the checkpoint and preloads afresh.
echo 'val _ = PolyML.SaveState.saveChildWithModules;' > "$tmpdir/probe.sml"
if ! "$HOLDIR/bin/hol" run --noconfig "$tmpdir/probe.sml" > /dev/null 2>&1; then
  echo 'module-dependent checkpoints unsupported by this Poly/ML'
  exit 0
fi
use_case_cache "$tmpdir/cache"
project=$tmpdir/project
mkdir -p "$project/src"
write_schema2_prelude > "$project/holproject.toml"
cat >> "$project/holproject.toml" <<'TOML'
[project]
name = "module-checkpoints"
[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Definition a_value_def:
  a_value = T
End
SML
cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors A

Theorem b_first:
  a_value
Proof
  simp[a_value_def]
QED

Theorem b_second:
  a_value /\ T
Proof
  simp[a_value_def]
QED
SML

build() {
  (cd "$project" && "$HOLBUILD_BIN" --cache-dir ../cache -j1 build BTheory) > "$1" 2>&1 ||
    { cat "$1" >&2; return 1; }
}
# Changes B's last proof line without changing a line number or an output.
edit_b() { sed -i "s/^  simp\[a_value_def\].*\$/  simp[a_value_def] (* $1 *)/" "$project/src/BScript.sml"; }
checkpoints=$project/.holbuild/checkpoints/module-checkpoints/src
deps_heap() { find "$checkpoints/BScript.sml.deps" -name deps_loaded.save | head -n 1; }
header() { od -An -tu4 -j8 -N8 "$1" | tr -s ' '; }
module_cache=$HOLBUILD_CACHE/theory-modules

# B's preload writes A's module; the next fresh preload loads it.
build "$tmpdir/first.log"
if grep -q 'module-cache unsupported' "$project/.holbuild/logs/current/module-checkpoints/BTheory/build.log"; then
  if [[ ${HOLBUILD_TEST_REQUIRE_THEORY_MODULES:-0} == 1 ]]; then
    echo 'module-dependent checkpoints need theory module support' >&2
    exit 1
  fi
  echo 'module-dependent checkpoints unsupported by this HOL'
  exit 0
fi
for ext in dat sig sml; do cp "$project/.holbuild/obj/src/BTheory.$ext" "$tmpdir/BTheory.$ext"; done
test "$(find "$module_cache" -name '*-A-*.pmo' | wc -l)" -eq 1
rm -rf "$checkpoints/BScript.sml.deps" "$checkpoints/BScript.sml.theorems" "$HOLBUILD_CACHE/checkpoint-store"
edit_b one
build "$tmpdir/module.log"
heap=$(deps_heap)
[[ "$(header "$heap")" == " 4 104" ]] || { echo "deps_loaded is not module-dependent: $(header "$heap")" >&2; exit 1; }

# A's module goes: the resume falls back with the distinct warning.
find "$module_cache" -name '*-A-*.pmo' -delete
edit_b two
build "$tmpdir/missing.log"
require_grep 'holbuild: warning: module-dependent checkpoint skipped: .*-A-.*\.pmo missing' "$tmpdir/missing.log"
for ext in dat sig sml; do cmp "$tmpdir/BTheory.$ext" "$project/.holbuild/obj/src/BTheory.$ext"; done

# The shared-heap path: a worker restores a module-dependent deps heap that
# another worker published, and A's module is gone from its store.
# exec_b NAME WORKER URL: exec-action of B's current spec on WORKER's cache and
# URL, after building A there.
exec_b() {
  local name=$1 worker=$2 url=$3 batch=$tmpdir/$1.batch spec status
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$url" action-spec --upload BTheory) > "$batch"
  link_hol_toolchain_cache "$worker"
  for theory in A B; do
    spec=$(awk -v want="module-checkpoints:${theory}Theory" '$1 == "action" && $5 == want { print $4 }' "$batch")
    [[ -n "$spec" ]] || continue
    HOLBUILD_CACHE=$worker "$HOLBUILD_BIN" --remote-cache "$url" exec-action "$spec" --share-heaps --cache-limit-gb 1000 \
      --result "$tmpdir/$name-$theory.result" > "$tmpdir/$name-$theory.log" 2>&1 ||
      { cat "$tmpdir/$name-$theory.log" >&2; return 1; }
    # A may come from the remote cache; B is built.
    status='status=(built|cached)'
    [[ $theory == A ]] || status=status=built
    grep -qxE "$status" "$tmpdir/$name-$theory.result" ||
      { cat "$tmpdir/$name-$theory.result" "$tmpdir/$name-$theory.log" >&2; return 1; }
  done
}
# A worker on the first remote writes A's module; a second worker with that
# store loads it, and publishes a module-dependent heap on the second remote.
start_remote_cache_server "$tmpdir/remote1" "$tmpdir/server1"
server_pids+=("$server_pid")
edit_b three
exec_b first "$tmpdir/worker1" "$remote_url"
start_remote_cache_server "$tmpdir/remote2" "$tmpdir/server2"
server_pids+=("$server_pid")
mkdir -p "$tmpdir/worker2"
cp -R "$tmpdir/worker1/theory-modules" "$tmpdir/worker2/"
edit_b four
exec_b publish "$tmpdir/worker2" "$remote_url"
versions=$(find "$tmpdir/worker2/checkpoint-store" -type f -size +1M -exec od -An -tu4 -j8 -N8 {} \; | tr -s ' ')
grep -qx ' 4 104' <<< "$versions" || { echo "no published heap is module-dependent: $versions" >&2; exit 1; }
# The second worker, with only the remote's copy left, restores it after A's
# module changed.  (A missing module is written again before the action
# runs; the heap key names the module store, so a worker shares heaps only
# with workers whose cache has the same path.)
rm -rf "$tmpdir/worker2/checkpoints" "$tmpdir/worker2/checkpoint-store"
for module in "$tmpdir"/worker2/theory-modules/*/*-A-*.pmo; do
  printf '\377' | dd of="$module" bs=1 seek=36 conv=notrunc status=none
done
edit_b five
exec_b restore "$tmpdir/worker2" "$remote_url"
require_grep 'holbuild: warning: module-dependent checkpoint skipped: .*-A-.*\.pmo has another id' "$tmpdir/restore-B.log"
