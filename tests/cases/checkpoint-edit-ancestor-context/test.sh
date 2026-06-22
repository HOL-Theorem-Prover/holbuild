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

write_project() {
  local project=$1
  local name=$2
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "$name"

[build]
members = ["src"]
TOML

  cat > "$project/src/BaseScript.sml" <<'SML'
Theory Base

Definition magic_def:
  magic = T
End
SML

  cat > "$project/src/AuxScript.sml" <<'SML'
Theory Aux
Ancestors Base

Theorem magic_simp[simp]:
  magic
Proof
  simp[magic_def]
QED
SML
}

project=$tmpdir/failed-prefix-project
write_project "$project" "checkpoint-edit-ancestor-context"

write_main_without_aux() {
  cat > "$project/src/MainScript.sml" <<'SML'
Theory Main
Ancestors Base

Theorem uses_imported_simp:
  magic
Proof
  ALL_TAC >> simp[] >> FAIL_TAC "missing Aux simp"
QED
SML
}

write_main_with_aux() {
  cat > "$project/src/MainScript.sml" <<'SML'
Theory Main
Ancestors Base Aux

Theorem uses_imported_simp:
  magic
Proof
  ALL_TAC >> simp[] >> FAIL_TAC "missing Aux simp"
QED
SML
}

write_main_with_aux_and_noop_edit() {
  cat > "$project/src/MainScript.sml" <<'SML'
Theory Main
Ancestors Base Aux

Theorem uses_imported_simp:
  magic
Proof
  ALL_TAC >> ALL_TAC >> simp[] >> FAIL_TAC "missing Aux simp"
QED
SML
}

# Failed-prefix variant: Base is loaded but Aux's exported [simp] theorem is
# not.  ALL_TAC and simp[] are a replayable prefix; without Aux, simp[] leaves
# the goal unsolved and the following FAIL_TAC creates a failed-prefix
# checkpoint.  With Aux present, simp[] solves the goal and the FAIL_TAC
# continuation is not run.
write_main_without_aux
missing_first_log=$tmpdir/missing-first.log
if (cd "$project" && "$HOLBUILD_BIN" build MainTheory) > "$missing_first_log" 2>&1; then
  echo "expected Main proof to fail before AuxTheory is imported" >&2
  exit 1
fi
require_grep "missing Aux simp" "$missing_first_log"
require_file "$(find "$project/.holbuild/checkpoints" -name '*uses_imported_simp_failed_prefix.save' -print -quit)"

# Adding the ancestor that exports the simp rule should change Main's dependency
# context and make the unchanged proof succeed.  A stale failed-prefix checkpoint
# from the old dependency context must not be used.
write_main_with_aux
with_aux_log=$tmpdir/with-aux.log
(cd "$project" && "$HOLBUILD_BIN" build MainTheory) > "$with_aux_log" 2>&1
require_grep "MainTheory built" "$with_aux_log"
require_file "$project/.holbuild/obj/src/MainTheory.dat"
if grep -q "from: failed-prefix checkpoint in uses_imported_simp" "$with_aux_log"; then
  echo "Main resumed from failed-prefix checkpoint created without AuxTheory" >&2
  exit 1
fi

# With the requisite ancestor still present, an ordinary proof edit should also
# succeed.  This guards that the previous success was not a one-off full rebuild
# artifact and that proof replay remains valid in the new dependency context.
write_main_with_aux_and_noop_edit
with_aux_noop_log=$tmpdir/with-aux-noop.log
(cd "$project" && "$HOLBUILD_BIN" build MainTheory) > "$with_aux_noop_log" 2>&1
require_grep "MainTheory built" "$with_aux_noop_log"

# Removing the ancestor again should return to the original failing context.  In
# particular, holbuild must not reuse theorem/failed-prefix state from the build
# where AuxTheory's simp rule was available.
write_main_without_aux
removed_aux_log=$tmpdir/removed-aux.log
if (cd "$project" && "$HOLBUILD_BIN" build MainTheory) > "$removed_aux_log" 2>&1; then
  echo "Main proof succeeded after AuxTheory import was removed" >&2
  exit 1
fi
require_grep "missing Aux simp" "$removed_aux_log"
if grep -q "MainTheory built" "$removed_aux_log"; then
  echo "Main was built despite missing AuxTheory simp ancestor" >&2
  exit 1
fi

# Finish-failure variant: without AuxTheory, simp[] runs but leaves the goal
# unsolved, so the proof fails at QED rather than at a later tactic and may not
# create a failed-prefix checkpoint.  Changing only the ancestor import should
# still make the same proof succeed, and removing the ancestor should make it
# fail again.
finish_project=$tmpdir/finish-project
write_project "$finish_project" "checkpoint-edit-ancestor-context-finish"

write_finish_main_without_aux() {
  cat > "$finish_project/src/MainScript.sml" <<'SML'
Theory Main
Ancestors Base

Theorem uses_imported_simp_finish:
  magic
Proof
  ALL_TAC >> simp[]
QED
SML
}

