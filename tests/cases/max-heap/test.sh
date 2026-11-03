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
{
  write_schema2_prelude
  cat <<'TOML'

[project]
name = "maxheap"

[build]
members = ["src"]
TOML
} > "$project/holproject.toml"
# The theory child prints its own command line, as the OS passed it, so the
# test sees the heap cap before the child's Poly/ML runtime consumes it.
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;

val _ = new_theory "A";

val _ =
  let
    val ins = TextIO.openIn "/proc/self/cmdline"
    val text = TextIO.inputAll ins before TextIO.closeIn ins
  in
    print ("child-argv: " ^ String.translate (fn #"\000" => " " | c => str c) text ^ "\n")
  end;

val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" --max-heap 4096 build ATheory) > "$tmpdir/build.out" 2>&1 || {
  cat "$tmpdir/build.out" >&2
  exit 1
}
build_log=$project/.holbuild/logs/current/maxheap/ATheory/build.log
require_file "$build_log"
require_grep '^child-argv: .*/bin/hol --gcthreads=1 --maxheap 4096 run ' "$build_log"

# The Poly/ML runtime consumes --maxheap and --gcthreads before holbuild parses
# its arguments, so holbuild rejects those spellings instead of building
# without them.
for spelling in "--maxheap 4096" "--maxheap=4096" "--gcthreads 2" "--gcthreads=2"; do
  # shellcheck disable=SC2086
  if (cd "$project" && "$HOLBUILD_BIN" $spelling build --force ATheory) > "$tmpdir/rejected.out" 2>&1; then
    echo "holbuild accepted $spelling" >&2
    exit 1
  fi
  case $spelling in
    --maxheap*) expected='--maxheap .* use --max-heap MB' ;;
    *) expected='--gcthreads .* use --gc-threads N' ;;
  esac
  require_grep "^holbuild: $expected\$" "$tmpdir/rejected.out"
done

# Every HOL child gets one GC thread unless --gc-threads says otherwise.
(cd "$project" && "$HOLBUILD_BIN" --gc-threads 3 build --force ATheory) > "$tmpdir/gcthreads.out" 2>&1 || {
  cat "$tmpdir/gcthreads.out" >&2
  exit 1
}
require_grep '^child-argv: .*/bin/hol --gcthreads=3 run ' "$build_log"

cat > "$tmpdir/argv.sml" <<'SML'
val _ =
  let
    val ins = TextIO.openIn "/proc/self/cmdline"
    val text = TextIO.inputAll ins before TextIO.closeIn ins
  in
    print ("run-argv: " ^ String.translate (fn #"\000" => " " | c => str c) text ^ "\n")
  end;
SML
(cd "$project" && "$HOLBUILD_BIN" run "$tmpdir/argv.sml") > "$tmpdir/run.out" 2>&1 || {
  cat "$tmpdir/run.out" >&2
  exit 1
}
require_grep '^run-argv: .*/bin/hol --gcthreads=1 run ' "$tmpdir/run.out"
(cd "$project" && "$HOLBUILD_BIN" --gc-threads=2 run "$tmpdir/argv.sml") > "$tmpdir/run.out" 2>&1 || {
  cat "$tmpdir/run.out" >&2
  exit 1
}
require_grep '^run-argv: .*/bin/hol --gcthreads=2 run ' "$tmpdir/run.out"

for spelling in "--gc-threads 0" "--gc-threads=x"; do
  # shellcheck disable=SC2086
  if (cd "$project" && "$HOLBUILD_BIN" $spelling build ATheory) > "$tmpdir/rejected.out" 2>&1; then
    echo "holbuild accepted $spelling" >&2
    exit 1
  fi
  require_grep '^holbuild: --gc-threads must be a positive integer$' "$tmpdir/rejected.out"
done
