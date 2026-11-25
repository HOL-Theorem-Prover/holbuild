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
    [[ ! -d "$tmpdir/capture" ]] || touch "$tmpdir/capture/release"
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
require_grep "the host store's deps heap needs a missing or changed theory module: .*-A-.*\.pmo" "$tmpdir/store.log"
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
# B's first run on W, whose store is empty, publishes a heap that loads
# none of its cone's modules, and says how many it lacks.  With a store
# that has them, the next B on W declines that heap, preloads afresh and
# replaces it.  (The cone is small: tests lower the threshold to 1.)
export HOLBUILD_TEST_MODULE_MIN_MISSING=1
edit_b short
exec_theory B short
short_entry=$(grep -lx 'holbuild-shared-heap-v1' "$tmpdir"/remote/ac/*)
short_missing=$(sed -n 's/^missing=//p' "$short_entry")
[[ ${short_missing:-0} -ge 1 ]] && ! grep -q ' module ' "$short_entry" ||
  { echo "the heap saved with an empty store isn't marked short:" >&2; cat "$short_entry" >&2; exit 1; }
phase short-B "depsmissn:$short_missing"
phase short-B 'rstdepskb:[1-9][0-9]*'
exec_theory Z z unshared
rm -rf "$worker/checkpoint-store" "$worker/checkpoints"
server_log=$tmpdir/server/requests.log
z_requests=$(wc -l < "$server_log")
edit_b publish
exec_theory B publish
unset HOLBUILD_TEST_MODULE_MIN_MISSING
phase publish-B 'rstheapdeclinen:1'
phase publish-B 'depsmissn:0'
grep -qx 'missing=0' "$short_entry" ||
  { echo "the short heap's entry wasn't replaced:" >&2; cat "$short_entry" "$tmpdir/publish-B.log" >&2; exit 1; }
declined=$(find "$worker" -name .declined-heaps)
[[ -n "$declined" && $(wc -l < "$declined") -eq 1 ]] ||
  { echo "the preload over the declined heap wasn't recorded once:" >&2; cat $declined >&2; exit 1; }
published=$(find "$worker/checkpoint-store" -type f -name '[0-9a-f]*' -size +1M)
modules=$(for heap in $published; do heap_modules "$heap"; done | { grep -- '-A-' || true; } | sort -u)
[[ -n "$modules" ]] || { echo "no published heap loads A's module" >&2; exit 1; }
module_sha=$(sha256sum "$modules" | cut -d' ' -f1)

# Z's run published A's module, so B's heap publish finds it in the cache
# and puts the heap but not the module.
grep -qx "PUT /cas/$module_sha" <<< "$(head -n "$z_requests" "$server_log")" ||
  { echo "Z's run didn't publish A's module" >&2; exit 1; }
publish_requests=$(tail -n +"$((z_requests + 1))" "$server_log")
grep -qx "HEAD /cas/$module_sha" <<< "$publish_requests" ||
  { echo "B's heap publish didn't probe A's module" >&2; exit 1; }
if grep -qx "PUT /cas/$module_sha" <<< "$publish_requests"; then
  echo "B's heap publish put A's module again" >&2; exit 1
fi
for heap in $published; do
  grep -qx "PUT /cas/$(sha256sum "$heap" | cut -d' ' -f1)" <<< "$publish_requests" ||
    { echo "B's heap publish didn't put the heap $heap" >&2; exit 1; }
done

# W loses its stores. The first cache node for A's module returns 404.
# Restore must fetch the recorded module from the other cache node.
primary_url=$remote_url
start_remote_cache_server "$tmpdir/remote" "$tmpdir/mirror" "$tmpdir/mirror-control"
server_pids+=("$server_pid")
mirror_url=$remote_url
rank() { printf '%s:%s' "$1" "$module_sha" | sha256sum | cut -d' ' -f1; }
miss_control=$tmpdir/control
if [[ $(rank "$mirror_url") > $(rank "$primary_url") ]]; then
  miss_control=$tmpdir/mirror-control
fi
echo 404 > "$miss_control/cas-get-status-$module_sha"
rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
edit_b four
remote_url=$primary_url,$mirror_url
exec_theory B fetch
remote_url=$primary_url
rm "$miss_control/cas-get-status-$module_sha"
phase fetch-B 'rstmodn:1'
require_grep 'restored shared' "$tmpdir/fetch-B.log"
resumed fetch-B
[[ -f "$modules" ]] || { echo "A's module wasn't fetched to $modules" >&2; exit 1; }
cp "$modules" "$tmpdir/A.pmo"

# The remote cache loses A's module too: W gives the heap up, B preloads
# afresh, and the run replaces the heap's entry, which names a blob the
# cache lost.
echo 404 > "$tmpdir/control/cas-get-status-$module_sha"
rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
heap_entry=$(grep -lx 'holbuild-shared-heap-v1' "$tmpdir"/remote/ac/*)
cp -a "$tmpdir/remote/ac" "$tmpdir/ac-before-loss"
edit_b five
exec_theory B dropped
phase dropped-B 'rstmoddropn:1'
require_grep "the shared deps-loaded heap needs a missing or unverifiable theory module: .*-A-.*\.pmo" "$tmpdir/dropped-B.log"
require_grep "the cache lost blob $module_sha of shared entry" "$tmpdir/dropped-B.log"
grep -qx 'status=built' "$tmpdir/dropped-B.result"
if grep -qE '^phase-ms=(.*,)?rstrejectn:' "$tmpdir/dropped-B.result"; then
  echo 'checkpoints on the heap given up were tried' >&2; cat "$tmpdir/dropped-B.result" >&2; exit 1
fi
# heap_blob ENTRY: the heap blob a shared heap entry names.
heap_blob() { sed -n 's/^blob=\([0-9a-f]*\) heap$/\1/p' "$1"; }
old_heap=$(heap_blob "$tmpdir/ac-before-loss/${heap_entry##*/}")
new_heap=$(heap_blob "$heap_entry" 2>/dev/null || true)
if ! grep -qx 'holbuild-shared-heap-v1' "$heap_entry" || [[ -z $new_heap || $new_heap == "$old_heap" ]]; then
  echo 'the heap entry naming a lost module was not replaced' >&2; cat "$tmpdir/dropped-B.log" >&2; exit 1
