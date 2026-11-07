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

dep=$tmpdir/dep
project=$tmpdir/project
mkdir -p "$dep/src" "$project/src"

{
  write_schema2_prelude
  cat <<'TOML'
[project]
name = "dep"

[build]
members = ["src"]
TOML
} > "$dep/holproject.toml"
cat > "$dep/src/BaseScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Base";
val _ = new_constant ("magic", ``:bool``);
val magic_ax = new_axiom ("magic_ax", ``magic``);
val _ = export_theory();
SML
dep_rev=$(init_git_repo "$dep")

{
  write_schema2_prelude
  cat <<TOML
[project]
name = "consumer"

[build]
members = ["src"]

[dependencies.dep]
git = "$dep"
rev = "$dep_rev"
TOML
} > "$project/holproject.toml"
cat > "$project/src/CleanScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Clean";
Theorem clean_thm:
  T
Proof
  simp[]
QED
val _ = export_theory();
SML
cat > "$project/src/CheatScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Cheat";
Theorem fine_thm:
  T
Proof
  simp[]
QED
Theorem cheated_thm:
  F
Proof
  cheat
QED
val _ = export_theory();
SML
cat > "$project/src/UsesScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
open BaseTheory;
val _ = new_theory "Uses";
Theorem uses_thm:
  magic
Proof
  ACCEPT_TAC magic_ax
QED
val _ = export_theory();
SML

cat > "$project/src/FpScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Fp";
Definition flip_def:
  flip b = ~b
End
Theorem lam_x:
  (\\x:bool. x) = (\\x. x)
Proof
  simp[]
QED
Theorem lam_y:
  (\\y:bool. y) = (\\y. y)
Proof
  simp[]
QED
Theorem lam_neg:
  (\\x:bool. ~x) = (\\x. ~x)
Proof
  simp[]
