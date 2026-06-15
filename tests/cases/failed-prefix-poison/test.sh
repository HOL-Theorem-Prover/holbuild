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
name = "failed-prefix-poison"

[build]
members = ["src"]
TOML

write_bad_source() {
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem poison:
  T /\ T
Proof
  CONJ_TAC >> FAIL_TAC "make failed-prefix checkpoint" >> ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML
}

write_good_source() {
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem poison:
  T /\ T
Proof
  CONJ_TAC >> ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML
}

bad_log=$tmpdir/bad.log
write_bad_source
if (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$bad_log" 2>&1; then
  echo "expected initial proof failure" >&2
  exit 1
fi
require_grep "make failed-prefix checkpoint" "$bad_log"

fp=$(find "$project/.holbuild/checkpoints" -path '*/.failed/poison_failed_prefix.save' -print -quit)
if [[ -z "$fp" || ! -e "$fp.ok" ]]; then
  echo "expected failed-prefix checkpoint" >&2
  find "$project/.holbuild/checkpoints" -print >&2 || true
  exit 1
fi

# Deliberately poison the failed-prefix metadata: claim far more retained
# proof-IR history than the checkpoint actually contains. A robust build
# should discard/ignore a failed failed-prefix resume and retry from a safe
# checkpoint/fresh preload.
printf 'step_count=999\nprefix_end=0\n' > "$fp.meta"

write_good_source
retry_log=$tmpdir/retry.log
if ! (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$retry_log" 2>&1; then
  echo "build failed after poisoned failed-prefix checkpoint; expected automatic recovery" >&2
  cat "$retry_log" >&2
  exit 1
fi
require_file "$project/.holbuild/obj/src/ATheory.dat"
