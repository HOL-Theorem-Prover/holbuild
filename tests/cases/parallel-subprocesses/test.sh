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
name = "parallel_subprocesses"

[build]
members = ["src"]
TOML

child_log=$project/child.log
: > "$child_log"
for i in 1 2 3 4 5 6; do
  cat > "$project/src/T${i}Script.sml" <<SML
open HolKernel Parse boolLib bossLib;
fun append msg =
  let val out = TextIO.openAppend "$child_log"
  in TextIO.output(out, msg ^ "\\n"); TextIO.closeOut out end;
val _ = append "START T${i}";
val _ = OS.Process.system "sleep 2";
val _ = append "END T${i}";
val _ = new_theory "T${i}";
val t${i}_thm = store_thm("t${i}_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
done

(cd "$project" && "$HOLBUILD_BIN" -j3 build --skip-checkpoints --skip-goalfrag) > "$tmpdir/build.log"

start_before_first_end=$(awk '
  /^END / { print starts; exit }
  /^START / { starts++ }
' "$child_log")
if [[ "$start_before_first_end" -lt 3 ]]; then
  echo "expected at least 3 subprocesses to start before the first finished" >&2
  echo "child log:" >&2
  cat "$child_log" >&2
  exit 1
fi

for i in 1 2 3 4 5 6; do
  require_grep "START T${i}" "$child_log"
  require_grep "END T${i}" "$child_log"
  require_file "$project/.holbuild/obj/src/T${i}Theory.dat"
done

fail_project=$tmpdir/fail-project
mkdir -p "$fail_project/src"
cat > "$fail_project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "parallel_failure_cleanup"

[build]
members = ["src"]
TOML

fail_child_log=$fail_project/child.log
cat > "$fail_project/src/SlowScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
fun append msg =
  let val out = TextIO.openAppend "$fail_child_log"
  in TextIO.output(out, msg ^ "\\n"); TextIO.closeOut out end;
val _ = append "START slow";
val _ = OS.Process.system "sleep 12";
val _ = append "END slow";
val _ = new_theory "Slow";
val slow_thm = store_thm("slow_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML
cat > "$fail_project/src/FailScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Fail";
val _ = raise Fail "expected parallel failure";
val _ = export_theory();
SML

start_seconds=$SECONDS
if (cd "$fail_project" && "$HOLBUILD_BIN" -j2 build --skip-checkpoints --skip-goalfrag) > "$tmpdir/fail-build.log" 2>&1; then
  echo "expected parallel build failure" >&2
  exit 1
fi
elapsed=$((SECONDS - start_seconds))
require_grep "expected parallel failure" "$tmpdir/fail-build.log"
if [[ "$elapsed" -ge 10 ]]; then
  echo "parallel failure waited for unrelated slow child ($elapsed seconds)" >&2
  cat "$tmpdir/fail-build.log" >&2
  exit 1
fi
if grep -q "END slow" "$fail_child_log" 2>/dev/null; then
  echo "unrelated slow child survived first parallel failure" >&2
  cat "$fail_child_log" >&2
  exit 1
fi