fi
# A cold worker restores the replacement.
rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
edit_b repaired
exec_theory B repaired
require_grep 'restored shared' "$tmpdir/repaired-B.log"
if grep -qE '^phase-ms=(.*,)?(rstmoddropn|rstdropn|rstmodrejn):' "$tmpdir/repaired-B.result"; then
  echo 'the replacement heap was not restored' >&2; cat "$tmpdir/repaired-B.result" >&2; exit 1
fi

# A node the repair didn't reach still serves the old entries.  Once the
# cache has A's module again, W fetches it and resumes from the heap's
# checkpoints.
rm -rf "$tmpdir/remote/ac"
mv "$tmpdir/ac-before-loss" "$tmpdir/remote/ac"
rm -f "$tmpdir/control/cas-get-status-$module_sha"
rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
edit_b six
exec_theory B healed
phase healed-B 'rstmodn:1'
require_grep 'restored shared' "$tmpdir/healed-B.log"
resumed healed-B 'theorem-context checkpoint after b_first'

# A heap needs its own manifest to identify A's module even if the file is
# already present. Reject missing or conflicting entries without changing it.
heap_entry=$(grep -lx 'holbuild-shared-heap-v1' "$tmpdir"/remote/ac/*)
cp "$heap_entry" "$tmpdir/B-heap.entry"
manifest=$(sed '1,/^manifest-text-v1$/d' "$tmpdir/B-heap.entry")$'\n'
set_heap_manifest() {
  local text=$1
  {
    printf 'holbuild-remote-cache-action-v2\nmanifest-sha256 %s\nmanifest-size %s\n' \
      "$(printf '%s' "$text" | sha256sum | cut -d' ' -f1)" "${#text}"
    awk -v omit="${2:-}" '$1 == "blob" && $2 != omit' "$tmpdir/B-heap.entry"
    printf 'manifest-text-v1\n%s' "$text"
  } > "$heap_entry"
}
unlisted=$(printf '%s' "$manifest" | sed '/ module /d')$'\n'
set_heap_manifest "$unlisted" "$module_sha"
rm -rf "$worker/checkpoint-store" "$worker/checkpoints"
edit_b unlisted
exec_theory B unlisted
phase unlisted-B 'rstmoddropn:1'
require_grep '^status=built$' "$tmpdir/unlisted-B.result"
cmp "$tmpdir/A.pmo" "$modules"

heap_sha=$(printf '%s' "$manifest" | sed -n 's/^blob=\([0-9a-f]*\) heap$/\1/p')
set_heap_manifest "$manifest""blob=$heap_sha module ${modules##*/}"$'\n'
rm -rf "$worker/checkpoint-store" "$worker/checkpoints"
edit_b conflicting
exec_theory B conflicting
require_grep 'conflicting theory module digests' "$tmpdir/conflicting-B.log"
require_grep '^status=built$' "$tmpdir/conflicting-B.result"
cmp "$tmpdir/A.pmo" "$modules"
mv "$tmpdir/B-heap.entry" "$heap_entry"

