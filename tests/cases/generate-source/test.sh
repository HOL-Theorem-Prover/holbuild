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
mkdir -p "$project/data" "$project/scripts" "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "generated_source"

[build]
members = ["src", "gen"]

[[generate]]
name = "copy-spec"
command = ["python3", "scripts/copy_spec.py", "data/spec.txt", "gen/spec.txt", "data/copy.count"]
inputs = ["scripts/copy_spec.py", "data/spec.txt"]
outputs = ["gen/spec.txt"]

[[generate]]
name = "make-theory"
deps = ["copy-spec"]
command = ["python3", "scripts/gen_theory.py", "gen/spec.txt", "gen/GScript.sml", "data/theory.count"]
inputs = ["scripts/gen_theory.py", "gen/spec.txt"]
outputs = ["gen/GScript.sml"]
TOML
cat > "$project/scripts/copy_spec.py" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1])
out = Path(sys.argv[2])
count = Path(sys.argv[3])
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(src.read_text())
count.write_text(count.read_text() + "x" if count.exists() else "x")
PY
cat > "$project/scripts/gen_theory.py" <<'PY'
from pathlib import Path
import sys
spec = Path(sys.argv[1]).read_text().strip()
out = Path(sys.argv[2])
count = Path(sys.argv[3])
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(f'''open HolKernel Parse boolLib bossLib;
val _ = new_theory "G";

(* generated spec: {spec} *)
Theorem generated_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED

val _ = export_theory();
''')
count.write_text(count.read_text() + "x" if count.exists() else "x")
PY
printf 'first\n' > "$project/data/spec.txt"

first_log=$tmpdir/first.log
(cd "$project" && "$HOLBUILD_BIN" build GTheory) > "$first_log"
require_file "$project/gen/spec.txt"
require_file "$project/gen/GScript.sml"
require_file "$project/.holbuild/obj/gen/GTheory.dat"
require_grep "generated spec: first" "$project/gen/GScript.sml"
[[ "$(wc -c < "$project/data/copy.count" | tr -d ' ')" = "1" ]] || { echo "copy generator did not run once" >&2; exit 1; }
[[ "$(wc -c < "$project/data/theory.count" | tr -d ' ')" = "1" ]] || { echo "theory generator did not run once" >&2; exit 1; }

second_log=$tmpdir/second.log
(cd "$project" && "$HOLBUILD_BIN" --verbose build GTheory) > "$second_log"
require_grep "GTheory is up to date" "$second_log"
[[ "$(wc -c < "$project/data/copy.count" | tr -d ' ')" = "1" ]] || { echo "copy generator reran despite unchanged inputs" >&2; exit 1; }
[[ "$(wc -c < "$project/data/theory.count" | tr -d ' ')" = "1" ]] || { echo "theory generator reran despite unchanged inputs" >&2; exit 1; }

printf 'second\n' > "$project/data/spec.txt"
third_log=$tmpdir/third.log
(cd "$project" && "$HOLBUILD_BIN" build GTheory) > "$third_log"
require_grep "generated spec: second" "$project/gen/GScript.sml"
[[ "$(wc -c < "$project/data/copy.count" | tr -d ' ')" = "2" ]] || { echo "copy generator did not rerun after input changed" >&2; exit 1; }
[[ "$(wc -c < "$project/data/theory.count" | tr -d ' ')" = "2" ]] || { echo "theory generator did not rerun after generated input changed" >&2; exit 1; }

printf 'poisoned generated source\n' > "$project/gen/GScript.sml"
repair_log=$tmpdir/repair.log
(cd "$project" && "$HOLBUILD_BIN" build GTheory) > "$repair_log"
require_grep "generated spec: second" "$project/gen/GScript.sml"
if grep -q "poisoned" "$project/gen/GScript.sml"; then
  echo "declared generated output was not overwritten/repaired" >&2
  exit 1
fi
[[ "$(wc -c < "$project/data/copy.count" | tr -d ' ')" = "2" ]] || { echo "unaffected dependency generator reran during repair" >&2; exit 1; }
[[ "$(wc -c < "$project/data/theory.count" | tr -d ' ')" = "3" ]] || { echo "theory generator did not rerun to repair changed output" >&2; exit 1; }

bad_project=$tmpdir/bad-project
mkdir -p "$bad_project/scripts"
cat > "$bad_project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "bad_generated_source"

[build]
members = ["gen"]

[[generate]]
name = "bad"
command = ["python3", "scripts/missing_output.py"]
outputs = ["gen/MissingScript.sml"]
TOML
cat > "$bad_project/scripts/missing_output.py" <<'PY'
# Intentionally produces no declared output.
PY
bad_log=$tmpdir/bad.log
if (cd "$bad_project" && "$HOLBUILD_BIN" build MissingTheory) > "$bad_log" 2>&1; then
  echo "generator with missing declared output unexpectedly succeeded" >&2
  exit 1
fi
require_grep "did not produce declared output: gen/MissingScript.sml" "$bad_log"

unknown_dep_project=$tmpdir/unknown-dep-project
mkdir -p "$unknown_dep_project"
cat > "$unknown_dep_project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "unknown_dep"

[build]
members = []

[[generate]]
name = "gen"
deps = ["missing"]
command = ["true"]
outputs = ["gen/out.txt"]
TOML
unknown_dep_log=$tmpdir/unknown-dep.log
if (cd "$unknown_dep_project" && "$HOLBUILD_BIN" build --dry-run) > "$unknown_dep_log" 2>&1; then
  echo "generator with unknown dependency unexpectedly succeeded" >&2
  exit 1
fi
require_grep "generator gen depends on unknown generator missing" "$unknown_dep_log"

cycle_project=$tmpdir/cycle-project
mkdir -p "$cycle_project"
cat > "$cycle_project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "cycle"

[build]
members = []

[[generate]]
name = "a"
deps = ["b"]
command = ["true"]
outputs = ["gen/a.txt"]

[[generate]]
name = "b"
deps = ["a"]
command = ["true"]
outputs = ["gen/b.txt"]
TOML
cycle_log=$tmpdir/cycle.log
if (cd "$cycle_project" && "$HOLBUILD_BIN" build --dry-run) > "$cycle_log" 2>&1; then
  echo "generator cycle unexpectedly succeeded" >&2
  exit 1
fi
require_grep "generator dependency cycle" "$cycle_log"
