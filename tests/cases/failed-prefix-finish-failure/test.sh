#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A proof whose steps all run but leave goals saves a failed-prefix checkpoint,
# in a Theorem and in a Resume block alike, so a step appended to it resumes
# after the last one that ran.

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
counter=$tmpdir/step-count.txt
mkdir -p "$project/src"
touch "$counter"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "failed-prefix-finish-failure"

[build]
members = ["src"]
TOML

# counted_tac counts the times it runs, so a resume shows which steps it reran.
# finish is the file's first theorem: its checkpoint's parent is the
# dependency heap.
cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
fun counted_tac g =
  let val out = TextIO.openAppend "$counter"
  in TextIO.output(out, "x"); TextIO.closeOut out; ALL_TAC g end;
Theorem finish:
  1 = 1 /\\ 2 = 2
Proof
  counted_tac >> CONJ_TAC >> counted_tac
QED
Theorem partial:
  T /\\ (3 = 3 /\\ 4 = 4)
Proof
  CONJ_TAC >- ACCEPT_TAC TRUTH >- suspend "right"
QED
Resume partial[right]:
  counted_tac >> CONJ_TAC >> counted_tac
QED
Finalise partial
val _ = export_theory();
SML

edit() {
  python3 - "$project/src/AScript.sml" "$1" "$2" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
assert text.count(sys.argv[2]) == 1, sys.argv[2]
path.write_text(text.replace(sys.argv[2], sys.argv[3]))
PY
}

expect_failure() {
  local log=$1 message=$2
  if (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$log" 2>&1; then
    cat "$log" >&2
    echo "expected the build to fail with $message" >&2
    exit 1
  fi
  require_grep "$message" "$log"
}

expect_count() {
  local expected=$1 what=$2
  local actual
  actual=$(wc -c < "$counter" | tr -d ' ')
  [[ "$actual" = "$expected" ]] || { echo "$what: counted_tac ran $actual times in all, expected $expected" >&2; exit 1; }
}

finish_end=$'counted_tac\nQED\nTheorem partial'
resume_end=$'counted_tac\nQED\nFinalise'

# finish ends with both conjuncts open.
expect_failure "$tmpdir/finish-seed.log" "finish"
require_grep "^ *2 = 2" "$tmpdir/finish-seed.log"
expect_count 3 "finish seed"
require_file "$(find "$project/.holbuild/checkpoints" -name 'finish_failed_prefix.save.ok' -print -quit)"

# A failing step appended to it resumes after the last step and fails on the
# goal that step left.
edit "$finish_end" $'counted_tac >> FAIL_TAC "after finish"\nQED\nTheorem partial'
expect_failure "$tmpdir/finish-step.log" "after finish"
require_grep "from: failed-prefix checkpoint in finish" "$tmpdir/finish-step.log"
require_grep "^ *1 = 1" "$tmpdir/finish-step.log"
expect_count 3 "finish appended step"

# The Resume block then ends with both of its conjuncts open.
edit 'FAIL_TAC "after finish"' 'REWRITE_TAC []'
expect_failure "$tmpdir/resume-seed.log" "partial"
require_grep "from: failed-prefix checkpoint in finish" "$tmpdir/resume-seed.log"
require_grep "^ *4 = 4" "$tmpdir/resume-seed.log"
expect_count 6 "Resume seed"
require_file "$(find "$project/.holbuild/checkpoints" -name 'partial_right_*failed_prefix.save.ok' -print -quit)"

edit "$resume_end" $'counted_tac >> FAIL_TAC "after resume"\nQED\nFinalise'
expect_failure "$tmpdir/resume-step.log" "after resume"
require_grep "from: failed-prefix checkpoint in partial_right_" "$tmpdir/resume-step.log"
require_grep "^ *3 = 3" "$tmpdir/resume-step.log"
expect_count 6 "Resume appended step"

edit 'FAIL_TAC "after resume"' 'REWRITE_TAC []'
if ! (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$tmpdir/fixed.log" 2>&1; then
  cat "$tmpdir/fixed.log" >&2
  echo "the proofs failed to finish from their checkpoints" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in partial_right_" "$tmpdir/fixed.log"
require_grep "ATheory built" "$tmpdir/fixed.log"
expect_count 6 "fixed"
