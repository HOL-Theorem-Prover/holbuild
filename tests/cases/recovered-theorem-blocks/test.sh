#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A theorem block HOL's source parser reports an error in, and recovers from,
# is not instrumented: the script runs it as written and fails on that error.
#
# A failed-prefix checkpoint matches a theorem by the source before it and its
# header.  An edit that fixes the proof but deletes its QED keeps both, and
# replaying the checkpoint as `Theorem target = ...;` closed the block, so the
# build hid the parse error and exported the theory.

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)

[project]
name = "recovered-theorem-blocks"

[build]
members = ["src"]
TOML

# Holdep reads the unclosed block differently, so the script names the modules
# the closed one mentions itself: both then have the same dependencies, and the
# same failed-prefix checkpoint key.
write_source() {
  cat > "$project/src/AScript.sml" <<SML
Theory A
Ancestors list

local open BasicProvers Context DB_dtype Q TypeBase boolTheory in end;

Theorem target:
  T /\\ T
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >> $1
$2
SML
}

write_source 'FAIL_TAC "first failure"' QED
seed_log=$tmpdir/seed.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$seed_log" 2>&1; then
  cat "$seed_log" >&2
  echo "expected the seed build to fail" >&2
  exit 1
fi
require_grep 'first failure' "$seed_log"
if [[ -z "$(find "$project/.holbuild/checkpoints" -name 'target_failed_prefix.save' -print -quit)" ]]; then
  echo "expected a failed-prefix checkpoint from the seed build" >&2
  find "$project/.holbuild/checkpoints" >&2
  exit 1
fi

write_source 'ACCEPT_TAC TRUTH' ''
log=$tmpdir/missing-qed.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$log" 2>&1; then
  cat "$log" >&2
  echo "built a theory whose theorem has no QED" >&2
  exit 1
fi
require_grep "expected 'QED'" "$log"
# Same dependencies as the seed, or the checkpoint was never in reach.
require_grep 'from: deps-loaded checkpoint' "$log"
if grep -q 'from: failed-prefix checkpoint' "$log"; then
  cat "$log" >&2
  echo "resumed the unclosed theorem from its failed-prefix checkpoint" >&2
  exit 1
fi
if [[ -n "$(find "$project" -name 'ATheory.dat' -print -quit)" ]]; then
  find "$project" -name 'ATheory.dat' >&2
  echo "exported the theory of an unclosed theorem" >&2
  exit 1
fi

# A block with no tactic was instrumented as `proof_ir_tactic (fn () => ())`,
# so HOL reported ML type errors in the generated code instead.
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors list

Theorem target:
  T
Proof
QED
SML
empty_log=$tmpdir/empty-tactic.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$empty_log" 2>&1; then
  cat "$empty_log" >&2
  echo "built a theory whose theorem has no tactic" >&2
  exit 1
fi
require_grep "AScript.sml:7:1-4: parse error: expected identifier" "$empty_log"
if grep -q 'proof_ir_tactic' "$empty_log"; then
  cat "$empty_log" >&2
  echo "instrumented a theorem with no tactic" >&2
  exit 1
fi
