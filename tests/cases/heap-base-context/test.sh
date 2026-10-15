#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
markers=$tmpdir/markers
mkdir -p "$project/src" "$markers"
write_manifest() {
  local base_line=$1
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "basectx"

[build]
members = ["src"]

[[heap]]
name = "base"
output = ".holbuild/heap/base.save"
objects = ["ATheory"]
$base_line
TOML
}

# Each theory records the saved-state chain its HOL session started from, and
# its load path.
record_hierarchy() {
  cat <<SML
val _ =
  let
    fun write name lines =
      let val out = TextIO.openOut ("$markers/$1." ^ name)
      in TextIO.output(out, String.concatWith "\n" lines ^ "\n"); TextIO.closeOut out end
  in
    write "hierarchy" (PolyML.SaveState.showHierarchy());
    write "loadpath" (!Meta.loadPath)
  end;
SML
}

{
  echo 'open HolKernel Parse boolLib bossLib;'
  record_hierarchy A
  cat <<'SML'
val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
} > "$project/src/AScript.sml"
{
  echo 'open HolKernel Parse boolLib bossLib ATheory;'
  record_hierarchy B
  cat <<'SML'
val _ = new_theory "B";
val b_thm = store_thm("b_thm", ``T /\ T``, REWRITE_TAC [a_thm]);
val _ = export_theory();
SML
} > "$project/src/BScript.sml"
{
  echo 'open HolKernel Parse boolLib bossLib BTheory;'
  record_hierarchy C
  cat <<'SML'
val _ = new_theory "C";
val c_thm = store_thm("c_thm", ``T /\ T /\ T``, REWRITE_TAC [b_thm]);
val _ = export_theory();
SML
} > "$project/src/CScript.sml"
{
  echo 'open HolKernel Parse boolLib bossLib;'
  record_hierarchy D
  cat <<'SML'
val _ = new_theory "D";
val d_thm = store_thm("d_thm", ``F ==> T``, REWRITE_TAC []);
val _ = export_theory();
SML
} > "$project/src/DScript.sml"

heap=$project/.holbuild/heap/base.save
obj=$project/.holbuild/obj/src
dat_hashes() {
  (cd "$obj" && sha256sum BTheory.dat CTheory.dat DTheory.dat)
}
require_heap_start() {
  require_grep "$heap" "$markers/$1.hierarchy"
}
require_toolchain_start() {
  if grep -q "$heap" "$markers/$1.hierarchy"; then
    echo "$1 unexpectedly started from the base heap" >&2
    cat "$markers/$1.hierarchy" >&2
    exit 1
  fi
}

# Every child adds the project's dirs to its load path when it starts; the
# heap must add nothing to that.  Which project dirs exist differs between
# builds, so compare the entries outside the project with a hol.state child's,
# and require no project entry twice.
outside_project() { grep -v "^$project\(/\|\$\)" "$1" || true; }
require_cold_load_path() {
  if ! diff <(outside_project "$tmpdir/B-cold.loadpath") \
            <(outside_project "$markers/$1.loadpath") > "$tmpdir/loadpath.diff"; then
    echo "base heap user $1's load path outside the project differs from a hol.state child's" >&2
    cat "$tmpdir/loadpath.diff" >&2
    exit 1
  fi
  if [[ -n "$(sort "$markers/$1.loadpath" | uniq -d)" ]]; then
    echo "base heap user $1 has duplicate load path entries" >&2
    cat "$markers/$1.loadpath" >&2
    exit 1
  fi
}

require_no_markers() {
  local theory
  for theory in "$@"; do require_no_file "$markers/$theory.hierarchy"; done
}

# Cold reference build: the heap is declared but is not a base context.
write_manifest ""
(cd "$project" && "$HOLBUILD_BIN" -j2 build) > "$tmpdir/cold.log"
require_no_file "$heap"
dat_hashes > "$tmpdir/cold.sha"
for theory in A B C D; do require_toolchain_start "$theory"; done
cp "$markers/B.loadpath" "$tmpdir/B-cold.loadpath"

