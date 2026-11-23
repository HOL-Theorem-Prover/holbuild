#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# Two branches differ in the type of A's constant c, which B doesn't use:
# C, on B, uses c, and its .dat file is the same on both, so its module's
# name is too, and HOL refuses on the second branch the module the first
# stored.  The second branch's build leaves that module's file alone, and
# the deps heap it saves for D, on C, doesn't require it.  A module
# writer with a limit of one writes the module missing after it, which it
# only registers.  A theory run's parent takes no deps heap that requires
# a module HOL refused, or whose modules it can't link as the heap
# requires them, and the child goes on either way; on a worker sharing
# heaps, it shares the heap only when the preload released the module.

tmpdir=$(make_temp_dir)
server_pid=
# A held writer is let go, so that it doesn't outlive the test.
trap '[[ ! -d $tmpdir/writer ]] || { touch "$tmpdir/writer/release"; sleep 1; }
      [[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null; cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"
project=$tmpdir/project
mkdir -p "$project/src"
write_schema2_prelude > "$project/holproject.toml"
cat >> "$project/holproject.toml" <<'TOML'
[project]
name = "module-refusal"
[build]
members = ["src"]
TOML
set_a() { printf 'Theory A\nAncestors bool\n\nDefinition c_def:\n  c (x:%s) = T\nEnd\n' "$1" > "$project/src/AScript.sml"; }
cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors A

Theorem b_thm:
  T
Proof
  REWRITE_TAC []
QED
SML
cat > "$project/src/CScript.sml" <<'SML'
Theory C
Ancestors B

Theorem c_thm:
  c T = T
Proof
  REWRITE_TAC [DB.fetch "A" "c_def"]
QED
SML
cat > "$project/src/C2Script.sml" <<'SML'
Theory C2
Ancestors B

Theorem c2_thm:
  c F = T
Proof
  REWRITE_TAC [DB.fetch "A" "c_def"]
QED
SML
cat > "$project/src/DScript.sml" <<'SML'
Theory D
Ancestors C C2

Theorem d_thm:
  T /\ T
Proof
  REWRITE_TAC []
QED
SML

build() {
  (cd "$project" && "$HOLBUILD_BIN" --cache-dir ../cache -j1 build DTheory) > "$1" 2>&1 ||
    { cat "$1" >&2; return 1; }
}
skip() {
  [[ ${HOLBUILD_TEST_REQUIRE_MODULE_HEAPS:-0} != 1 ]] ||
    { echo "refused theory modules need $1" >&2; exit 1; }
  echo "refused theory modules unsupported: no $1"
  exit 0
}
c_module() { find "$HOLBUILD_CACHE/theory-modules" -name "*-${1:-C}-*.pmo"; }

set_a "'a"
build "$tmpdir/first.log"
[[ -n $(c_module) ]] || {
  [[ ${HOLBUILD_TEST_REQUIRE_THEORY_MODULES:-0} != 1 ]] ||
    { echo 'no module was written for C' >&2; exit 1; }
  skip 'theory module support'
}
[[ $(c_module | wc -l) == 1 ]] || { echo "C has modules $(c_module)" >&2; exit 1; }
c_dat=$(sha1sum < "$project/.holbuild/obj/src/CTheory.dat")
c_path=$(c_module)
c_id=$(stat -c '%i %s' "$c_path")
c_sha=$(sha256sum < "$c_path")
c2_sha=$(sha256sum < "$(c_module C2)")
store=$(dirname "$c_path")
a1_dat=$(sha1sum < "$project/.holbuild/obj/src/ATheory.dat" | cut -d' ' -f1)

set_a bool
build "$tmpdir/second.log"
[[ $(sha1sum < "$project/.holbuild/obj/src/CTheory.dat") == "$c_dat" ]] ||
  { echo "C's .dat file differs on the second branch" >&2; exit 1; }
d_log=$project/.holbuild/logs/current/module-refusal/DTheory/build.log
require_grep 'theory modules: C: module refused, loading from .dat' "$d_log"
require_grep 'theory modules: C2: module refused, loading from .dat' "$d_log"
[[ $(c_module) == "$c_path" && $(stat -c '%i %s' "$c_path") == "$c_id" && $(sha256sum < "$c_path") == "$c_sha" ]] ||
  { echo "the second branch wrote C's refused module again" >&2; exit 1; }

echo 'val _ = PolyML.SaveState.saveChildWithModules;' > "$tmpdir/probe.sml"
"$HOLDIR/bin/hol" run --noconfig "$tmpdir/probe.sml" > /dev/null 2>&1 || skip 'PolyML.SaveState.saveChildWithModules'
cat > "$tmpdir/modules.sml" <<'SML'
val _ =
  List.app (fn (_, path) => print (path ^ "\n"))
    (PolyML.SaveState.showModuleDependencies (valOf (OS.Process.getEnv "HEAP")));
SML
heap_modules() { HEAP=$1 "$HOLDIR/bin/hol" run --noconfig "$tmpdir/modules.sml" | grep '\.pmo$' || true; }
d_heap=$(find "$project/.holbuild/checkpoints" -path '*DScript.sml.deps*' -name deps_loaded.save | head -n 1)
[[ -n $d_heap ]] || { echo 'D saved no deps heap' >&2; exit 1; }
d_modules=$(heap_modules "$d_heap")
grep -q -- '-A-' <<< "$d_modules" || { echo "D's deps heap doesn't load A's module: $d_modules" >&2; exit 1; }
if grep -q -- '-C2\?-' <<< "$d_modules"; then
  echo "D's deps heap requires C's refused module: $d_modules" >&2; exit 1
fi

# The toolchains whose store this may be.
holdirs=$(for candidate in "$HOLBUILD_CACHE"/hol-toolchains/*/hol; do
  printf '"%s"\n"%s"\n' "$candidate" "$(realpath "$candidate")"
done | paste -sd,)

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
find "$store" -name '*-D-*.pmo' -delete
cat > "$tmpdir/check.sml" <<SML
use "sml/holbuild-script.sml";
structure E = HolbuildBuildExec;
fun check message condition = if condition then () else raise Fail message;
fun exists path = OS.FileSys.access (path, []);
fun dep name = {target = "module-refusal:" ^ name ^ "Theory", stem = "src/" ^ name ^ "Theory", key = ""};
fun toolchain holdir = {holdir = holdir, maxheap = NONE, kernel_variant = HolbuildToolchain.StandardKernel};
val store = "$store";
val tc =
  case List.find (fn holdir => E.module_store (toolchain holdir) = store) [$holdirs] of
      SOME holdir => toolchain holdir
    | NONE => raise Fail "no toolchain has the store $store";
fun modules part = List.filter (String.isSubstring part) (map OS.Path.file (HolbuildCache.children store));

(* The writer, allowed one module, writes D's after the refused ones. *)
val {installed, trace, ...} =
  E.fill_module_store (HolbuildRemoteCache.remote "$remote_url") "$project/.holbuild/obj" tc
    {deps = map dep ["A", "B", "C", "C2", "D"], loads = []} (Time.+ (Time.now (), Time.fromSeconds 120));
val _ = check "the writer didn't store D's module after the refused ones"
          (installed = 1 andalso length (modules "-D-") = 1);
val _ = check ("the trace doesn't show the refused modules and D's: " ^ trace)
          (String.isSubstring ",written:1," trace andalso String.isSubstring "refused:" trace andalso
           String.isSubstring " modules_outputs=files:1,discarded:0,installed:1," trace andalso
           not (String.isSubstring "modules_base=unavailable" trace));

(* The parent's capture of D's deps heap, from a child that lists the
   modules HOL refused, and then waits. *)
val heap = "$tmpdir/heap/deps_loaded.save";
val _ = OS.FileSys.mkDir "$tmpdir/heap";
val _ = E.copy_binary "$d_heap" heap;
val ids = E.saved_module_ids heap;
fun child refused () =
  let
    val give_up = Time.+ (Time.now (), Time.fromSeconds 30)
    fun wait () =
      if not (exists (heap ^ ".capture")) then ()
      else if Time.> (Time.now (), give_up) then raise Fail "the child was left waiting"
      else (OS.Process.sleep (Time.fromMilliseconds 10); wait ())
  in
    if null refused then () else E.write_text (heap ^ ".refused") (String.concat (map (fn id => id ^ "\n") refused));
    E.write_text (heap ^ ".capture") "";
    wait ()
  end;
fun capture refused =
  (E.with_deps_heap_capture store heap (child refused);
   check "the refused modules' list stayed" (not (exists (heap ^ ".refused")));
   Option.isSome (!E.captured_deps_heap));
fun snapshots () = modules ".heap-snapshot";
fun dropped () = (E.drop_heap_snapshot (); check "a snapshot of the heap's modules stayed" (null (snapshots ())));
val _ = check "the heap wasn't taken" (capture ["0000000000000000"]);
val _ = check "the heap's modules weren't linked"
          (case !E.captured_heap_modules of SOME {modules, ...} => length modules = length ids | NONE => false);
val _ = dropped ();
val _ = check "a heap requiring a module HOL refused was taken" (not (capture [E.module_id_hex (#1 (hd ids))]));
val _ = dropped ();
(* A module the heap requires is gone, or has another id, when it's taken. *)
val a = hd (List.filter (String.isSubstring "-A-") (map #2 ids));
val _ = OS.FileSys.rename {old = a, new = "$tmpdir/A.pmo"};
val _ = check "a heap whose module is gone was taken" (not (capture []));
val _ = dropped ();
val _ = E.copy_binary "$c_path" a;
val _ = check "a heap whose module has another id was taken" (not (capture []));
val _ = dropped ();
val _ = OS.FileSys.rename {old = "$tmpdir/A.pmo", new = a};
SML
(cd "$HOLBUILD_ROOT" && HOLBUILD_CACHE="$HOLBUILD_CACHE" HOLBUILD_TEST_MODULE_WRITER_LIMIT=1 \
  "${HOLBUILD_POLY:-poly}" -q --error-exit --script "$tmpdir/check.sml")
[[ $(sha256sum < "$c_path") == "$c_sha" && $(sha256sum < "$(c_module C2)") == "$c2_sha" ]] ||
  { echo "the writer wrote a refused module again" >&2; exit 1; }

# A worker sharing heaps runs an edited D: its parent shares no deps heap
# that requires C's refused module, which the preload couldn't release
# (FAILS=1), and shares one that doesn't.  The child goes on either way.
# spec_d NAME: the spec of D, edited, on the current branch, in NAME.spec.
spec_d() {
  printf '\n(* %s *)\n' "$1" >> "$project/src/DScript.sml"
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload DTheory) > "$tmpdir/$1.batch"
  awk '$1 == "action" && $5 == "module-refusal:DTheory" { print $4 }' "$tmpdir/$1.batch" > "$tmpdir/$1.spec"
  [[ -s "$tmpdir/$1.spec" ]] || { echo "D has no action: $(cat "$tmpdir/$1.batch")" >&2; exit 1; }
}
# run_d NAME FAILS [unshared [MIN]]: runs NAME.spec on the worker; MIN,
# the fewest missing modules worth prefetching or writing.
run_d() {
  local name=$1 share=(--share-heaps)
  [[ ${3:-} != unshared ]] || share=()
  HOLBUILD_TEST_RELEASE_MODULE_FAILS=$2 HOLBUILD_TEST_MODULE_MIN_MISSING=${4:-} \
    "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$(cat "$tmpdir/$name.spec")" \
    ${share[@]+"${share[@]}"} --cache-limit-gb 1000 --result "$tmpdir/$name.result" > "$tmpdir/$name.log" 2>&1 ||
    { cat "$tmpdir/$name.log" "$tmpdir/$name.result" >&2; exit 1; }
  require_grep '^status=built$' "$tmpdir/$name.result"
}
# exec_d NAME FAILS [unshared [MIN]]: both, from no local heap.
exec_d() {
  spec_d "$1"
  rm -rf "$HOLBUILD_CACHE/checkpoint-store" "$HOLBUILD_CACHE/checkpoints"
  run_d "$@"
}
heap_entries() { grep -lx 'holbuild-shared-heap-v1' "$tmpdir"/remote/ac/* || true; }
exec_d unreleased 1
require_grep 'not sharing the deps-loaded heap: it requires a theory module HOL refused' "$tmpdir/unreleased.log"
[[ -z $(heap_entries) ]] || { echo "a heap requiring C's refused module was shared" >&2; exit 1; }
exec_d released 0
if grep -q 'not sharing the deps-loaded heap' "$tmpdir/released.log"; then
  cat "$tmpdir/released.log" >&2; exit 1
fi
[[ -n $(heap_entries) ]] || { cat "$tmpdir/released.log" >&2; echo "D's deps heap wasn't shared" >&2; exit 1; }
grep -q -- ' module .*-A-.*\.pmo$' $(heap_entries) || { echo "the shared heap doesn't load A's module" >&2; exit 1; }
if grep -q -- ' module .*-C2\?-.*\.pmo$' $(heap_entries); then
  echo "the shared heap requires C's refused module" >&2; exit 1
fi
[[ $(sha256sum < "$c_path") == "$c_sha" ]] || { echo "the worker wrote C's refused module again" >&2; exit 1; }
b2_entries=$(heap_entries)
# Its record counts the preload's module loads: A's from its module, C's
# and C2's refused, loaded from their .dat files with the rest.
phase() { sed -n "s/^phase-ms=\(.*,\)\?$2:\([0-9]*\)\(,.*\)\?\$/\2/p" "$tmpdir/$1.result"; }
hits=$(phase released holmodhitn) misses=$(phase released holmodmissn) refused=$(phase released holmodrefusedn)
[[ ${hits:-0} -ge 1 && ${misses:-0} -ge 2 && $refused == 2 && -n $(phase released holmodwriten) ]] ||
  { echo "released's module counts: hits=$hits misses=$misses refused=$refused" >&2; cat "$tmpdir/released.result" >&2; exit 1; }

# Back on the first branch, a worker whose store lacks A's module, which
# no host published, records it as unpublished, and writes and publishes
# it after its run.  Lacking it again, the next fetches it before its
# preload, whose shared heap then loads it.
set_a "'a"
a1_module() { find "$store" -name "*-A-$a1_dat.pmo"; }
rm "$(a1_module)"
exec_d publish-a 0 unshared 1
require_grep "A-$a1_dat\.pmo" "$store/.probed-missing"
[[ -n $(a1_module) ]] || { echo "the worker didn't write A's missing module" >&2; exit 1; }
rm "$(a1_module)" "$store/.probed-missing"
exec_d prefetch-a 0 shared 1
b1_entries=$(comm -13 <(echo "$b2_entries") <(heap_entries))
[[ -n $b1_entries ]] || { echo "the first branch's heap wasn't shared" >&2; exit 1; }
grep -q -- " module .*-A-$a1_dat\.pmo$" $b1_entries ||
  { echo "the first branch's shared heap doesn't load the A module fetched before its preload" >&2; exit 1; }

# Each branch in turn resumes from its own shared heap: neither's
# modules were replaced.
resumed() {
  grep -qE '^phase-ms=(.*,)?res(deps|ctx)n:1' "$tmpdir/$1.result" ||
    { echo "$1 didn't resume:" >&2; cat "$tmpdir/$1.result" "$tmpdir/$1.log" >&2; exit 1; }
  if grep -qE '^phase-ms=(.*,)?(rstmodrejn|rstdropn|rstmoddropn):' "$tmpdir/$1.result"; then
    echo "$1 dropped a heap:" >&2; cat "$tmpdir/$1.result" "$tmpdir/$1.log" >&2; exit 1
  fi
}
set_a bool
exec_d resume-2 0
resumed resume-2
set_a "'a"
exec_d resume-1 0
resumed resume-1

# Both at once: the second branch's writer is held once it has written
# the C2 module it found missing, while the first branch's restore stores
# the C2 its heap requires; the writer's, of another id, stays out of the
# store.  With C2's entry gone, the writer has no winner to fetch.
set_a bool
spec_d both-2
set_a "'a"
spec_d both-1
c2_path=$(c_module C2)
rm "$c2_path"
# Its theory-module entry, not the heap entries that list it too.
{ grep -rlE -- '^blob=[0-9a-f]+ file [^ ]*-C2-[0-9a-f]+\.pmo$' "$tmpdir/remote/ac" || true; } | xargs -r rm --
rm -rf "$HOLBUILD_CACHE/checkpoint-store" "$HOLBUILD_CACHE/checkpoints" "$tmpdir/writer"
mkdir "$tmpdir/writer"
# wait_for FILE PID: until FILE exists, while PID runs.
wait_for() {
  for _ in {1..6000}; do
    [[ -e $1 ]] && return
    kill -0 "$2" 2>/dev/null || break
    sleep 0.1
  done
  [[ -e $1 ]] || { echo "$1 did not appear" >&2; exit 1; }
}
(export HOLBUILD_TEST_WRITER_PAUSE=$tmpdir/writer; run_d both-2 0 shared 1) &
both_2=$!
wait_for "$tmpdir/writer/reached" "$both_2"
written=$(find "$store/.writer" -name '*-C2-*.pmo')
[[ -n $written && $(sha256sum < "$written") != "$c2_sha" ]] ||
  { echo "the second branch's writer wrote no C2 module of another id: $written" >&2; exit 1; }
[[ ! -e $c2_path ]] || { echo "C2's module was stored before the restore" >&2; exit 1; }
run_d both-1 0 &
both_1=$!
wait_for "$c2_path" "$both_1"
touch "$tmpdir/writer/release"
wait "$both_2"
wait "$both_1"
require_grep 'modules_outputs=files:[1-9][0-9]*,discarded:0,installed:[0-9]*,existing:[1-9]' "$tmpdir/both-2.log"
resumed both-2
resumed both-1
[[ $(c_module C2) == "$c2_path" && $(sha256sum < "$c2_path") == "$c2_sha" ]] ||
  { echo "the writer replaced the C2 module the restore stored" >&2; exit 1; }
[[ $(sha256sum < "$c_path") == "$c_sha" ]] || { echo "a worker wrote C's module again" >&2; exit 1; }