write_finish_main_with_aux() {
  cat > "$finish_project/src/MainScript.sml" <<'SML'
Theory Main
Ancestors Base Aux

Theorem uses_imported_simp_finish:
  magic
Proof
  ALL_TAC >> simp[]
QED
SML
}

write_finish_main_with_aux_and_noop_edit() {
  cat > "$finish_project/src/MainScript.sml" <<'SML'
Theory Main
Ancestors Base Aux

Theorem uses_imported_simp_finish:
  magic
Proof
  ALL_TAC >> ALL_TAC >> simp[]
QED
SML
}

write_finish_main_without_aux
finish_missing_log=$tmpdir/finish-missing.log
if (cd "$finish_project" && "$HOLBUILD_BIN" build MainTheory) > "$finish_missing_log" 2>&1; then
  echo "expected finish-failure Main proof to fail before AuxTheory is imported" >&2
  exit 1
fi
require_grep "no theorem proved" "$finish_missing_log"

write_finish_main_with_aux
finish_with_aux_log=$tmpdir/finish-with-aux.log
(cd "$finish_project" && "$HOLBUILD_BIN" build MainTheory) > "$finish_with_aux_log" 2>&1
require_grep "MainTheory built" "$finish_with_aux_log"
require_file "$finish_project/.holbuild/obj/src/MainTheory.dat"

write_finish_main_with_aux_and_noop_edit
finish_with_aux_noop_log=$tmpdir/finish-with-aux-noop.log
(cd "$finish_project" && "$HOLBUILD_BIN" build MainTheory) > "$finish_with_aux_noop_log" 2>&1
require_grep "MainTheory built" "$finish_with_aux_noop_log"

write_finish_main_without_aux
finish_removed_aux_log=$tmpdir/finish-removed-aux.log
if (cd "$finish_project" && "$HOLBUILD_BIN" build MainTheory) > "$finish_removed_aux_log" 2>&1; then
  echo "finish-failure Main proof succeeded after AuxTheory import was removed" >&2
  exit 1
fi
require_grep "no theorem proved" "$finish_removed_aux_log"
if grep -q "MainTheory built" "$finish_removed_aux_log"; then
  echo "finish-failure Main was built despite missing AuxTheory simp ancestor" >&2
  exit 1
fi

# Ancestor-content variant: Main's source and ancestor list are unchanged while
# Aux's exported simp facts change.  Checkpoint/replay validity must follow the
# rebuilt ancestor context, not just edits to MainScript.sml.
content_project=$tmpdir/content-project
write_project "$content_project" "checkpoint-edit-ancestor-content"

write_content_aux_without_simp() {
  cat > "$content_project/src/AuxScript.sml" <<'SML'
Theory Aux
Ancestors Base

Theorem aux_placeholder:
  T
Proof
  simp[]
QED
SML
}

write_content_aux_with_simp() {
  cat > "$content_project/src/AuxScript.sml" <<'SML'
Theory Aux
Ancestors Base

Theorem magic_simp[simp]:
  magic
Proof
  simp[magic_def]
QED
SML
}

write_content_main() {
  cat > "$content_project/src/MainScript.sml" <<'SML'
Theory Main
Ancestors Base Aux

Theorem uses_imported_simp_from_changed_aux:
  magic
Proof
  ALL_TAC >> simp[]
QED
SML
}

write_content_main_noop_edit() {
  cat > "$content_project/src/MainScript.sml" <<'SML'
Theory Main
Ancestors Base Aux

Theorem uses_imported_simp_from_changed_aux:
  magic
Proof
  ALL_TAC >> ALL_TAC >> simp[]
QED
SML
}

write_content_aux_without_simp
write_content_main
content_missing_log=$tmpdir/content-missing.log
if (cd "$content_project" && "$HOLBUILD_BIN" build MainTheory) > "$content_missing_log" 2>&1; then
  echo "expected Main proof to fail before AuxTheory exports magic_simp" >&2
  exit 1
fi
require_grep "no theorem proved" "$content_missing_log"

write_content_aux_with_simp
content_with_simp_log=$tmpdir/content-with-simp.log
(cd "$content_project" && "$HOLBUILD_BIN" build MainTheory) > "$content_with_simp_log" 2>&1
require_grep "MainTheory built" "$content_with_simp_log"
require_file "$content_project/.holbuild/obj/src/MainTheory.dat"

write_content_main_noop_edit
content_with_simp_noop_log=$tmpdir/content-with-simp-noop.log
(cd "$content_project" && "$HOLBUILD_BIN" build MainTheory) > "$content_with_simp_noop_log" 2>&1
require_grep "MainTheory built" "$content_with_simp_noop_log"

write_content_aux_without_simp
content_removed_simp_log=$tmpdir/content-removed-simp.log
if (cd "$content_project" && "$HOLBUILD_BIN" build MainTheory) > "$content_removed_simp_log" 2>&1; then
  echo "Main proof succeeded after AuxTheory stopped exporting magic_simp" >&2
  exit 1
fi
require_grep "no theorem proved" "$content_removed_simp_log"
if grep -q "MainTheory built" "$content_removed_simp_log"; then
  echo "Main was built despite AuxTheory no longer exporting required simp theorem" >&2
  exit 1
fi