# Declaring the base heap changes the input keys of the theories that start
# from it, so B and C rebuild from the heap; A and D stay up to date.
write_manifest "base = true"
rm -f "$markers"/*.hierarchy
(cd "$project" && "$HOLBUILD_BIN" -j2 build) > "$tmpdir/heap.log"
require_grep "exporting base heap" "$tmpdir/heap.log"
require_file "$heap"
require_grep "kind=base_heap" "$heap.ok"
require_heap_start B
require_heap_start C
require_no_markers A D
require_cold_load_path B
dat_hashes > "$tmpdir/heap.sha"
if ! cmp -s "$tmpdir/cold.sha" "$tmpdir/heap.sha"; then
  echo "theory outputs differ between toolchain and base heap starts" >&2
  diff "$tmpdir/cold.sha" "$tmpdir/heap.sha" >&2 || true
  exit 1
fi

(cd "$project" && "$HOLBUILD_BIN" -j2 build) > "$tmpdir/noop.log"
if grep -q "exporting base heap" "$tmpdir/noop.log"; then
  echo "current base heap was exported again" >&2
  exit 1
fi
key_before=$(grep '^heap_key=' "$heap.ok")

# Cold and heap builds are cached under different keys: switching back and
# forth restores each from the cache, and a heap nobody has to build from is
# not exported.
write_manifest ""
rm -f "$markers"/*.hierarchy
(cd "$project" && "$HOLBUILD_BIN" -j2 build) > "$tmpdir/cold-again.log"
require_grep "BTheory restored from cache" "$tmpdir/cold-again.log"
require_no_markers A B C D
rm -f "$heap" "$heap.ok"
write_manifest "base = true"
(cd "$project" && "$HOLBUILD_BIN" -j2 build) > "$tmpdir/heap-again.log"
require_grep "BTheory restored from cache" "$tmpdir/heap-again.log"
require_no_markers A B C D
require_no_file "$heap"

# Changing a heap object re-exports the heap and rebuilds its dependents
# from the new heap.
rm -f "$markers"/*.hierarchy
printf '\nval a2_thm = store_thm("a2_thm", ``~F``, REWRITE_TAC []);\nval _ = export_theory();\n' \
  >> "$project/src/AScript.sml"
(cd "$project" && "$HOLBUILD_BIN" -j2 build) > "$tmpdir/edit.log"
require_grep "exporting base heap" "$tmpdir/edit.log"
key_after=$(grep '^heap_key=' "$heap.ok")
[[ "$key_before" != "$key_after" ]] || { echo "base heap key did not change after editing ATheory" >&2; exit 1; }
require_heap_start B
require_heap_start C
require_no_file "$markers/D.hierarchy"

# `holbuild heap` re-exports the same heap a build would use, even when it is
# current.
(cd "$project" && "$HOLBUILD_BIN" heap base) > "$tmpdir/heap-command.log"
require_grep "exporting base heap" "$tmpdir/heap-command.log"
require_grep "$key_after" "$heap.ok"

# That re-export kept the heap key but rewrote the file, so checkpoints saved
# over the previous file must not be resumed.
rm -f "$markers"/*.hierarchy
printf '\nval c2_thm = store_thm("c2_thm", ``~F``, REWRITE_TAC []);\nval _ = export_theory();\n' \
  >> "$project/src/CScript.sml"
(cd "$project" && "$HOLBUILD_BIN" -j2 build) > "$tmpdir/reexport-resume.log" 2>&1
if grep -q "discarding invalid checkpoint" "$tmpdir/reexport-resume.log"; then
  echo "resumed a checkpoint saved over a replaced base heap" >&2
  cat "$tmpdir/reexport-resume.log" >&2
  exit 1
fi
require_heap_start C

# A heap damaged after export is exported again: a build finds that the file
# no longer matches the hash in its .ok, and `holbuild heap` always exports.
truncate -s 4096 "$heap"
rm -f "$markers"/*.hierarchy
(cd "$project" && "$HOLBUILD_BIN" build --force=theory CTheory) > "$tmpdir/repair-build.log" 2>&1
require_grep "exporting base heap" "$tmpdir/repair-build.log"
require_heap_start C
truncate -s 4096 "$heap"
(cd "$project" && "$HOLBUILD_BIN" heap base) > "$tmpdir/repair-command.log"
require_grep "exporting base heap" "$tmpdir/repair-command.log"
require_no_file "$heap.tmp"
rm -f "$markers"/*.hierarchy
(cd "$project" && "$HOLBUILD_BIN" build --force=theory CTheory) > "$tmpdir/after-repair.log" 2>&1
if grep -q "exporting base heap" "$tmpdir/after-repair.log"; then
  echo "repaired base heap was exported again" >&2
  exit 1
fi
require_heap_start C

# Exporting the heap as a plain heap drops the base heap's .ok, so setting
# base again re-exports it rather than trusting the plain heap.
write_manifest ""
(cd "$project" && "$HOLBUILD_BIN" heap base) > "$tmpdir/plain-export.log"
require_file "$heap"
require_no_file "$heap.ok"
write_manifest "base = true"
rm -f "$markers"/*.hierarchy
(cd "$project" && "$HOLBUILD_BIN" build --force=theory CTheory) > "$tmpdir/after-plain.log"
require_grep "exporting base heap" "$tmpdir/after-plain.log"
require_heap_start C

# A heap file deleted while its .ok stays is just stale: no checkpoint
# residue warning, and it is exported again.
rm "$heap"
rm -f "$markers"/*.hierarchy
(cd "$project" && "$HOLBUILD_BIN" build --force=theory CTheory) > "$tmpdir/missing-heap.log" 2>&1
if grep -q "checkpoint metadata exists without checkpoint file" "$tmpdir/missing-heap.log"; then
  echo "missing base heap was reported as checkpoint residue" >&2
  cat "$tmpdir/missing-heap.log" >&2
  exit 1
fi
require_grep "exporting base heap" "$tmpdir/missing-heap.log"
require_heap_start C

# Key dumps mark the rows of theories that start from the heap.
(cd "$project" && HOLBUILD_DUMP_KEYS="$tmpdir/heap.keys" "$HOLBUILD_BIN" build) > /dev/null
for theory in B C; do require_grep "${theory}Theory.*	base_heap\$" "$tmpdir/heap.keys"; done
for theory in A D; do
  if grep -q "${theory}Theory.*base_heap" "$tmpdir/heap.keys"; then
    echo "$theory is not a base heap user but its key row is marked" >&2
    cat "$tmpdir/heap.keys" >&2
    exit 1
  fi
done

# `--dry-run` and `export` compute a heap user's input key as a build does:
# dry-run prints it, and export finds the build's cache entry under it.
c_key=$(awk -F'\t' '$1 ~ /CTheory/ {print $2}' "$tmpdir/heap.keys")
[[ -n "$c_key" ]] || { echo "no CTheory row in the key dump" >&2; cat "$tmpdir/heap.keys" >&2; exit 1; }
(cd "$project" && "$HOLBUILD_BIN" build --dry-run CTheory) > "$tmpdir/dry-run.log"
dry_key=$(awk '/^CTheory / {found = 1} found && /input_key:/ {print $2; exit}' "$tmpdir/dry-run.log")
[[ "$dry_key" == "$c_key" ]] || { echo "dry-run input key $dry_key differs from build's $c_key" >&2; exit 1; }
(cd "$project" && "$HOLBUILD_BIN" export -o "$tmpdir/heap-user.hbx" CTheory) > "$tmpdir/export.log" 2>&1
require_grep "exported 3 cache action" "$tmpdir/export.log"

# Two users that build at once share one export, and a failed export fails
# both without being retried.
for theory in F G; do
  cat > "$project/src/${theory}Script.sml" <<SML
open HolKernel Parse boolLib bossLib ATheory;
$(record_hierarchy "$theory")
val _ = new_theory "$theory";
val ${theory,,}_thm = store_thm("${theory,,}_thm", \`\`T /\\ T\`\`, REWRITE_TAC [a_thm]);
val _ = export_theory();
SML
done
rm -f "$heap" "$heap.ok" "$markers"/*.hierarchy
(cd "$project" && HOLBUILD_TIMING_LOG="$tmpdir/shared-export.timing" HOLBUILD_TIMING_DETAIL=fine \
   "$HOLBUILD_BIN" -j2 build FTheory GTheory) > "$tmpdir/shared-export.log" 2>&1
exports=$(grep -c "exporting base heap" "$tmpdir/shared-export.log" || true)
[[ "$exports" == 1 ]] || { echo "two base heap users exported the heap $exports times" >&2; exit 1; }
require_heap_start F
require_heap_start G
# A user that finds the heap already exported returns at once, so a user that
# took at least half as long as the export waited for it.
phase_ms() {
  grep "name=build.exec.base_heap.$1	status=ok" "$tmpdir/shared-export.timing" |
    sed 's/.*	ms=\([0-9]*\).*/\1/'
}
export_ms=$(phase_ms export)
waits=$(phase_ms ensure | awk -v export_ms="$export_ms" '2 * $1 >= export_ms' | wc -l)
if [[ -z "$export_ms" || "$waits" != 2 ]]; then
  echo "expected both base heap users to wait for the one export" >&2
  grep "base_heap" "$tmpdir/shared-export.timing" >&2
  exit 1
