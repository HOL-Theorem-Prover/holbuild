#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src" "$project/shims"
cat > "$project/shims/hol-subtree.toml" <<'TOML'
[holbuild]
schema = 2
minimum_version = "0.10.0"

[project]
name = "hol_subtree"

[build]
members = ["src/bool"]
TOML
{
  write_schema2_prelude
  cat <<'TOML'
[project]
name = "probe"

[build]
members = []

[dependencies.hol_subtree]
from = "hol"
path = "."
manifest = "shims/hol-subtree.toml"
TOML
} > "$project/holproject.toml"

(cd "$project" && "$HOLBUILD_BIN" context) > "$tmpdir/context.log"
require_grep "dependency: hol_subtree \[from=hol, path=., manifest=shims/hol-subtree.toml" "$tmpdir/context.log"
require_grep "package: hol_subtree" "$tmpdir/context.log"

bad=$tmpdir/bad
mkdir -p "$bad"
{
  write_schema2_prelude
  cat <<'TOML'
[project]
name = "bad_holdir"

[dependencies.HOLDIR]
from = "hol"
path = "."
manifest = "missing.toml"
TOML
} > "$bad/holproject.toml"
if (cd "$bad" && "$HOLBUILD_BIN" context) > "$tmpdir/bad.log" 2>&1; then
  echo "missing from-hol shim manifest unexpectedly accepted" >&2
  exit 1
fi
require_grep "dependency HOLDIR manifest not found:" "$tmpdir/bad.log"
