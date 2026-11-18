#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A resume compiles holbuild's proof runtime after the script's own opens, so
# the runtime must not depend on top-level Basis names a project library can
# shadow.  appLib binds app to a term function, as a library a script opens
# can.

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
name = "failed-prefix-shadowed-basis"

[build]
members = ["src"]
TOML

cat > "$project/src/appLib.sml" <<'SML'
structure appLib =
struct
  fun app f args : Term.term = Term.list_mk_comb (f, args)
end
SML

cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool
Libs appLib

Theorem before_shadow:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem shadowed:
  (1 = 1 /\ 2 = 2) /\ 3 = 3
Proof
  CONJ_TAC
  >- (CONJ_TAC
      >- ACCEPT_TAC (REFL ``1``)
      >- FAIL_TAC "seed failure")
  >- FAIL_TAC "advance failure"
QED
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

build() { (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$1" 2>&1; }

expect_failure() {
  local log=$1 message=$2
  if build "$log"; then
    cat "$log" >&2
    echo "expected the build to fail with $message" >&2
    exit 1
  fi
  require_grep "$message" "$log"
}

# The first build compiles the runtime before the script's opens.
expect_failure "$tmpdir/seed.log" "seed failure"

# Editing the statement resumes from the earlier theorem's context, with app
# in scope; the resumed proof fails again and saves a failed-prefix checkpoint.
edit '/\ 3 = 3' '/\ 3 = 3 /\ T'
expect_failure "$tmpdir/context.log" "seed failure"
require_grep "from: theorem-context checkpoint after before_shadow" "$tmpdir/context.log"
checkpoint=$(find "$project/.holbuild/checkpoints" -name 'shadowed_failed_prefix.save' -print -quit)
require_file "$checkpoint.ok"
seed_steps=$(sed -n 's/^step_count=//p' "$checkpoint.meta")

# A resume that gets past that checkpoint advances it.
edit 'FAIL_TAC "seed failure"' 'ACCEPT_TAC (REFL ``2``)'
expect_failure "$tmpdir/advance.log" "advance failure"
require_grep "restoring proof-ir prefix with $seed_steps successful leaf steps" "$tmpdir/advance.log"
advanced_steps=$(sed -n 's/^step_count=//p' "$checkpoint.meta")
(( advanced_steps > seed_steps )) || { echo "checkpoint stayed at $advanced_steps steps after a resume got past it" >&2; exit 1; }

edit 'FAIL_TAC "advance failure"' 'ACCEPT_TAC (CONJ (REFL ``3``) TRUTH)'
if ! build "$tmpdir/fixed.log"; then
  cat "$tmpdir/fixed.log" >&2
  echo "the proof failed to finish from the advanced checkpoint" >&2
  exit 1
fi
require_grep "ATheory built" "$tmpdir/fixed.log"
