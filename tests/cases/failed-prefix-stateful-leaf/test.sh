#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A failed-prefix resume applies the leaves the failed run constructed, so it
# fails where a fresh run fails.  `REWRITE_RULE [Once th]` allocates its use
# counter when it is constructed, so one closure applied to two goals rewrites
# only the first; plain HOL fails on the second goal.  The body holds a `by`,
# so it runs goal by goal and the failed prefix holds the first goal's steps.  A resume that
# constructed the leaf again would give the second goal a fresh counter and
# pass.

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
name = "failed-prefix-stateful-leaf"

[build]
members = ["src"]
TOML

cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Definition both_def:
  both a b <=> a /\ b
End

Theorem shared_once:
  both a b ==> a /\ a
Proof
  strip_tac >> CONJ_TAC >> (
    `a` by (qpat_assum `both a b`
              (mp_tac o CONJUNCT1 o REWRITE_RULE [Once both_def]) >>
            disch_then ACCEPT_TAC) >>
    first_assum ACCEPT_TAC)
QED

val _ = export_theory();
SML

expect_failure() {
  local log=$1
  if (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$log" 2>&1; then
    cat "$log" >&2
    echo "expected the build to fail on the second goal" >&2
    exit 1
  fi
  require_grep "fragment: qpat_assum" "$log"
  require_grep "failed tactic input goals: 1" "$log"
}

expect_failure "$tmpdir/fresh.log"
require_file "$(find "$project/.holbuild/checkpoints" -name 'shared_once_failed_prefix.save' -print -quit)"

expect_failure "$tmpdir/resume.log"
require_grep "from: failed-prefix checkpoint in shared_once" "$tmpdir/resume.log"
