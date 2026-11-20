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
worker_pid=
cleanup() {
  if [[ -n "$worker_pid" ]]; then
    touch "$tmpdir/control/action-get-release"
    wait "$worker_pid" 2>/dev/null || true
  fi
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
cat > "$project/src/CScript.sml" <<'SML'
Theory C
Ancestors A Z

Theorem c_first:
  a_value
Proof
  simp[a_value_def]
QED

Theorem c_thm:
  a_value
Proof
  rw[a_value_def] (* c_thm *)
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
# discarded_once LOG: the build discarded the deps heap and the checkpoints
# on it once, for the missing module, and then preloaded afresh.
discarded_once() {
  local all module
  all=$(grep -c 'discarding invalid checkpoint after HOL state load failure' "$1" || true)
  module=$(grep -c 'discarding invalid checkpoint after HOL state load failure: .*Required module missing or changed' "$1" || true)
  [[ $all == 1 && $module == 1 ]] ||
    { echo "$1: $all discards, $module for a module, not one" >&2; cat "$1" >&2; exit 1; }
}
# deps_saved SHARE WITH_MODULES: how B's last build saved its deps heap.
deps_saved() { require_grep "holbuild checkpoint kind=deps_loaded share=$1 with_modules=$2 " "$b_log"; }

# B's first preload loads A from its .dat, loading no module (a cold store,
# or no theory modules), so its heap is shared and holds A, as without
# saveChildWithModules.  It writes A's module.
build "$tmpdir/first.log"
deps_saved true false
# skip REASON: the rest needs what this toolchain lacks.
skip() {
  if [[ ${HOLBUILD_TEST_REQUIRE_MODULE_HEAPS:-0} == 1 ]]; then
    echo "deps heaps that refer to modules need $1" >&2
    exit 1
  fi
  echo "deps heaps that refer to modules unsupported: no $1"
  exit 0
}
if grep -q 'module-cache unsupported' "$b_log" ||
   [[ -z "$(find "$module_cache" -name '*-A-*.pmo' 2>/dev/null)" ]]; then
  [[ ${HOLBUILD_TEST_REQUIRE_THEORY_MODULES:-0} != 1 ]] ||
    { echo 'deps heaps that refer to modules need theory module support' >&2; exit 1; }
  skip 'theory module support'
fi
# The next fresh preload loads A's module, and the heap it saves refers to
# it, if Poly/ML has saveChildWithModules; without it, the heap is saved
# shared, holding A, as before.
for ext in dat sig sml; do cp "$project/.holbuild/obj/src/BTheory.$ext" "$tmpdir/BTheory.$ext"; done
rm -rf "$checkpoints/BScript.sml.deps" "$checkpoints/BScript.sml.theorems" "$HOLBUILD_CACHE/checkpoint-store"
edit_b one
build "$tmpdir/module.log"
same_outputs
echo 'val _ = PolyML.SaveState.saveChildWithModules;' > "$tmpdir/probe.sml"
if ! "$HOLDIR/bin/hol" run --noconfig "$tmpdir/probe.sml" > /dev/null 2>&1; then
  deps_saved true false
  skip 'PolyML.SaveState.saveChildWithModules'
fi
deps_saved false true
needs_a "$(deps_heap)"

# A resume from b_first's context, on that heap, after A's module went.
find "$module_cache" -name '*-A-*.pmo' -delete
edit_b two
build "$tmpdir/resume.log"
require_grep 'from: theorem-context checkpoint after b_first' "$tmpdir/resume.log"
discarded_once "$tmpdir/resume.log"
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
discarded_once "$tmpdir/prefix.log"
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
# exec_theory THEORY NAME [unshared] [tool cache name]: exec-action of THEORY's current spec
# on W, sharing heaps unless told otherwise, after A's on another worker if
# A has one.
exec_theory() {
  local theory=$1 name=$2 batch=$tmpdir/$2.batch spec dep cache share=(--share-heaps) options=()
  [[ ${3:-} != unshared ]] || share=()
  [[ -z ${4:-} ]] || options=(--tool-cache "$4")
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload \
    ${options[@]+"${options[@]}"} "${theory}Theory") > "$batch"
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
# resumed NAME [FROM]: NAME's HOL child started from the restored deps
# heap or a checkpoint on it (FROM, a regex, if given), and dropped none.
resumed() {
  phase "$1" 'res(deps|ctx)n:1'
  grep -qE "from: ${2:-(deps-loaded|theorem-context) checkpoint}" "$tmpdir/$1.log" ||
    { echo "$1 didn't resume:" >&2; cat "$tmpdir/$1.log" >&2; exit 1; }
  if grep -qE '^phase-ms=(.*,)?(rstdropn|rstmodrejn):' "$tmpdir/$1.result" ||
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
cp "$modules" "$tmpdir/A.pmo"

# The remote cache loses A's module too: W gives the heap up, and B
# preloads afresh.
module_sha=$(sha256sum "$modules" | cut -d' ' -f1)
echo 404 > "$tmpdir/control/cas-get-status-$module_sha"
rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
edit_b five
exec_theory B dropped
phase dropped-B 'rstmoddropn:1'
require_grep "the shared deps-loaded heap needs a theory module this host lacks: .*-A-.*\.pmo" "$tmpdir/dropped-B.log"
grep -qx 'status=built' "$tmpdir/dropped-B.result"
if grep -qE '^phase-ms=(.*,)?rstrejectn:' "$tmpdir/dropped-B.result"; then
  echo 'checkpoints on the heap given up were tried' >&2; cat "$tmpdir/dropped-B.result" >&2; exit 1
fi

# The shared heap stays: once the cache has A's module again, W fetches it
# and resumes from the heap's checkpoints.
rm -f "$tmpdir/control/cas-get-status-$module_sha"
rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
edit_b six
exec_theory B healed
phase healed-B 'rstmodn:1'
require_grep 'restored shared' "$tmpdir/healed-B.log"
resumed healed-B 'theorem-context checkpoint after b_first'

# C's heap loads A's module. A module for the same .dat file with a
# different Poly/ML ID must be replaced before C can resume.
edit_c() { sed -i "s/^  .*(\* c_thm.*\$/  rw[a_value_def] (* c_thm $1 *)/" "$project/src/CScript.sml"; }
rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
mkdir -p "$(dirname "$modules")"
cp "$tmpdir/A.pmo" "$modules"
exec_theory C c
published=$(find "$worker/checkpoint-store" -type f -name '[0-9a-f]*' -size +1M)
for heap in $published; do heap_modules "$heap"; done | grep -q -- '-A-' ||
  { echo "C's published heap doesn't load A's module" >&2; exit 1; }
# Export the same theory's theorem values with different sharing in the
# module. Keep the decoded ATheory.dat and the normal module filename.
cat > "$tmpdir/alternate-module.sml" <<'SML'
val _ = PolyML.use (valOf (OS.Process.getEnv "MODULE_HELPER"));
val _ = let
  open TheoryModules
  fun env name = valOf (OS.Process.getEnv name)
  val stem = env "A_STEM"
  val path = stem ^ ".dat"
  val (thy, hash) = valOf (sml_header (stem ^ ".sml"))
  val (data, _) = TheoryReader.decode_thydata {thyname = thy, path = path, hash = hash}
  val digest = file_digest path
  val signature_root :: values_root :: rest =
    valOf (module_roots "ATheory" digest data (core_bindings ()))
  val (name, values) = Universal.tagProject TheoryReader.values_tag values_root
  fun copy th = Thm.EQ_MP (Thm.REFL (Thm.concl th)) th
  val alternate = Universal.tagInject TheoryReader.values_tag (name, Vector.map copy values)
  val roots = signature_root :: alternate :: rest
  val base_id = valOf (base_id_of (env "BASE_STATE"))
  val id = #1 (Save.getModuleInfo (env "MODULE"))
  val _ = save_module (env "MODULE") base_id roots
in
  if #1 (Save.getModuleInfo (env "MODULE")) = id
  then raise Fail "A's modules have the same Poly/ML ID"
  else ()
end;
SML
BASE_STATE=$HOLDIR/bin/hol.state
A_STEM=$project/.holbuild/obj/src/ATheory BASE_STATE=$BASE_STATE MODULE=$modules \
  MODULE_HELPER=$HOLDIR/tools-poly/poly/theory_modules.ML \
  "$HOLDIR/bin/hol" run --noconfig --holstate "$BASE_STATE" "$tmpdir/alternate-module.sml"
rm -rf "$worker/checkpoint-store" "$worker/checkpoints"
edit_c same-theory
exec_theory C same-theory
require_grep 'restored shared' "$tmpdir/same-theory-C.log"
phase same-theory-C 'rstmodn:1'
resumed same-theory-C 'theorem-context checkpoint after c_first'
cmp "$tmpdir/A.pmo" "$modules"

# A module for a different theory at A's path is recovered the same way.
z_module=$(find "$worker_modules" -name '*-Z-*.pmo' | head -n 1)
[[ -n "$z_module" ]] || { echo "W has no module for Z" >&2; exit 1; }
cp "$z_module" "$tmpdir/Z.pmo"
cp "$z_module" "$modules"
rm -rf "$worker/checkpoint-store" "$worker/checkpoints"
edit_c changed
exec_theory C changed
require_grep 'restored shared' "$tmpdir/changed-C.log"
phase changed-C 'rstmodn:1'
resumed changed-C 'theorem-context checkpoint after c_first'
cmp "$tmpdir/A.pmo" "$modules"
# The shared heap and its checkpoints stay: with A's module back, W
# resumes from them.
rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
edit_c healed
exec_theory C c-healed
require_grep 'restored shared' "$tmpdir/c-healed-C.log"
resumed c-healed-C 'theorem-context checkpoint after c_first'

# Tool cache lookup happens after checkpoint restore and before HOL starts.
# Pause there to replace the module after its digest was checked. HOL must
# still reject the restored checkpoint and rebuild successfully.
spec_c=$(awk '$1 == "action" && $5 == "deps-modules:CTheory" { print $4 }' "$tmpdir/c.batch")
spec_file=$project/.holbuild/action-specs/$spec_c
tool_key=$(printf 'holbuild-tool-cache-v1\nname=post-restore\ndeps_key=%s\ntoolchain=%s' \
  "$(sed -n 's/^deps-key=//p' "$spec_file")" "$(sed -n 's/^toolchain=//p' "$spec_file")" | sha256sum | cut -d' ' -f1)
control=$tmpdir/control
printf 'holbuild-remote-ac-v1\n%s\n' "$tool_key" | sha256sum | cut -d' ' -f1 > "$control/action-get-key"
touch "$control/action-get-enable"
edit_c post-restore
exec_theory C post-restore shared post-restore &
worker_pid=$!
for _ in {1..3000}; do
  [[ -s "$control/action-get-count" ]] && break
  kill -0 "$worker_pid" 2>/dev/null || break
  sleep 0.01
done
[[ -s "$control/action-get-count" ]] || { echo 'C did not reach the tool cache lookup' >&2; exit 1; }
cp "$tmpdir/Z.pmo" "$tmpdir/replacement.pmo"
mv "$tmpdir/replacement.pmo" "$modules"
touch "$control/action-get-release"
wait "$worker_pid"
worker_pid=
rm "$control/action-get-enable" "$control/action-get-key" "$control/action-get-release"
require_grep 'restored shared theorem_context checkpoint' "$tmpdir/post-restore-C.log"
require_grep 'Required module missing or changed' "$tmpdir/post-restore-C.log"
phase post-restore-C 'rstmodrejn:1'
phase post-restore-C 'rstdropn:1'
require_grep '^status=built$' "$tmpdir/post-restore-C.result"

# A proof-only change to A (here, a source line moved) changes ATheory.dat
# but not B's dependencies' key, so B's shared heap still loads A's old
# module.  W, lacking it, fetches it as the heap's entry lists it, not by
# the current ATheory.dat.
sed -i 's/^Definition a_value_def:/(* moved down a line *)\nDefinition a_value_def:/' "$project/src/AScript.sml"
rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
edit_b seven
exec_theory B proof-edit
require_grep 'restored shared' "$tmpdir/proof-edit-B.log"
phase proof-edit-B 'rstmodn:1'
resumed proof-edit-B 'theorem-context checkpoint after b_first'
[[ -f "$modules" ]] || { echo "A's old module wasn't fetched to $modules" >&2; exit 1; }
# W's store has A's module for the current ATheory.dat too, under its own
# name.
[[ $(find "$worker_modules" -name '*-A-*.pmo' | wc -l) == 2 ]] ||
  { echo "A's proof-only change didn't change ATheory.dat" >&2; exit 1; }
