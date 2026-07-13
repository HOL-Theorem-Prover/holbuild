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

cat > "$tmpdir/analyser-response-parser-test.sml" <<'SML'
val root =
  case OS.Process.getEnv "HOLBUILD_ROOT" of
      SOME path => path
    | NONE => raise Fail "HOLBUILD_ROOT not set";
val tmp =
  case OS.Process.getEnv "ANALYSER_RESPONSE_TEST_TMP" of
      SOME path => path
    | NONE => raise Fail "ANALYSER_RESPONSE_TEST_TMP not set";

val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

structure D = HolbuildDependencies
structure P = HolbuildAnalysisProtocol

fun fail message = (TextIO.output (TextIO.stdErr, message ^ "\n");
                    OS.Process.exit OS.Process.failure)
fun assert message condition = if condition then () else fail message

fun join (a, b) = OS.Path.concat(a, b)

fun write_text path text =
  let val out = TextIO.openOut path
  in TextIO.output(out, text); TextIO.closeOut out end

fun response_text lines = String.concatWith "\n" lines ^ "\n"

val response_path = join(tmp, "response.txt")
val _ =
  write_text response_path
    (response_text
       [P.join ["version", P.protocol_version],
        P.join ["ok"],
        P.join ["begin-file", "1"],
        P.join ["load", "Z"],
        P.join ["load", "A"],
        P.join ["load", "A"],
        P.join ["use", "other file.sml"],
        P.join ["extra-dep", "config file"],
        P.join ["mention", "arithTheory"],
        P.join ["end-file", "1"],
        P.join ["begin-file", "2"],
        P.join ["end-file", "2"],
        P.join ["begin-file", "3"],
        P.join ["load", "B"],
        P.join ["end-file", "3"],
        P.join ["end"]])

val parsed =
  D.parse_analyser_response response_path
    [("1", "AScript.sml"), ("2", "EmptyScript.sml"), ("3", "BScript.sml")]