# C's heap loads A's module. A module for the same .dat file with a
# different Poly/ML ID must be replaced before C can resume.
edit_c() { sed -i "s/^  .*(\* c_thm.*\$/  rw[a_value_def] (* c_thm $1 *)/" "$project/src/CScript.sml"; }
rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
mkdir -p "$(dirname "$modules")"
cp "$tmpdir/A.pmo" "$modules"
# A cache that fails the probe of A's module leaves it to be put, and C's
# heap is published all the same.
echo 503 > "$tmpdir/control/cas-head-status-$module_sha"
c_requests=$(wc -l < "$server_log")
# The entries of the heaps' publish claims.
claims() { grep -lx 'holbuild-shared-heap-claim-v1' "$tmpdir"/remote/ac/* | sort || true; }
claims_before=$(claims)
exec_theory C c
c_claim=$(comm -13 <(echo "$claims_before") <(claims))
[[ -n "$c_claim" && $(wc -l <<< "$c_claim") == 1 ]] || { echo "C's publish made claims: $c_claim" >&2; exit 1; }
c_heap_entry=$(grep -lx "blob=$module_sha module ${modules##*/}" $(grep -lx 'holbuild-shared-heap-v1' "$tmpdir"/remote/ac/*) |
  { grep -vx "$heap_entry" || true; })
[[ -n "$c_heap_entry" && $(wc -l <<< "$c_heap_entry") == 1 ]] ||
  { echo "C's heap entries naming A's module: $c_heap_entry" >&2; exit 1; }
rm "$tmpdir/control/cas-head-status-$module_sha"
publish_requests=$(tail -n +"$((c_requests + 1))" "$server_log")
grep -qx "HEAD /cas/$module_sha" <<< "$publish_requests" ||
  { echo "C's heap publish didn't probe A's module" >&2; exit 1; }
grep -qx "PUT /cas/$module_sha" <<< "$publish_requests" ||
  { echo "C's heap publish didn't put A's module after a failed probe" >&2; exit 1; }
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
cp "$modules" "$tmpdir/alternate-A.pmo"
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
# While a deps heap exists, the children starting from it, or from a
# checkpoint on it, may read only the theory modules it was saved with, not
# every stored module of the theory's cone: C's heap was saved before Z's
# module existed, so C's child can't read it.
# c_check LINE: C's line after c_first, blank but for checks of a run.
c_check() { sed -i "0,/^QED\$/{/^QED\$/{n;s|^.*\$|$1|}}" "$project/src/CScript.sml"; }
# z_readable READABLE: C's child can (true) or can't (false) read Z's module.
z_readable() {
  c_check "val _ = if ((TextIO.closeIn (TextIO.openIn \"$z_module\"); true) handle IO.Io _ => false) = $1 then () else raise Fail \"C's child read Z's module: not $1\""
}
z_readable false
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
# c_tool_entry NAME: the cache entry C's run reads for tool cache NAME.
c_tool_entry() {
  local key
  key=$(printf 'holbuild-tool-cache-v1\nname=%s\ndeps_key=%s\ntoolchain=%s' "$1" \
    "$(sed -n 's/^deps-key=//p' "$spec_file")" "$(sed -n 's/^toolchain=//p' "$spec_file")" | sha256sum | cut -d' ' -f1)
  printf 'holbuild-remote-ac-v1\n%s\n' "$key" | sha256sum | cut -d' ' -f1
}
control=$tmpdir/control
# start_paused ENTRY THEORY NAME...: exec_theory THEORY NAME... in the
# background, paused at its first read of the cache entry ENTRY until
# release_paused.
start_paused() {
  echo "$1" > "$control/action-get-key"
  rm -f "$control/action-get-count"
  touch "$control/action-get-enable"
  shift
  exec_theory "$@" &
  worker_pid=$!
  for _ in {1..3000}; do
    [[ -s "$control/action-get-count" ]] && break
    kill -0 "$worker_pid" 2>/dev/null || break
    sleep 0.01
  done
  [[ -s "$control/action-get-count" ]] || { echo "$2-$1 did not reach the paused read" >&2; exit 1; }
}
release_paused() {
  touch "$control/action-get-release"
  wait "$worker_pid"
  worker_pid=
  rm "$control/action-get-enable" "$control/action-get-key" "$control/action-get-release"
}
# Once the heap is gone, the retry's fresh preload may read the modules of
# C's cone, Z's among them.
mkdir -p "$(dirname "$z_module")"
cp "$tmpdir/Z.pmo" "$z_module"
z_readable true
edit_c post-restore
start_paused "$(c_tool_entry post-restore)" C post-restore shared post-restore
cp "$tmpdir/Z.pmo" "$tmpdir/replacement.pmo"
mv "$tmpdir/replacement.pmo" "$modules"
release_paused
require_grep 'restored shared theorem_context checkpoint' "$tmpdir/post-restore-C.log"
require_grep 'Required module missing or changed' "$tmpdir/post-restore-C.log"
phase post-restore-C 'rstmodrejn:1'
phase post-restore-C 'rstdropn:1'
require_grep '^status=built$' "$tmpdir/post-restore-C.result"
c_check ''

