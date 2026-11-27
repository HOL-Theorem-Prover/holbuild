#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
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

check_json_parse_failure() {
  build_fails --json build ATheory
  python3 - "$tmpdir/build.out" "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    failure, = [event["failure"] for event in map(json.loads, stream)
                if event.get("event") == "node_failed"]
assert failure["kind"] == "parse_error", failure
assert failure["source_line"] == int(sys.argv[2]), failure
PY
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
   (* ( (* [ *) { *) >>
Type.mk_type >>
Datatype
QED

Theorem only_missing_qed:
  T
Proof
  ALL_TAC
SML

build_fails build ATheory
log=$tmpdir/build.log
require_grep 'HOL source parse error: expected closing parenthesis' "$log"
python3 - "$log" "$script" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
script = sys.argv[2]
warnings, staged = text.split("ATheory failed:", 1)
_, recovering = warnings.split("HOL source parser recovered while instrumenting theorem boundaries", 1)
unclosed, missing_qed = recovering.split("HOL source parse error: expected 'QED'", 1)
note = f"note: unclosed '(' opened at {script}:11:3\n  |   (ALL_TAC (* tactic timed out *)"
assert f"source: {script}:20:1" in unclosed and note in unclosed, unclosed
assert "note: unclosed" not in missing_qed, missing_qed
assert "\nstatic error:\n" in staged, staged
assert "AScript.sml:20:1: parse error: expected closing parenthesis" in staged and note in staged, staged
PY

check_json_parse_failure 20

cat > "$script" <<'SML'
Theory A
Ancestors list

Theorem broken:
  T
Proof
  simp [TRUTH
QED
(* tactic timed out *)
SML

build_fails build ATheory
require_grep 'AScript.sml:8:1[^:]*: parse error: expected close delimiter' "$log"
require_grep "note: unclosed '\[' opened at .*AScript.sml:7:8$" "$log"
require_grep '  |   simp \[TRUTH$' "$log"
check_json_parse_failure 8

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

cat > "$tmpdir/lexical-scan.sml" <<'SML'
use "sml/holbuild-script.sml";
(* Some HOL parsers can recover before seeing an explicit quote's delimiter. *)
val header = "Theorem broken:\n  T\nProof\n";
val proof = "  (ALL_TAC >> Q.SUBGOAL_THEN `(\nval )` ASSUME_TAC\n";
val source = header ^ proof ^ "QED\n";
val _ =
  if HolbuildTheoryDiagnostics.unclosed_delimiter source (size header + size proof) (fn _ => true)
     = SOME (#"(", size header + 2)
  then () else raise Fail "column-zero keyword inside quotation hid the outer opener";
val header = "Theory A[bare\n";
fun check_header entry =
  let val source = header ^ entry ^ "\nval next = [1];\n]\n"
  in
    if HolbuildTheoryDiagnostics.unclosed_delimiter source (size header) (fn _ => true)
       = SOME (#"[", size "Theory A")
    then () else raise Fail ("a later closer hid the header opener before " ^ entry)
  end;
val _ = List.app check_header ["Ancestors list", "Libs bossLib"];
val control_literal = String.implode [#"\"", #"\\", #"^", #"\\", #"\""];
val prefix = "Proof\n  (fn _ => ALL_TAC) " ^ control_literal ^ " >> ";
val tactic = "(ALL_TAC\n";
val _ =
  if HolbuildTheoryDiagnostics.unclosed_delimiter (prefix ^ tactic ^ "QED\n")
       (size prefix + size tactic) (fn _ => true) = SOME (#"(", size prefix)
  then () else raise Fail "SML control escape hid the opener after the string";
SML
(cd "$HOLBUILD_ROOT" && poly -q --error-exit --script "$tmpdir/lexical-scan.sml")

# A worker keeps the note in its log without mistaking the quoted source for
# an out-of-store report from Poly/ML.
cat > "$script" <<'SML'
Theory A
Ancestors list

Theorem broken:
  T
Proof
  (ALL_TAC (* Run out of store *)
   >> ALL_TAC
   >> ALL_TAC
   >> ALL_TAC
QED
SML

start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
(cd "$project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload ATheory) \
  > "$tmpdir/batch"
spec=$(awk '$1 == "action" && $5 == "unclosed-delimiter:ATheory" { print $4 }' "$tmpdir/batch")
worker=$tmpdir/worker
link_hol_toolchain_cache "$worker/cache"
result=$worker/result
status=0
(cd "$worker" && HOLBUILD_CACHE=$worker/cache "$HOLBUILD_BIN" --remote-cache "$remote_url" \
  exec-action "$spec" --cache-limit-gb 1000 --result "$result") > "$worker/out" 2>&1 || status=$?
require_grep '^status=failed$' "$result"
require_grep '^failure=proof$' "$result"
[[ "$status" == 1 ]]
input_key=$(sed -n 's/^input-key=//p' "$result")
cache_entry=$(printf 'holbuild-remote-ac-v1\n%s\n' "$input_key" | sha256sum | cut -d' ' -f1)
require_no_file "$tmpdir/remote/ac/$cache_entry"
log_sha=$(sed -n 's/^log=\([0-9a-f]*\) .*/\1/p' "$result")
curl -fsS "$remote_url/cas/$log_sha" > "$worker/child.log"
require_grep 'parse error: expected closing parenthesis' "$worker/child.log"
require_grep "note: unclosed '(' opened at .*AScript.sml:7:3$" "$worker/child.log"
require_grep '^  |   (ALL_TAC (\* Run out of store \*)$' "$worker/child.log"
