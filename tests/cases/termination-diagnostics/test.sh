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
name = "termination-diagnostics"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Definition test_def:
  test n = if n = 0 then 0 else test (n - 1)
Termination
  FAIL_TAC "expected termination failure"
End

val _ = export_theory();
SML

failure_log=$tmpdir/failure.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$failure_log" 2>&1; then
  echo "expected termination proof failure" >&2
  exit 1
fi

require_grep "termination: test_def (line " "$failure_log"
require_grep "proof: line " "$failure_log"
require_grep "source: .*AScript.sml:7:3-42" "$failure_log"
require_grep "termination condition goal:" "$failure_log"
require_grep "WF" "$failure_log"
require_grep "expected termination failure" "$failure_log"
require_grep "instrumented log:" "$failure_log"

success_project=$tmpdir/success-project
mkdir -p "$success_project/src"
cat > "$success_project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "termination-success"

[build]
members = ["src"]
TOML
cat > "$success_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Definition simple_def:
  simple = 1
End

Definition test_def:
  test n = if n = 0 then 0 else test (n - 1)
Termination
  WF_REL_TAC `measure I` >> simp[]
End

val _ = export_theory();
SML

success_log=$tmpdir/success.log
(cd "$success_project" && "$HOLBUILD_BIN" build ATheory) > "$success_log" 2>&1
require_grep "ATheory built" "$success_log"
require_file "$success_project/.holbuild/obj/src/AScript.uo"
require_file "$success_project/.holbuild/obj/src/ATheory.uo"
require_file "$success_project/.holbuild/obj/src/ATheory.dat"
if find "$success_project/.holbuild/checkpoints" -path '*.decls/*/proof_ir_v3*/*/simple_def_context.save' -print -quit | grep -q .; then
  echo "unexpected definition-context checkpoint for non-termination definition" >&2
  exit 1
fi
if ! find "$success_project/.holbuild/checkpoints" -path '*.decls/*/proof_ir_v3*/*/test_def_context.save' -print -quit | grep -q .; then
  echo "missing definition-context checkpoint for successful termination definition" >&2
  exit 1
fi

resume_project=$tmpdir/resume-project
mkdir -p "$resume_project/src"
cp "$project/holproject.toml" "$resume_project/holproject.toml"
cat > "$resume_project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Definition first_def:
  first n = if n = 0 then 0 else first (n - 1)
Termination
  WF_REL_TAC `measure I` >> simp[]
End

Definition second_def:
  second n = if n = 0 then 0 else second (n - 1)
Termination
  FAIL_TAC "expected second termination failure"
End

val _ = export_theory();
SML

resume_first_log=$tmpdir/resume-first.log
if (cd "$resume_project" && "$HOLBUILD_BIN" build ATheory) > "$resume_first_log" 2>&1; then
  echo "expected second termination proof failure" >&2
  exit 1
fi
require_grep "termination: second_def (line " "$resume_first_log"
require_grep "expected second termination failure" "$resume_first_log"
require_file "$(find "$resume_project/.holbuild/checkpoints" -path '*.decls/*/proof_ir_v3*/*/first_def_context.save' -print -quit)"
rm -rf "$resume_project/.holbuild/checkpoints/termination-diagnostics/src/AScript.sml.decls"

resume_missing_decl_log=$tmpdir/resume-missing-decl-dir.log
if (cd "$resume_project" && "$HOLBUILD_BIN" build ATheory) > "$resume_missing_decl_log" 2>&1; then
  echo "expected second termination proof failure after removing definition checkpoint dirs" >&2
  exit 1
fi
require_grep "from: deps-loaded checkpoint" "$resume_missing_decl_log"
require_grep "termination: second_def (line " "$resume_missing_decl_log"
if grep -q "No such file or directory" "$resume_missing_decl_log"; then
  echo "definition checkpoint save failed to recreate parent dirs" >&2
  exit 1
fi
require_file "$(find "$resume_project/.holbuild/checkpoints" -path '*.decls/*/proof_ir_v3*/*/first_def_context.save' -print -quit)"

resume_second_log=$tmpdir/resume-second.log
if (cd "$resume_project" && "$HOLBUILD_BIN" build ATheory) > "$resume_second_log" 2>&1; then
  echo "expected repeated second termination proof failure" >&2
  exit 1
fi
require_grep "from: definition-context checkpoint after first_def" "$resume_second_log"
require_grep "termination: second_def (line " "$resume_second_log"
