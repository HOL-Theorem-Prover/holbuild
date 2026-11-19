#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A failed-prefix resume compiles only the leaf programs an edit changed.  An
# edit that changes its leaf's length moves every later leaf, so those miss
# the leaves the failed run built; they must be built again from the
# programs the failed run compiled, not compiled again.  The HOL child counts
# its compilations in its "holbuild hol-phases" line (holcompiledn).

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
name = "failed-prefix-compiled-leaves"

[build]
members = ["src"]
TOML

# $1 is the first leaf, $2 the fourth.
write_script() {
  cat > "$project/src/AScript.sml" <<SML
Theory A

Theorem moved_leaves:
  T /\\ F
Proof
  $1 >> CONJ_TAC >- ACCEPT_TAC TRUTH >> $2 >>
  (fn g => ALL_TAC g) >> FAIL_TAC "moved leaves failure"
QED
SML
}

child_log=$project/.holbuild/logs/current/failed-prefix-compiled-leaves/ATheory/instrumented-failure.log

expect_failure() {
  local log=$1
  if (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$log" 2>&1; then
    cat "$log" >&2
    echo "expected moved_leaves to fail" >&2
    exit 1
  fi
  require_grep "moved leaves failure" "$log"
}

phase_value() {
  local name=$1
  require_file "$child_log"
  local line
  line=$(grep '^holbuild hol-phases' "$child_log" | tail -n 1)
  if [[ -z "$line" ]]; then
    echo "no holbuild hol-phases line in $child_log" >&2
    exit 1
  fi
  sed -n "s/.* $name=\\([0-9]*\\).*/\\1/p" <<<"$line" | grep . || echo 0
}

expect_phase() {
  local name=$1 expected=$2 what=$3
  local actual
  actual=$(phase_value "$name")
  if [[ "$actual" != "$expected" ]]; then
    echo "$what: expected $name=$expected, got $actual" >&2
    grep '^holbuild hol-phases' "$child_log" >&2 || true
    exit 1
  fi
}

write_script ALL_TAC ALL_TAC
expect_failure "$tmpdir/seed.log"
require_file "$(find "$project/.holbuild/checkpoints" -name 'moved_leaves_failed_prefix.save' -print -quit)"

# Mid-proof resume: the prefix up to the third leaf stands; the fourth
# changes and lengthens, moving the last two.
write_script ALL_TAC "(ALL_TAC : tactic)"
expect_failure "$tmpdir/mid.log"
require_grep "from: failed-prefix checkpoint in moved_leaves" "$tmpdir/mid.log"
# Five leaves succeeded before the failure; the last two are rewound.
expect_phase holrewoundn 2 "mid-proof resume"
expect_phase holcompiledn 1 "mid-proof resume"

# Resume from before the first leaf: the first leaf changes, moving all
# the others.
write_script "I ALL_TAC" "(ALL_TAC : tactic)"
expect_failure "$tmpdir/zero.log"
require_grep "from: failed-prefix checkpoint in moved_leaves" "$tmpdir/zero.log"
expect_phase holrewoundn 5 "zero-step resume"
expect_phase holcompiledn 1 "zero-step resume"
