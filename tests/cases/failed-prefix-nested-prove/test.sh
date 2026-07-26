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
name = "failed-prefix-nested-prove"

[build]
members = ["src"]
TOML

write_failing_source() {
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem pairarg_after_failed_prefix:
  !p : bool # bool. (\(x,y). x = x) p
Proof
  rpt gen_tac >>
  FAIL_TAC "seed failed-prefix checkpoint"
QED

val _ = export_theory();
SML
}

write_fixed_source() {
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem pairarg_after_failed_prefix:
  !p : bool # bool. (\(x,y). x = x) p
Proof
  rpt gen_tac >>
  pairarg_tac >>
  simp[]
QED

val _ = export_theory();
SML
}

# First save a failed-prefix heap after the successful `rpt gen_tac` leaf.
write_failing_source
seed_log=$tmpdir/seed.log
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$seed_log" 2>&1; then
  echo "expected initial proof failure" >&2
  exit 1
fi
require_grep "seed failed-prefix checkpoint" "$seed_log"

failed_prefix=$(find "$project/.holbuild/checkpoints" \
  -path '*/.failed/pairarg_after_failed_prefix_failed_prefix.save' \
  -print -quit)
if [[ -z "$failed_prefix" || ! -e "$failed_prefix.ok" ]]; then
  echo "expected a failed-prefix checkpoint after the successful proof leaf" >&2
  find "$project/.holbuild/checkpoints" -print >&2 || true
  exit 1
fi

# Resume the unchanged prefix and execute pairarg_tac in the suffix.  pairarg_tac
# calls prove internally to establish `?x y. p = (x,y)`.  That nested proof must
# bypass proof-IR instrumentation while the outer theorem is being resumed.
write_fixed_source
resume_log=$tmpdir/resume.log
if ! (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$resume_log" 2>&1; then
  echo "pairarg_tac failed after failed-prefix resume; nested prove may have been treated as an outer theorem" >&2
  cat "$resume_log" >&2
  exit 1
fi

require_grep "from: failed-prefix checkpoint in pairarg_after_failed_prefix" "$resume_log"
require_grep "ATheory built" "$resume_log"
require_file "$project/.holbuild/obj/src/ATheory.dat"
