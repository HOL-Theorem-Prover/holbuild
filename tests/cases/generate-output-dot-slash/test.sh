#!/usr/bin/env bash
set -euo pipefail
HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"
project=$tmpdir/project
mkdir -p "$project/src" "$project/gen" "$project/scripts"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "dot_slash_output"

[build]
members = ["src", "gen"]

[[generate]]
name = "make-theory"
command = ["sh", "-c", "mkdir -p gen; echo ran >> gen.count; cp scripts/G.tmpl gen/GScript.sml"]
outputs = ["./gen/GScript.sml"]
TOML
cat > "$project/scripts/G.tmpl" <<'SML'
Theory G
Theorem g_thm: T
Proof ACCEPT_TAC TRUTH
QED
SML
rc=0
(cd "$project" && "$HOLBUILD_BIN" build GTheory) > "$tmpdir/out.log" 2>&1 || rc=$?
cat "$tmpdir/out.log"
echo "exit=$rc gen.count=$(cat "$project/gen.count" 2>/dev/null || echo none)"
[[ $rc = 0 ]] || { echo "build failed: ./-spelled generator output" >&2; exit 1; }
[[ $(cat "$project/gen.count") = ran ]] || { echo "generator did not run exactly once" >&2; exit 1; }
