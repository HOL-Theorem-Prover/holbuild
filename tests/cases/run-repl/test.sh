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
name = "runrepl"

[build]
members = ["src"]

[run]
loads = ["ATheory"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val repl_smoke_thm = store_thm("repl_smoke_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/build.log" 2>&1

repl_log=$tmpdir/repl.log
(
  printf 'val _ = (ATheory.repl_smoke_thm; print "REPL_SMOKE_OK\\n");\n'
) | (cd "$project" && timeout 20 "$HOLBUILD_BIN" repl) > "$repl_log" 2>&1
require_grep "REPL_SMOKE_OK" "$repl_log"

context="$project/.holbuild/holbuild-run-context.sml"
require_file "$context"
require_grep "loadPath :=" "$context"
require_grep "load \"ATheory\"" "$context"

run_script=$tmpdir/run-smoke.sml
cat > "$run_script" <<'SML'
val _ = (ATheory.repl_smoke_thm; print "RUN_SMOKE_OK\n");
SML
run_log=$tmpdir/run.log
(cd "$project" && "$HOLBUILD_BIN" run "$run_script") > "$run_log" 2>&1
require_grep "RUN_SMOKE_OK" "$run_log"

no_run_loads=$tmpdir/no-run-loads
cp -R "$project" "$no_run_loads"
python3 - "$no_run_loads/holproject.toml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace('\n[run]\nloads = ["ATheory"]\n', '\n')
path.write_text(text)
PY
manual_repl_log=$tmpdir/manual-repl.log
(
  printf 'load "ATheory";\n'
  printf 'val _ = (ATheory.repl_smoke_thm; print "MANUAL_REPL_LOAD_OK\\n");\n'
) | (cd "$no_run_loads" && timeout 20 "$HOLBUILD_BIN" repl) > "$manual_repl_log" 2>&1
require_grep "MANUAL_REPL_LOAD_OK" "$manual_repl_log"
