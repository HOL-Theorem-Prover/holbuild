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
printf 'HEADERDEPS\n' > "$project/.holpath"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "headerdeps"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors arithmetic[qualified, ignore_grammar] string
Libs numLib monadsyntax cv_transLib

Type identifier = “:string”;

Datatype:
  colour = Red | Blue
End

val _ = Theory.add_ML_dependency "monadsyntax";

Theorem add_one:
  1 + 1 = 2
Proof
  numLib.REDUCE_TAC
QED

val _ = export_theory();
SML
cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors A

Theorem two:
  2 = 2
Proof
  simp[]
QED

val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" build --dry-run ATheory) > "$tmpdir/dry.log"
require_grep "external theories: .*arithmeticTheory" "$tmpdir/dry.log"
require_grep "external theories: .*stringTheory" "$tmpdir/dry.log"
require_grep "external libs: .*cv_transLib" "$tmpdir/dry.log"
require_grep "external libs: .*monadsyntax" "$tmpdir/dry.log"
require_grep "external libs: .*numLib" "$tmpdir/dry.log"
if grep -q "ignore_grammar\|qualified\|identifier" "$tmpdir/dry.log"; then
  echo "HOLSource header/body qualifier or Type declaration was misclassified" >&2
  exit 1
fi

(cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/build.log"
require_file "$project/.holbuild/obj/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_file "$project/.holbuild/obj/src/BTheory.dat"
require_grep "numLib" "$project/.holbuild/obj/src/AScript.uo"
require_grep "monadsyntax" "$project/.holbuild/obj/src/AScript.uo"
require_grep "cv_transLib" "$project/.holbuild/obj/src/AScript.uo"
require_grep "monadsyntax" "$project/.holbuild/obj/src/ATheory.uo"
require_grep "cv_primTheory" "$project/.holbuild/obj/src/ATheory.uo"
if grep -q "arithmeticTheory" "$project/.holbuild/obj/src/ATheory.uo"; then
  echo "source-header-only arithmeticTheory leaked into generated theory load manifest" >&2
  exit 1
fi
if grep -q "\.holbuild/stage" "$project/.holbuild/obj/src/ATheory.uo"; then
  echo "transient stage path leaked into generated theory load manifest" >&2
  exit 1
fi
if grep -q "\.holbuild/stage" "$project/.holbuild/obj/src/ATheory.sml"; then
  echo "transient stage dat path leaked into generated theory source" >&2
  exit 1
fi
if grep -q "numLib\|cv_transLib" "$project/.holbuild/obj/src/ATheory.uo"; then
  echo "source-only Libs leaked into generated theory load manifest" >&2
  exit 1
fi
if grep -q "numLib\|cv_transLib" "$project/.holbuild/obj/src/BTheory.uo"; then
  echo "dependency source-only Libs leaked into dependent theory load manifest" >&2
  exit 1
fi
require_grep "dependency_context_key=" "$project/.holbuild/dep/headerdeps/src/AScript.sml.key"

rm -rf "$project/.holbuild"
(cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/cache.log"
# If HOL embeds transient stage/worktree strings into ATheory.dat, holbuild may
# restore from a path-scoped cache key for the same project root, but must not
# leak transient stage paths into generated sources/load manifests.
require_grep "ATheory restored from cache" "$tmpdir/cache.log"
require_file "$project/.holbuild/obj/src/ATheory.dat"
require_grep "monadsyntax" "$project/.holbuild/obj/src/ATheory.uo"
require_grep "cv_primTheory" "$project/.holbuild/obj/src/ATheory.uo"
if grep -q "\.holbuild/stage" "$project/.holbuild/obj/src/ATheory.uo"; then
  echo "cache restore leaked transient stage path into generated theory load manifest" >&2
  exit 1
fi
if grep -q "\.holbuild/stage" "$project/.holbuild/obj/src/ATheory.sml"; then
  echo "cache restore leaked transient stage dat path into generated theory source" >&2
  exit 1
fi
if grep -q "numLib\|cv_transLib" "$project/.holbuild/obj/src/ATheory.uo"; then
  echo "cache restore leaked source-only Libs into generated theory load manifest" >&2
  exit 1
fi
