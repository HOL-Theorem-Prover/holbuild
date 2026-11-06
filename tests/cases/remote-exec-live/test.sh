#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

# run --remote-exec --remote-only against a real coordinator and the remote
# cache its workers use: a run of theories no cache holds builds nothing
# locally. Credentials come from HOLBUILD_REMOTE_EXEC_CURL_CONFIG and
# HOLBUILD_REMOTE_CACHE_CURL_CONFIG, as for any build.

if [[ -z "${HOLBUILD_TEST_REMOTE_EXEC_URL:-}" || -z "${HOLBUILD_REMOTE_CACHE_URL:-}" ]]; then
  echo "SKIP remote-exec-live: HOLBUILD_TEST_REMOTE_EXEC_URL or HOLBUILD_REMOTE_CACHE_URL is not set"
  exit 0
fi

tmpdir=$(make_temp_dir)
log=$tmpdir/run.log
trap 'status=$?; [[ $status -eq 0 || ! -e $log ]] || cat "$log" >&2; cleanup_temp_dir "$tmpdir"' EXIT
use_case_cache "$tmpdir/cache"

# A stamp no earlier run used, so neither cache holds these theories.
stamp=$(basename "$tmpdir")-$(date +%s%N)
project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "rx-live"

[build]
members = ["src"]

[run]
loads = ["BTheory"]
TOML
cat > "$project/src/AScript.sml" <<SML
Theory A
Ancestors bool

Theorem a_thm:
  T
Proof
  simp[] (* $stamp *)
QED
SML
cat > "$project/src/BScript.sml" <<SML
Theory B
Ancestors A

Theorem b_thm:
  T
Proof
  ACCEPT_TAC a_thm (* $stamp *)
QED
SML
printf 'val _ = (BTheory.b_thm; print "RUN_REMOTE_OK\\n");\n' > "$tmpdir/run-script.sml"

(cd "$project" && "$HOLBUILD_BIN" run --remote-exec "$HOLBUILD_TEST_REMOTE_EXEC_URL" --remote-only \
   "$tmpdir/run-script.sml") > "$log" 2>&1
require_grep "holbuild: remote batch " "$log"
require_grep "remote execution: remote workers finished 2 of 2 theories" "$log"
require_grep "BTheory restored from cache" "$log"
require_grep "RUN_REMOTE_OK" "$log"
if grep -q "Theory built" "$log"; then
  echo "built a theory locally" >&2
  exit 1
fi
