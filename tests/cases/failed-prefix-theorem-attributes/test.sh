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
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "failed-prefix-theorem-attributes"

[build]
members = ["src"]
TOML

# c_simp's [simp] attribute is what lets uses_simp's simp[] prove c, and
# its [local] attribute keeps it out of the exported theory.
write_script() {
  local tail=$1
  cat > "$project/src/AScript.sml" <<SML
Theory A

Definition c_def:
  c = T
End

Theorem c_simp[local,simp]:
  c
Proof
  ALL_TAC >> $tail
QED

Theorem uses_simp:
  c
Proof
  simp[]
QED
SML
}

# Seed a failed-prefix checkpoint inside c_simp.
write_script 'FAIL_TAC "seeded failure"'
seed_log=$tmpdir/seed.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$seed_log" 2>&1; then
  echo "expected seeded proof to fail" >&2
  exit 1
fi
require_grep "seeded failure" "$seed_log"
require_file "$(find "$project/.holbuild/checkpoints" -name 'c_simp_failed_prefix.save' -print -quit)"

# Repair the failing step.  The resumed build saves c_simp from the
# checkpoint; it must keep the theorem's attributes, as a clean build does.
write_script 'REWRITE_TAC[c_def]'
resume_log=$tmpdir/resume.log
if ! (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$resume_log" 2>&1; then
  cat "$resume_log" >&2
  echo "resumed build lost c_simp's [simp] attribute" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in c_simp" "$resume_log"
require_grep "ATheory built" "$resume_log"

sig=$project/.holbuild/obj/src/ATheory.sig
require_file "$sig"
if grep -q "c_simp" "$sig"; then
  echo "resumed build exported the [local] theorem c_simp" >&2
  exit 1
fi
