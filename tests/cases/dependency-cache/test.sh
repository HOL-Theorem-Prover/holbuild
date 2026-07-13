#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
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
name = "dependency-cache"

[build]
members = ["src"]
roots = ["src/AScript.sml"]
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
cat > "$project/src/UnusedScript.sml" <<'SML'
Theory Unused

Theorem unused:
  T
Proof
  simp[]
QED

val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" build --dry-run ATheory) > "$tmpdir/first.log"
require_grep "external theories: .*arithmeticTheory" "$tmpdir/first.log"
cache_file="$project/.holbuild/obj/src/AScript.uo.deps"
unused_cache_file="$project/.holbuild/obj/src/UnusedScript.uo.deps"
require_file "$cache_file"
if [[ -e "$unused_cache_file" ]]; then
  echo "dependency analysis cached an unreachable source" >&2
  exit 1
fi
require_grep "mention=arithmeticTheory" "$cache_file"

cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors arithmetic list

Theorem a:
  1 + 1 = 2
Proof
  simp[]
QED

val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" build --dry-run ATheory) > "$tmpdir/second.log"
require_grep "external theories: .*arithmeticTheory" "$tmpdir/second.log"
require_grep "external theories: .*listTheory" "$tmpdir/second.log"
require_grep "mention=listTheory" "$cache_file"

printf 'not a valid dependency cache\n' > "$cache_file"
(cd "$project" && "$HOLBUILD_BIN" build --dry-run ATheory) > "$tmpdir/corrupt.log"
require_grep "external theories: .*listTheory" "$tmpdir/corrupt.log"
require_grep "holbuild-dependencies-cache-v2" "$cache_file"
