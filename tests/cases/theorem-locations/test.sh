#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

# Theorem locations in the theory database must name the source script and
# its lines, not holbuild's instrumented stage copy of it.

write_project() {
  local project=$1
  mkdir -p "$project/src"
  {
    write_schema2_prelude
    cat <<'TOML'
[project]
name = "locs"

[build]
members = ["src"]
TOML
  } > "$project/holproject.toml"
  cat > "$project/src/locScript.sml" <<'SML'
Theory loc
Ancestors arithmetic

Definition double_def:
  double n = n + n
End

Theorem double_0:
  double 0 = 0
Proof
  simp[double_def]
QED

Definition countdown_def:
  countdown n = if n = 0 then 0 else countdown (n - 1)
Termination
  WF_REL_TAC `measure I`
End

Theorem double_1:
  double 1 = 2
Proof
  simp[double_def]
QED

Theorem double_2:
  double 2 = 4
Proof
  simp[double_def]
QED
SML
  cat > "$project/probe.sml" <<'SML'
load "locTheory";
fun show n =
  case DB.lookup {Thy = "loc", Name = n} of
      SOME (_, {loc = DB.Located {scriptpath, linenum, ...}, ...}) =>
        print ("location " ^ n ^ " " ^ scriptpath ^ ":" ^ Int.toString linenum ^ "\n")
    | _ => print ("location " ^ n ^ " unknown\n");
val _ = List.app show ["double_def", "double_0", "countdown_def", "double_1", "double_2"];
SML
}

check_locations() {
  local project=$1
  local expected=$2
  local label=$3
  local log=$tmpdir/$label-probe.log
  (cd "$project" && "$HOLBUILD_BIN" run probe.sml) > "$log" 2>&1
  if ! diff <(grep '^location ' "$log") "$expected"; then
    echo "$label: theorem locations differ from the source (log: $log)" >&2
    exit 1
  fi
}

expected=$tmpdir/expected
cat > "$expected" <<'TXT'
location double_def $(locs)/src/locScript.sml:4
location double_0 $(locs)/src/locScript.sml:8
location countdown_def $(locs)/src/locScript.sml:14
location double_1 $(locs)/src/locScript.sml:20
location double_2 $(locs)/src/locScript.sml:26
TXT

project=$tmpdir/project
write_project "$project"
(cd "$project" && "$HOLBUILD_BIN" build locTheory) > "$tmpdir/build.log" 2>&1
check_locations "$project" "$expected" full

# Resuming from the checkpoint after double_1 replays only the tail of the
# script; two inserted lines move double_2 down.
python3 - "$project/src/locScript.sml" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
old = "Theorem double_2:\n  double 2 = 4\nProof\n  simp[double_def]\nQED"
new = "(* moved *)\n\nTheorem double_2:\n  double 2 = 4\nProof\n  rw[double_def]\nQED"
assert old in text
path.write_text(text.replace(old, new))
PY
(cd "$project" && "$HOLBUILD_BIN" build locTheory) > "$tmpdir/resume.log" 2>&1
require_grep "from: theorem-context checkpoint after double_1" "$tmpdir/resume.log"
sed 's/double_2 \(.*\):26$/double_2 \1:28/' "$expected" > "$tmpdir/expected-resume"
check_locations "$project" "$tmpdir/expected-resume" resume

# Without proof-step instrumentation the stage copy is the plain script.
plain=$tmpdir/plain
write_project "$plain"
(cd "$plain" && "$HOLBUILD_BIN" build --no-cache --skip-proof-steps --skip-checkpoints locTheory) > "$tmpdir/plain.log" 2>&1
check_locations "$plain" "$expected" plain

# Poly reports static errors at source lines, which the diagnostic quotes.
broken=$tmpdir/broken
write_project "$broken"
python3 - "$broken/src/locScript.sml" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
lines = path.read_text().split("\n")
lines.insert(18, 'val _ = 1 + "a";')
path.write_text("\n".join(lines))
PY
if (cd "$broken" && "$HOLBUILD_BIN" build --no-cache locTheory) > "$tmpdir/broken.log" 2>&1; then
  echo "expected static error to fail the build" >&2
  exit 1
fi
require_grep "^locScript.sml:19: error: Type error" "$tmpdir/broken.log"
require_grep "source: .*/src/locScript.sml:19$" "$tmpdir/broken.log"
require_grep '^> 19 | val _ = 1 + "a";$' "$tmpdir/broken.log"