# A poisoned heap entry: C's, rewritten to name the other-ID copy of A's
# module, as by a publish that hashed the store while another restore
# replaced the module there.  Every host loading it rejected the heap.
alternate_sha=$(sha256sum "$tmpdir/alternate-A.pmo" | cut -d' ' -f1)
cp "$tmpdir/alternate-A.pmo" "$tmpdir/remote/cas/$alternate_sha"
cp "$c_heap_entry" "$tmpdir/C-heap.entry"
poisoned=$(sed '1,/^manifest-text-v1$/d' "$tmpdir/C-heap.entry" | sed "s/$module_sha/$alternate_sha/")$'\n'
{
  printf 'holbuild-remote-cache-action-v2\nmanifest-sha256 %s\nmanifest-size %s\n' \
    "$(printf '%s' "$poisoned" | sha256sum | cut -d' ' -f1)" "${#poisoned}"
  awk -v old="$module_sha" -v new="$alternate_sha" -v size="$(stat -c %s "$tmpdir/alternate-A.pmo")" \
    '$1 == "blob" { if ($2 == old) print "blob", new, size; else print }' "$tmpdir/C-heap.entry"
  printf 'manifest-text-v1\n%s' "$poisoned"
} > "$tmpdir/C-poisoned.entry"
# poisoned_once NAME: C's run NAME gave the poisoned heap up before HOL
# loaded it, built, and replaced the entry.
poisoned_once() {
  phase "$1" 'rstmoddropn:1'
  require_grep "the shared deps-loaded heap's entry names a theory module of another id: .*-A-.*\.pmo" "$tmpdir/$1.log"
  if grep -qE '^phase-ms=(.*,)?(rstdropn|rstmodrejn):' "$tmpdir/$1.result"; then
    echo "$1 loaded the poisoned heap" >&2; cat "$tmpdir/$1.result" >&2; exit 1
  fi
  require_grep '^status=built$' "$tmpdir/$1.result"
  if cmp -s "$tmpdir/C-poisoned.entry" "$c_heap_entry"; then
    echo "$1 left the poisoned entry" >&2; exit 1
  fi
}
# Cold: W lacks A's module, and the copy it fetches has another ID than C's
# heap requires.  A second cache node of its own holds the same entries
# (not their blobs): the replacements must reach it too.
cp "$tmpdir/C-poisoned.entry" "$c_heap_entry"
mkdir -p "$tmpdir/replica/ac"
cp "$tmpdir"/remote/ac/* "$tmpdir/replica/ac/"
start_remote_cache_server "$tmpdir/replica" "$tmpdir/replica-server"
server_pids+=("$server_pid")
replica_url=$remote_url
remote_url=$primary_url,$replica_url
rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
edit_c cold-poisoned
exec_theory C cold-poisoned
poisoned_once cold-poisoned-C
# Its checkpoints replace those chained to the poisoned heap, so the next
# edit resumes from them.
rm -rf "$worker/checkpoint-store" "$worker/checkpoints"
edit_c cold-repaired
exec_theory C cold-repaired
resumed cold-repaired-C 'theorem-context checkpoint after c_first'
if grep -qE '^phase-ms=(.*,)?rstrejectn:' "$tmpdir/cold-repaired-C.result"; then
  echo "cold-repaired-C found a checkpoint entry on the replaced heap" >&2; cat "$tmpdir/cold-repaired-C.result" >&2; exit 1
fi
for entry in "$tmpdir"/replica/ac/*; do
  primary_entry=$tmpdir/remote/ac/${entry##*/}
  [[ -f "$primary_entry" ]] && grep -qxE 'holbuild-shared-(heap|checkpoint)-v1' "$entry" || continue
  cmp -s "$entry" "$primary_entry" ||
    { echo "the cache nodes hold different shared entries ${entry##*/}" >&2; exit 1; }
