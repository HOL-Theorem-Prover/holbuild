#!/usr/bin/env bash
# The child policy's theory-module lines, which writer outputs the worker
# moves into the host's module store, and that each child using a store
# marks it recently used for the cache sweeps.
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

(* The v2 store sits beside the v1 one, whose name the remote entries keep. *)
val _ = check "the store is not the v2 one of its toolchain"
          (OS.Path.file (E.module_store "/h1") = "v2-" ^ E.module_store_id "/h1" andalso
           E.module_store_v1 "/h1" = OS.Path.concat (E.module_stores (), E.module_store_id "/h1"));
val _ = check "the remote key of a module changed"
          (E.module_remote_key {toolchain = "t", store = E.module_store_id "/h1", wanted = "w", dat_sha256 = "d"} =
           HolbuildHash.string_sha256
             ("holbuild-theory-module-v1\ntoolchain=t\nstore=" ^ HolbuildHash.string_sha256 "/h1" ^
              "\nmodule=w\ndat-sha256=d\n"));

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

val policy_file = OS.Path.concat (valOf (OS.Process.getEnv "HOLBUILD_CACHE"), "policy.sml");
val tc = {holdir = "/h1", maxheap = NONE, kernel_variant = HolbuildToolchain.StandardKernel};
val _ = OS.FileSys.mkDir (E.module_stores ());
val _ = OS.FileSys.mkDir (E.module_store "/h1");
val _ = OS.FileSys.setTime (E.module_store "/h1", SOME Time.zeroTime);
val _ = E.write_child_policy_with {module_cache = false} tc policy_file;
val _ = check "a child without the module cache marked the store used"
          (OS.FileSys.modTime (E.module_store "/h1") = Time.zeroTime);
val _ = E.write_child_policy tc policy_file;
val _ = check "a child using the store left it looking unused"
          (Time.> (OS.FileSys.modTime (E.module_store "/h1"), Time.zeroTime));

(* A new store takes the v1 store's base theories. *)
val _ = OS.FileSys.mkDir (E.module_store_v1 "/h1");
val _ = E.write_text (OS.Path.concat (E.module_store_v1 "/h1", "base-theories")) "min\nbool\n";
val _ = E.seed_module_store "/h1";
val _ = check "the v1 store's base theories were not copied"
          (E.read_text (OS.Path.concat (E.module_store "/h1", "base-theories")) = "min\nbool\n");
SML
(cd "$ROOT" && HOLBUILD_CACHE="$tmpdir/cache" \
  "${HOLBUILD_POLY:-poly}" -q --error-exit --script "$tmpdir/store.sml")
