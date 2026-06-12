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
name = "direct-preload"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A

Theorem a_thm:
  T
Proof
  simp[]
QED

val _ = export_theory();
SML
cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors A

Theorem b_thm:
  T
Proof
  simp[]
QED

val _ = export_theory();
SML
cat > "$project/src/CScript.sml" <<'SML'
Theory C
Ancestors B

Theorem c_thm:
  T
Proof
  simp[]
QED

val _ = export_theory();
SML
cat > "$project/src/DScript.sml" <<'SML'
Theory D
Ancestors C

val _ = raise Fail "preserve D stage for preload inspection";

val _ = export_theory();
SML

if (cd "$project" && "$HOLBUILD_BIN" build --skip-checkpoints DTheory) > "$tmpdir/build.log" 2>&1; then
  echo "DTheory build unexpectedly succeeded" >&2
  exit 1
fi

preload=$(find "$project/.holbuild/stage" -name holbuild-preload.sml -print | head -n 1)
if [[ -z "$preload" ]]; then
  echo "missing failed DTheory preload" >&2
  cat "$tmpdir/build.log" >&2
  exit 1
fi

require_grep 'load ".*/CTheory";' "$preload"
if grep -Eq 'load ".*/(ATheory|BTheory)";' "$preload"; then
  echo "preload flattened transitive project dependencies" >&2
  cat "$preload" >&2
  exit 1
fi
