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
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "heapcase"

[build]
members = ["src"]

[[heap]]
name = "main"
output = ".holbuild/heap/main.save"
objects = ["ATheory"]

[[executable]]
name = "runtests"
output = "runtests.exe"
objects = ["RunSig", "runtests"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
cat > "$project/src/RunSig.sig" <<'SML'
signature RunSig = sig
  type value = unit PIntMap.t
  val message : string
end
SML
cat > "$project/src/runtests.sml" <<'SML'
structure Run : RunSig = struct
  type value = unit PIntMap.t
  val message = "executable ok"
end
fun main () = print (Run.message ^ "\n")
SML

(cd "$project" && "$HOLBUILD_BIN" -j2 heap main)
require_file "$project/.holbuild/heap/main.save"

(cd "$project" && "$HOLBUILD_BIN" executable runtests)
require_file "$project/runtests.exe"
"$project/runtests.exe" > "$tmpdir/runtests.out"
require_grep "executable ok" "$tmpdir/runtests.out"

printf '\n(* heap edit *)\n' >> "$project/src/AScript.sml"
(cd "$project" && "$HOLBUILD_BIN" heap main)
printf '\n(* executable edit *)\n' >> "$project/src/runtests.sml"
(cd "$project" && "$HOLBUILD_BIN" executable runtests)
(cd "$project" && "$HOLBUILD_BIN" build)
python3 - "$project" <<'PYCODE'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
records=sorted((json.loads(p.read_text()) for p in (root/'.holbuild/commands').glob('*.json')),
               key=lambda r:r['started_at_ms'])
assert len(records)==5, records
assert all(len(r['plans'])==1 for r in records), records
assert records[0]['plans'][0]['cold_worktree']
assert not records[1]['plans'][0]['cold_worktree']
assert [s['name'] for s in records[2]['plans'][0]['changed_sources']]==['ATheory'], records[2]
assert [s['name'] for s in records[3]['plans'][0]['changed_sources']]==['runtests'], records[3]
assert not records[4]['plans'][0]['changed_sources'], records[4]
PYCODE

bad=$tmpdir/bad
cp -R "$project" "$bad"
python3 - "$bad/holproject.toml" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace('objects = ["ATheory"]', 'objects = ["RunSig"]', 1)
p.write_text(s)
PY
if (cd "$bad" && "$HOLBUILD_BIN" heap main) > "$tmpdir/bad-heap.log" 2>&1; then
  echo "heap unexpectedly accepted signature target" >&2
  exit 1
fi
require_grep "heap objects cannot be signature targets" "$tmpdir/bad-heap.log"
