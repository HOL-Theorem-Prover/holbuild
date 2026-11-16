#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# HOL reports any failure to create the .hol/objs it exports into, a full
# disk included, as a path that "already exists but is not a directory".
# The stage holds that directory before HOL starts, so a failed export write
# names its own error.

tmpdir=$(make_temp_dir)
cleanup() { chmod -R u+w "$tmpdir" 2>/dev/null || true; rm -rf "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "${HOLBUILD_TEST_HOL_GIT:-https://github.com/HOL-Theorem-Prover/HOL.git}"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "exportdir"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;

val _ = new_theory "A";

val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);

val _ =
  if OS.FileSys.isDir ".hol/objs" handle OS.SysErr _ => false then
    ignore (OS.Process.system "chmod 555 .hol/objs")
  else raise Fail "the stage has no .hol/objs";

val _ = export_theory();
SML

log=$tmpdir/build.log
if (cd "$project" && HOLBUILD_ECHO_CHILD_LOGS=1 "$HOLBUILD_BIN" --max-heap 4096 build ATheory) > "$log" 2>&1; then
  echo "the build should fail when its export can't write .hol/objs" >&2
  exit 1
fi
require_grep "Permission denied" "$log"
if grep -q "already exists but is not a directory" "$log"; then
  echo "the export failure should name its error, not HOL's directory message" >&2
  cat "$log" >&2
  exit 1
fi
