#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"

project=$tmpdir/project
fresh=$tmpdir/fresh
mkdir -p "$project/src" "$fresh/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)

[project]
name = "checkpoint-original-source"

[build]
members = ["src"]

[actions.SourceReaderTheory]
cache = false
TOML
cp "$project/holproject.toml" "$fresh/holproject.toml"

counter=$tmpdir/prefix-runs
source_file=$project/src/SourceReaderScript.sml
write_source() {
  cat > "$source_file" <<SML
Theory SourceReader

Theorem earlier:
  T
Proof
  simp[]
QED

fun counted_conj_tac goal =
  let val out = TextIO.openAppend "$counter"
  in TextIO.output (out, "x"); TextIO.closeOut out; CONJ_TAC goal end

Theorem resume_here:
  T /\\ T
Proof
  counted_conj_tac >> $1
QED

val () =
  let
    val input = TextIO.openIn "SourceReaderScript.sml"
    val source = TextIO.inputAll input before TextIO.closeIn input
  in
    if String.isPrefix ("Theory SourceReader\\n\\nTheorem " ^ "earlier:\\n") source then ()
    else raise Fail "did not read the original theory source${2:-}"
  end
SML
}

build() {
  (cd "$1" && "$HOLBUILD_BIN" -j1 build SourceReaderTheory) > "$2" 2>&1 || {
    cat "$2" >&2
    return 1
  }
}

write_source 'FAIL_TAC "seed failed prefix"'
seed_log=$tmpdir/seed.log
if (cd "$project" && "$HOLBUILD_BIN" -j1 build SourceReaderTheory) > "$seed_log" 2>&1; then
  echo "expected seed proof to fail" >&2
  exit 1
fi
require_grep 'seed failed prefix' "$seed_log"
require_file "$(find "$project/.holbuild/checkpoints" -name 'resume_here_failed_prefix.save' -print -quit)"
cmp "$counter" <(printf x)

write_source 'simp[]'
cp "$source_file" "$fresh/src/SourceReaderScript.sml"
resume_log=$tmpdir/resumed.log
build "$project" "$resume_log"
require_grep 'from: failed-prefix checkpoint in resume_here' "$resume_log"
require_grep 'restoring proof-ir prefix with 1 successful leaf steps' "$resume_log"
require_grep 'SourceReaderTheory built' "$resume_log"
cmp "$counter" <(printf x)

use_case_cache "$tmpdir/fresh-cache"
fresh_log=$tmpdir/fresh.log
build "$fresh" "$fresh_log"
require_grep 'SourceReaderTheory built' "$fresh_log"
cmp "$counter" <(printf xx)
if grep -q '^resuming SourceReaderTheory' "$fresh_log"; then
  echo "expected the fresh build to run without a checkpoint" >&2
  exit 1
fi

# Editing only after the proofs lets the next run resume a theorem context.
source_file=$fresh/src/SourceReaderScript.sml
write_source 'simp[]' ' after a theorem-context resume'
context_log=$tmpdir/context.log
build "$fresh" "$context_log"
require_grep 'from: theorem-context checkpoint after resume_here' "$context_log"
require_grep 'SourceReaderTheory built' "$context_log"
cmp "$counter" <(printf xx)