QED
val _ =
  let val out = TextIO.openOut "$tmpdir/term-fingerprint.txt"
  in
    TextIO.output (out, HolbuildFingerprint.term \`\`(\\z:bool. z) = (\\z. z)\`\` ^ "\\n");
    TextIO.closeOut out
  end;
val _ = export_theory();
SML
cat > "$project/src/BypassScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Bypass";
(* RunCall.unsafeCast in a comment is not a use. *)
val _ = "PolyML.compiler in a string is not one either";
val forge = Thm.disk_thm;
val _ = export_theory();
SML

# Expects the check of $1 to exit with status $2; leaves its output in $log.
run_check() {
  local selector=$1 expected=$2 status
  log=$tmpdir/check-${selector//:/-}.log
  set +e
  (cd "$project" && "$HOLBUILD_BIN" check "$selector") > "$log" 2>&1
  status=$?
  set -e
  if [[ $status -ne $expected ]]; then
    echo "check $selector exited $status, expected $expected" >&2
    cat "$log" >&2
    exit 1
  fi
}

require_no_grep() {
  local pattern=$1 path=$2
  if grep -q "$pattern" "$path"; then
    echo "unexpected pattern '$pattern' in $path" >&2
    cat "$path" >&2
    exit 1
  fi
}

# HOL's own axioms (bool's ETA_AX, SELECT_AX, ...) are not findings.
run_check CleanTheory 0
require_grep "CleanTheory built" "$log"
require_grep "^CleanTheory: clean (1 theorem)$" "$log"
require_no_grep "axiom" "$log"

run_check CheatTheory 1
require_grep "^CheatTheory.cheated_thm: cheat$" "$log"
require_grep "^CheatTheory: 1 finding$" "$log"
require_no_grep "fine_thm" "$log"

run_check CheatTheory:fine_thm 0
require_grep "^CheatTheory.fine_thm: clean (1 theorem)$" "$log"

run_check CheatTheory:cheated_thm 1
require_grep "^CheatTheory.cheated_thm: cheat$" "$log"

# Theorems loaded from disk do not record the axioms they use, so an axiom
# anywhere in the ancestry outside HOL is a finding, here in a dependency.
run_check UsesTheory 1
require_grep "^BaseTheory.magic_ax: axiom$" "$log"
require_grep "^UsesTheory: 1 finding$" "$log"

# A single theorem still gets the ancestry's axioms reported.
run_check UsesTheory:uses_thm 1
require_grep "^BaseTheory.magic_ax: axiom$" "$log"

# A theory's own axioms are findings too.
run_check BaseTheory 1
require_grep "^BaseTheory.magic_ax: axiom$" "$log"

# Kernel-bypass calls in a theory's sources are findings; names in comments
# and strings are not.
run_check BypassTheory 1
require_grep "^consumer:src/BypassScript.sml:5: kernel bypass: disk_thm$" "$log"
require_grep "^BypassTheory: 1 finding$" "$log"
require_no_grep "RunCall\|unsafeCast\|PolyML" "$log"

# Expects check --fingerprint $1 to exit with status $2; leaves its output in
# $log and the fingerprint lines alone in $lines.
run_fingerprint() {
  local theory=$1 expected=$2 status
  log=$tmpdir/fingerprint-${theory//:/-}.log
  lines=$log.lines
  set +e
  (cd "$project" && "$HOLBUILD_BIN" check --fingerprint "$theory") > "$log" 2>&1
  status=$?
  set -e
  if [[ $status -ne $expected ]]; then
    echo "check --fingerprint $theory exited $status, expected $expected" >&2
    cat "$log" >&2
    exit 1
  fi
  grep '^fingerprint	' "$log" > "$lines" || true
}

fingerprint_of() {
  awk -F '\t' -v thy="$1" -v kind="$2" -v name="$3" \
    '$2 == thy && $3 == kind && $4 == name { print $5 }' "$4"
}

run_fingerprint FpTheory 0
fp_lines=$tmpdir/fingerprint-before-rebuild.lines
cp "$lines" "$fp_lines"
if ! LC_ALL=C sort -c "$fp_lines"; then
  echo "fingerprint lines are not sorted" >&2
  exit 1
fi
line_format='^fingerprint\t[A-Za-z0-9_]+Theory\t(axiom|definition|theorem)\t[^\t]+\t[0-9a-f]{64}\t[^\t]+$'
if grep -qvP "$line_format" "$fp_lines"; then
  echo "malformed fingerprint line" >&2
  grep -vP "$line_format" "$fp_lines" >&2
  exit 1
fi
require_grep "^fingerprint	FpTheory	definition	flip_def	[0-9a-f]*	-$" "$fp_lines"
require_grep "^fingerprint	FpTheory	theorem	lam_x	[0-9a-f]*	-$" "$fp_lines"
# Definitions and axioms are not listed again as theorems.
require_no_grep "^fingerprint	FpTheory	theorem	flip_def	" "$fp_lines"
# HOL's own theories are part of the ancestry.
require_grep "^fingerprint	boolTheory	axiom	ETA_AX	" "$fp_lines"
lam_x=$(fingerprint_of FpTheory theorem lam_x "$fp_lines")
lam_y=$(fingerprint_of FpTheory theorem lam_y "$fp_lines")
lam_neg=$(fingerprint_of FpTheory theorem lam_neg "$fp_lines")
if [[ -z "$lam_x" || "$lam_x" != "$lam_y" || "$lam_x" == "$lam_neg" ]]; then
  echo "alpha-equivalent statements must agree and different ones differ: $lam_x $lam_y $lam_neg" >&2
  exit 1
fi
# The script's in-session fingerprint of the statement is the same.
if [[ "$(cat "$tmpdir/term-fingerprint.txt")" != "$lam_x" ]]; then
  echo "HolbuildFingerprint.term disagrees with check --fingerprint" >&2
  exit 1
fi

# A rebuild gives the same lines.
echo "(* rebuilt *)" >> "$project/src/FpScript.sml"
run_fingerprint FpTheory 0
require_grep "FpTheory built" "$log"
if ! cmp -s "$fp_lines" "$lines"; then
  echo "fingerprints changed across a rebuild" >&2
  diff "$fp_lines" "$lines" >&2 || true
  exit 1
fi

run_fingerprint CheatTheory 0
require_grep "^fingerprint	CheatTheory	theorem	cheated_thm	[0-9a-f]*	cheat$" "$lines"
require_grep "^fingerprint	CheatTheory	theorem	fine_thm	[0-9a-f]*	-$" "$lines"

run_fingerprint UsesTheory 0
require_grep "^fingerprint	BaseTheory	axiom	magic_ax	[0-9a-f]*	-$" "$lines"

run_fingerprint CheatTheory:fine_thm 1
require_grep "holbuild: check --fingerprint takes a theory, not THEORY:THEOREM" "$log"

run_check CheatTheory:missing_thm 1
require_grep "holbuild: theorem not found: CheatTheory.missing_thm" "$log"

run_check MissingTheory 1
require_grep "holbuild: theory not found for check: MissingTheory" "$log"

run_check CheatTheory: 1
require_grep "holbuild: check requires THEORY or THEORY:THEOREM" "$log"

help_log=$tmpdir/help.log
"$HOLBUILD_BIN" check --help > "$help_log"
require_grep "holbuild \[GLOBAL OPTIONS\] check THEORY\[:THEOREM\]" "$help_log"

if find "$project/.holbuild" -maxdepth 1 -name 'holbuild-check-*.sml' -print -quit | grep -q .; then
  echo "check left its generated script behind" >&2
  exit 1
fi

# A [run].heap holding an older CheatTheory must not hide the rebuilt one.
cat >> "$project/holproject.toml" <<'TOML'

[[heap]]
name = "main"
output = ".holbuild/heap/main.save"
objects = ["CheatTheory"]

[run]
heap = ".holbuild/heap/main.save"
TOML
(cd "$project" && "$HOLBUILD_BIN" -j2 heap main) > "$tmpdir/heap.log" 2>&1
python3 - "$project/src/CheatScript.sml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace("  F\nProof\n  cheat\n", "  T\nProof\n  simp[]\n"))
PY
run_check CheatTheory 0
require_grep "^CheatTheory: clean (2 theorems)$" "$log"

# check builds plain, as heap does: no step timeout, no checkpoints, and it
# reuses theories built by build --skip-proof-steps --skip-checkpoints.
slow=$tmpdir/slow
mkdir -p "$slow/src"
{
  write_schema2_prelude
  cat <<'TOML'
[project]
name = "slow"

[build]
members = ["src"]
tactic_timeout = 0.1
TOML
} > "$slow/holproject.toml"
cat > "$slow/src/SlowScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Slow";
fun slow_tac g = (OS.Process.sleep (Time.fromReal 0.45); ACCEPT_TAC TRUTH g);
Theorem slow_thm:
  T
Proof
  slow_tac
QED
val _ = export_theory();
SML

project=$slow
run_check SlowTheory 0
require_grep "^SlowTheory: clean (1 theorem)$" "$log"
if find "$slow/.holbuild" -name '*.save' -print -quit | grep -q .; then
  echo "check left checkpoints behind" >&2
  exit 1
fi

printf '(* edited *)\n' >> "$slow/src/SlowScript.sml"
(cd "$slow" && "$HOLBUILD_BIN" build --skip-proof-steps --skip-checkpoints SlowTheory) > "$tmpdir/slow-plain-build.log" 2>&1
rm -rf "$slow/.holbuild"
run_check SlowTheory 0
require_grep "SlowTheory restored from cache" "$log"
require_grep "^SlowTheory: clean (1 theorem)$" "$log"

# [run].loads build plain too: the load is the checked theory, edited and
# built by build --skip-proof-steps --skip-checkpoints.
cat >> "$slow/holproject.toml" <<'TOML'

[run]
loads = ["SlowTheory"]
TOML
printf '(* edited again *)\n' >> "$slow/src/SlowScript.sml"
(cd "$slow" && "$HOLBUILD_BIN" build --skip-proof-steps --skip-checkpoints SlowTheory) > "$tmpdir/slow-plain-build2.log" 2>&1
run_check SlowTheory 0
require_grep "^SlowTheory: clean (1 theorem)$" "$log"
if find "$slow/.holbuild" -name '*.save' -print -quit | grep -q .; then
  echo "check left checkpoints behind building [run].loads" >&2
  exit 1
fi
