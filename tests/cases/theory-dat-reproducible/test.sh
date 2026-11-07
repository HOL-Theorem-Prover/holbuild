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
  (cd "$project" && HOLBUILD_CACHE="$root/cache" "$HOLBUILD_BIN" build CTheory) > "$root/build.log" 2>&1 || { cat "$root/build.log" >&2; exit 1; }
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
    cmp -s "$first/project/.holbuild/obj/src/$theory.sml" \
      "$second/project/.holbuild/obj/src/$theory.sml" ||
      echo "$theory.sml differs"
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

# Load independent parents in opposite orders while keeping the sources and
# action keys identical. Explicit deps order the build without preloading them.
write_parent_order_project() {
  local project=$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "parent-order"
[build]
members = ["src"]
[actions.CTheory]
deps = ["ATheory", "BTheory"]
TOML
  for name in A B; do
    cat > "$project/src/${name}Script.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "$name";
val _ = new_constant ("${name}_constant", bool);
val _ = export_theory ();
SML
  done
  cat > "$project/src/CScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val names = ["A", "B"];
val ordered = if OS.Process.getEnv "HOLBUILD_TEST_PARENT_ORDER" = SOME "reverse"
              then rev names else names;
val _ = List.app (fn name => load (name ^ "Theory")) ordered;
val _ = new_theory "C";
val _ = export_theory ();
SML
}

for order in forward reverse; do
  root=$tmpdir/parent-order-$order
  write_parent_order_project "$root/project"
  link_hol_toolchain_cache "$root/cache"
  (cd "$root/project" && HOLBUILD_CACHE="$root/cache" HOLBUILD_TEST_PARENT_ORDER="$order" \
    "$HOLBUILD_BIN" build CTheory) > "$root/build.log" 2>&1 || { cat "$root/build.log" >&2; exit 1; }
  for theory in "${theories[@]}"; do
    require_grep "$theory built" "$root/build.log"
  done
  (cd "$root/project" && HOLBUILD_CACHE="$root/cache" "$HOLBUILD_BIN" build --dry-run CTheory) > "$root/dry-run.log" 2>&1
  awk '/^[A-Za-z0-9_]+ \(theory,/ {name = $1} /^  input_key:/ {print name, $2}' \
    "$root/dry-run.log" > "$root/input-keys"
done
differences=$(compare_roots "$tmpdir/parent-order-forward" "$tmpdir/parent-order-reverse")
if [[ -n "$differences" ]]; then
  echo "theory exports depend on parent load order:" >&2
  echo "$differences" >&2
  exit 1
fi

# A theory's cache key covers its inputs, not its outputs, so holbuild must
# never change what a theory exports without bumping theory_manifest_version
# (sml/build_exec.sml): entries from before and after would share keys.  The
# golden file pins one fixture's outputs per HOL revision and version.
write_golden_project() {
  local project=$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "theory-golden"
[build]
members = ["src"]
[actions.GoldenTheory]
deps = ["ZetaTheory", "AlphaTheory"]
TOML
  for name in Zeta Alpha; do
    lower=$(tr '[:upper:]' '[:lower:]' <<< "$name")
    cat > "$project/src/${name}Script.sml" <<SML
open HolKernel Parse boolLib bossLib;
val _ = new_theory "$name";

Definition ${lower}_def:
  $lower = T
End

val _ = export_theory ();
SML
  done
  cat > "$project/src/GoldenScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = List.app (fn name => load (name ^ "Theory")) ["Zeta", "Alpha"];
val _ = new_theory "Golden";

Definition both_def:
  both = (zeta /\ alpha)
End

Theorem both_thm:
  both
Proof
  simp[both_def, ZetaTheory.zeta_def, AlphaTheory.alpha_def]
QED

val _ = export_theory ();
SML
}

golden_root=$tmpdir/golden
write_golden_project "$golden_root/project"
link_hol_toolchain_cache "$golden_root/cache"
(cd "$golden_root/project" && HOLBUILD_CACHE="$golden_root/cache" "$HOLBUILD_BIN" build GoldenTheory) \
  > "$golden_root/build.log" 2>&1 || { cat "$golden_root/build.log" >&2; exit 1; }
manifest_version=$(sed -n 's/^val theory_manifest_version = "\(.*\)"$/\1/p' "$HOLBUILD_ROOT/sml/build_exec.sml")
[[ -n "$manifest_version" ]] || { echo "theory_manifest_version not found in sml/build_exec.sml" >&2; exit 1; }
hol_rev=$(holbuild_pinned_hol_rev)
if [[ "$hol_rev" != "$(tr -d '[:space:]' < "$HOLBUILD_ROOT/vendor/hol/REV")" ]]; then
  echo "skipping golden outputs: HOL $hol_rev is not vendor/hol/REV"
  exit 0
fi
obj=$golden_root/project/.holbuild/obj/src
prefix="hol=$hol_rev version=$manifest_version"
actual=$prefix
for suffix in sig sml dat; do
  actual+=" $suffix=$(sha256sum "$obj/GoldenTheory.$suffix" | cut -d' ' -f1)"
done
golden_file=$SCRIPT_DIR/golden-outputs
expected=$(grep "^$prefix " "$golden_file" || true)
if [[ $(grep -c . <<< "$expected") -gt 1 ]]; then
  echo "$golden_file has more than one line for $prefix; outputs changed without a theory_manifest_version bump" >&2
  exit 1
fi
if [[ -z "$expected" ]]; then
  echo "$golden_file has no line for $prefix; add:" >&2
  echo "  $actual" >&2
  exit 1
fi
if [[ "$expected" != "$actual" ]]; then
  echo "holbuild changed GoldenTheory's outputs: bump theory_manifest_version and add a line for the new version" >&2
  echo "  expected: $expected" >&2
  echo "  actual:   $actual" >&2
  exit 1
fi
