#!/usr/bin/env bash
# The child policy's theory-module lines, and which writer outputs the
# worker moves into the host's module store.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$ROOT/tests/lib.sh"
tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
mkdir -p "$tmpdir/cache"
cat > "$tmpdir/store.sml" <<'SML'
use "sml/holbuild-script.sml";
structure E = HolbuildBuildExec;
fun check message condition = if condition then () else raise Fail message;

fun policy sandboxed = E.module_policy {sandboxed = sandboxed, store = "/s", base_state = "/b"};
fun has text s = String.isSubstring text s;
val limit = "Meta.theoryModuleWriteLimit := 0";
val _ = check "a sandboxed action can write modules" (has limit (policy true));
val _ = check "a sandboxed action's limit is not capability-checked"
          (has "[\"configureTheoryModuleCache\", \"theoryModuleWriteLimit\"] then" (policy true));
val _ = check "a local child cannot write modules" (not (has limit (policy false)));
val _ = check "the store is not configured"
          (List.all (fn s => has "configureTheoryModuleCache {directory = \\\"/s\\\", base_state = \\\"/b\\\"}" s)
                    [policy true, policy false]);

val _ = check "two toolchains share a module store"
          (E.module_store "/h1" <> E.module_store "/h2");
val _ = check "a toolchain's store is outside the stores directory"
          (OS.Path.dir (E.module_store "/h1") = E.module_stores ());

val sha = "0123456789abcdef0123456789abcdef01234567";
val expected = ["A-" ^ sha ^ ".pmo"];
val wanted = E.module_file_wanted expected;
val _ = check "an expected module was refused" (wanted ("3fa9-A-" ^ sha ^ ".pmo"));
val _ = List.app (fn file => check ("accepted " ^ file) (not (wanted file)))
          ["3fa9-B-" ^ sha ^ ".pmo",
           "3fa9-A-" ^ String.map (fn _ => #"0") sha ^ ".pmo",
           "3fa9-A-" ^ sha ^ ".pmo.tmp",
           "xyz-A-" ^ sha ^ ".pmo",
           "-A-" ^ sha ^ ".pmo",
           "A-" ^ sha ^ ".pmo",
           ".holbuild"];
SML
(cd "$ROOT" && HOLBUILD_CACHE="$tmpdir/cache" \
  "${HOLBUILD_POLY:-poly}" -q --error-exit --script "$tmpdir/store.sml")
