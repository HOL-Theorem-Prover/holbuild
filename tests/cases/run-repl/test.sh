#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

require_no_run_contexts() {
  local dir=$1
  if find "$dir" -maxdepth 1 -type f -name 'holbuild-run-context-*.sml' -print -quit | grep -q .; then
    echo "unexpected run context remains in $dir" >&2
    exit 1
  fi
}

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
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
loads = ["ATheory", "ProjectLib"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val repl_smoke_thm = store_thm("repl_smoke_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
cat > "$project/src/ProjectLib.sig" <<'SML'
signature PROJECT_LIB = sig
  val marker : bool
end
SML
cat > "$project/src/ProjectLib.sml" <<'SML'
structure ProjectLib :> PROJECT_LIB = struct
  open HolKernel boolLib stringSyntax
  val marker = true
end
SML

require_no_file "$project/.holbuild/packages/hol/obj/src/string/stringSyntax.ui"
require_no_file "$project/.holbuild/obj/src/ATheory.uo"
require_no_file "$project/.holbuild/obj/src/ProjectLib.uo"

repl_log=$tmpdir/repl.log
(
  printf 'val _ = (ATheory.repl_smoke_thm; print "REPL_SMOKE_OK\\n");\n'
  printf 'val _ = (ProjectLib.marker; print "REPL_PACKAGE_DEP_OK\\n");\n'
) | (cd "$project" && timeout 60 "$HOLBUILD_BIN" repl) > "$repl_log" 2>&1
require_grep "REPL_SMOKE_OK" "$repl_log"
require_grep "REPL_PACKAGE_DEP_OK" "$repl_log"
require_file "$project/.holbuild/obj/src/ATheory.uo"
require_file "$project/.holbuild/obj/src/ProjectLib.uo"
require_file "$project/.holbuild/packages/hol/obj/src/string/stringSyntax.ui"

require_no_run_contexts "$project/.holbuild"
require_no_file "$project/.holbuild/holbuild-run-context.sml"

run_script=$tmpdir/run-smoke.sml
cat > "$run_script" <<'SML'
val _ = load "stringSyntax";
val _ = print "RUN_PACKAGE_LOAD_OK\n";
val _ = (ATheory.repl_smoke_thm; print "RUN_SMOKE_OK\n");
val _ = (ProjectLib.marker; print "RUN_CONFIGURED_PACKAGE_DEP_OK\n");
SML
run_log=$tmpdir/run.log
(cd "$project" && "$HOLBUILD_BIN" run "$run_script") > "$run_log" 2>&1
require_grep "RUN_PACKAGE_LOAD_OK" "$run_log"
require_grep "RUN_SMOKE_OK" "$run_log"
require_grep "RUN_CONFIGURED_PACKAGE_DEP_OK" "$run_log"
require_grep "holbuild finished in" "$run_log"
if grep -q ' built$' "$run_log"; then
  echo "incremental run rebuilt an up-to-date configured load or dependency" >&2
  exit 1
fi
require_no_run_contexts "$project/.holbuild"

no_run_loads=$tmpdir/no-run-loads
cp -R "$project" "$no_run_loads"
python3 - "$no_run_loads/holproject.toml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace('\n[run]\nloads = ["ATheory", "ProjectLib"]\n', '\n')
path.write_text(text)
PY

concurrent_script=$tmpdir/concurrent-run.sml
cat > "$concurrent_script" <<'SML'
val _ = OS.Process.sleep (Time.fromSeconds 3);
val _ = print "CONCURRENT_RUN_OK\n";
SML
concurrent1_log=$tmpdir/concurrent1.log
concurrent2_log=$tmpdir/concurrent2.log
(cd "$no_run_loads" && "$HOLBUILD_BIN" run "$concurrent_script") > "$concurrent1_log" 2>&1 &
concurrent1_pid=$!
(cd "$no_run_loads" && "$HOLBUILD_BIN" run "$concurrent_script") > "$concurrent2_log" 2>&1 &
concurrent2_pid=$!
found_two_contexts=
for _ in $(seq 1 50); do
  context_count=$(find "$no_run_loads/.holbuild" -maxdepth 1 -type f -name 'holbuild-run-context-*.sml' | wc -l)
  if [[ $context_count -ge 2 ]]; then
    found_two_contexts=1
    break
  fi
  sleep 0.1
done
wait "$concurrent1_pid"
wait "$concurrent2_pid"
if [[ -z "$found_two_contexts" ]]; then
  echo "concurrent run invocations did not retain distinct contexts" >&2
  exit 1
fi
require_grep "CONCURRENT_RUN_OK" "$concurrent1_log"
require_grep "CONCURRENT_RUN_OK" "$concurrent2_log"
require_no_run_contexts "$no_run_loads/.holbuild"

manual_repl_log=$tmpdir/manual-repl.log
(
  printf 'load "stringSyntax";\n'
  printf 'val _ = print "MANUAL_REPL_PACKAGE_LOAD_OK\\n";\n'
  printf 'load "ATheory";\n'
  printf 'val _ = (ATheory.repl_smoke_thm; print "MANUAL_REPL_LOAD_OK\\n");\n'
) | (cd "$no_run_loads" && timeout 20 "$HOLBUILD_BIN" repl) > "$manual_repl_log" 2>&1
require_grep "MANUAL_REPL_PACKAGE_LOAD_OK" "$manual_repl_log"
require_grep "MANUAL_REPL_LOAD_OK" "$manual_repl_log"

unknown_load=$tmpdir/unknown-load
cp -R "$no_run_loads" "$unknown_load"
cat >> "$unknown_load/holproject.toml" <<'TOML'

[run]
loads = ["MissingRunTarget"]
TOML
unknown_load_log=$tmpdir/unknown-load.log
if (cd "$unknown_load" && "$HOLBUILD_BIN" repl </dev/null) > "$unknown_load_log" 2>&1; then
  echo "repl accepted an unknown configured load target" >&2
  exit 1
fi
require_grep "unknown build target: MissingRunTarget" "$unknown_load_log"

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
