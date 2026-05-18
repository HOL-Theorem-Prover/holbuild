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
export HOLBUILD_CACHE="$tmpdir/cache"

project=$tmpdir/project
counter=$tmpdir/slow-prefix-count.txt
mkdir -p "$project/src"
touch "$counter"
cat > "$project/holproject.toml" <<'TOML'
[project]
name = "new-ir-replay"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val slow_prefix_counter = "$counter";
fun bump_counter () =
  let val out = TextIO.openAppend slow_prefix_counter
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun slow_tac g = (bump_counter(); OS.Process.sleep (Time.fromReal 0.25); ALL_TAC g);
Theorem slow_prefix_failure:
  T
Proof
  slow_tac >> slow_tac >> FAIL_TAC "first suffix failure"
QED
val _ = export_theory();
SML

first_log=$tmpdir/first.log
if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$first_log" 2>&1; then
  echo "expected first new-ir proof to fail" >&2
  exit 1
fi
first_count=$(wc -c < "$counter" | tr -d ' ')
[[ "$first_count" = "2" ]] || { echo "expected first run to execute slow prefix twice, got $first_count" >&2; exit 1; }
require_grep "FAIL_TAC \"first suffix failure\"" "$first_log"
require_grep "failed tactic top input goal:" "$first_log"
require_grep "plan position: 02 list_tactic >> FAIL_TAC" "$first_log"
require_grep "failed tactic input goals: 1" "$first_log"
require_file "$(find "$project/.holbuild/checkpoints" -name '*slow_prefix_failure_failed_prefix.save' -print -quit)"

python3 - <<PY
from pathlib import Path
path = Path("$project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "first suffix failure"', 'FAIL_TAC "edited suffix failure"'))
PY
edited_log=$tmpdir/edited.log
if (cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$edited_log" 2>&1; then
  echo "expected edited suffix new-ir proof to fail" >&2
  exit 1
fi
edited_count=$(wc -c < "$counter" | tr -d ' ')
[[ "$edited_count" = "2" ]] || { echo "new-ir failed-prefix replay reran unchanged slow prefix after suffix edit; count $edited_count" >&2; exit 1; }
require_grep "from: failed-prefix checkpoint in slow_prefix_failure" "$edited_log"
require_grep "edited suffix failure" "$edited_log"
require_grep "plan position: 02 list_tactic >> FAIL_TAC" "$edited_log"
require_grep "failed tactic input goals: 1" "$edited_log"

python3 - <<PY
from pathlib import Path
path = Path("$project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "edited suffix failure"', 'ACCEPT_TAC TRUTH'))
PY
fixed_log=$tmpdir/fixed.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$fixed_log" 2>&1
fixed_count=$(wc -c < "$counter" | tr -d ' ')
[[ "$fixed_count" = "2" ]] || { echo "new-ir failed-prefix replay reran unchanged slow prefix after suffix fix; count $fixed_count" >&2; exit 1; }
require_grep "from: failed-prefix checkpoint in slow_prefix_failure" "$fixed_log"
require_grep "ATheory built" "$fixed_log"
require_file "$project/.holbuild/obj/src/ATheory.dat"

shorten_project=$tmpdir/shorten-project
shorten_counter=$tmpdir/shorten-count.txt
mkdir -p "$shorten_project/src"
touch "$shorten_counter"
cp "$project/holproject.toml" "$shorten_project/holproject.toml"
python3 - <<PY
from pathlib import Path
project = Path("$shorten_project")
counter = Path("$shorten_counter")
long_prefix = " >> ".join(["slow_tac"] + ["ALL_TAC"] * 20 + ['FAIL_TAC "long suffix failure"'])
(project / "src" / "AScript.sml").write_text(f'''open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val slow_prefix_counter = "{counter}";
fun bump_counter () =
  let val out = TextIO.openAppend slow_prefix_counter
  in TextIO.output(out, "x"); TextIO.closeOut out end;
fun slow_tac g = (bump_counter(); ALL_TAC g);
Theorem shortened_replay:
  T
Proof
  {long_prefix}
QED
val _ = export_theory();
''')
PY

shorten_first_log=$tmpdir/shorten-first.log
if (cd "$shorten_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$shorten_first_log" 2>&1; then
  echo "expected shortened replay first build to fail" >&2
  exit 1
fi
shorten_first_count=$(wc -c < "$shorten_counter" | tr -d ' ')
[[ "$shorten_first_count" = "1" ]] || { echo "expected shortened replay first run to execute slow prefix once, got $shorten_first_count" >&2; exit 1; }
require_grep "long suffix failure" "$shorten_first_log"

python3 - <<PY
from pathlib import Path
path = Path("$shorten_project/src/AScript.sml")
text = path.read_text()
proof = text.index('Proof')
start = text.index('slow_tac', proof)
end = text.index('QED', start)
path.write_text(text[:start] + 'slow_tac >> FAIL_TAC "short suffix failure"\n' + text[end:])
PY
shorten_edit_log=$tmpdir/shorten-edit.log
if (cd "$shorten_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$shorten_edit_log" 2>&1; then
  echo "expected shortened replay edited build to fail" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in shortened_replay" "$shorten_edit_log"
require_grep "short suffix failure" "$shorten_edit_log"
if grep -q "CANT_BACKUP_ANYMORE" "$shorten_edit_log"; then
  echo "failed-prefix replay could not rewind retained proof history" >&2
  exit 1
fi

unsolved_project=$tmpdir/unsolved-project
mkdir -p "$unsolved_project/src"
cp "$project/holproject.toml" "$unsolved_project/holproject.toml"
cat > "$unsolved_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem unsolved_finish_replay:
  T
Proof
  ALL_TAC >> FAIL_TAC "saved failed-prefix before unsolved suffix"
QED
val _ = export_theory();
SML

unsolved_first_log=$tmpdir/unsolved-first.log
if (cd "$unsolved_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$unsolved_first_log" 2>&1; then
  echo "expected unsolved replay seed to fail" >&2
  exit 1
fi
require_grep "saved failed-prefix before unsolved suffix" "$unsolved_first_log"

python3 - <<PY
from pathlib import Path
path = Path("$unsolved_project/src/AScript.sml")
path.write_text(path.read_text().replace('FAIL_TAC "saved failed-prefix before unsolved suffix"', 'ALL_TAC'))
PY
unsolved_edit_log=$tmpdir/unsolved-edit.log
if (cd "$unsolved_project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory) > "$unsolved_edit_log" 2>&1; then
  echo "expected failed-prefix replay with unsolved suffix to fail" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in unsolved_finish_replay" "$unsolved_edit_log"
require_grep "no theorem proved" "$unsolved_edit_log"
require_grep "failed tactic top input goal:" "$unsolved_edit_log"
require_grep "failed tactic input goals: 1" "$unsolved_edit_log"
