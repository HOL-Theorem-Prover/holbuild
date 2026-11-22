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
trap '[[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null; cleanup_temp_dir "$tmpdir"' EXIT
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
cat > "$project/src/DScript.sml" <<'SML'
Theory D
Ancestors C

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
c_module() { find "$HOLBUILD_CACHE/theory-modules" -name '*-C-*.pmo'; }

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
store=$(dirname "$c_path")

set_a bool
build "$tmpdir/second.log"
[[ $(sha1sum < "$project/.holbuild/obj/src/CTheory.dat") == "$c_dat" ]] ||
  { echo "C's .dat file differs on the second branch" >&2; exit 1; }
d_log=$project/.holbuild/logs/current/module-refusal/DTheory/build.log
require_grep 'theory modules: C: module refused, loading from .dat' "$d_log"
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
if grep -q -- '-C-' <<< "$d_modules"; then
  echo "D's deps heap requires C's refused module: $d_modules" >&2; exit 1
fi

# The toolchain whose store this is.
holdir=
for candidate in "$HOLBUILD_CACHE"/hol-toolchains/*/hol; do
  for path in "$candidate" "$(realpath "$candidate")"; do
    [[ "v2-$(printf '%s' "$path" | sha256sum | cut -d' ' -f1)" == "$(basename "$store")" ]] && holdir=$path
  done
done
[[ -n $holdir ]] || { echo "no toolchain has the store $store" >&2; exit 1; }

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
find "$store" -name '*-D-*.pmo' -delete
cat > "$tmpdir/check.sml" <<SML
use "sml/holbuild-script.sml";
structure E = HolbuildBuildExec;
fun check message condition = if condition then () else raise Fail message;
fun exists path = OS.FileSys.access (path, []);
fun dep name = {target = "module-refusal:" ^ name ^ "Theory", stem = "src/" ^ name ^ "Theory", key = ""};
val tc = {holdir = "$holdir", maxheap = NONE, kernel_variant = HolbuildToolchain.StandardKernel};
val store = "$store";
fun modules part = List.filter (String.isSubstring part) (map OS.Path.file (HolbuildCache.children store));

(* The writer, allowed one module, writes D's after C's refused one. *)
val {installed, ...} =
  E.fill_module_store (HolbuildRemoteCache.remote "$remote_url") "$project/.holbuild/obj" tc
    {deps = map dep ["A", "B", "C", "D"], loads = []} (Time.+ (Time.now (), Time.fromSeconds 120));
val _ = check "the writer didn't store D's module after C's refused one"
          (installed = 1 andalso length (modules "-D-") = 1);

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
[[ $(sha256sum < "$c_path") == "$c_sha" ]] || { echo "the writer wrote C's refused module again" >&2; exit 1; }

# A worker sharing heaps runs an edited D: its parent shares no deps heap
# that requires C's refused module, which the preload couldn't release
# (FAILS=1), and shares one that doesn't.  The child goes on either way.
exec_d() {
  local name=$1 spec
  printf '\n(* %s *)\n' "$name" >> "$project/src/DScript.sml"
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload DTheory) > "$tmpdir/$name.batch"
  spec=$(awk '$1 == "action" && $5 == "module-refusal:DTheory" { print $4 }' "$tmpdir/$name.batch")
  [[ -n $spec ]] || { echo "D has no action: $(cat "$tmpdir/$name.batch")" >&2; exit 1; }
  rm -rf "$HOLBUILD_CACHE/checkpoint-store" "$HOLBUILD_CACHE/checkpoints"
  HOLBUILD_TEST_RELEASE_MODULE_FAILS=$2 "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$spec" \
    --share-heaps --cache-limit-gb 1000 --result "$tmpdir/$name.result" > "$tmpdir/$name.log" 2>&1 ||
    { cat "$tmpdir/$name.log" "$tmpdir/$name.result" >&2; exit 1; }
  require_grep '^status=built$' "$tmpdir/$name.result"
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
if grep -q -- ' module .*-C-.*\.pmo$' $(heap_entries); then
  echo "the shared heap requires C's refused module" >&2; exit 1
fi
[[ $(sha256sum < "$c_path") == "$c_sha" ]] || { echo "the worker wrote C's refused module again" >&2; exit 1; }
