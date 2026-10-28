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
require_grep '^child-argv: .*/bin/hol .*--maxheap 4096 run ' "$build_log"

# The Poly/ML runtime consumes --maxheap before holbuild parses its arguments,
# so holbuild rejects that spelling instead of building without a cap.
for spelling in "--maxheap 4096" "--maxheap=4096"; do
  # shellcheck disable=SC2086
  if (cd "$project" && "$HOLBUILD_BIN" $spelling build --force ATheory) > "$tmpdir/rejected.out" 2>&1; then
    echo "holbuild accepted $spelling" >&2
    exit 1
  fi
  require_grep '^holbuild: --maxheap is consumed by holbuild.s Poly/ML runtime .* use --max-heap MB$' "$tmpdir/rejected.out"
done
