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
export HOLBUILD_CACHE="$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project"
cat > "$project/holproject.toml" <<TOML
[project]
name = "root_hol_probe"

[build]
members = []

[dependencies.HOLDIR]
TOML

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" context) > "$tmpdir/context.log"
require_grep "dependency: HOLDIR \[local=$HOLDIR, resolved-manifest=builtin:HOLDIR\]" "$tmpdir/context.log"
(cd "$project" && HOLDIR="$HOLDIR" "$HOLBUILD_BIN" context) > "$tmpdir/context-env.log"
require_grep "dependency: HOLDIR \[local=$HOLDIR, resolved-manifest=builtin:HOLDIR\]" "$tmpdir/context-env.log"

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --dry-run) > "$tmpdir/dry.log"

require_grep "KernelTypes (sml, package HOLDIR)" "$tmpdir/dry.log"
require_grep "boolTheory (theory, package HOLDIR)" "$tmpdir/dry.log"
require_grep "listTheory (theory, package HOLDIR)" "$tmpdir/dry.log"

if grep -Eq 'source: HOLDIR:.*/selftest\.sml|source: HOLDIR:.*/examples/|source: HOLDIR:.*/tests/|source: HOLDIR:.*/theory_tests/|source: HOLDIR:src/emit/MLton/|source: HOLDIR:src/portableML/(mlton|mosml)/|source: HOLDIR:src/simp/src/mosml/|source: HOLDIR:src/tracing/no/|source: HOLDIR:src/num/reduce/conv-old/' "$tmpdir/dry.log"; then
  echo "root-HOL sketch included an excluded source" >&2
  exit 1
fi

# This case intentionally tests only the built-in root-HOL manifest sketch:
# HOLDIR resolution, source discovery, and excluded subtrees.  Do not execute-build
# a HOLDIR target here.  Upstream HOL bootstrap directories such as src/0 and
# src/1 carry Holmake phase semantics (--poly_not_hol / hol.state0) that the
# synthetic builtin:HOLDIR manifest does not currently model.
