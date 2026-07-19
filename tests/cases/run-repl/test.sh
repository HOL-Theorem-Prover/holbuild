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

(cd "$project" && "$HOLBUILD_BIN" build ATheory stringSyntax) > "$tmpdir/build.log" 2>&1
require_file "$project/.holbuild/packages/hol/obj/src/string/stringSyntax.ui"

repl_log=$tmpdir/repl.log
(
  printf 'val _ = (ATheory.repl_smoke_thm; print "REPL_SMOKE_OK\\n");\n'
) | (cd "$project" && timeout 20 "$HOLBUILD_BIN" repl) > "$repl_log" 2>&1
require_grep "REPL_SMOKE_OK" "$repl_log"

context="$project/.holbuild/holbuild-run-context.sml"
require_file "$context"
require_grep "loadPath :=" "$context"
require_grep "HolbuildRuntime.load \"ATheory\"" "$context"

run_script=$tmpdir/run-smoke.sml
cat > "$run_script" <<'SML'
val _ = load "stringSyntax";
val _ = print "RUN_PACKAGE_LOAD_OK\n";
val _ = (ATheory.repl_smoke_thm; print "RUN_SMOKE_OK\n");
SML
run_log=$tmpdir/run.log
(cd "$project" && "$HOLBUILD_BIN" run "$run_script") > "$run_log" 2>&1
require_grep "RUN_PACKAGE_LOAD_OK" "$run_log"
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
  printf 'load "stringSyntax";\n'
  printf 'val _ = print "MANUAL_REPL_PACKAGE_LOAD_OK\\n";\n'
  printf 'load "ATheory";\n'
  printf 'val _ = (ATheory.repl_smoke_thm; print "MANUAL_REPL_LOAD_OK\\n");\n'
) | (cd "$no_run_loads" && timeout 20 "$HOLBUILD_BIN" repl) > "$manual_repl_log" 2>&1
require_grep "MANUAL_REPL_PACKAGE_LOAD_OK" "$manual_repl_log"
require_grep "MANUAL_REPL_LOAD_OK" "$manual_repl_log"

legacy_obj=$no_run_loads/.holbuild/deps/legacy/obj/src
mkdir -p "$legacy_obj/.hol/objs"
mv "$no_run_loads/.holbuild/obj/src/ATheory.ui" \
   "$no_run_loads/.holbuild/obj/src/ATheory.uo" \
   "$legacy_obj/"
mv "$no_run_loads/.holbuild/obj/src/.hol/objs/ATheory.ui" \
   "$no_run_loads/.holbuild/obj/src/.hol/objs/ATheory.uo" \
   "$legacy_obj/.hol/objs/"

legacy_run_script=$tmpdir/legacy-run.sml
cat > "$legacy_run_script" <<'SML'
val _ = load "ATheory";
val _ = print "LEGACY_LAYOUT_LOAD_OK\n";
SML
legacy_run_log=$tmpdir/legacy-run.log
if ! (cd "$no_run_loads" && "$HOLBUILD_BIN" run "$legacy_run_script") > "$legacy_run_log" 2>&1; then
  cat "$legacy_run_log" >&2
  exit 1
fi
require_grep "LEGACY_LAYOUT_LOAD_OK" "$legacy_run_log"
