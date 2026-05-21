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
TOML

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" context) > "$tmpdir/context.log"
if grep -q 'dependency: HOLDIR' "$tmpdir/context.log"; then
  echo "context should not report an explicit HOLDIR dependency" >&2
  exit 1
fi
(cd "$project" && HOLDIR="$HOLDIR" "$HOLBUILD_BIN" build --dry-run) > "$tmpdir/dry.log"

bad=$tmpdir/bad
mkdir -p "$bad"
cat > "$bad/holproject.toml" <<TOML
[project]
name = "bad_holdir_dep"

[dependencies.HOLDIR]
TOML
if (cd "$bad" && "$HOLBUILD_BIN" --holdir "$HOLDIR" context) >"$tmpdir/bad.out" 2>"$tmpdir/bad.err"; then
  echo "explicit dependencies.HOLDIR unexpectedly succeeded" >&2
  exit 1
fi
require_grep 'do not declare \[dependencies.HOLDIR\]' "$tmpdir/bad.err"
