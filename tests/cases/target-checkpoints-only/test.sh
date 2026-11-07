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
name = "targets"

[build]
members = ["src"]
TOML
for theory in A B; do
  parent=$([ "$theory" = B ] && echo "open ATheory;" || true)
  cat > "$project/src/${theory}Script.sml" <<SML
open HolKernel Parse boolLib bossLib;
$parent

val _ = new_theory "$theory";

Theorem ${theory}_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML
done

checkpoints=$project/.holbuild/checkpoints/targets/src
has_save() { find "$checkpoints/$1" -name "$2" -print -quit 2>/dev/null | grep -q .; }

# A is a dependency, not a requested target: it keeps its deps_loaded
# checkpoint but saves none per theorem.  B, the target, saves both.
log=$tmpdir/build.log
(cd "$project" && "$HOLBUILD_BIN" build --target-checkpoints-only BTheory) > "$log" 2>&1 \
  || { cat "$log" >&2; exit 1; }
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_file "$project/.holbuild/obj/src/BTheory.dat"
has_save AScript.sml.deps deps_loaded.save || { echo "dependency lost its deps_loaded checkpoint" >&2; exit 1; }
has_save BScript.sml.deps deps_loaded.save || { echo "target lost its deps_loaded checkpoint" >&2; exit 1; }
if has_save AScript.sml.theorems '*_context.save'; then
  echo "--target-checkpoints-only saved theorem checkpoints in a dependency" >&2
  exit 1
fi
has_save BScript.sml.theorems '*_context.save' || { echo "target saved no theorem checkpoints" >&2; exit 1; }

# The flag changes no input key: a build without it finds both up to date.
up_log=$tmpdir/up.log
(cd "$project" && "$HOLBUILD_BIN" --verbose build BTheory) > "$up_log"
require_grep "ATheory is up to date" "$up_log"
require_grep "BTheory is up to date" "$up_log"

# Nor any output: rebuilt from source without it, both are byte-identical.
outputs() { (cd "$project/.holbuild/obj/src" && sha256sum ATheory.sig ATheory.sml ATheory.dat BTheory.sig BTheory.sml BTheory.dat); }
flagged=$(outputs)
(cd "$project" && "$HOLBUILD_BIN" build --force --no-cache BTheory) > "$tmpdir/plain.log" 2>&1 \
  || { cat "$tmpdir/plain.log" >&2; exit 1; }
has_save AScript.sml.theorems '*_context.save' || { echo "rebuild without the flag saved no dependency checkpoints" >&2; exit 1; }
if [ "$flagged" != "$(outputs)" ]; then
  echo "--target-checkpoints-only changed theory outputs" >&2
  exit 1
fi

# With no targets and no roots, every root-package theory is a requested target.
rm -rf "$project/.holbuild"
(cd "$project" && "$HOLBUILD_BIN" build --target-checkpoints-only --no-cache) > "$tmpdir/all.log" 2>&1 \
  || { cat "$tmpdir/all.log" >&2; exit 1; }
for theory in A B; do
  has_save "${theory}Script.sml.theorems" '*_context.save' \
    || { echo "default build skipped theorem checkpoints in $theory" >&2; exit 1; }
done
