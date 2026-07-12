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
name = "clean-target"

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

build_log=$tmpdir/build.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$build_log" 2>&1
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_file "$project/.holbuild/dep/clean-target/src/AScript.sml.key"
if ! find "$project/.holbuild/checkpoints" -path '*AScript.sml.theorems*' -print -quit | grep -q .; then
  echo "expected theorem checkpoints before clean" >&2
  exit 1
fi

clean_log=$tmpdir/clean.log
(cd "$project" && "$HOLBUILD_BIN" clean ATheory) > "$clean_log" 2>&1
require_grep "cleaned ATheory" "$clean_log"
require_grep "build --no-cache TARGET" "$clean_log"
if [[ -e "$project/.holbuild/obj/src/ATheory.dat" ]]; then
  echo "clean left theory dat artifact" >&2
  exit 1
fi
if [[ -e "$project/.holbuild/dep/clean-target/src/AScript.sml.key" ]]; then
  echo "clean left dependency metadata" >&2
  exit 1
fi
if find "$project/.holbuild/checkpoints" -path '*AScript.sml*' -print -quit 2>/dev/null | grep -q .; then
  echo "clean left target checkpoints" >&2
  find "$project/.holbuild/checkpoints" -path '*AScript.sml*' -print >&2
  exit 1
fi

rebuild_log=$tmpdir/rebuild.log
(cd "$project" && "$HOLBUILD_BIN" build --no-cache ATheory) > "$rebuild_log" 2>&1
require_grep "ATheory built" "$rebuild_log"
require_file "$project/.holbuild/obj/src/ATheory.dat"

if (cd "$project" && "$HOLBUILD_BIN" clean) > "$tmpdir/clean-empty.log" 2>&1; then
  echo "expected clean with no targets to fail" >&2
  exit 1
fi
require_grep "usage: holbuild clean THEORY" "$tmpdir/clean-empty.log"
