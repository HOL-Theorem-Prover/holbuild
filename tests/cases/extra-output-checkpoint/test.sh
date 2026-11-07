#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"
project=$tmpdir/project
mkdir -p "$project/src"
write_schema2_prelude > "$project/holproject.toml"
cat >> "$project/holproject.toml" <<'TOML'
[project]
name = "extra-output-checkpoint"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
fun holbuild_extra_outputs (_ : string list) = ()
val _ = holbuild_extra_outputs ["results/A.out"]
val _ = let val out = TextIO.openOut "results/A.out"
        in TextIO.output(out, "prefix\n"); TextIO.closeOut out end
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
Theorem a2_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = let val out = TextIO.openAppend "results/A.out"
        in TextIO.output(out, "suffix\n"); TextIO.closeOut out end
val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/first.log" 2>&1
require_file "$(find "$project/.holbuild/checkpoints" -name 'a2_thm_context.save' -print -quit)"
cp "$project/src/results/A.out" "$tmpdir/expected.out"

# Leave the theorem prefix unchanged, so a theorem-context checkpoint exists.
python3 - "$project/src/AScript.sml" <<'PYTHON'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().replace('val _ = export_theory();', """Theorem a3_thm:
  T
Proof
  ALL_TAC >> ACCEPT_TAC TRUTH
QED
val _ = export_theory();"""))
PYTHON
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/edited.log" 2>&1
require_grep "from: deps-loaded checkpoint" "$tmpdir/edited.log"
cmp "$tmpdir/expected.out" "$project/src/results/A.out"

# A failed-prefix checkpoint must not skip the output writer either.
sed -i 's/ALL_TAC >> ACCEPT_TAC TRUTH/ALL_TAC >> FAIL_TAC "extra-output failure"/' "$project/src/AScript.sml"
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/failed.log" 2>&1; then
  echo "failing theorem unexpectedly succeeded" >&2
  exit 1
fi
require_grep "extra-output failure" "$tmpdir/failed.log"
require_file "$(find "$project/.holbuild/checkpoints" -name 'a3_thm_failed_prefix.save' -print -quit)"
sed -i 's/FAIL_TAC "extra-output failure"/ACCEPT_TAC TRUTH >> ALL_TAC/' "$project/src/AScript.sml"
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/repaired.log" 2>&1
require_grep "from: deps-loaded checkpoint" "$tmpdir/repaired.log"
cmp "$tmpdir/expected.out" "$project/src/results/A.out"
cp "$project/.holbuild/obj/src/ATheory.dat" "$tmpdir/repaired.dat"

# The rebuilt output and theory must match execution without script checkpoints.
(cd "$project" && "$HOLBUILD_BIN" build --force --skip-checkpoints ATheory) > "$tmpdir/cold.log" 2>&1
cmp "$tmpdir/expected.out" "$project/src/results/A.out"
cmp "$tmpdir/repaired.dat" "$project/.holbuild/obj/src/ATheory.dat"
