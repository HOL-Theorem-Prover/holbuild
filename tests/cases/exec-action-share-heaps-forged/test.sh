#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# exec-action --share-heaps under a theory script that replaces the deps
# heap and a theorem context the run saved: no other worker restores what
# the script saved.  With --share-deps-heap, a worker shares the deps heap
# and no checkpoint the script saved.

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

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
server_pids+=("$server_pid")
shared_url=$remote_url
start_remote_cache_server "$tmpdir/remote-deps" "$tmpdir/server-deps"
server_pids+=("$server_pid")
deps_url=$remote_url
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "forged"

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

worker_cache=$tmpdir/worker
# write_t FIRST SECOND TAIL: theory T, its theorems' statements, then TAIL.
# Each version checks, after the header and after t1, that it runs on no
# state the forging tail saved.
write_t() {
  cat > "$project/src/TScript.sml" <<SML
Theory T
Ancestors A

val _ = if Option.isSome (#lookupVal PolyML.globalNameSpace "holbuild_forged_marker")
        then raise Fail "running on a forged heap" else ();

Theorem t1:
  $1
Proof
  simp[]
QED

val _ = if Option.isSome (#lookupVal PolyML.globalNameSpace "holbuild_forged_marker")
        then raise Fail "running on a forged context" else ();

Theorem t2:
  $2
Proof
  simp[]
QED
$3
SML
}

# Replaces the deps heap and t1's context with states holding a marker: the
# heap a child of the base state, the context a child of that heap.
forge_tail=$(cat <<SML

val holbuild_forged_marker = 1;
local
  fun find dir name =
    let
      val stream = OS.FileSys.openDir dir
      fun loop found =
        case OS.FileSys.readDir stream of
            NONE => found
          | SOME entry =>
              let val path = OS.Path.concat (dir, entry)
              in
                loop (if entry = name then path :: found
                      else if OS.FileSys.isDir path andalso not (OS.FileSys.isLink path)
                      then find path name @ found
                      else found)
              end
    in
      loop [] before OS.FileSys.closeDir stream
    end
  fun saved name =
    case find "$worker_cache/checkpoints" name of
        [path] => path
      | paths => raise Fail (name ^ ": " ^ Int.toString (length paths) ^ " saves")
  (* The depth the run saved the state at: its place in the hierarchy. *)
  fun depth path =
    let
      val path = OS.FileSys.fullPath path
      fun at (n, state :: states) = if OS.FileSys.fullPath state = path then n else at (n + 1, states)
        | at (_, []) = raise Fail (path ^ " is not in the state hierarchy")
    in
      at (0, PolyML.SaveState.showHierarchy ())
    end
  val heap = saved "deps_loaded.save"
  val context = saved "t1_context.save"
  val (heap_depth, context_depth) = (depth heap, depth context)
  fun forge (path, at) = (OS.FileSys.remove path; PolyML.SaveState.saveChild (path, at))
in
  val _ = forge (heap, heap_depth)
  val _ = forge (context, context_depth)
end;
SML
)

# worker NAME URL SPEC [OPTION...]: exec-action of SPEC with no local
# checkpoints or store; the record goes to $tmpdir/NAME.result.
worker() {
  local name=$1 url=$2 spec=$3
  shift 3
  rm -rf "$worker_cache/checkpoints" "$worker_cache/checkpoint-store"
  link_hol_toolchain_cache "$worker_cache"
  set +e
  HOLBUILD_CACHE=$worker_cache "$HOLBUILD_BIN" --remote-cache "$url" exec-action "$spec" \
    --cache-limit-gb 1000 --result "$tmpdir/$name.result" "$@" > "$tmpdir/$name.log" 2>&1
  worker_status=$?
  set -e
  if [[ "$worker_status" != 0 ]] || ! grep -qxE "status=(built|cached)" "$tmpdir/$name.result"; then
    echo "worker $name exited $worker_status:" >&2
    cat "$tmpdir/$name.log" "$tmpdir/$name.result" >&2 || true
    exit 1
  fi
}

field() { awk -v want="$2" -v col="$3" '$1 == "action" && $5 == want { print $col }' "$1"; }

# export NAME URL OPTION: T's spec in URL's cache, with A built there.
export_t() {
  local name=$1 url=$2 option=$3 batch spec_a
  batch=$tmpdir/batch-$name.txt
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$url" action-spec --upload TTheory) > "$batch"
  spec_a=$(field "$batch" forged:ATheory 4)
  [[ -z "$spec_a" ]] || worker "a-$name" "$url" "$spec_a" "$option"
  spec_t=$(field "$batch" forged:TTheory 4)
  [[ -n "$spec_t" ]] || { cat "$batch" >&2; exit 1; }
}

entries() { grep -lx "$1" "$2"/ac/* 2>/dev/null | wc -l; }

# The forging run builds, but shares neither forged state.
write_t "T" "T /\\ T" "$forge_tail"
export_t v1 "$shared_url" --share-heaps
worker v1 "$shared_url" "$spec_t" --share-heaps

# An edit of t2 resumes from whatever t1 context is shared, then one of t1
# from whatever deps heap is.  Neither may hold the marker.
write_t "T" "T /\\ T /\\ T" ""
export_t v2 "$shared_url" --share-heaps
worker v2 "$shared_url" "$spec_t" --share-heaps
write_t "T \\/ F" "T /\\ T" ""
export_t v3 "$shared_url" --share-heaps
worker v3 "$shared_url" "$spec_t" --share-heaps
resumed_from() {
  require_grep "restored shared deps-loaded heap" "$tmpdir/$1.log"
  require_grep "from: deps-loaded checkpoint" "$tmpdir/$1.log"
}
# v1 shared nothing; v2 shared the heap v3 resumed from.
require_grep "not publishing the shared deps-loaded heap" "$tmpdir/v1.log"
resumed_from v3

# --share-deps-heap: the heap is shared and used, no script checkpoint is.
# A worker of its own, whose local cache holds none of T's versions above.
worker_cache=$tmpdir/worker-deps
write_t "T" "T /\\ T" ""
export_t d1 "$deps_url" --share-deps-heap
worker d1 "$deps_url" "$spec_t" --share-deps-heap
[[ $(entries holbuild-shared-heap-v1 "$tmpdir/remote-deps") == 1 ]] || {
  echo "--share-deps-heap shared no deps heap" >&2; cat "$tmpdir/d1.log" >&2; exit 1; }
[[ $(entries holbuild-shared-checkpoint-v1 "$tmpdir/remote-deps") == 0 ]] || {
  echo "--share-deps-heap shared a script checkpoint" >&2; exit 1; }
write_t "T" "T /\\ T /\\ T" ""
export_t d2 "$deps_url" --share-deps-heap
worker d2 "$deps_url" "$spec_t" --share-deps-heap
resumed_from d2
[[ $(entries holbuild-shared-checkpoint-v1 "$tmpdir/remote-deps") == 0 ]] || {
  echo "--share-deps-heap shared a script checkpoint" >&2; exit 1; }
