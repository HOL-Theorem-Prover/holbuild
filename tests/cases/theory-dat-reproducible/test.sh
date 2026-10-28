#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# Both builds must run from source, so neither may restore from or publish to a
# shared remote cache.
unset HOLBUILD_REMOTE_CACHE_URL

# Theory cache keys depend on sources, not on parent .dat outputs, so a cache
# entry is shared only if a deterministic theory script yields the same
# Theory.dat bytes wherever it is built.  Build the same chain from source in
# two project directories with separate artifact caches and compare the bytes.

tmpdir=$(make_temp_dir)
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

theories=(ATheory BTheory CTheory)

write_project() {
  local project=$1
  local a_extra=$2
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "theory-dat-reproducible"

[build]
members = ["src"]
TOML
  cat > "$project/src/AScript.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";
$a_extra
Datatype:
  colour = Red | Green | Blue
End

Definition next_def:
  next Red = Green /\\ next Green = Blue /\\ next Blue = Red
End

Theorem next_cycle:
  !c. next (next (next c)) = c
Proof
  Cases \\\\ simp[next_def]
QED

val _ = export_theory();
SML
  cat > "$project/src/BScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib ATheory;
val _ = new_theory "B";

Definition prev_def:
  prev c = next (next c)
End

Theorem prev_next:
  !c. prev (next c) = c
Proof
  simp[prev_def, next_cycle]
QED

val _ = export_theory();
SML
  cat > "$project/src/CScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib ATheory BTheory;
val _ = new_theory "C";

Theorem next_prev:
  !c. next (prev c) = c
Proof
  simp[prev_def, next_cycle]
QED

val _ = export_theory();
SML
}

# Builds the chain from source in a fresh project directory with its own
# artifact cache, then records each theory's input key from a dry run.
build_root() {
  local root=$1
  local a_extra=$2
  local project=$root/project
  write_project "$project" "$a_extra"
  link_hol_toolchain_cache "$root/cache"
  (cd "$project" && HOLBUILD_CACHE="$root/cache" "$HOLBUILD_BIN" build CTheory) > "$root/build.log" 2>&1
  for theory in "${theories[@]}"; do
    require_grep "$theory built" "$root/build.log"
  done
  (cd "$project" && HOLBUILD_CACHE="$root/cache" "$HOLBUILD_BIN" build --dry-run CTheory) > "$root/dry-run.log" 2>&1
  awk '/^[A-Za-z0-9_]+ \(theory,/ {name = $1} /^  input_key:/ {print name, $2}' \
    "$root/dry-run.log" > "$root/input-keys"
  [[ $(wc -l < "$root/input-keys") -eq ${#theories[@]} ]] || {
    echo "expected ${#theories[@]} input keys in $root/dry-run.log" >&2
    cat "$root/dry-run.log" >&2
    exit 1
  }
}

# Prints one line per theory whose input key or .dat bytes differ between the
# two roots; prints nothing when the builds are reproducible.
compare_roots() {
  local first=$1
  local second=$2
  if ! cmp -s "$first/input-keys" "$second/input-keys"; then
    echo "input keys differ: $(diff "$first/input-keys" "$second/input-keys" | grep '^[<>]' | tr '\n' ' ')"
  fi
  for theory in "${theories[@]}"; do
    cmp -s "$first/project/.holbuild/obj/src/$theory.dat" \
      "$second/project/.holbuild/obj/src/$theory.dat" ||
      echo "$theory.dat differs"
  done
}

# The second root's path is longer, so any absolute path that reaches a .dat
# or an input key shows up as a difference.
first=$tmpdir/a
second=$tmpdir/a-second-root-with-a-much-longer-path
build_root "$first" ""
build_root "$second" ""
differences=$(compare_roots "$first" "$second")
if [[ -n "$differences" ]]; then
  echo "theory builds are not reproducible across roots:" >&2
  echo "$differences" >&2
  exit 1
fi

# The comparison must catch a script that is not deterministic: a constant
# named after the build time gives every build of ATheory different .dat
# bytes under the same input key.
nondet_a='val _ = new_constant ("c" ^ LargeInt.toString (Time.toMicroseconds (Time.now ())), bool);'
nondet_first=$tmpdir/nondet
nondet_second=$tmpdir/nondet-second-root-with-a-much-longer-path
build_root "$nondet_first" "$nondet_a"
build_root "$nondet_second" "$nondet_a"
nondet_differences=$(compare_roots "$nondet_first" "$nondet_second")
if ! grep -qx "ATheory.dat differs" <<< "$nondet_differences" ||
   grep -q "input keys differ" <<< "$nondet_differences"; then
  echo "comparison did not report exactly a .dat difference for the time-dependent ATheory:" >&2
  echo "${nondet_differences:-(no differences)}" >&2
  exit 1
fi
