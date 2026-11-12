#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"
hol_rev=$(holbuild_pinned_hol_rev)
mkdir -p "$tmpdir/project/src"
cd "$tmpdir/project"
cat > holproject.toml <<TOML
[holbuild]
schema = 2
[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$hol_rev"
[project]
name = "summary"
[build]
members = ["src"]
TOML
for name in A B C; do
  parent=
  [[ $name != B ]] || parent='open ATheory;'
  [[ $name != C ]] || parent='open BTheory;'
  cat > "src/${name}Script.sml" <<SML
open HolKernel Parse boolLib bossLib;
$parent
val _ = new_theory "$name";
val ok = store_thm("ok", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
done

build() {
  "$HOLBUILD_BIN" "$@" > "$tmpdir/build.log" 2>&1 || { cat "$tmpdir/build.log" >&2; return 1; }
}

# Exporting a plan must not turn the first build into a warm worktree.
build --remote-cache http://127.0.0.1:1 action-spec CTheory
[[ ! -e .holbuild/command-sources ]]
build build CTheory
python3 - <<'PY'
import json,pathlib
records=[json.loads(p.read_text()) for p in pathlib.Path('.holbuild/commands').glob('*.json')]
assert len(records)==1, records
assert records[0]['exit_code']==0
assert records[0]['plans'][0]['source_hashes_complete']
assert records[0]['plans'][0]['cold_worktree']
assert len(records[0]['plans'][0]['newly_observed_sources'])>=3
PY
build build CTheory
printf '\n(* root edit *)\n' >> src/AScript.sml
build build CTheory
printf '\n(* leaf edit *)\n' >> src/CScript.sml
build build CTheory
# A failed attempt advances the source baseline, so its unchanged retry is
# not reported as another source edit.
printf '\nval broken = this_is_not_declared;\n' >> src/CScript.sml
if build build CTheory; then echo 'broken script passed' >&2; exit 1; fi
if build build CTheory; then echo 'broken retry passed' >&2; exit 1; fi
python3 - <<'PY'
import json,pathlib
records=sorted((json.loads(p.read_text()) for p in pathlib.Path('.holbuild/commands').glob('*.json')),
               key=lambda r:r['started_at_ms'])
assert len(records)==6, len(records)
assert all(r['ended_at_ms']>=r['started_at_ms'] for r in records)
assert not records[1]['plans'][0]['changed_sources']
assert records[1]['local_outcomes']['built']==0
root=records[2]['plans'][0]['changed_sources']
assert len(root)==1 and root[0]['name']=='ATheory', root
assert root[0]['affected_theories_in_plan']==3, root
leaf=records[3]['plans'][0]['changed_sources']
assert len(leaf)==1 and leaf[0]['name']=='CTheory', leaf
assert leaf[0]['affected_theories_in_plan']==1
assert records[4]['exit_code']==1 and records[5]['exit_code']==1
assert records[4]['plans'][0]['changed_sources']
assert not records[5]['plans'][0]['changed_sources']
PY

# Caller-owned summaries are per process, and do not enter the plan key.
HOLBUILD_COMMAND_RECORD="$tmpdir/not-this-process.json" HOLBUILD_COMMAND_RECORD_PID=not-a-pid \
  build --version
[[ ! -e "$tmpdir/not-this-process.json" ]]
