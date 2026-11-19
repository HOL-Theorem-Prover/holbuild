#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# With a Poly/ML that has PolyML.SaveState.saveChildWithModules, a deps
# heap refers to the theory modules its dependencies loaded instead of
# copying them.  When one of them is gone, the heap and the checkpoints on
# it are dropped and the theory preloads afresh: in a local build resuming
# from a context, from the host's heap store, and on a worker restoring a
# shared heap, which first fetches the modules it lacks.

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

cat > "$tmpdir/modules.sml" <<'SML'
val _ =
  List.app (fn (_, path) => print (path ^ "\n"))
    (PolyML.SaveState.showModuleDependencies (valOf (OS.Process.getEnv "HEAP")));
SML
# heap_modules HEAP: the paths of the modules HEAP loads, one per line.
heap_modules() { HEAP=$1 "$HOLDIR/bin/hol" run --noconfig "$tmpdir/modules.sml" | grep '\.pmo$' || true; }

use_case_cache "$tmpdir/cache"
module_cache=$HOLBUILD_CACHE/theory-modules
project=$tmpdir/project
mkdir -p "$project/src"
write_schema2_prelude > "$project/holproject.toml"
cat >> "$project/holproject.toml" <<'TOML'
[project]
name = "deps-modules"
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
cat > "$project/src/ZScript.sml" <<'SML'
Theory Z
Ancestors A

Theorem z_thm:
  a_value
Proof
  simp[a_value_def]
QED
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
  rw[a_value_def] (* b_second *)
QED
SML

build() {
  (cd "$project" && HOLBUILD_CHECKPOINT_TIMING=1 "$HOLBUILD_BIN" --cache-dir ../cache -j1 build BTheory) > "$1" 2>&1 ||
    { cat "$1" >&2; return 1; }
}
# Changes b_second's proof without changing a line number or an output,
# so that a build can resume from b_first's context.
edit_b() { sed -i "s/^  .*(\* b_second.*\$/  rw[a_value_def] (* b_second $1 *)/" "$project/src/BScript.sml"; }
break_b() { sed -i "s/^  .*(\* b_second.*\$/  FAIL_TAC \"b_second broken\" (* b_second *)/" "$project/src/BScript.sml"; }
checkpoints=$project/.holbuild/checkpoints/deps-modules/src
deps_heap() { find "$checkpoints/BScript.sml.deps" -name deps_loaded.save | head -n 1; }
same_outputs() { for ext in dat sig sml; do cmp "$tmpdir/BTheory.$ext" "$project/.holbuild/obj/src/BTheory.$ext"; done; }
# needs_a HEAP: HEAP loads A's module, which is in the store.
needs_a() {
  local module
  module=$(heap_modules "$1" | grep -- '-A-' || true)
  [[ -n "$module" && -f "$module" ]] ||
    { echo "$1 doesn't load A's module: $(heap_modules "$1")" >&2; exit 1; }
}

b_log=$project/.holbuild/logs/current/deps-modules/BTheory/build.log
# deps_saved SHARE WITH_MODULES: how B's last build saved its deps heap.
deps_saved() { require_grep "holbuild checkpoint kind=deps_loaded share=$1 with_modules=$2 " "$b_log"; }

# B's first preload loads A from its .dat, loading no module (a cold store,
# or no theory modules), so its heap is shared and holds A, as without
# saveChildWithModules.  It writes A's module.
build "$tmpdir/first.log"
deps_saved true false
echo 'val _ = PolyML.SaveState.saveChildWithModules;' > "$tmpdir/probe.sml"
if ! "$HOLDIR/bin/hol" run --noconfig "$tmpdir/probe.sml" > /dev/null 2>&1; then
  if [[ ${HOLBUILD_TEST_REQUIRE_MODULE_HEAPS:-0} == 1 ]]; then
    echo 'this Poly/ML has no PolyML.SaveState.saveChildWithModules' >&2
    exit 1
  fi
  echo 'deps heaps that refer to modules unsupported by this Poly/ML'
  exit 0
