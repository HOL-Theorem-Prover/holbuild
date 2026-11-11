#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

mkdir -p "$tmpdir/project/src"
cat > "$tmpdir/project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"
[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"
[project]
name = "slow"
[build]
members = ["src"]
tactic_timeout = 1.0
TOML
cat > "$tmpdir/project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
fun slow_tac g = (OS.Process.sleep (Time.fromReal 0.7); ALL_TAC g);
Theorem slow_success:
  T
Proof
  slow_tac >> simp[]
QED
val _ = export_theory();
SML

(cd "$tmpdir/project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/build.log" 2>&1 ||
  { cat "$tmpdir/build.log" >&2; exit 1; }
log=$tmpdir/project/.holbuild/logs/current/slow/ATheory/build.log
collector=$HOLBUILD_ROOT/tools/slow-proof-steps.py
python3 "$collector" "$log" > "$tmpdir/steps.tsv" 2> "$tmpdir/coverage.log"
require_grep $'slow_success\t0\tstep\tok\t[0-9.]*\t1000.000\tslow_tac' "$tmpdir/steps.tsv"
require_grep '1/1 logs instrumented' "$tmpdir/coverage.log"

# Old build logs and restored actions without a retained original log are
# unknown coverage, not evidence of zero near-limit steps.
printf 'Saved theorem "old"\n' > "$tmpdir/old.log"
cat > "$tmpdir/batch.json" <<'JSON'
{"state":"done","actions":[{"theory":"slow:ATheory","input_key":"old","log_sha256":null}]}
JSON
python3 "$collector" "$tmpdir/old.log" --batch "$tmpdir/batch.json" \
  --cache-url https://unused.example.org > "$tmpdir/old.tsv" 2> "$tmpdir/old-coverage.log"
[[ $(wc -l < "$tmpdir/old.tsv") -eq 1 ]]
require_grep 'timings unavailable: slow:ATheory@old' "$tmpdir/old-coverage.log"
require_grep '0/2 logs instrumented' "$tmpdir/old-coverage.log"
