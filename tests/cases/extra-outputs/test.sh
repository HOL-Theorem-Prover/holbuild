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

write_manifest() {
  local project=$1
  local name=$2
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.11.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "$name"

[build]
members = ["src"]
TOML
}

project=$tmpdir/project
write_manifest "$project" extra-outputs
cat > "$project/src/AScript.sml" <<'SML'
fun holbuild_extra_outputs (_ : string list) = ()
val _ = holbuild_extra_outputs ["results/A.nsv"]
val _ = let
  val out = TextIO.openOut "results/A.nsv"
in
  TextIO.output(out, "deterministic result\n");
  TextIO.closeOut out
end
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
Theorem a_thm: T Proof ACCEPT_TAC TRUTH QED
val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/build1.log" 2>&1
output=$project/src/results/A.nsv
require_file "$output"
require_grep "deterministic result" "$output"
metadata=$project/.holbuild/dep/extra-outputs/src/AScript.sml.key
require_grep "source_extra_output=results/A.nsv" "$metadata"

(cd "$project" && "$HOLBUILD_BIN" --verbose build ATheory) > "$tmpdir/build2.log" 2>&1
require_grep "ATheory is up to date" "$tmpdir/build2.log"

rm "$output"
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/restore.log" 2>&1
require_file "$output"
require_grep "deterministic result" "$output"
require_grep "restored from cache" "$tmpdir/restore.log"

(cd "$project" && "$HOLBUILD_BIN" clean ATheory) > "$tmpdir/clean.log" 2>&1
require_no_file "$output"
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/restore-after-clean.log" 2>&1
require_file "$output"
require_grep "restored from cache" "$tmpdir/restore-after-clean.log"

archive=$tmpdir/extra-output.hbx
(cd "$project" && "$HOLBUILD_BIN" export -o "$archive" ATheory) > "$tmpdir/export.log" 2>&1
(cd "$project" && "$HOLBUILD_BIN" clean ATheory) > "$tmpdir/clean-before-import.log" 2>&1
import_cache=$tmpdir/import-cache
use_case_cache "$import_cache"
"$HOLBUILD_BIN" import "$archive" > "$tmpdir/import.log" 2>&1
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/restore-import.log" 2>&1
require_file "$output"
require_grep "deterministic result" "$output"
require_grep "restored from cache" "$tmpdir/restore-import.log"

# Changing a declaration removes the formerly owned output and releases its claim.
python3 - "$project/src/AScript.sml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace('results/A.nsv', 'results/B.nsv'))
PY
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/changed-output.log" 2>&1
new_output=$project/src/results/B.nsv
require_no_file "$output"
require_file "$new_output"

# Cleaning still uses the recorded ownership after the source declaration is removed.
python3 - "$project/src/AScript.sml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace('val _ = holbuild_extra_outputs ["results/B.nsv"]\n', '')
path.write_text(text)
PY
(cd "$project" && "$HOLBUILD_BIN" clean ATheory) > "$tmpdir/clean-removed-declaration.log" 2>&1
require_no_file "$new_output"

missing=$tmpdir/missing
write_manifest "$missing" missing-extra-output
cat > "$missing/src/AScript.sml" <<'SML'
fun holbuild_extra_outputs (_ : string list) = ()
val _ = holbuild_extra_outputs ["missing.nsv"]
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val _ = export_theory();
SML
if (cd "$missing" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/missing.log" 2>&1; then
  echo "action that omitted a declared extra output unexpectedly succeeded" >&2
  exit 1
fi
require_grep "did not produce declared extra output: missing.nsv" "$tmpdir/missing.log"

invalid=$tmpdir/invalid
write_manifest "$invalid" invalid-extra-output
cat > "$invalid/src/AScript.sml" <<'SML'
fun holbuild_extra_outputs (_ : string list) = ()
val _ = holbuild_extra_outputs ["../outside.nsv"]
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val _ = export_theory();
SML
if (cd "$invalid" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/invalid.log" 2>&1; then
  echo "parent-relative extra output unexpectedly succeeded" >&2
  exit 1
fi
require_grep "must not contain . or .. components" "$tmpdir/invalid.log"

conflict=$tmpdir/conflict
write_manifest "$conflict" conflicting-extra-outputs
cat > "$conflict/src/AScript.sml" <<'SML'
fun holbuild_extra_outputs (_ : string list) = ()
val _ = holbuild_extra_outputs ["owned.nsv"]
val _ = let val out = TextIO.openOut "owned.nsv"
        in TextIO.output(out, "A\n"); TextIO.closeOut out end
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
val _ = export_theory();
SML
cat > "$conflict/src/BScript.sml" <<'SML'
fun holbuild_extra_outputs (_ : string list) = ()
val _ = holbuild_extra_outputs ["owned.nsv"]
val _ = let val out = TextIO.openOut "owned.nsv"
        in TextIO.output(out, "B\n"); TextIO.closeOut out end
open HolKernel Parse boolLib bossLib;
val _ = new_theory "B";
val _ = export_theory();
SML
(cd "$conflict" && "$HOLBUILD_BIN" build ATheory) > "$tmpdir/owner-a.log" 2>&1
require_grep "A" "$conflict/src/owned.nsv"
if (cd "$conflict" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/owner-b-conflict.log" 2>&1; then
  echo "separately built extra-output owner unexpectedly replaced the first owner" >&2
  exit 1
fi
require_grep "extra output is already owned" "$tmpdir/owner-b-conflict.log"
require_grep "A" "$conflict/src/owned.nsv"
(cd "$conflict" && "$HOLBUILD_BIN" clean ATheory) > "$tmpdir/owner-a-clean.log" 2>&1
require_no_file "$conflict/src/owned.nsv"
(cd "$conflict" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/owner-b.log" 2>&1
require_grep "B" "$conflict/src/owned.nsv"

claim=$(find "$conflict/.holbuild/extra-outputs/owners" -type f -name '*.owner')
cp "$claim" "$tmpdir/owner-record"
printf 'corrupt\n' > "$claim"
if (cd "$conflict" && "$HOLBUILD_BIN" clean BTheory) > "$tmpdir/corrupt-owner.log" 2>&1; then
  echo "clean accepted a corrupt extra-output ownership record" >&2
  exit 1
fi
require_grep "invalid extra-output ownership record" "$tmpdir/corrupt-owner.log"
require_file "$conflict/src/owned.nsv"
cp "$tmpdir/owner-record" "$claim"

# Selected-plan conflicts are diagnosed before either action executes.
(cd "$conflict" && "$HOLBUILD_BIN" clean BTheory) > "$tmpdir/owner-b-clean.log" 2>&1
if (cd "$conflict" && "$HOLBUILD_BIN" build ATheory BTheory) > "$tmpdir/conflict.log" 2>&1; then
  echo "multiply-owned selected extra output unexpectedly succeeded" >&2
  exit 1
fi
require_grep "extra output has multiple owners" "$tmpdir/conflict.log"
