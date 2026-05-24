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
export HOLBUILD_CACHE="$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<'TOML'
[project]
name = "loadmods"

[build]
members = ["src"]

[actions.Baz]
deps = ["Foo"]
loads = ["numLib"]

[run]
loads = ["ATheory"]
TOML
cat > "$project/src/Foo.sig" <<'SML'
signature FOO = sig
  val value : bool
end
SML
cat > "$project/src/Foo.sml" <<'SML'
structure Foo : FOO = struct
  val value = true
end
SML
cat > "$project/src/Bar.sml" <<'SML'
load "Foo";

structure Bar = struct
  val witness = Foo.value
end
SML
cat > "$project/src/Baz.sml" <<'SML'
structure Baz = struct
  val witness = Foo.value
  val reduce = numLib.REDUCE_CONV
end
SML
cat > "$project/src/Quux.sml" <<'SML'
open Foo numLib;

structure Quux = struct
  val witness = value
  val reduce = REDUCE_CONV
end
SML
cat > "$project/src/RawLoad.sml" <<'SML'
load "numLib";

structure RawLoad = struct
  val reduce = numLib.REDUCE_CONV
end
SML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;

load "Bar";
load "Baz";
load "Quux";
load "RawLoad";
val _ = if Bar.witness then () else raise Fail "Bar did not load Foo";
val _ = if Baz.witness then () else raise Fail "Baz did not load declared dep Foo";
val _ = if Quux.witness then () else raise Fail "Quux did not load Holdep-inferred Foo";
val _ = RawLoad.reduce ``1 + 1``;

val _ = new_theory "A";
val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);
val _ = export_theory();
SML

dry_log=$tmpdir/dry.log
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build --dry-run ATheory) > "$dry_log"
require_grep "Foo (sig" "$dry_log"
require_grep "Foo (sml" "$dry_log"
require_grep "Bar (sml" "$dry_log"
require_grep "Baz (sml" "$dry_log"
require_grep "Quux (sml" "$dry_log"
require_grep "RawLoad (sml" "$dry_log"
require_grep "ATheory" "$dry_log"

(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" build ATheory)
require_file "$project/.holbuild/obj/src/Foo.ui"
require_file "$project/.holbuild/obj/src/Foo.uo"
require_file "$project/.holbuild/obj/src/Bar.uo"
require_file "$project/.holbuild/obj/src/Baz.uo"
require_file "$project/.holbuild/obj/src/Quux.uo"
require_file "$project/.holbuild/obj/src/RawLoad.uo"
require_file "$project/.holbuild/obj/src/ATheory.sml"
require_file "$project/.holbuild/obj/src/ATheory.dat"

require_grep ".holbuild/obj/src/Foo" "$project/.holbuild/obj/src/Bar.uo"
require_grep ".holbuild/obj/src/Foo" "$project/.holbuild/obj/src/Baz.uo"
require_grep "numLib" "$project/.holbuild/obj/src/Baz.uo"
require_grep ".holbuild/obj/src/Foo" "$project/.holbuild/obj/src/Quux.uo"
require_grep "numLib" "$project/.holbuild/obj/src/Quux.uo"
require_grep "numLib" "$project/.holbuild/obj/src/RawLoad.uo"
require_grep ".holbuild/obj/src/Bar" "$project/.holbuild/obj/src/AScript.uo"
require_grep ".holbuild/obj/src/Baz" "$project/.holbuild/obj/src/AScript.uo"
require_grep ".holbuild/obj/src/Quux" "$project/.holbuild/obj/src/AScript.uo"
require_grep ".holbuild/obj/src/RawLoad" "$project/.holbuild/obj/src/AScript.uo"
if grep -q ".holbuild/obj/src/Bar\|.holbuild/obj/src/Baz\|.holbuild/obj/src/Quux\|.holbuild/obj/src/RawLoad" "$project/.holbuild/obj/src/ATheory.uo"; then
  echo "source-only project loads leaked into generated theory load manifest" >&2
  exit 1
fi

cat > "$tmpdir/load-internal-theory.sml" <<'SML'
val _ = ATheory.a_thm;
SML
(cd "$project" && "$HOLBUILD_BIN" --holdir "$HOLDIR" run "$tmpdir/load-internal-theory.sml") > "$tmpdir/load-internal-theory.log" 2>&1

second_log=$tmpdir/second.log
(cd "$project" && "$HOLBUILD_BIN" --verbose --holdir "$HOLDIR" build ATheory) > "$second_log"
require_grep "ATheory is up to date" "$second_log"