done
# Back to one node, holding what either was given.
remote_url=$primary_url
cp -n "$tmpdir"/replica/ac/* "$tmpdir/remote/ac/"
[[ ! -d "$tmpdir/replica/cas" ]] || cp -n "$tmpdir"/replica/cas/* "$tmpdir/remote/cas/"

# C's run gives the poisoned heap up again, and A's module is replaced by
# the other-ID copy while its publish reads the claim on C's heap: it
# publishes the heap with the modules it linked when the preload saved it,
# replacing the entry.
cp "$tmpdir/C-poisoned.entry" "$c_heap_entry"
rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
mkdir -p "$(dirname "$modules")"
cp "$tmpdir/A.pmo" "$modules"
edit_c publish-swap
start_paused "${c_claim##*/}" C publish-swap
cp "$tmpdir/alternate-A.pmo" "$tmpdir/replacement.pmo"
mv "$tmpdir/replacement.pmo" "$modules"
release_paused
phase publish-swap-C 'rstmoddropn:1'
require_grep '^status=built$' "$tmpdir/publish-swap-C.result"
if grep -q 'not publishing the shared deps-loaded heap' "$tmpdir/publish-swap-C.log"; then
  echo 'publish-swap-C published no heap' >&2; cat "$tmpdir/publish-swap-C.log" >&2; exit 1
fi
grep -qx "blob=$module_sha module ${modules##*/}" "$c_heap_entry" ||
  { echo "C's republished heap doesn't load the copy of A's module its preload loaded" >&2; exit 1; }
[[ -z $(find "$worker_modules" -name '*.heap-snapshot*') ]] ||
  { echo 'publish-swap-C left its snapshot of the heap modules' >&2; exit 1; }
cp "$tmpdir/C-poisoned.entry" "$c_heap_entry"

# Again, but A's module is replaced, or gone, while the parent takes the
# heap the preload saved, before it links the heap's modules: it
# publishes no heap, and the child goes on.
capture_paused() {
  rm -rf "$tmpdir/capture"
  mkdir "$tmpdir/capture"
  HOLBUILD_TEST_CAPTURE_PAUSE=$tmpdir/capture exec_theory C "$1" &
  worker_pid=$!
  for _ in {1..6000}; do
    [[ -e "$tmpdir/capture/reached" ]] && break
    kill -0 "$worker_pid" 2>/dev/null || break
    sleep 0.01
  done
  [[ -e "$tmpdir/capture/reached" ]] || { echo "$1-C did not reach the heap capture" >&2; exit 1; }
}
capture_released() {
  touch "$tmpdir/capture/release"
  for _ in {1..6000}; do
    kill -0 "$worker_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$worker_pid" 2>/dev/null; then
    kill "$worker_pid"
    echo "the released worker did not finish" >&2
    exit 1
  fi
  wait "$worker_pid"
  worker_pid=
}
for change in swap removal; do
  rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
  mkdir -p "$(dirname "$modules")"
  cp "$tmpdir/A.pmo" "$modules"
  edit_c "capture-$change"
  capture_paused "capture-$change"
  if [[ $change == swap ]]; then
    cp "$tmpdir/alternate-A.pmo" "$tmpdir/replacement.pmo"
    mv "$tmpdir/replacement.pmo" "$modules"
    expected="not sharing the deps-loaded heap: its theory module .*-A-.*\.pmo was replaced by one of another id"
  else
    rm "$modules"
    expected="not sharing the deps-loaded heap: its theory module .*-A-.*\\.pmo is gone"
  fi
  capture_released
  require_grep '^status=built$' "$tmpdir/capture-$change-C.result"
  require_grep "$expected" "$tmpdir/capture-$change-C.log"
  cmp "$tmpdir/C-poisoned.entry" "$c_heap_entry" ||
    { echo "capture-$change-C published its heap" >&2; exit 1; }
  [[ -z $(find "$worker_modules" -name '*.heap-snapshot*') ]] ||
    { echo "capture-$change-C left a snapshot of the heap modules" >&2; exit 1; }