fi
# A regular file where the heap's directory belongs fails the export, even
# for root.  holbuild reports only the first failure, so the timing log shows
# that both users asked for the heap.
rm -rf "$heap" "$heap.ok" "$project/.holbuild/heap"
touch "$project/.holbuild/heap"
if (cd "$project" && HOLBUILD_TIMING_LOG="$tmpdir/failed-export.timing" HOLBUILD_TIMING_DETAIL=fine \
      "$HOLBUILD_BIN" -j2 build --force=theory FTheory GTheory) > "$tmpdir/failed-export.log" 2>&1; then
  echo "build succeeded although the base heap could not be exported" >&2
  exit 1
fi
rm "$project/.holbuild/heap"
exports=$(grep -c "exporting base heap" "$tmpdir/failed-export.log" || true)
[[ "$exports" == 1 ]] || { echo "a failed base heap export was attempted $exports times" >&2; exit 1; }
require_grep "hol buildheap failed while exporting heap" "$tmpdir/failed-export.log"
users=$(grep -c "name=build.exec.base_heap.ensure	status=fail" "$tmpdir/failed-export.timing" || true)
[[ "$users" == 2 ]] || { echo "$users base heap users saw the failed export, expected 2" >&2; exit 1; }
rm "$project/src/FScript.sml" "$project/src/GScript.sml"

