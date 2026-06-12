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
name = "replfail"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;

val _ = new_theory "A";

Theorem fail_thm:
  T
Proof
  FAIL_TAC "boom"
QED

val _ = export_theory();
SML

cd "$project"

skip_log=$tmpdir/skip-checkpoints.log
if "$HOLBUILD_BIN" build --repl-on-failure --skip-checkpoints ATheory >"$skip_log" 2>&1; then
  echo "expected --repl-on-failure --skip-checkpoints to fail" >&2
  exit 1
fi
if ! grep -q -- "--repl-on-failure requires checkpoints" "$skip_log"; then
  echo "missing --skip-checkpoints rejection" >&2
  cat "$skip_log" >&2
  exit 1
fi

json_log=$tmpdir/json.log
if "$HOLBUILD_BIN" --json build --repl-on-failure ATheory >"$json_log" 2>&1; then
  echo "expected --json --repl-on-failure to fail" >&2
  exit 1
fi
if ! grep -q -- "--json does not support --repl-on-failure" "$json_log"; then
  echo "missing --json rejection" >&2
  cat "$json_log" >&2
  exit 1
fi

repl_log=$tmpdir/repl.log
if printf 'val _ = (proofManagerLib.p(); print "P_OK\\n"); val _ = OS.Process.exit OS.Process.success;\n' |
   "$HOLBUILD_BIN" build --repl-on-failure --force --no-cache ATheory >"$repl_log" 2>&1; then
  echo "expected failing proof to keep build exit status failed after repl exits" >&2
  exit 1
fi
if ! grep -q "starting HOL repl from failed-prefix checkpoint" "$repl_log"; then
  echo "missing failed-prefix repl launch" >&2
  cat "$repl_log" >&2
  exit 1
fi
if ! grep -q "checkpoint: .*fail_thm_failed_prefix.save" "$repl_log"; then
  echo "missing failed-prefix checkpoint path" >&2
  cat "$repl_log" >&2
  exit 1
fi
if ! grep -q "failed proof state loaded; run p();" "$repl_log"; then
  echo "missing failed proof-state bootstrap message" >&2
  cat "$repl_log" >&2
  exit 1
fi
if ! grep -q "P_OK" "$repl_log"; then
  echo "p() did not work in failure repl" >&2
  cat "$repl_log" >&2
  exit 1
fi
if ! grep -q 'fragment: FAIL_TAC "boom"' "$repl_log"; then
  echo "missing original failure diagnostics after repl" >&2
  cat "$repl_log" >&2
  exit 1
fi
