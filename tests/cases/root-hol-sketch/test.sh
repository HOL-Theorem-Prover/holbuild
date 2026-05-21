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

if grep -Eq 'source: HOLDIR:.*/selftest\.sml|source: HOLDIR:.*/examples/|source: HOLDIR:.*/tests/|source: HOLDIR:.*/theory_tests/|source: HOLDIR:src/emit/MLton/|source: HOLDIR:src/portableML/(mlton|mosml)/|source: HOLDIR:src/tracing/no/|source: HOLDIR:src/num/reduce/conv-old/' "$tmpdir/dry.log"; then
  echo "root-HOL sketch included an excluded source" >&2
  exit 1
fi

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build KernelTypes) > "$tmpdir/kerneltypes.log"
require_file "$project/.holbuild/deps/HOLDIR/obj/src/0/KernelTypes.uo"
require_file "$project/.holbuild/deps/HOLDIR/obj/src/0/KernelTypes.ui"
if find "$project/.holbuild/checkpoints/_base" -name '*.save' -o -name '*.save.ok' 2>/dev/null | grep -q .; then
  echo "root-HOL SML probe created an unexpected project base checkpoint" >&2
  exit 1
fi
