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
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)

[project]
name = "unclosed-delimiter"

[build]
members = ["src"]
TOML

script=$project/src/AScript.sml
build_fails() {
  if (cd "$project" && "$HOLBUILD_BIN" "$@") > "$tmpdir/build.out" 2> "$tmpdir/build.err"; then
    echo "expected a parse failure" >&2
    exit 1
  fi
  cat "$tmpdir/build.out" "$tmpdir/build.err" > "$tmpdir/build.log"
}

cat > "$script" <<'SML'
Theory A
Ancestors list string

Definition left_delimiter_def:
  left_delimiter = "("
End

Theorem broken:
  T
Proof
  (ALL_TAC (* tactic timed out *)
   >> (fn _ => ALL_TAC) #"("
   >> (fn _ => ALL_TAC) "escaped \" [ \
     \  {"
   >> (fn _ => ALL_TAC) `[ ^(fn x => ``{``) (* ( (* ] *) { *)`
   >> (fn _ => ALL_TAC) “(”
   (* ( (* [ *) { *)
QED

Theorem only_missing_qed:
  T
Proof
  ALL_TAC
SML

build_fails build ATheory
log=$tmpdir/build.log
require_grep 'HOL source parse error: expected closing parenthesis' "$log"
require_grep 'source: .*AScript.sml:18:1$' "$log"
require_grep 'AScript.sml:18:1: parse error: expected closing parenthesis' "$log"
require_grep "note: unclosed '(' opened at .*AScript.sml:11:3$" "$log"
require_grep '  |   (ALL_TAC (\* tactic timed out \*)$' "$log"
if [[ $(grep -c "note: unclosed '(' opened at .*AScript.sml:11:3$" "$log") -lt 3 ]]; then
  echo "missing an opener note from the analyser or the staged build" >&2
  cat "$log" >&2
  exit 1
fi
require_grep "expected 'QED'" "$log"
if grep -A 6 "expected 'QED'" "$log" | grep 'note: unclosed'; then
  echo "the later missing QED inherited an opener from the first theorem" >&2
  cat "$log" >&2
  exit 1
fi

build_fails --json build ATheory
python3 - "$tmpdir/build.out" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    failures = [event["failure"] for event in map(json.loads, stream)
                if event.get("event") == "node_failed"]
assert len(failures) == 1, failures
assert failures[0]["kind"] == "parse_error", failures
PY

cat > "$script" <<'SML'
Theory A
Ancestors list

Theorem broken:
  T
Proof
  simp [TRUTH
QED
SML

build_fails build ATheory
require_grep 'AScript.sml:8:1[^:]*: parse error: expected close delimiter' "$log"
require_grep "note: unclosed '\[' opened at .*AScript.sml:7:8$" "$log"
require_grep '  |   simp \[TRUTH$' "$log"

build_fails execution-plan ATheory:termination:any
require_grep 'HOL source parse error: expected close delimiter' "$log"
require_grep "note: unclosed '\[' opened at .*AScript.sml:7:8$" "$log"

cat > "$script" <<'SML'
Theory A
Ancestors list

Theorem earlier:
  T
Proof
  ACCEPT_TAC TRUTH
QED

Theorem broken:
  T
Proof
  (fn _ => ALL_TAC) {field = 1
SML

build_fails build ATheory
require_grep '^static error:' "$log"
require_grep 'AScript.sml:14:1[^:]*: parse error: expected close delimiter' "$log"
require_grep "note: unclosed '{' opened at .*AScript.sml:13:21$" "$log"
grep -A 5 "HOL source parse error: expected 'QED'" "$log" |
  grep "note: unclosed '{' opened at .*AScript.sml:13:21$"

cat > "$script" <<'SML'
Theory A
Ancestors list

Definition countdown_def:
  countdown (n:num) = if n = 0 then 0 else countdown (n - 1)
Termination
  (ALL_TAC
SML

build_fails build ATheory
grep -A 5 "HOL source parse error: expected 'End'" "$log" |
  grep "note: unclosed '(' opened at .*AScript.sml:7:3$"

cat > "$script" <<'SML'
Theory A
Ancestors list

Theorem bad_separator:
  T
Proof
  (TRUTH, TRUTH; TRUTH)
QED
SML

build_fails build ATheory
require_grep 'parse error: expected close delimiter' "$log"
if grep -q 'note: unclosed' "$log"; then
  echo "reported a closed tuple as unclosed" >&2
  cat "$log" >&2
  exit 1
fi
