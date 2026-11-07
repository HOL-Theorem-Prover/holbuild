#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"

# Build a disposable source copy so no compile-time fallback can mask missing data.
mkdir -p "$tmpdir/source"
cp -R "$HOLBUILD_ROOT/sml" "$HOLBUILD_ROOT/vendor" "$tmpdir/source/"
cp "$HOLBUILD_ROOT/Makefile" "$HOLBUILD_ROOT/LICENSE" "$tmpdir/source/"
make -C "$tmpdir/source" install PREFIX="$tmpdir/installed" > "$tmpdir/install.log" 2>&1
make -C "$tmpdir/source" install PREFIX="$tmpdir/custom-prefix" \
  BINDIR="$tmpdir/custom-bin" DATADIR="$tmpdir/custom-data" > "$tmpdir/custom-install.log" 2>&1
rm -rf "$tmpdir/source"
mv "$tmpdir/installed" "$tmpdir/relocated"
mkdir -p "$tmpdir/project" "$tmpdir/links"
ln -s "$tmpdir/relocated/bin/holbuild" "$tmpdir/links/holbuild"
{
  write_schema2_prelude
  printf '\n[project]\nname = "installed-runtime"\n'
} > "$tmpdir/project/holproject.toml"
cat > "$tmpdir/project/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem installed_true:
  T
Proof
  ACCEPT_TAC TRUTH
QED
val _ = export_theory ();
SML

HOLBUILD_BIN="$tmpdir/links/holbuild"
(cd "$tmpdir/project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/build.log" 2>&1
require_file "$tmpdir/project/.holbuild/obj/ATheory.dat"
(cd "$tmpdir/project" && PATH="$tmpdir/relocated/bin:$PATH" holbuild build --force=full ATheory) > "$tmpdir/path-build.log" 2>&1
require_file "$tmpdir/relocated/share/holbuild/LICENSE"
require_file "$tmpdir/relocated/share/holbuild/copyrights/smlnj.txt"
require_file "$tmpdir/relocated/share/holbuild/sml/analyser/analyser_main.sml"
require_file "$tmpdir/relocated/share/holbuild/sml/diagnostic_limits.sml"

use_case_cache "$tmpdir/custom-cache"
(cd "$tmpdir/project" && "$tmpdir/custom-bin/holbuild" build --force=full ATheory) > "$tmpdir/custom-build.log" 2>&1
require_file "$tmpdir/custom-data/sml/holbuild_runtime.sml"

make -C "$HOLBUILD_ROOT" uninstall PREFIX="$tmpdir/relocated" > "$tmpdir/uninstall.log" 2>&1
require_no_file "$tmpdir/relocated/bin/holbuild"
require_no_file "$tmpdir/relocated/share/holbuild/sml/holbuild_runtime.sml"
make -C "$HOLBUILD_ROOT" uninstall BINDIR="$tmpdir/custom-bin" DATADIR="$tmpdir/custom-data" > "$tmpdir/custom-uninstall.log" 2>&1
require_no_file "$tmpdir/custom-bin/holbuild"
require_no_file "$tmpdir/custom-data/sml/holbuild_runtime.sml"
