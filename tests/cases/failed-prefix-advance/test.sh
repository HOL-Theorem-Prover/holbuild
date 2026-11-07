#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A resume that gets past its failed-prefix checkpoint and fails later moves the
# checkpoint forward; one that fails at the same step, or can't write the new
# checkpoint, leaves the old one as it was.

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
name = "failed-prefix-advance"

[build]
members = ["src"]
TOML

# counted_tac counts the times it runs, so a resume shows which steps it reran.
# The seed fails inside the inner CONJ_TAC branch, so the first resume has to
# restore the goals the other branches still hold.  The theorem before makes
# the checkpoint's parent a theorem context rather than the dependency heap.
cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
fun counted_tac g =
  let val out = TextIO.openAppend "$counter"
  in TextIO.output(out, "x"); TextIO.closeOut out; ALL_TAC g end;
Theorem before_advance:
  T
Proof
  ACCEPT_TAC TRUTH
QED
Theorem advance:
  (1 = 1 /\\ 2 = 2) /\\ 3 = 3
Proof
  CONJ_TAC
  >- (CONJ_TAC
      >- (counted_tac >> ACCEPT_TAC (REFL \`\`1\`\`))
      >- (counted_tac >> FAIL_TAC "seed failure"))
  >- (counted_tac >> SUFFIX)
QED
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

count() { wc -c < "$counter" | tr -d ' '; }

expect_failure() {
  local log=$1 message=$2
  if (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$log" 2>&1; then
    cat "$log" >&2
    echo "expected the build to fail with $message" >&2
    exit 1
  fi
  require_grep "$message" "$log"
  if grep -q "discarding" "$log"; then
    cat "$log" >&2
    echo "a resume discarded a checkpoint" >&2
    exit 1
  fi
}

expect_count() {
  local expected=$1 what=$2
  local actual
  actual=$(count)
  [[ "$actual" = "$expected" ]] || { echo "$what: counted_tac ran $actual times in all, expected $expected" >&2; exit 1; }
}

step_count() { sed -n 's/^step_count=//p' "$checkpoint.meta"; }

checkpoint_sums() { sha256sum "$checkpoint" "$checkpoint.ok" "$checkpoint.meta" "$checkpoint.prefix"; }

require_no_temporary_files() {
  if find "$project/.holbuild/checkpoints" -name '*.new*' | grep -q .; then
    find "$project/.holbuild/checkpoints" -name '*.new*' >&2
    echo "$1: temporary checkpoint files were left behind" >&2
    exit 1
  fi
}

edit SUFFIX 'FAIL_TAC "unreached"'
expect_failure "$tmpdir/seed.log" "seed failure"
expect_count 2 "seed"
checkpoint=$(find "$project/.holbuild/checkpoints" -name 'advance_failed_prefix.save' -print -quit)
require_file "$checkpoint"
require_file "$checkpoint.ok"
seed_steps=$(step_count)
context=$(find "$project/.holbuild/checkpoints" -name 'before_advance_context.save' -print -quit)
require_file "$context"
context_sum=$(sha256sum "$context")

# The resume gets past the saved step into the last branch: the checkpoint
# moves forward to there.
edit 'FAIL_TAC "seed failure"' 'ACCEPT_TAC (REFL ``2``)'
edit 'FAIL_TAC "unreached"' 'FAIL_TAC "first advance"'
expect_failure "$tmpdir/first.log" "first advance"
require_grep "from: failed-prefix checkpoint in advance" "$tmpdir/first.log"
require_grep "restoring proof-ir prefix with $seed_steps successful leaf steps" "$tmpdir/first.log"
expect_count 3 "first advance"
first_steps=$(step_count)
(( first_steps > seed_steps )) || { echo "checkpoint stayed at $first_steps steps after a resume got past it" >&2; exit 1; }
require_no_temporary_files "first advance"

# It moves forward again from the moved checkpoint: the earlier steps, the
# ones in the CONJ_TAC branch included, aren't rerun, and the failure is on
# the goal the last branch has.
edit 'FAIL_TAC "first advance"' 'counted_tac >> FAIL_TAC "second advance"'
expect_failure "$tmpdir/second.log" "second advance"
require_grep "restoring proof-ir prefix with $first_steps successful leaf steps" "$tmpdir/second.log"
require_grep "^ *3 = 3" "$tmpdir/second.log"
expect_count 4 "second advance"
second_steps=$(step_count)
(( second_steps > first_steps )) || { echo "checkpoint stayed at $second_steps steps after a second resume got past it" >&2; exit 1; }
require_no_temporary_files "second advance"

# A resume that fails at the step it restored leaves the checkpoint alone.
sums=$(checkpoint_sums)
expect_failure "$tmpdir/same.log" "second advance"
require_grep "restoring proof-ir prefix with $second_steps successful leaf steps" "$tmpdir/same.log"
expect_count 4 "same-step resume"
[[ "$(checkpoint_sums)" = "$sums" ]] || { echo "a resume that failed at the restored step rewrote the checkpoint" >&2; exit 1; }

# The resume gets further but can't write one of the new checkpoint's files
# (the .ok, which the heap save handles, or the .meta, written after it): the
# old checkpoint stays in place, whole.
failed_write() {
  local blocker="$checkpoint.new.$1.tmp"
  edit "$2" "(fn g => (OS.FileSys.mkDir \"$blocker\"; ALL_TAC g)) >> FAIL_TAC \"failed $1 write\""
  if (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$tmpdir/failed-$1.log" 2>&1; then
    echo "expected the failed $1 write build to fail" >&2
    exit 1
  fi
  require_grep "failed $1 write" "$tmpdir/failed-$1.log"
  require_grep "dropping checkpoint kind=failed_prefix path=$checkpoint.new" \
    "$project/.holbuild/logs/current/failed-prefix-advance/ATheory/build.log"
  rmdir "$blocker"
  [[ "$(checkpoint_sums)" = "$sums" ]] || { echo "a failed $1 write lost the old checkpoint" >&2; exit 1; }
  require_no_temporary_files "failed $1 write"
}
failed_write ok 'FAIL_TAC "second advance"'
failed_write meta "(fn g => (OS.FileSys.mkDir \"$checkpoint.new.ok.tmp\"; ALL_TAC g)) >> FAIL_TAC \"failed ok write\""

# The checkpoint that survived resumes, and the proof finishes from it.
edit "(fn g => (OS.FileSys.mkDir \"$checkpoint.new.meta.tmp\"; ALL_TAC g)) >> FAIL_TAC \"failed meta write\"" \
  'ACCEPT_TAC (REFL ``3``)'
if ! (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$tmpdir/fixed.log" 2>&1; then
  cat "$tmpdir/fixed.log" >&2
  echo "the proof failed to finish from the surviving checkpoint" >&2
  exit 1
fi
require_grep "restoring proof-ir prefix with $second_steps successful leaf steps" "$tmpdir/fixed.log"
require_grep "ATheory built" "$tmpdir/fixed.log"
expect_count 4 "fixed"

# Every new checkpoint was a sibling of the one it replaced: their parent,
# the earlier theorem's context, is the file it was.
[[ "$(sha256sum "$context")" = "$context_sum" ]] || { echo "the checkpoints' parent heap changed" >&2; exit 1; }
