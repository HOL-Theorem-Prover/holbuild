#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# A failed-prefix resume salvages the prefix the edited proof still shares
# by hashing one leaf's dependency prefix, falling back to checking leaf by
# leaf.  With HOLBUILD_CHECK_SALVAGE=1 (tests/run.sh sets it) every salvage
# is also checked leaf by leaf and a disagreement fails the build.  Each
# proof below is edited inside a structural combinator, once keeping every
# later leaf where it was and once moving them; the edited leaf ends the
# cheap checks, so the hash is taken at the leaf before it, an unchanged
# leaf inside the same combinator.  An edit outside
# every leaf (a selector) leaves all leaves passing the cheap checks: the
# hash then misses and the leaf-by-leaf check finds the prefix.
export HOLBUILD_CHECK_SALVAGE=1

tmpdir=$(make_temp_dir)
cleanup() { cleanup_temp_dir "$tmpdir"; }
trap cleanup EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "failed-prefix-salvage-oracle"

[build]
members = ["src"]
TOML

# Each proof has @@ where the edit goes.
declare -A proofs=(
  [select]='CONJ_TAC >>~- ([`F`], ALL_TAC >> @@ >> ALL_TAC >> FAIL_TAC "oracle failure")'
  [each]='CONJ_TAC >> (ALL_TAC >> @@ >> ALL_TAC >> (fn g => ALL_TAC g)) >> FAIL_TAC "oracle failure"'
  [cases]='CONJ_TAC >| [ALL_TAC >> @@ >> ALL_TAC, ALL_TAC] >> ALL_TAC >> FAIL_TAC "oracle failure"'
  [choice]='(NO_TAC ORELSE (ALL_TAC >> @@)) >> ALL_TAC >> FAIL_TAC "oracle failure"'
  [try]='TRY (ALL_TAC >> @@ >> ALL_TAC) >> ALL_TAC >> FAIL_TAC "oracle failure"'
  [repeat]='rpt (CONJ_TAC >> ALL_TAC >> @@) >> ALL_TAC >> FAIL_TAC "oracle failure"'
)

child_log=$project/.holbuild/logs/current/failed-prefix-salvage-oracle/ATheory/instrumented-failure.log
# Where the salvaged prefix ends (resbyten): just past the unchanged leaf
# before the edit, nested in the combinator, so the hash taken there is
# that of a nested path.  An `rpt` body runs as one leaf, which the edit
# changes, so nothing of it is kept.
declare -A kept_end=([select]=29 [each]=20 [cases]=20 [choice]=23 [try]=12 [repeat]=0)
for construct in select each cases choice try repeat; do
  name=salvage_$construct
  for edit in "(ALL_TAC)" "I ALL_TAC" "(ALL_TAC : tactic)"; do
    proof=${proofs[$construct]//@@/$edit}
    cat > "$project/src/AScript.sml" <<SML
Theory A

Theorem $name:
  T /\\ F /\\ T
Proof
  $proof
QED
SML
    log=$tmpdir/$construct-${#edit}.log
    if (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$log" 2>&1; then
      cat "$log" >&2
      echo "expected $name to fail with $edit" >&2
      exit 1
    fi
    if grep -q "salvage disagrees" "$log"; then
      cat "$log" >&2
      echo "$name: single-hash salvage disagrees with the leaf-by-leaf check after editing to $edit" >&2
      exit 1
    fi
    require_grep "oracle failure" "$log"
    if [[ "$edit" != "(ALL_TAC)" ]]; then
      require_grep "from: failed-prefix checkpoint in $name" "$log"
      kept=$(grep '^holbuild hol-phases' "$child_log" | tail -n 1 | sed -n 's/.* resbyten=\([0-9]*\).*/\1/p')
      if [[ "$kept" != "${kept_end[$construct]}" ]]; then
        grep '^holbuild hol-phases' "$child_log" >&2 || true
        echo "$name: expected the salvage to keep the prefix through offset ${kept_end[$construct]}, got '$kept'" >&2
        exit 1
      fi
    fi
  done
done

# Changing the selector keeps every leaf's span and program, so the scan
# passes all three leaves; the third leaf's dependency prefix holds the
# selector, so its hash misses and the leaf-by-leaf check keeps two.
write_selector() {
  cat > "$project/src/AScript.sml" <<SML
Theory A

Theorem salvage_selector:
  T /\\ F
Proof
  ALL_TAC >> CONJ_TAC >>~- ([\`$1\`], ALL_TAC >> FAIL_TAC "oracle failure")
QED
SML
}
for selected in T F; do
  write_selector "$selected"
  log=$tmpdir/selector-$selected.log
  if (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$log" 2>&1; then
    cat "$log" >&2
    echo "expected salvage_selector to fail selecting $selected" >&2
    exit 1
  fi
  if grep -q "salvage disagrees" "$log"; then
    cat "$log" >&2
    echo "salvage_selector: single-hash salvage disagrees with the leaf-by-leaf check" >&2
    exit 1
  fi
  require_grep "oracle failure" "$log"
done
require_grep "from: failed-prefix checkpoint in salvage_selector" "$tmpdir/selector-F.log"
require_file "$child_log"
rewound=$(grep '^holbuild hol-phases' "$child_log" | tail -n 1 | sed -n 's/.* holrewoundn=\([0-9]*\).*/\1/p')
if [[ "$rewound" != 1 ]]; then
  grep '^holbuild hol-phases' "$child_log" >&2 || true
  echo "salvage_selector: expected the leaf-by-leaf check to rewind 1 of 3 leaves, got '$rewound'" >&2
  exit 1
fi

# A leaf saved without a prefix signature ends the salvage before it, on
# both paths.  Metadata with one is refused when parsed, so this calls the
# salvage on a plan and leaves built by hand.  The theorem makes the build
# load the proof runtime.
cat > "$project/src/AScript.sml" <<'SML'
Theory A

Theorem loads_runtime:
  T
Proof
  ACCEPT_TAC TRUTH
QED

val plan =
  [HolbuildProofIr.StepTactic {start_pos = 0, end_pos = 7, label = "a", program = "ALL_TAC"},
   HolbuildProofIr.StepTactic {start_pos = 11, end_pos = 18, label = "b", program = "ALL_TAC"},
   HolbuildProofIr.StepTactic {start_pos = 22, end_pos = 29, label = "c", program = "ALL_TAC"}];
fun leaf count signed : HolbuildProofRuntime.leaf_snapshot =
  let val path = [HolbuildProofIr.PathStep (count - 1)]
  in
    {count = count, prefix_end = 11 * count - 4, path = path, focus = [], frames = [], events = [],
     sig_text = ("step", "ALL_TAC"),
     prefix_signature =
       if signed then Option.map HolbuildSha256.string_hex (HolbuildProofIr.canonical_dependency_prefix plan path)
       else NONE,
     history_count = count}
  end;
fun steps leaves = #step_count (HolbuildProofRuntime.salvage_failed_prefix_leaves plan leaves);
val _ = if steps [leaf 1 true, leaf 2 true, leaf 3 true] = 3 then ()
        else raise Fail "salvage of three signed leaves";
val _ = if steps [leaf 1 true, leaf 2 false, leaf 3 true] = 1 then ()
        else raise Fail "salvage past an unsigned leaf";
val _ = if steps [leaf 1 false, leaf 2 true, leaf 3 true] = 0 then ()
        else raise Fail "salvage past an unsigned first leaf";
SML
if ! (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$tmpdir/unsigned.log" 2>&1; then
  cat "$tmpdir/unsigned.log" >&2
  echo "unsigned-leaf salvage checks failed" >&2
  exit 1
fi
