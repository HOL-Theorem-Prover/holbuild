#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A failed-prefix resume must see each leaf as a fresh run would at the
# restored point.  `REWRITE_RULE [Once th]` allocates its use counter when it
# is constructed, so one closure applied twice rewrites only the first time.
#
# shared_once applies such a closure to two goals; plain HOL fails on the
# second.  The body holds a `by`, so it runs goal by goal and the failed
# prefix holds the first goal's steps.  A resume that constructed the leaf
# again would give the second goal a fresh counter and pass.
#
# retried's leaf fails the first time it is applied and passes after.  A
# resume that kept the leaf the failed step changed would pass.
#
# rewound applies the closure once, after the step an edit then changes, so
# the resume rewinds past that application.  A resume that kept the spent
# closure would fail where a fresh run of the edited proof passes.

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

cat > "$project/src/CScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "C";

Theorem retried:
  T
Proof
  ALL_TAC >>
  (let val seen = ref false
   in fn g => if !seen then ACCEPT_TAC TRUTH g else (seen := true; NO_TAC g) end)
QED

val _ = export_theory();
SML

for run in fresh resume; do
  if (cd "$project" && "$HOLBUILD_BIN" build CTheory) >"$tmpdir/c-$run.log" 2>&1; then
    cat "$tmpdir/c-$run.log" >&2
    echo "expected retried to fail on the $run build" >&2
    exit 1
  fi
  require_grep "fragment: let val seen" "$tmpdir/c-$run.log"
done
require_grep "from: failed-prefix checkpoint in retried" "$tmpdir/c-resume.log"

write_b() {
  cat > "$project/src/BScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "B";

Definition duo_def:
  duo a b <=> a /\ b
End

Theorem rewound:
  duo a b ==> a /\ a
Proof
  strip_tac >> $1 >>
  qpat_assum \`duo a b\` (mp_tac o CONJUNCT1 o REWRITE_RULE [Once duo_def]) >>
  disch_then ACCEPT_TAC
QED

val _ = export_theory();
SML
}

# ALL_TAC leaves the goal a /\ a, which the final step can't close; simp []
# (the same length, so later leaves keep their keys) reduces it to a.
write_b "ALL_TAC"
if (cd "$project" && "$HOLBUILD_BIN" build BTheory) >"$tmpdir/b-fresh.log" 2>&1; then
  cat "$tmpdir/b-fresh.log" >&2
  echo "expected rewound to fail before the edit" >&2
  exit 1
fi
require_grep "fragment: disch_then ACCEPT_TAC" "$tmpdir/b-fresh.log"
require_file "$(find "$project/.holbuild/checkpoints" -name 'rewound_failed_prefix.save' -print -quit)"

write_b "simp []"
if ! (cd "$project" && "$HOLBUILD_BIN" build BTheory) >"$tmpdir/b-resume.log" 2>&1; then
  cat "$tmpdir/b-resume.log" >&2
  echo "expected the edited proof to pass on resume, as it does fresh" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in rewound" "$tmpdir/b-resume.log"
