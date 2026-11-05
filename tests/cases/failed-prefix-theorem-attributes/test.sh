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
name = "failed-prefix-theorem-attributes"

[build]
members = ["src"]
TOML

# foo_simp is [simp] and [local]: a theorem resumed from its failed-prefix
# checkpoint must keep both, so uses_simp proves by simp alone and the theory's
# signature leaves foo_simp out.  Its proof's first step clears the overload
# its statement uses, so the resumed theorem must not parse the statement
# again.
write_source() {
  local tail=$1
  cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

val foo_def = new_definition ("foo_def", \`\`foo = T\`\`);
val _ = overload_on ("hbtrue", \`\`T\`\`);

Theorem foo_simp[simp,local]:
  foo /\\ hbtrue
Proof
  (fn g => (Parse.temp_clear_overloads_on "hbtrue"; ALL_TAC g)) >>
  conj_tac >- simp [foo_def] >>
  $tail
QED

Theorem uses_simp:
  foo
Proof
  simp []
QED

val _ = export_theory();
SML
}

write_source 'FAIL_TAC "seed failed-prefix checkpoint"'
seed_log=$tmpdir/seed.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$seed_log" 2>&1; then
  echo "expected initial proof failure" >&2
  exit 1
fi
require_grep "seed failed-prefix checkpoint" "$seed_log"

write_source 'ACCEPT_TAC TRUTH'
resume_log=$tmpdir/resume.log
if ! (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$resume_log" 2>&1; then
  echo "build after failed-prefix resume failed; foo_simp may have lost [simp]" >&2
  cat "$resume_log" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in foo_simp" "$resume_log"
if grep -q "discarding" "$resume_log"; then
  echo "the failed-prefix resume fell back to a fresh run" >&2
  cat "$resume_log" >&2
  exit 1
fi
require_grep "ATheory built" "$resume_log"

sig=$project/.holbuild/obj/src/ATheory.sig
require_file "$sig"
require_grep "uses_simp" "$sig"
if grep -q "foo_simp" "$sig"; then
  echo "failed-prefix resume exported the [local] theorem foo_simp" >&2
  cat "$sig" >&2
  exit 1
fi