fun require_deps label deps loads uses extra_deps mentions =
  (assert (label ^ " loads") (#loads deps = loads);
   assert (label ^ " uses") (#uses deps = uses);
   assert (label ^ " extra_deps") (#extra_deps deps = extra_deps);
   assert (label ^ " mentions") (#holdep_mentions deps = mentions))

val _ =
  case parsed of
      [("1", deps1), ("2", deps2), ("3", deps3)] =>
        (require_deps "file 1" deps1 ["A", "Z"] ["other file.sml"] ["config file"] ["arithTheory"];
         require_deps "empty file" deps2 [] [] [] [];
         require_deps "file 3" deps3 ["B"] [] [] [])
    | _ => fail "unexpected parsed analyser response shape"

val missing_end_path = join(tmp, "missing-end.txt")
val _ =
  write_text missing_end_path
    (response_text
       [P.join ["version", P.protocol_version],
        P.join ["ok"],
        P.join ["begin-file", "1"],
        P.join ["load", "A"],
        P.join ["end-file", "1"]])

val _ =
  (D.parse_analyser_response missing_end_path [("1", "AScript.sml")];
   fail "missing analyser response end was accepted")
  handle D.Error msg =>
    assert "missing end error should mention end" (String.isSubstring "missing end" msg)

val truncated_file_path = join(tmp, "truncated-file.txt")
val _ =
  write_text truncated_file_path
    (response_text
       [P.join ["version", P.protocol_version],
        P.join ["ok"],
        P.join ["begin-file", "1"],
        P.join ["load", "A"],
        P.join ["end"]])
val _ =
  (D.parse_analyser_response truncated_file_path [("1", "AScript.sml")];
   fail "truncated analyser response was accepted")
  handle D.Error msg =>
    assert "truncated response should identify missing end-file"
           (String.isSubstring "missing end-file" msg)

fun malformed_response name requested lines expected =
  let val path = join(tmp, name)
      val _ = write_text path (response_text lines)
  in
    (D.parse_analyser_response path requested;
     fail (name ^ " was accepted"))
    handle D.Error msg => assert (name ^ " error") (String.isSubstring expected msg)
  end

val _ =
  malformed_response "missing-version.txt" [("1", "AScript.sml")]
    [P.join ["ok"], P.join ["begin-file", "1"], P.join ["end-file", "1"], P.join ["end"]]
    "missing version header"
val _ =
  malformed_response "missing-ok.txt" [("1", "AScript.sml")]
    [P.join ["version", P.protocol_version], P.join ["begin-file", "1"],
     P.join ["end-file", "1"], P.join ["end"]]
    "missing ok header"
val _ =
  malformed_response "trailing-record.txt" [("1", "AScript.sml")]
    [P.join ["version", P.protocol_version], P.join ["ok"], P.join ["begin-file", "1"],
     P.join ["end-file", "1"], P.join ["end"], P.join ["begin-file", "1"]]
    "trailing records"
val _ =
  malformed_response "missing-file.txt" [("1", "AScript.sml"), ("2", "BScript.sml")]
    [P.join ["version", P.protocol_version], P.join ["ok"], P.join ["begin-file", "1"],
     P.join ["end-file", "1"], P.join ["end"]]
    "missing file"
val _ =
  malformed_response "unknown-file.txt" [("1", "AScript.sml")]
    [P.join ["version", P.protocol_version], P.join ["ok"], P.join ["begin-file", "2"], P.join ["end-file", "2"],
     P.join ["end"]]
    "unknown file id"
val _ =
  malformed_response "duplicate-file.txt" [("1", "AScript.sml")]
    [P.join ["version", P.protocol_version], P.join ["ok"], P.join ["begin-file", "1"], P.join ["end-file", "1"],
     P.join ["begin-file", "1"], P.join ["end-file", "1"], P.join ["end"]]
    "duplicate file id"
val _ =
  malformed_response "orphan-end-file.txt" [("1", "AScript.sml")]
    [P.join ["version", P.protocol_version], P.join ["ok"], P.join ["end-file", "1"], P.join ["end"]]
    "without begin-file"

val _ = print "analyser response parser unit tests passed\n"
SML

ANALYSER_RESPONSE_TEST_TMP="$tmpdir" "${HOLBUILD_POLY:-poly}" \
  < "$tmpdir/analyser-response-parser-test.sml" \
  > "$tmpdir/analyser-response-parser-test.log" 2>&1 || {
    cat "$tmpdir/analyser-response-parser-test.log" >&2
    exit 1
  }
grep -q "analyser response parser unit tests passed" "$tmpdir/analyser-response-parser-test.log"

project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
[holbuild]
schema = 2

[dependencies.hol]
git = "https://github.com/HOL-Theorem-Prover/HOL.git"
rev = "$(holbuild_pinned_hol_rev)"

[project]
name = "analyser-response-parser"

[build]
members = ["src"]
TOML

cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors arithmetic

Theorem a:
  1 + 1 = 2
Proof
  simp[]
QED

val _ = export_theory();
SML

cat > "$project/src/BScript.sml" <<'SML'
Theory B
Ancestors A arithmetic

Theorem b:
  2 + 2 = 4
Proof
  simp[]
QED

val _ = export_theory();
SML

first_timing=$tmpdir/first.timing
(cd "$project" && HOLBUILD_TIMING_LOG="$first_timing" HOLBUILD_TIMING_DETAIL=fine "$HOLBUILD_BIN" build --dry-run BTheory) > "$tmpdir/first.log" 2>&1
require_grep $'^phase\tname=source\.discover\tstatus=ok\tms=' "$first_timing"
require_grep $'^phase\tname=build\.plan\tstatus=ok\tms=' "$first_timing"

before_deps=$tmpdir/before-deps
after_deps=$tmpdir/after-deps
mkdir "$before_deps" "$after_deps"
cp "$project/.holbuild/obj/src/"*.deps "$before_deps/"
rm "$project/.holbuild/obj/src/"*.deps

(cd "$project" && "$HOLBUILD_BIN" build --dry-run BTheory) > "$tmpdir/second.log" 2>&1
cp "$project/.holbuild/obj/src/"*.deps "$after_deps/"
diff -ru "$before_deps" "$after_deps"

(cd "$project" && "$HOLBUILD_BIN" build BTheory) > "$tmpdir/build.log" 2>&1
noop_json=$tmpdir/noop.json
(cd "$project" && "$HOLBUILD_BIN" --json build BTheory) > "$noop_json" 2>&1
python3 - <<PY
import json
from pathlib import Path
events = [json.loads(line) for line in Path("$noop_json").read_text().splitlines() if line.startswith("{")]
finished = [event for event in events if event.get("event") == "build_finished"]
if not finished:
    raise SystemExit("no build_finished event in no-op log")
event = finished[-1]
if event.get("built") != 0 or event.get("from_cache") != 0 or event.get("unchanged") != 2:
    raise SystemExit(f"no-op counts were not 0 built / 0 restored / 2 unchanged: {event}")
PY
