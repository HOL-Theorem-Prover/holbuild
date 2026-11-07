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

for mode in manifest-directory manifest-glob source-directory source-glob; do
  project=$tmpdir/$mode
  mkdir -p "$project/src"
  printf 'first\n' > "$project/input.txt"
  declaration=data
  [[ $mode != *-glob ]] || declaration='data/*.txt'
  cat > "$project/holproject.toml" <<TOML
[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "$mode"

[build]
members = ["src"]
TOML
  if [[ $mode == manifest-* ]]; then
    cat >> "$project/holproject.toml" <<TOML

[actions.ATheory]
extra_deps = ["src/$declaration"]
TOML
  fi
  for output in one nested/two; do
    cat >> "$project/holproject.toml" <<TOML

[[generate]]
name = "$output"
command = ["sh", "-c", "mkdir -p src/data/nested; cp input.txt src/data/$output.txt; printf x >> $output.count"]
inputs = ["input.txt"]
outputs = ["src/data/$output.txt"]
TOML
  done
  # The counter for the nested output lives outside the selected directory.
  mkdir -p "$project/nested"
  cat >> "$project/holproject.toml" <<'TOML'

[[generate]]
name = "unrelated"
command = ["generator-that-must-not-run"]
outputs = ["src/database/unrelated.txt"]
TOML
  if [[ $mode == source-* ]]; then
    cat > "$project/src/AScript.sml" <<SML
fun holbuild_extra_deps (_ : string list) = ()
val () = holbuild_extra_deps ["$declaration"]
SML
  fi
  cat >> "$project/src/AScript.sml" <<'SML'
fun holbuild_extra_outputs (_ : string list) = ()
val () = holbuild_extra_outputs ["seen.txt"]
val () = let
  fun read path = let val input = TextIO.openIn path
                  in TextIO.inputAll input before TextIO.closeIn input end
  val contents = read "data/one.txt" ^ read "data/nested/two.txt"
  val output = TextIO.openOut "seen.txt"
in
  TextIO.output(output, contents);
  TextIO.closeOut output
end
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem truth: T
Proof ACCEPT_TAC TRUTH
QED
val _ = export_theory();
SML

  (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/$mode-first.log" 2>&1
  printf 'first\nfirst\n' > "$tmpdir/expected"
  cmp "$tmpdir/expected" "$project/src/seen.txt"
  for count in one nested/two; do
    [[ $(cat "$project/$count.count") == x ]]
  done

  (cd "$project" && "$HOLBUILD_BIN" --verbose build ATheory) > "$tmpdir/$mode-unchanged.log" 2>&1
  require_grep "ATheory is up to date" "$tmpdir/$mode-unchanged.log"
  for count in one nested/two; do
    [[ $(cat "$project/$count.count") == x ]]
  done

  printf 'second\n' > "$project/input.txt"
  (cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/$mode-changed.log" 2>&1
  printf 'second\nsecond\n' > "$tmpdir/expected"
  cmp "$tmpdir/expected" "$project/src/seen.txt"
  for count in one nested/two; do
    [[ $(cat "$project/$count.count") == xx ]]
  done
  require_no_file "$project/src/database/unrelated.txt"
done
