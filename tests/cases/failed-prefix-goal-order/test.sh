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

# A failed-prefix resume inside a `>|` or `>>` block must leave the block's
# subgoals in the same order as a clean run: the subgoals of branches that
# finished before the checkpoint come first.
check_goal_order() {
  local name=$1 block=$2 frame_pattern=$3
  local project=$tmpdir/$name marker=$tmpdir/$name-ready
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "$name"

[build]
members = ["src"]
TOML

  cat > "$project/src/AScript.sml" <<SML
Theory A

(* Fails on the goal 3 = 3 until the marker exists. *)
fun fail_on_3_once (asl, goal) =
  if aconv goal \`\`3 = 3\`\` andalso not (OS.FileSys.access ("$marker", [])) then
    (TextIO.closeOut (TextIO.openOut "$marker"); raise Fail "seed failure on 3 = 3")
  else ALL_TAC (asl, goal);

Theorem goal_order:
  (1 = 1 /\\ 2 = 2) /\\ (3 = 3 /\\ 4 = 4)
Proof
  $block
  >- ACCEPT_TAC (REFL \`\`1\`\`)
  >- ACCEPT_TAC (REFL \`\`2\`\`)
  >- ACCEPT_TAC (REFL \`\`3\`\`)
  >- ACCEPT_TAC (REFL \`\`4\`\`)
QED
SML

  local seed_log=$tmpdir/$name-seed.log
  if (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$seed_log" 2>&1; then
    echo "$name: expected the seed build to fail" >&2
    exit 1
  fi
  require_grep "seed failure on 3 = 3" "$seed_log"
  local checkpoint
  checkpoint=$(find "$project/.holbuild/checkpoints" -name 'goal_order_failed_prefix.save' -print -quit)
  require_file "$checkpoint"
  # The checkpoint is inside the block, after an earlier branch left two subgoals.
  require_grep "$frame_pattern" "$checkpoint.meta"

  local resume_log=$tmpdir/$name-resume.log
  if ! (cd "$project" && "$HOLBUILD_BIN" build ATheory) >"$resume_log" 2>&1; then
    cat "$resume_log" >&2
    echo "$name: resumed build failed" >&2
    exit 1
  fi
  require_grep "from: failed-prefix checkpoint in goal_order" "$resume_log"
  if grep -q "discarding failed-prefix checkpoint" "$resume_log"; then
    cat "$resume_log" >&2
    echo "$name: resume left the subgoals in a different order than a clean run" >&2
    exit 1
  fi
}

# The failure is in case 2, after case 1 left two subgoals.
check_goal_order cases '(CONJ_TAC >| [CONJ_TAC, CONJ_TAC >> fail_on_3_once])' \
  $'^frame=case\t.*\t2\t1\t2$'
# The failure is in the second goal of the `>>`, after the first left two
# subgoals.  The TRY makes the parenthesized suffix a per-goal block.
check_goal_order each '(CONJ_TAC >> (CONJ_TAC >> fail_on_3_once >> TRY ALL_TAC))' \
  $'^frame=each\t.*\t1\t1\t2$'
