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

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "parenthash"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "B";

Theorem b_thm:
  T
Proof
  ACCEPT_TAC ATheory.a_thm
QED

val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/initial.log" 2>&1
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_file "$project/.holbuild/obj/src/BTheory.dat"

python3 - <<PY
from pathlib import Path
import re
path = Path("$project/.holbuild/obj/src/BTheory.dat")
text = path.read_text()
changed = re.sub(r'\("A"\s*\.\s*"[0-9a-f]{40}"\)', '("A" .\n   "0000000000000000000000000000000000000000")', text, count=1)
if changed == text:
    raise SystemExit('BTheory.dat did not record A parent hash')
path.write_text(changed)
PY

stale_log=$tmpdir/stale.log
(cd "$project" && "$HOLBUILD_BIN" build --no-cache BTheory) > "$stale_log" 2>&1
require_grep "BTheory built" "$stale_log"
if grep -q "BTheory is up to date\|link_parents" "$stale_log"; then
  echo "stale local theory parent hash was accepted" >&2
  exit 1
fi

python3 - <<PY
from pathlib import Path
import re
path = Path("$project/.holbuild/obj/src/BTheory.dat")
text = path.read_text()
changed = re.sub(r'\("A"\s*\.\s*"[0-9a-f]{40}"\)', '("A" .\n   "0000000000000000000000000000000000000000")', text, count=1)
if changed == text:
    raise SystemExit('BTheory.dat did not record A parent hash after rebuild')
path.write_text(changed)
PY

rebuild_log=$tmpdir/rebuild.log
(cd "$project" && "$HOLBUILD_BIN" build --no-cache BTheory) > "$rebuild_log" 2>&1
require_grep "BTheory built" "$rebuild_log"
if grep -q "BTheory is up to date\|link_parents" "$rebuild_log"; then
  echo "stale theory parent hash was accepted" >&2
  exit 1
fi