fi
# The next fresh preload loads A's module, and the heap it saves refers to it.
if grep -q 'module-cache unsupported' "$b_log" ||
   [[ -z "$(find "$module_cache" -name '*-A-*.pmo' 2>/dev/null)" ]]; then
  if [[ ${HOLBUILD_TEST_REQUIRE_THEORY_MODULES:-0} == 1 ]]; then
    echo 'deps heaps that refer to modules need theory module support' >&2
    exit 1
  fi
  echo 'deps heaps that refer to modules unsupported by this HOL'
  exit 0
fi
for ext in dat sig sml; do cp "$project/.holbuild/obj/src/BTheory.$ext" "$tmpdir/BTheory.$ext"; done
rm -rf "$checkpoints/BScript.sml.deps" "$checkpoints/BScript.sml.theorems" "$HOLBUILD_CACHE/checkpoint-store"
edit_b one
build "$tmpdir/module.log"
deps_saved false true
needs_a "$(deps_heap)"
same_outputs

# A resume from b_first's context, on that heap, after A's module went.
find "$module_cache" -name '*-A-*.pmo' -delete
edit_b two
build "$tmpdir/resume.log"
require_grep 'from: theorem-context checkpoint after b_first' "$tmpdir/resume.log"
require_grep 'discarding invalid checkpoint after HOL state load failure' "$tmpdir/resume.log"
same_outputs
# The fresh preload loaded A from its .dat again, and wrote the module.
deps_saved true false

# A resume from b_second's failed prefix, on such a heap, after A's module
# went.
rm -rf "$checkpoints" "$HOLBUILD_CACHE/checkpoint-store"
edit_b prefix
build "$tmpdir/prefix-heap.log"
deps_saved false true
break_b
if build "$tmpdir/broken.log" 2> /dev/null; then
  echo 'b_second built with a failing proof' >&2; exit 1
fi
require_grep 'b_second broken' "$tmpdir/broken.log"
find "$module_cache" -name '*-A-*.pmo' -delete
edit_b fixed
build "$tmpdir/prefix.log"
require_grep 'from: failed-prefix checkpoint in b_second' "$tmpdir/prefix.log"
require_grep 'discarding invalid checkpoint after HOL state load failure' "$tmpdir/prefix.log"
same_outputs

# The host's heap store: a tree without a heap takes the store's, but not
# once A's module went.
rm -rf "$checkpoints" "$HOLBUILD_CACHE/checkpoint-store"
edit_b store
build "$tmpdir/stored.log"
deps_saved false true
needs_a "$(deps_heap)"
rm -rf "$checkpoints"
find "$module_cache" -name '*-A-*.pmo' -delete
edit_b three
build "$tmpdir/store.log"
require_grep "the host store's deps heap needs a missing theory module: .*-A-.*\.pmo" "$tmpdir/store.log"
if grep -q 'discarding invalid checkpoint' "$tmpdir/store.log"; then
  echo 'the store heap was loaded without its module' >&2; cat "$tmpdir/store.log" >&2; exit 1
fi
same_outputs