# The export's own holproject.toml stops HOL's search for a project, so
# neither the project's nor one planted above it adds to the heap's load path.
mkdir -p "$tmpdir/planted-incs"
printf 'external_includes = ["%s"]\n' "$tmpdir/planted-incs" > "$tmpdir/holproject.toml"
(cd "$project" && "$HOLBUILD_BIN" heap base) > "$tmpdir/planted-export.log" 2>&1
rm -f "$markers"/*.hierarchy
(cd "$project" && "$HOLBUILD_BIN" build --force=theory BTheory) > "$tmpdir/planted.log" 2>&1
require_heap_start B
require_cold_load_path B
if compgen -G "$project/.holbuild/stage/heap-export-*" > /dev/null; then
  echo "base heap export left its directory behind" >&2
  exit 1
fi
rm "$tmpdir/holproject.toml"

# The export does not write to the holbuild cache, which may be read-only or
# inside the project.  A regular file at the cache's tmp/ also blocks the
# export directory the cache used to hold, for root too.
for cache in "$project/.hol/cache" "$tmpdir/read-only-cache"; do
  use_case_cache "$cache"
  rm -f "$markers"/*.hierarchy
  build_flags=(--force=theory)
  if [[ "$cache" == "$tmpdir/read-only-cache" ]]; then
    touch "$cache/tmp"
    chmod a-w "$cache"
    build_flags=(--no-cache --force=theory)
  fi
  if ! (cd "$project" && "$HOLBUILD_BIN" build "${build_flags[@]}" CTheory) > "$tmpdir/cache-$(basename "$cache").log" 2>&1; then
    chmod u+w "$cache"
    echo "base heap export failed with HOLBUILD_CACHE=$cache" >&2
    cat "$tmpdir/cache-$(basename "$cache").log" >&2
    exit 1
  fi
  chmod u+w "$cache"
  require_grep "exporting base heap" "$tmpdir/cache-$(basename "$cache").log"
  require_heap_start C
done
rm -rf "$project/.hol"
use_case_cache "$tmpdir/cache"

# The heap records the path of the hol.state it extends, so moving the
# toolchain (here, with the cache that links to it) exports it again.
(cd "$project" && "$HOLBUILD_BIN" build --force=theory CTheory) > "$tmpdir/before-move.log"
require_file "$heap.ok"
mv "$tmpdir/cache" "$tmpdir/cache-moved"
use_case_cache "$tmpdir/cache-moved"
rm -f "$markers"/*.hierarchy
(cd "$project" && "$HOLBUILD_BIN" build --force=theory CTheory) > "$tmpdir/moved-toolchain.log" 2>&1
require_grep "exporting base heap" "$tmpdir/moved-toolchain.log"
require_heap_start C

# A theory that reaches only some of the objects starts from hol.state.
cat > "$project/src/EScript.sml" <<SML
open HolKernel Parse boolLib bossLib CTheory DTheory;
$(record_hierarchy E)
val _ = new_theory "E";
val e_thm = store_thm("e_thm", \`\`T /\\ T\`\`, REWRITE_TAC [c_thm]);
val _ = export_theory();
SML
sed -i 's/objects = \["ATheory"\]/objects = ["ATheory", "DTheory"]/' "$project/holproject.toml"
rm -f "$markers"/*.hierarchy
(cd "$project" && "$HOLBUILD_BIN" -j2 build --force) > "$tmpdir/two-objects.log"
for theory in A B C D; do require_toolchain_start "$theory"; done
require_heap_start E
write_manifest "base = true"
rm "$project/src/EScript.sml"

# An object with project ancestors: a user whose preloads also name one of
# them starts from the heap and builds what a hol.state child builds.
{
  echo 'open HolKernel Parse boolLib bossLib BTheory CTheory;'
  record_hierarchy H
  cat <<'SML'
val _ = new_theory "H";
val h_thm = store_thm("h_thm", ``T /\ T``, REWRITE_TAC [b_thm, c_thm]);
val _ = export_theory();
SML
} > "$project/src/HScript.sml"
write_manifest ""
rm -f "$markers"/*.hierarchy
(cd "$project" && "$HOLBUILD_BIN" build HTheory) > "$tmpdir/ancestor-cold.log"
require_toolchain_start H
h_cold=$(sha256sum < "$obj/HTheory.dat")
write_manifest "base = true"
sed -i 's/objects = \["ATheory"\]/objects = ["CTheory"]/' "$project/holproject.toml"
rm -f "$markers"/*.hierarchy
(cd "$project" && "$HOLBUILD_BIN" build HTheory) > "$tmpdir/ancestor-heap.log"
require_grep "exporting base heap" "$tmpdir/ancestor-heap.log"
require_heap_start H
require_cold_load_path H
[[ "$(sha256sum < "$obj/HTheory.dat")" == "$h_cold" ]] ||
  { echo "HTheory differs between toolchain and base heap starts" >&2; exit 1; }
write_manifest "base = true"
rm "$project/src/HScript.sml"

# With --source-dir, each build directory exports its own base heap under its
# .holbuild/, and the source tree, here read-only, is never written.
shared_src=$tmpdir/shared-src
cp -R "$project" "$shared_src"
rm -rf "$shared_src/.holbuild"
chmod -R a-w "$shared_src"
pids=()
for out in out1 out2; do
  mkdir -p "$tmpdir/$out"
  (cd "$tmpdir/$out" && "$HOLBUILD_BIN" --source-dir "$shared_src" build --force=theory CTheory) \
    > "$tmpdir/$out.log" 2>&1 &
  pids+=($!)
done
status=0
for pid in "${pids[@]}"; do wait "$pid" || status=1; done
chmod -R u+w "$shared_src"
if [[ "$status" != 0 ]]; then
  echo "a --source-dir build failed" >&2
  cat "$tmpdir/out1.log" "$tmpdir/out2.log" >&2
  exit 1
fi
for out in out1 out2; do
  require_grep "exporting base heap $tmpdir/$out/.holbuild/heap/base.save" "$tmpdir/$out.log"
  require_grep "kind=base_heap" "$tmpdir/$out/.holbuild/heap/base.save.ok"
done
require_no_file "$shared_src/.holbuild"
# Each build directory keeps its own heap current.
(cd "$tmpdir/out1" && "$HOLBUILD_BIN" --source-dir "$shared_src" build --force=theory CTheory) \
  > "$tmpdir/out1-again.log" 2>&1
if grep -q "exporting base heap" "$tmpdir/out1-again.log"; then
  echo "a build directory's base heap was exported again after another's export" >&2
  exit 1
fi
# --quiet hides the export message, like the other progress lines.
rm "$tmpdir/out2/.holbuild/heap/base.save"
(cd "$tmpdir/out2" && "$HOLBUILD_BIN" --quiet --source-dir "$shared_src" build --force=theory CTheory) \
  > "$tmpdir/out2-quiet.log" 2>&1
require_file "$tmpdir/out2/.holbuild/heap/base.save"
if grep -q "exporting base heap" "$tmpdir/out2-quiet.log"; then
  echo "--quiet printed the base heap export" >&2
  exit 1
fi

# Only root-package theories start from the base heap: a dependency theory
# that reaches the objects keeps its input key and starts from hol.state.  A
# dependency's own base heaps are ignored with a warning, and the root
# project's heap checks skip its manifest, here with two base heaps sharing an
# output.
dep=$tmpdir/dep
consumer=$tmpdir/consumer
consumer_heap=$consumer/.holbuild/heap/base.save
mkdir -p "$dep/src" "$consumer/src"
{
  write_schema2_prelude
  cat <<'TOML'
[project]
name = "depbase"

[build]
members = ["src"]

[[heap]]
name = "base"
output = "base.save"
objects = ["PTheory"]
base = true

[[heap]]
name = "other"
output = "base.save"
objects = ["PTheory"]
base = true
TOML
} > "$dep/holproject.toml"
cat > "$dep/src/PScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "P";
val p_thm = store_thm("p_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
{
  echo 'open HolKernel Parse boolLib bossLib PTheory;'
  record_hierarchy Q
  cat <<'SML'
val _ = new_theory "Q";
val q_thm = store_thm("q_thm", ``T /\ T``, REWRITE_TAC [p_thm]);
val _ = export_theory();
SML
} > "$dep/src/QScript.sml"
dep_rev=$(init_git_repo "$dep")
write_consumer_manifest() {
  {
    write_schema2_prelude
    cat <<TOML
[project]
name = "consumer"

[build]
members = ["src"]

[dependencies.depbase]
git = "$dep"
rev = "$dep_rev"

[[heap]]
name = "base"
output = ".holbuild/heap/base.save"
objects = ["PTheory"]
$1
TOML
  } > "$consumer/holproject.toml"
}
{
  echo 'open HolKernel Parse boolLib bossLib QTheory;'
  record_hierarchy R
  cat <<'SML'
val _ = new_theory "R";
val r_thm = store_thm("r_thm", ``T /\ T``, REWRITE_TAC [q_thm]);
val _ = export_theory();
SML
} > "$consumer/src/RScript.sml"
write_consumer_manifest ""
rm -f "$markers"/*.hierarchy
(cd "$consumer" && "$HOLBUILD_BIN" -j2 build) > "$tmpdir/consumer-cold.log" 2>&1
warnings=$(grep -c "ignoring base = true in dependency package depbase" "$tmpdir/consumer-cold.log" || true)
[[ "$warnings" == 1 ]] || { echo "dependency base heap warning printed $warnings times" >&2; exit 1; }
require_file "$markers/Q.hierarchy"
if grep -q 'base\.save' "$markers/Q.hierarchy"; then
  echo "dependency theory Q did not start from hol.state" >&2
  cat "$markers/Q.hierarchy" >&2
  exit 1
fi
write_consumer_manifest "base = true"
rm -f "$markers"/*.hierarchy
(cd "$consumer" && "$HOLBUILD_BIN" -j2 build) > "$tmpdir/consumer-heap.log" 2>&1
require_no_file "$markers/Q.hierarchy"
require_grep "$consumer_heap" "$markers/R.hierarchy"

reject() {
  local name=$1 expected=$2 extra=$3
  local dir=$tmpdir/$name
  cp -R "$project" "$dir"
  printf '%s\n' "$extra" >> "$dir/holproject.toml"
  if (cd "$dir" && "$HOLBUILD_BIN" build) > "$tmpdir/$name.log" 2>&1; then
    echo "$name: build unexpectedly accepted the manifest" >&2
    exit 1
  fi
  require_grep "$expected" "$tmpdir/$name.log"
}

reject two-bases "at most one \[\[heap\]\] may set base = true" '
[[heap]]
name = "other"
output = "other.save"
objects = ["BTheory"]
base = true'
reject duplicate-output "duplicate heap/executable output: \./\.holbuild/heap/base\.save" '
[[heap]]
name = "other"
output = "./.holbuild/heap/base.save"
objects = ["BTheory"]'
reject duplicate-absolute-output "duplicate heap/executable output: $tmpdir/duplicate-absolute-output/" "
[[heap]]
name = \"other\"
output = \"$tmpdir/duplicate-absolute-output/.holbuild/heap/base.save\"
objects = [\"BTheory\"]"
reject non-boolean-base "holproject.toml: base must be a boolean in \[\[heap\]\] other" '
[[heap]]
name = "other"
output = "other.save"
objects = ["BTheory"]
base = "yes"'
reject executable-base "unknown field in executable: base" '
[[executable]]
name = "tool"
output = "tool.exe"
objects = ["ATheory"]
base = true'
no_objects=$tmpdir/no-objects
cp -R "$project" "$no_objects"
sed -i 's/objects = \["ATheory"\]/objects = []/' "$no_objects/holproject.toml"
if (cd "$no_objects" && "$HOLBUILD_BIN" build) > "$tmpdir/no-objects.log" 2>&1; then
  echo "build unexpectedly accepted a base heap with no objects" >&2
  exit 1
fi
require_grep "heap target has no objects: base" "$tmpdir/no-objects.log"
cat > "$project/src/helperLib.sml" <<'SML'
structure helperLib = struct val x = 1 end
SML
sed -i 's/objects = \["ATheory"\]/objects = ["helperLib"]/' "$project/holproject.toml"
if (cd "$project" && "$HOLBUILD_BIN" build) > "$tmpdir/sml-object.log" 2>&1; then
  echo "base heap unexpectedly accepted an SML object" >&2
  exit 1
fi
require_grep "base heap objects must be theory targets: helperLib" "$tmpdir/sml-object.log"