done
# A run whose result can't be written, once its capture took the heap,
# publishes nothing and leaves no snapshot.
rm -rf "$worker_modules" "$worker/checkpoint-store" "$worker/checkpoints"
mkdir -p "$(dirname "$modules")"
cp "$tmpdir/A.pmo" "$modules"
edit_c capture-unwritten
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload CTheory) > "$tmpdir/capture-unwritten.batch"
spec=$(awk '$1 == "action" && $5 == "deps-modules:CTheory" { print $4 }' "$tmpdir/capture-unwritten.batch")
[[ -n $spec ]] || { echo "C has no action: $(cat "$tmpdir/capture-unwritten.batch")" >&2; exit 1; }
# A directory in the result's place.
mkdir "$tmpdir/capture-unwritten.result"
if HOLBUILD_CACHE=$worker "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$spec" --share-heaps \
     --cache-limit-gb 1000 --result "$tmpdir/capture-unwritten.result" > "$tmpdir/capture-unwritten.log" 2>&1; then
  echo "capture-unwritten-C wrote no result, yet succeeded" >&2; exit 1
fi
if grep -q 'not sharing the deps-loaded heap' "$tmpdir/capture-unwritten.log"; then
  echo "capture-unwritten-C did not take its heap:" >&2; cat "$tmpdir/capture-unwritten.log" >&2; exit 1
fi
cmp "$tmpdir/C-poisoned.entry" "$c_heap_entry" || { echo "capture-unwritten-C published its heap" >&2; exit 1; }
[[ -z $(find "$worker_modules" -name '*.heap-snapshot*') ]] ||
  { echo "capture-unwritten-C left a snapshot of the heap modules" >&2; exit 1; }
rm -f "$modules"
cp "$tmpdir/alternate-A.pmo" "$modules"

# Warm: W already holds the copy the entry names, so it fetches nothing,
# but gives the heap up all the same.  C's own heap loads that copy.
rm -rf "$worker/checkpoint-store" "$worker/checkpoints"
edit_c warm-poisoned
warm_requests=$(wc -l < "$server_log")
exec_theory C warm-poisoned
poisoned_once warm-poisoned-C
if tail -n +"$((warm_requests + 1))" "$server_log" | grep -qx "GET /cas/$alternate_sha"; then
  echo "warm-poisoned-C fetched the module it held" >&2; exit 1
fi
grep -qx "blob=$alternate_sha module ${modules##*/}" "$c_heap_entry" ||
  { echo "C's new heap doesn't load the copy of A's module W holds" >&2; exit 1; }
rm -rf "$worker/checkpoint-store" "$worker/checkpoints"
edit_c warm-repaired
exec_theory C warm-repaired
resumed warm-repaired-C 'theorem-context checkpoint after c_first'
if grep -qE '^phase-ms=(.*,)?rstrejectn:' "$tmpdir/warm-repaired-C.result"; then
  echo "warm-repaired-C found a checkpoint entry on the replaced heap" >&2; cat "$tmpdir/warm-repaired-C.result" >&2; exit 1
fi

# Two valid heaps need different copies of A's module: C's the other-ID
# one, B's the first.  A restore of B's heap on the same host installs B's
# copy after C's restore checked its own and before C's HOL opens it: C's
# HOL rejects the heap once and C rebuilds, leaving its entry as it was,
# and each resumes on its next edit.  (One worker cache runs one action at
# a time; on a fleet host, workers share the module store.)
cp "$c_heap_entry" "$tmpdir/C-alternate.entry"
rm -rf "$worker/checkpoint-store" "$worker/checkpoints"
edit_c overlap
start_paused "$(c_tool_entry overlap)" C overlap shared overlap
cp "$tmpdir/A.pmo" "$tmpdir/replacement.pmo"
mv "$tmpdir/replacement.pmo" "$modules"
release_paused
phase overlap-C 'rstmodrejn:1'
if grep -qE '^phase-ms=(.*,)?rstmoddropn:' "$tmpdir/overlap-C.result"; then
  echo 'overlap-C gave the heap up' >&2; cat "$tmpdir/overlap-C.result" >&2; exit 1
fi
require_grep '^status=built$' "$tmpdir/overlap-C.result"
cmp "$tmpdir/C-alternate.entry" "$c_heap_entry"
for theory in C B; do
  rm -rf "$worker/checkpoint-store" "$worker/checkpoints"
  "edit_${theory,,}" after-overlap
  exec_theory "$theory" "${theory,,}-after-overlap"
  phase "${theory,,}-after-overlap-$theory" 'rstmodn:1'
  resumed "${theory,,}-after-overlap-$theory"
done

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