# Shared heaps.  A runs on another worker, so that W's store is fresh when
# Z's run on W writes the modules Z loads, A's among them, and publishes
# them.  Z shares no heap: its heap, saved before A's module existed,
# would serve B, which has the same dependencies.  B's run on W then loads
# A's module and publishes a heap that refers to it.
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server" "$tmpdir/control"
server_pids+=("$server_pid")
worker=$tmpdir/worker
# exec_theory THEORY NAME [unshared]: exec-action of THEORY's current spec
# on W, sharing heaps unless told otherwise, after A's on another worker if
# A has one.
exec_theory() {
  local theory=$1 name=$2 batch=$tmpdir/$2.batch spec dep cache share=(--share-heaps)
  [[ ${3:-} != unshared ]] || share=()
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload "${theory}Theory") > "$batch"
  for dep in A "$theory"; do
    spec=$(awk -v want="deps-modules:${dep}Theory" '$1 == "action" && $5 == want { print $4 }' "$batch")
    # A cached theory has no action.
    [[ -n "$spec" ]] || continue
    cache=$worker
    [[ $dep == "$theory" ]] || cache=$tmpdir/worker-deps
    link_hol_toolchain_cache "$cache"
    HOLBUILD_CACHE=$cache "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$spec" ${share[@]+"${share[@]}"} \
      --cache-limit-gb 1000 --result "$tmpdir/$name-$dep.result" > "$tmpdir/$name-$dep.log" 2>&1 ||
      { cat "$tmpdir/$name-$dep.log" "$tmpdir/$name-$dep.result" >&2; return 1; }
    grep -qxE 'status=(built|cached)' "$tmpdir/$name-$dep.result" ||
      { cat "$tmpdir/$name-$dep.result" "$tmpdir/$name-$dep.log" >&2; return 1; }
  done
}
phase() {
  grep -qE "^phase-ms=(.*,)?$2(,|\$)" "$tmpdir/$1.result" ||
    { echo "$1 lacks phase $2:" >&2; cat "$tmpdir/$1.result" "$tmpdir/$1.log" >&2; exit 1; }
}
# resumed NAME: NAME's HOL child started from the restored deps heap or a
# checkpoint on it, and dropped none.
resumed() {
  phase "$1" 'res(deps|ctx)n:1'
  grep -qE 'from: (deps-loaded|theorem-context) checkpoint' "$tmpdir/$1.log" ||
    { echo "$1 didn't resume:" >&2; cat "$tmpdir/$1.log" >&2; exit 1; }
  if grep -qE '^phase-ms=(.*,)?rstdropn:' "$tmpdir/$1.result" ||
     grep -q 'discarding invalid checkpoint' "$tmpdir/$1.log"; then
    echo "$1 dropped a checkpoint:" >&2; cat "$tmpdir/$1.result" "$tmpdir/$1.log" >&2; exit 1
  fi
}
worker_modules=$worker/theory-modules
exec_theory Z z unshared
rm -rf "$worker/checkpoint-store" "$worker/checkpoints"
exec_theory B publish
published=$(find "$worker/checkpoint-store" -type f -name '[0-9a-f]*' -size +1M)
modules=$(for heap in $published; do heap_modules "$heap"; done | { grep -- '-A-' || true; } | sort -u)
[[ -n "$modules" ]] || { echo "no published heap loads A's module" >&2; exit 1; }

# W loses its stores: the restore fetches A's module, then the heap.
rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
edit_b four
exec_theory B fetch
phase fetch-B 'rstmodn:1'
require_grep 'restored shared' "$tmpdir/fetch-B.log"
resumed fetch-B
[[ -f "$modules" ]] || { echo "A's module wasn't fetched to $modules" >&2; exit 1; }

# The remote cache loses A's module too: the heap is dropped, and B preloads
# afresh.
module_sha=$(sha256sum "$modules" | cut -d' ' -f1)
echo 404 > "$tmpdir/control/cas-get-status-$module_sha"
rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
edit_b five
exec_theory B dropped
phase dropped-B 'rstmoddropn:1'
require_grep "the shared deps-loaded heap needs a theory module this host lacks: .*-A-.*\.pmo" "$tmpdir/dropped-B.log"
grep -qx 'status=built' "$tmpdir/dropped-B.result"

# B's run published the heap it saved in place of the one it gave up.
rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
edit_b six
exec_theory B replaced
require_grep 'restored shared' "$tmpdir/replaced-B.log"
resumed replaced-B
if grep -qE '^phase-ms=(.*,)?rstmoddropn:' "$tmpdir/replaced-B.result"; then
  echo 'the heap given up was not replaced' >&2; cat "$tmpdir/replaced-B.result" >&2; exit 1
fi
