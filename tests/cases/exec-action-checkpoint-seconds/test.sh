#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# build --checkpoint-seconds N reaches a remote worker through one spec line,
# which a default build leaves out, and changes no key.

tmpdir=$(make_temp_dir)
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
use_case_cache "$tmpdir/cache"
# The suite saves every context; this case checks what the option does.
unset HOLBUILD_CHECKPOINT_EVERY_CONTEXT

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "ck"

[build]
members = ["src"]
TOML
# write_a TAIL: A proves two quick theorems, then runs TAIL.
write_a() {
  cat > "$project/src/AScript.sml" <<SML
Theory A
Ancestors bool

Theorem first_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem second_thm:
  T
Proof
  ACCEPT_TAC TRUTH
QED

val _ = $1;
SML
}

field() { awk -v want="$2" -v col="$3" '$1 == "action" && $5 == want { print $col }' "$1"; }

# export_a NAME [OPTION...]: A's spec into $tmpdir/batch-NAME.txt.
export_a() {
  local name=$1
  shift
  (cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload "$@" ATheory) \
    > "$tmpdir/batch-$name.txt"
  [[ -n "$(field "$tmpdir/batch-$name.txt" ck:ATheory 4)" ]] || { cat "$tmpdir/batch-$name.txt" >&2; exit 1; }
}

# worker CACHE NAME STATUS: exec-action of NAME's spec on cache root CACHE,
# sharing its heaps; it must end with STATUS.
worker() {
  local cache=$tmpdir/worker-$1 name=$2
  link_hol_toolchain_cache "$cache"
  HOLBUILD_CACHE=$cache "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action \
    "$(field "$tmpdir/batch-$name.txt" ck:ATheory 4)" --share-heaps \
    --cache-limit-gb 1000 --result "$tmpdir/$1-$name.result" > "$tmpdir/$1-$name.log" 2>&1 || true
  grep -qx "status=$3" "$tmpdir/$1-$name.result" || {
    echo "worker $1 on $name: wanted status=$3" >&2
    cat "$tmpdir/$1-$name.result" "$tmpdir/$1-$name.log" >&2
    exit 1
  }
}

write_a 'raise Fail "expected failure"'
export_a default
export_a every --checkpoint-seconds 0
specs=$project/.holbuild/action-specs
diff "$specs/$(field "$tmpdir/batch-default.txt" ck:ATheory 4)" \
     "$specs/$(field "$tmpdir/batch-every.txt" ck:ATheory 4)" > "$tmpdir/spec.diff" && {
  echo "the spec does not carry --checkpoint-seconds" >&2; exit 1; }
[[ "$(grep -c '^[<>]' "$tmpdir/spec.diff")" == 1 ]] && grep -qx '> option checkpoint-seconds=0.0' "$tmpdir/spec.diff" || {
  echo "--checkpoint-seconds changed more of the spec than its option:" >&2; cat "$tmpdir/spec.diff" >&2; exit 1; }
[[ "$(field "$tmpdir/batch-default.txt" ck:ATheory 3)" == "$(field "$tmpdir/batch-every.txt" ck:ATheory 3)" ]] || {
  echo "--checkpoint-seconds changed the action's input key" >&2; exit 1; }

# A spec value that isn't wholly a finite number >= 0 is rejected, as the
# flag's would be.
for bad in 2x inf 1e999 -1; do
  sed "s/^option checkpoint-seconds=0.0\$/option checkpoint-seconds=$bad/" \
    "$specs/$(field "$tmpdir/batch-every.txt" ck:ATheory 4)" > "$tmpdir/bad-spec"
  bad_sha=$(sha256sum "$tmpdir/bad-spec" | cut -d' ' -f1)
  curl -fsS -X PUT --data-binary "@$tmpdir/bad-spec" "$remote_url/cas/$bad_sha"
  link_hol_toolchain_cache "$tmpdir/worker-bad"
  if HOLBUILD_CACHE=$tmpdir/worker-bad "$HOLBUILD_BIN" --remote-cache "$remote_url" exec-action "$bad_sha" \
       --cache-limit-gb 1000 --result "$tmpdir/bad.result" > "$tmpdir/bad.log" 2>&1; then
    echo "a worker accepted checkpoint-seconds=$bad" >&2; exit 1
  fi
  require_grep "^failure=spec-rejected" "$tmpdir/bad.result"
  require_grep "malformed option checkpoint-seconds: $bad" "$tmpdir/bad.log"
  if (cd "$project" && "$HOLBUILD_BIN" build --checkpoint-seconds="$bad" ATheory) > "$tmpdir/bad-flag.log" 2>&1; then
    echo "build accepted --checkpoint-seconds=$bad" >&2; exit 1
  fi
  require_grep "checkpoint-seconds must be a non-negative number" "$tmpdir/bad-flag.log"
done

# The theorems take well under the default 2 s, so after a default failed run
# a fix resumes from the dependencies; after a run given 0, from the context
# after the last theorem.  The default run goes first, as the shared
# checkpoints of the other would serve it too, and each fix is its own action.
worker gated default failed
write_a '()'
export_a fixed-gated
worker gated fixed-gated built
require_grep "from: deps-loaded checkpoint" "$tmpdir/gated-fixed-gated.log"
worker every every failed
write_a 'print ""'
export_a fixed-every
worker every fixed-every built
require_grep "from: theorem-context checkpoint after second_thm" "$tmpdir/every-fixed-every.log"
