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

# --checkpoint-seconds sets the least time between context saves: 0 saves
# every context, and a long one saves none.  Each build starts without
# checkpoints, so it runs every theorem rather than resuming.
rm -rf "$project/.holbuild/checkpoints"
write_script 'ACCEPT_TAC TRUTH' 'raise Fail "expected failure"'
every_log=$tmpdir/every.log
if (cd "$project" && "$HOLBUILD_BIN" build --checkpoint-seconds 0 ATheory) > "$every_log" 2>&1; then
  echo "expected the failing declaration to fail the build" >&2
  exit 1
fi
for name in quick_one quick_two after_pause quick_three last_one; do
  require_file "$(context_save "$name")"
done
rm -rf "$project/.holbuild/checkpoints"
none_log=$tmpdir/none.log
if (cd "$project" && "$HOLBUILD_BIN" build --checkpoint-seconds=1000 ATheory) > "$none_log" 2>&1; then
  echo "expected the failing declaration to fail the build" >&2
  exit 1
fi
for name in quick_one quick_two after_pause quick_three last_one; do
  if [[ -n "$(context_save "$name")" ]]; then
    echo "saved the context after $name with --checkpoint-seconds=1000" >&2
    exit 1
  fi
done

# The option is in no cache key: a theory cached under the default is
# restored under another value.
write_script 'ACCEPT_TAC TRUTH' '()'
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/default.log" 2>&1
rm -rf "$project/.holbuild"
(cd "$project" && "$HOLBUILD_BIN" build --checkpoint-seconds 10 ATheory) > "$tmpdir/ten.log" 2>&1
require_grep "ATheory restored from cache" "$tmpdir/ten.log"

if (cd "$project" && "$HOLBUILD_BIN" build --checkpoint-seconds -1 ATheory) > "$tmpdir/negative.log" 2>&1; then
  echo "accepted a negative --checkpoint-seconds" >&2
  exit 1
fi
require_grep "checkpoint-seconds must be a non-negative number" "$tmpdir/negative.log"

# Definition contexts (after a termination proof) follow the option too.
cat > "$project/src/DScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;

val _ = new_theory "D";

Definition d_one_def:
  d_one n = if n = 0 then 0 else d_one (n - 1)
Termination
  WF_REL_TAC `measure I` >> simp[]
End

Definition d_two_def:
  d_two n = if n = 0 then 0 else d_two (n - 1)
Termination
  WF_REL_TAC `measure I` >> simp[]
End

val _ = raise Fail "expected failure";

val _ = export_theory ();
SML
definition_saves() {
  find "$project/.holbuild/checkpoints" -path '*DScript.sml.decls/*' -name 'd_*_def_context.save' | wc -l
}
rm -rf "$project/.holbuild/checkpoints"
if (cd "$project" && "$HOLBUILD_BIN" build --checkpoint-seconds 0 DTheory) > "$tmpdir/d-every.log" 2>&1; then
  echo "expected D to fail" >&2; exit 1
fi
[[ "$(definition_saves)" == 2 ]] || {
  echo "--checkpoint-seconds 0 saved $(definition_saves) definition contexts, wanted 2" >&2; exit 1; }
rm -rf "$project/.holbuild/checkpoints"
if (cd "$project" && "$HOLBUILD_BIN" build DTheory) > "$tmpdir/d-default.log" 2>&1; then
  echo "expected D to fail" >&2; exit 1
fi
[[ "$(definition_saves)" == 0 ]] || {
  echo "a default build saved $(definition_saves) definition contexts under 2 s" >&2; exit 1; }
