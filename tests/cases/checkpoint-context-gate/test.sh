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

# The suite saves every context; this case checks the default gate.
unset HOLBUILD_CHECKPOINT_EVERY_CONTEXT

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "gate"

[build]
members = ["src"]
TOML
write_script() {
  cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;

val _ = new_theory "A";

Theorem quick_one:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem quick_two:
  T
Proof
  ACCEPT_TAC TRUTH
QED

val _ = OS.Process.sleep (Time.fromReal 2.5);

Theorem after_pause:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem quick_three:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem last_one:
  T
Proof
  $1
QED

val _ = $2;

val _ = export_theory ();
SML
}

context_save() {
  find "$project/.holbuild/checkpoints" -name "*$1_context.save" -print -quit
}

# A context is saved only once 2 s have passed since the last context save,
# so the quick theorems after the start and after after_pause save none.
write_script 'ACCEPT_TAC TRUTH' 'raise Fail "expected failure"'
failed_log=$tmpdir/failed.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$failed_log" 2>&1; then
  echo "expected the failing declaration to fail the build" >&2
  exit 1
fi
require_file "$(context_save after_pause)"
for name in quick_one quick_two quick_three last_one; do
  if [[ -n "$(context_save "$name")" ]]; then
    echo "saved the context after $name, under 2 s after the last save" >&2
    exit 1
  fi
done

# The fixed build resumes from the latest context that was saved.
write_script 'ACCEPT_TAC TRUTH' '()'
fixed_log=$tmpdir/fixed.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$fixed_log" 2>&1
require_grep "from: theorem-context checkpoint after after_pause" "$fixed_log"
require_grep "ATheory built" "$fixed_log"

# A failed proof resumes from its failed-prefix checkpoint, whose parent is the
# last context saved before it.
write_script 'FAIL_TAC "expected failure"' '()'
prefix_failed_log=$tmpdir/prefix-failed.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$prefix_failed_log" 2>&1; then
  echo "expected the failing proof to fail the build" >&2
  exit 1
fi
write_script 'cheat' '()'
prefix_fixed_log=$tmpdir/prefix-fixed.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$prefix_fixed_log" 2>&1
require_grep "from: failed-prefix checkpoint in last_one" "$prefix_fixed_log"
require_grep "ATheory built" "$prefix_fixed_log"
