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
# Every child adds the project's dirs to its load path when it starts; the
# heap must not carry a second copy taken when it was exported.
project_entries=$(grep -c '/project$' "$markers/B.loadpath" || true)
if [[ "$project_entries" != 1 ]]; then
  echo "base heap user has the project root on its load path $project_entries times" >&2
  cat "$markers/B.loadpath" >&2
  exit 1
fi
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

# Only root-package theories start from the base heap: a dependency theory
# that reaches the objects keeps its input key, and a dependency's own base
# heap is ignored with a warning.
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
require_grep "ignoring base = true in dependency package depbase" "$tmpdir/consumer-cold.log"
require_file "$markers/Q.hierarchy"
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
reject duplicate-output "duplicate heap/executable output: .holbuild/heap/base.save" '
[[heap]]
name = "other"
output = "./.holbuild/heap/base.save"
objects = ["BTheory"]'
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
