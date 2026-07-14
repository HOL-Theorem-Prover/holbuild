#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOLBUILD_BIN=${HOLBUILD_BIN:-"$ROOT/bin/holbuild"}
export HOLBUILD_ROOT="$ROOT"
export HOLBUILD_TEST_GLOBAL_CACHE="${HOLBUILD_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/holbuild}"
GOLDEN_TMPDIR=

cleanup() {
  if [[ -n "${GOLDEN_TMPDIR:-}" ]]; then
    rm -rf "$GOLDEN_TMPDIR"
  fi
}
trap cleanup EXIT

# shellcheck source=lib.sh
source "$ROOT/tests/lib.sh"

usage() {
  cat >&2 <<'USAGE'
usage:
  tests/golden-key-dump.sh capture OUT_DIR
  tests/golden-key-dump.sh diff BASELINE_DIR NEW_DIR

Environment:
  HOLBUILD_BIN       holbuild binary to run (default: ./bin/holbuild)
USAGE
  exit 2
}

write_fixture() {
  local project=$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "key-dump-fixture"

[build]
members = ["src"]
TOML
  cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;

val _ = new_theory "A";

val a_thm = store_thm("a_thm", ``T``, ACCEPT_TAC TRUTH);

val _ = export_theory();
SML
  cat > "$project/src/Util.sml" <<'SML'
structure Util = struct val n = 1 end
SML
}

capture_project() {
  local project=$1
  local dump=$2
  shift 2
  mkdir -p "$(dirname "$dump")"
  (cd "$project" && HOLBUILD_DUMP_KEYS="$dump" "$HOLBUILD_BIN" -j1 build "$@") >/dev/null
}

capture_all() {
  local out_dir=$1
  local tmpdir
  mkdir -p "$out_dir"
  out_dir=$(cd "$out_dir" && pwd)
  GOLDEN_TMPDIR=$(make_temp_dir)
  tmpdir=$GOLDEN_TMPDIR
  use_case_cache "$tmpdir/cache"

  write_fixture "$tmpdir/fixture"
  capture_project "$tmpdir/fixture" "$out_dir/fixture.keys"

}

diff_file_if_present() {
  local baseline=$1
  local candidate=$2
  if [[ -f "$baseline" && -f "$candidate" ]]; then
    diff -u -a "$baseline" "$candidate"
  elif [[ -f "$baseline" || -f "$candidate" ]]; then
    printf 'dump presence differs: %s vs %s\n' "$baseline" "$candidate" >&2
    return 1
  fi
}

diff_all() {
  local baseline_dir=$1
  local new_dir=$2
  diff_file_if_present "$baseline_dir/fixture.keys" "$new_dir/fixture.keys"
}

case "${1:-}" in
  capture)
    [[ $# -eq 2 ]] || usage
    capture_all "$2"
    ;;
  diff)
    [[ $# -eq 3 ]] || usage
    diff_all "$2" "$3"
    ;;
  *)
    usage
    ;;
esac
