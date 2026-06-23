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
name = "default-build-command"

[build]
members = ["src"]
roots = ["src/AScript.sml"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, rw[]);
val _ = export_theory();
SML

bare_log=$tmpdir/bare.log
(cd "$project" && "$HOLBUILD_BIN") > "$bare_log" 2>&1
require_file "$project/.holbuild/obj/src/ATheory.dat"

rm -rf "$project/.holbuild"
target_log=$tmpdir/target.log
(cd "$project" && "$HOLBUILD_BIN" ATheory) > "$target_log" 2>&1
require_file "$project/.holbuild/obj/src/ATheory.dat"

rm -rf "$project/.holbuild"
dry_run_log=$tmpdir/dry-run.log
(cd "$project" && "$HOLBUILD_BIN" --dry-run ATheory) > "$dry_run_log" 2>&1
if [[ -e "$project/.holbuild/obj/src/ATheory.dat" ]]; then
  echo "default build --dry-run unexpectedly produced ATheory.dat" >&2
  exit 1
fi
require_grep "ATheory" "$dry_run_log"

context_log=$tmpdir/context.log
(cd "$project" && "$HOLBUILD_BIN" context) > "$context_log" 2>&1
require_grep "default-build-command" "$context_log"

help_log=$tmpdir/unknown-help.log
if (cd "$project" && "$HOLBUILD_BIN" unknown --help) > "$help_log" 2>&1; then
  echo "unknown command with --help unexpectedly succeeded" >&2
  exit 1
fi
require_grep "unknown command: unknown" "$help_log"

top_help_log=$tmpdir/top-help.log
(cd "$tmpdir" && "$HOLBUILD_BIN" --help) > "$top_help_log" 2>&1
require_grep "\[build\] \[TARGET ...\]" "$top_help_log"

build_help_log=$tmpdir/build-help.log
(cd "$tmpdir" && "$HOLBUILD_BIN" build --help) > "$build_help_log" 2>&1
require_grep "holbuild \[GLOBAL OPTIONS\] \[build\] \[OPTIONS\] \[TARGET ...\]" "$build_help_log"
require_grep "force\[=theory|project|full\]" "$build_help_log"
