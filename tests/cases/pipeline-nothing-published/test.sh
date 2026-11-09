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
unset HOLBUILD_REMOTE_CACHE_URL

# C proves against B's outline and finishes, then B fails, deferring its
# proof and again without: nothing of C's may be published anywhere, since
# only a commit after B's gate may.
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
name = "unpublished"

[build]
members = ["src"]
TOML
pause='(fn g => (OS.Process.sleep (Time.fromSeconds 2); ALL_TAC g))'
cat > "$project/src/BScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "B";
Theorem b_thm:
  T
Proof
  $pause >> $pause >> $pause >> $pause >> (fn _ => raise Fail "slow failure")
QED
val _ = export_theory();
SML
cat > "$project/src/CScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib BTheory;
val _ = new_theory "C";
Theorem c_thm:
  T
Proof
  ACCEPT_TAC BTheory.b_thm
QED
val _ = export_theory();
SML

log=$tmpdir/build.log
if (cd "$project" && HOLBUILD_CACHE_TRACE=1 "$HOLBUILD_BIN" -j4 build --skip-checkpoints --skip-proof-steps CTheory) > "$log" 2>&1; then
  echo "build of a failing theory succeeded" >&2
  cat "$log" >&2
  exit 1
fi
require_grep "pipeline: attempt done: CTheory" "$log"
require_grep "pipeline: attempt failed: BTheory" "$log"
require_grep "slow failure" "$log"
# The planner's dependency analysis of the script (CScript.uo.deps) is no
# build output.
leaks=$(find "$project/.holbuild" "$tmpdir/cache" -path "$tmpdir/cache/hol-toolchains" -prune -o \
          \( -name '*CTheory*' -o \( -name '*CScript*' ! -name 'CScript.uo.deps' \) \) -print)
if [[ -n "$leaks" ]]; then
  echo "speculative outputs of C were published:" >&2
  echo "$leaks" >&2
  exit 1
fi
if [[ -d "$tmpdir/cache/actions" ]] && grep -rl "CTheory" "$tmpdir/cache/actions" >/dev/null; then
  echo "the cache has an entry for C" >&2
  exit 1
fi
# No build here saves checkpoints, so no heap may appear, shared or local.
heaps=$(find "$project/.holbuild" "$tmpdir/cache" -path "$tmpdir/cache/hol-toolchains" -prune -o \
          \( -name 'deps_loaded.save' -o -path "$tmpdir/cache/checkpoint-store/*" \) -print)
if [[ -n "$heaps" ]]; then
  echo "checkpoints were published:" >&2
  echo "$heaps" >&2
  exit 1
fi
