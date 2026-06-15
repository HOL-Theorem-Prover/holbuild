#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
_HOLDIR=$2
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
name = "runtime-hygiene-test"

[build]
members = ["src"]
TOML
} > "$project/holproject.toml"

cat > "$project/src/HygieneScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "Hygiene";
val hygiene_thm = store_thm("hygiene_thm", ``T``, simp[]);
val _ = export_theory();

val load = fn _ => raise Fail "shadowed load";
val use = fn _ => raise Fail "shadowed use";
val print = fn _ => raise Fail "shadowed print";
val length = fn _ => 0;
SML

(cd "$project" && "$HOLBUILD_BIN" build HygieneTheory) > "$tmpdir/build.log" 2>&1
