#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

# check builds its theory, then [run].loads, under the same process argv.
# Each prebuild needs its own plan even when record comparison is disabled.
for reader in data hol; do
for mode in on check; do
  project=$tmpdir/$reader-$mode
  flags=()
  [[ $reader != hol ]] || flags=(--with-fingerprints)
  mkdir -p "$project/src"
  {
    write_schema2_prelude
    cat <<'TOML'
[project]
name = "check-run-loads"

[build]
members = ["src"]

[run]
loads = ["Probe"]
TOML
  } > "$project/holproject.toml"
  cat > "$project/src/CleanScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Clean";
val _ = save_thm ("clean_thm", TRUTH);
val _ = export_theory();
SML
  cat > "$project/src/Probe.sml" <<'SML'
structure Probe = struct
  val _ = print "independent run load: original\n"
end
SML

  for step in cold warm edited; do
    if [[ $step == edited ]]; then
      sed -i 's/original/edited/' "$project/src/Probe.sml"
    fi
    log=$tmpdir/$reader-$mode-$step.log
    if ! (cd "$project" && HOLBUILD_PLAN_RECORD=$mode \
        "$HOLBUILD_BIN" --verbose check "${flags[@]}" CleanTheory) > "$log" 2>&1; then
      cat "$log" >&2
      exit 1
    fi
    require_grep '^CleanTheory: clean (1 theorem)$' "$log"
    expected=original
    [[ $step != edited ]] || expected=edited
    if [[ $reader == hol ]]; then
      require_grep "^independent run load: $expected$" "$log"
    elif grep -q '^independent run load:' "$log"; then
      echo 'plain check executed a run load' >&2
      cat "$log" >&2
      exit 1
    fi
    if [[ $step != warm ]]; then
      require_grep 'Probe \(built\|restored from cache\)' "$log"
    elif [[ $step == warm ]]; then
      if [[ $(grep -c '^holbuild: plan: from record ' "$log") -ne 2 ]]; then
        echo "both prebuilds must restore their own plan records" >&2
        cat "$log" >&2
        exit 1
      fi
    fi
  done
done
done
