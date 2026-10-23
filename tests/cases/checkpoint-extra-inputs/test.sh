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

# Each theory defines input_flag from an extra input it reads while running.
# After an input-only edit, no checkpoint saved from the old bytes may be
# resumed: the rebuilt theory must define input_flag from the new bytes.
project=$tmpdir/project
mkdir -p "$project/src" "$project/data"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2
minimum_version = "0.10.0"

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "checkpoint-extra-inputs"

[build]
members = ["src"]

[actions.ManifestCtxTheory]
extra_inputs = ["data/manifest_ctx.txt"]
TOML

# Source-declared input, read through the copy staged next to the build.
source_input_prelude() {
  local name=$1
  cat <<SML
fun holbuild_extra_deps (_ : string list) = ()
val _ = holbuild_extra_deps ["../data/$name.txt"]
val input_path = "../data/$name.txt"
SML
}

input_flag_sml() {
  cat <<'SML'
val stream = TextIO.openIn input_path
val contents = TextIO.inputAll stream before TextIO.closeIn stream
val flag = if String.isPrefix "one" contents then ``T`` else ``F``
val input_flag_def = Define `input_flag = ^flag`
val _ = print ("INPUT_FLAG: " ^ term_to_string (concl input_flag_def) ^ "\n")
SML
}

marker_theorem='Theorem checkpoint_marker:
  T
Proof
  ACCEPT_TAC TRUTH
QED'

{
  echo "Theory SourceCtx"
  source_input_prelude source_ctx
  input_flag_sml
  printf '\n%s\n' "$marker_theorem"
} > "$project/src/SourceCtxScript.sml"

{
  echo "Theory ManifestCtx"
  printf 'val input_path = "%s"\n' "$project/data/manifest_ctx.txt"
  input_flag_sml
  printf '\n%s\n' "$marker_theorem"
} > "$project/src/ManifestCtxScript.sml"

{
  echo "Theory SourceDecl"
  source_input_prelude source_decl
  input_flag_sml
  cat <<'SML'

Definition down_def:
  down n = if n = 0 then 0 else down (n - 1)
Termination
  WF_REL_TAC `measure I` >> simp[]
End
SML
} > "$project/src/SourceDeclScript.sml"

# With input "one" the proof fails after its first step, leaving a
# failed-prefix checkpoint; with input "two" the same proof succeeds.
{
  echo "Theory SourceFailed"
  source_input_prelude source_failed
  input_flag_sml
  cat <<'SML'

Theorem flag_thm:
  ~input_flag
Proof
  REWRITE_TAC [input_flag_def] >> FAIL_TAC "expected input flag failure"
QED
SML
} > "$project/src/SourceFailedScript.sml"

for name in source_ctx manifest_ctx source_decl source_failed; do
  printf 'one\n' > "$project/data/$name.txt"
done

build() {
  local theory=$1
  local log=$2
  (cd "$project" && "$HOLBUILD_BIN" -j1 build "$theory" --no-cache) > "$log" 2>&1
}

child_log() {
  printf '%s\n' "$project/.holbuild/logs/current/checkpoint-extra-inputs/$1/build.log"
}

require_flag() {
  local theory=$1
  local value=$2
  require_grep "INPUT_FLAG: input_flag ⇔ $value" "$(child_log "$theory")"
}

require_no_resume_from() {
  local kind=$1
  local log=$2
  if grep -q "from: $kind checkpoint" "$log"; then
    echo "input-only edit resumed a $kind checkpoint saved from the old input:" >&2
    cat "$log" >&2
    exit 1
  fi
}

# Theorem-context checkpoints, for source-declared and manifest inputs.
for theory in SourceCtxTheory ManifestCtxTheory; do
  case $theory in
    SourceCtxTheory) input=source_ctx ;;
    ManifestCtxTheory) input=manifest_ctx ;;
  esac
  build "$theory" "$tmpdir/$theory-one.log"
  require_flag "$theory" T
  printf 'two\n' > "$project/data/$input.txt"
  build "$theory" "$tmpdir/$theory-two.log"
  require_no_resume_from theorem-context "$tmpdir/$theory-two.log"
  require_flag "$theory" F
done

# A source edit after the last checkpoint, with unchanged inputs, still
# resumes the checkpoint saved under the current input.
printf '\n(* suffix edit *)\n' >> "$project/src/SourceCtxScript.sml"
build SourceCtxTheory "$tmpdir/SourceCtxTheory-suffix.log"
require_grep "from: theorem-context checkpoint after checkpoint_marker" "$tmpdir/SourceCtxTheory-suffix.log"
require_grep "SourceCtxTheory built" "$tmpdir/SourceCtxTheory-suffix.log"

# Definition-context checkpoints, after a termination proof.
build SourceDeclTheory "$tmpdir/SourceDeclTheory-one.log"
require_flag SourceDeclTheory T
if ! find "$project/.holbuild/checkpoints" -path '*.decls/*/down_def_context.save' -print -quit | grep -q .; then
  echo "missing definition-context checkpoint for down_def" >&2
  exit 1
fi
printf 'two\n' > "$project/data/source_decl.txt"
build SourceDeclTheory "$tmpdir/SourceDeclTheory-two.log"
require_no_resume_from definition-context "$tmpdir/SourceDeclTheory-two.log"
require_flag SourceDeclTheory F

# Failed-prefix checkpoints.  An unchanged rerun resumes the failed prefix;
# after the input edit the proof must run against the new definition.
if build SourceFailedTheory "$tmpdir/SourceFailedTheory-one.log"; then
  echo "expected flag_thm to fail with input one" >&2
  exit 1
fi
require_grep "expected input flag failure" "$tmpdir/SourceFailedTheory-one.log"
if build SourceFailedTheory "$tmpdir/SourceFailedTheory-rerun.log"; then
  echo "expected flag_thm to fail again with input one" >&2
  exit 1
fi
require_grep "from: failed-prefix checkpoint in flag_thm" "$tmpdir/SourceFailedTheory-rerun.log"
printf 'two\n' > "$project/data/source_failed.txt"
if ! build SourceFailedTheory "$tmpdir/SourceFailedTheory-two.log"; then
  echo "flag_thm should hold after the input edit:" >&2
  cat "$tmpdir/SourceFailedTheory-two.log" >&2
  exit 1
fi
require_no_resume_from failed-prefix "$tmpdir/SourceFailedTheory-two.log"
require_flag SourceFailedTheory F
