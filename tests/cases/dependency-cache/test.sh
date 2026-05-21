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
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<'TOML'
[project]
name = "dependency-cache"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors arithmetic

Theorem a:
  1 + 1 = 2
Proof
  simp[]
QED

val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --dry-run ATheory) > "$tmpdir/first.log"
require_grep "external theories: .*arithmeticTheory" "$tmpdir/first.log"
cache_file="$project/.holbuild/obj/src/AScript.uo.deps"
require_file "$cache_file"
require_grep "mention=arithmeticTheory" "$cache_file"

cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors arithmetic string

Theorem a:
  1 + 1 = 2
Proof
  simp[]
QED

val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --dry-run ATheory) > "$tmpdir/second.log"
require_grep "external theories: .*arithmeticTheory" "$tmpdir/second.log"
require_grep "external theories: .*stringTheory" "$tmpdir/second.log"
require_grep "mention=stringTheory" "$cache_file"

printf 'not a valid dependency cache\n' > "$cache_file"
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --dry-run ATheory) > "$tmpdir/corrupt.log"
require_grep "external theories: .*stringTheory" "$tmpdir/corrupt.log"
require_grep "holbuild-dependencies-cache-v2" "$cache_file"
