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
name = "external-key-test"

[build]
members = ["src"]
TOML
} > "$project/holproject.toml"
cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = load "pred_setLib";
val _ = new_theory "B";
val _ = export_theory();
SML

input_key() {
  (cd "$project" && "$HOLBUILD_BIN" build --dry-run BTheory) |
    awk '/input_key:/ {print $2; exit}'
}

key_v1=$(input_key)
if [[ -z "$key_v1" ]]; then
  echo "dry-run did not report an input_key" >&2
  exit 1
fi

if ! find "$HOLBUILD_CACHE/deps/external" -name '*.deps' -print -quit | grep -q .; then
  echo "external HOL source dependency extraction was not cached" >&2
  exit 1
fi

key_v2=$(input_key)
if [[ "$key_v2" != "$key_v1" ]]; then
  echo "external HOL key was not stable across repeated dry-runs" >&2
  exit 1
fi

(cd "$project" && "$HOLBUILD_BIN" build --dry-run BTheory) > "$tmpdir/dry.log"
require_grep "external libs: pred_setLib" "$tmpdir/dry.log"
