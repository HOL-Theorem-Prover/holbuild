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
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "checkpointinvalid"

[build]
members = ["src"]
TOML
cat > "$project/src/AScript.sml" <<'SML'
open HolKernel Parse boolLib bossLib;
val _ = new_theory "A";

Theorem first:
  T
Proof
  ACCEPT_TAC TRUTH
QED

val _ = export_theory();
SML

(cd "$project" && "$HOLBUILD_BIN" build ATheory)

metadata="$project/.holbuild/dep/checkpointinvalid/src/AScript.sml.key"
require_file "$metadata"
old_input_key=$(grep '^input_key=' "$metadata")
require_grep '^dependency_context_key=' "$metadata"
# checkpoints persist after successful builds for incremental rebuilds
if ! find "$project/.holbuild/checkpoints" -path '*/first_context.save' -print -quit 2>/dev/null | grep -q .; then
  echo "successful build should retain theorem context checkpoint" >&2
  exit 1
fi

# Plant invalid old-format checkpoints alongside valid new-format ones.
# These use v1 ok format and legacy paths that holbuild no longer queries.
context_path="$project/.holbuild/checkpoints/checkpointinvalid/src/AScript.sml.first_context.save"
end_path="$project/.holbuild/checkpoints/checkpointinvalid/src/AScript.sml.first_end_of_proof.save"
mkdir -p "$(dirname "$context_path")"
printf 'not a valid PolyML checkpoint
' > "$context_path"
printf 'holbuild-checkpoint-ok-v1
' > "$context_path.ok"
printf 'not a valid PolyML checkpoint
' > "$end_path"
printf 'holbuild-checkpoint-ok-v1
' > "$end_path.ok"

prefix_hash=$(python3 - <<PY
from pathlib import Path
src = Path("$project/src/AScript.sml").read_text()
end = src.index("QED") + len("QED")
Path("$tmpdir/prefix").write_text(src[:end])
PY
sha1sum "$tmpdir/prefix" | awk '{print $1}')
printf 'theorem_boundary first %s %s %s
' "$prefix_hash" "$context_path" "$end_path" >> "$metadata"

# Source edit after the first theorem: changes the action key but not the
# first theorem's prefix hash. With retained checkpoints, the rebuild can
# correctly resume from the first theorem context checkpoint.
printf '
(* source edit after first theorem invalidates the action key but not the theorem prefix *)
' >> "$project/src/AScript.sml"

rebuild_log=$tmpdir/rebuild.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$rebuild_log" 2>&1
new_input_key=$(grep '^input_key=' "$metadata")
[[ "$old_input_key" != "$new_input_key" ]] || { echo "source edit did not change input key" >&2; exit 1; }
# The rebuild should succeed; the planted old-format invalid checkpoints
# should not cause build failures or crashes.
if grep -q "goalfrag/checkpoint run failed" "$rebuild_log"; then
  echo "old-format invalid checkpoint files caused build failure" >&2
  exit 1
fi
require_file "$project/.holbuild/obj/src/ATheory.dat"

# Plant stale old-format checkpoints again and verify cache restore works.
printf 'stale checkpoint before cache restore
' > "$context_path"
printf 'holbuild-checkpoint-ok-v1
' > "$context_path.ok"
rm -rf "$project/.holbuild/gen" "$project/.holbuild/obj" "$project/.holbuild/dep"
cache_restore_log=$tmpdir/cache-restore.log
(cd "$project" && "$HOLBUILD_BIN" build ATheory) > "$cache_restore_log" 2>&1
require_file "$project/.holbuild/obj/src/ATheory.dat"
# Old-format checkpoint files should not prevent cache restore
