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
for hol in h1 h2; do
  mkdir -p "$tmpdir/$hol/bin"
  printf '%s\n' "$hol" > "$tmpdir/$hol/bin/hol"
  : > "$tmpdir/$hol/bin/hol.state"
done
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

(* The HOL directories h1 and h2 sit beside the cache. *)
val tmpdir = OS.Path.dir (valOf (OS.Process.getEnv "HOLBUILD_CACHE"));
fun tc hol = {holdir = OS.Path.concat (tmpdir, hol), maxheap = NONE, kernel_variant = HolbuildToolchain.StandardKernel};
val h1 = #holdir (tc "h1");
val _ = check "two toolchains share a module store"
          (E.module_store (tc "h1") <> E.module_store (tc "h2"));
val _ = check "a toolchain's store is outside the stores directory"
          (OS.Path.dir (E.module_store (tc "h1")) = E.module_stores ());

(* The v4 and v3 stores use the exact toolchain key; v2 uses HOLDIR alone. *)
val exact_id = HolbuildHash.string_sha256 (h1 ^ "\n" ^ HolbuildToolchain.toolchain_key (tc "h1"));
val _ = check "unexpected store paths"
          (E.module_store (tc "h1") = OS.Path.concat (E.module_stores (), "v4-" ^ exact_id) andalso
           E.module_store_v3 (tc "h1") = OS.Path.concat (E.module_stores (), "v3-" ^ exact_id) andalso
           E.module_store_v2 h1 = OS.Path.concat (E.module_stores (), "v2-" ^ E.module_store_id h1));
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
val store = E.module_store (tc "h1");
val _ = OS.FileSys.mkDir (E.module_stores ());
val _ = OS.FileSys.mkDir store;
val _ = OS.FileSys.setTime (store, SOME Time.zeroTime);
val _ = E.write_child_policy_with {module_cache = false} (tc "h1") policy_file;
val _ = check "a child without the module cache marked the store used"
          (OS.FileSys.modTime store = Time.zeroTime);
val _ = E.write_child_policy (tc "h1") policy_file;
val _ = check "a child using the store left it looking unused"
          (Time.> (OS.FileSys.modTime store, Time.zeroTime));

(* A warm host seeds only the marker, favouring v3 when both exist. *)
fun base_theories dir = OS.Path.concat (dir, "base-theories");
fun seed_legacy dir text =
  (OS.FileSys.mkDir dir; E.write_text (base_theories dir) text);
val v3 = E.module_store_v3 (tc "h1");
val _ = seed_legacy (E.module_store_v2 h1) "min\n";
val _ = seed_legacy v3 "min\nbool\n";
val legacy_module = hd expected;
val _ = E.write_text (OS.Path.concat (v3, legacy_module)) "legacy module";
val _ = E.seed_module_store (tc "h1");
val _ = check "the v3 marker did not take precedence"
          (E.read_text (base_theories store) = "min\nbool\n");
val _ = check "seeding copied a legacy module"
          (not (E.file_exists (OS.Path.concat (store, legacy_module))));
val _ = E.write_text (base_theories v3) "changed\n";
val _ = E.seed_module_store (tc "h1");
val _ = check "seeding overwrote the current store's base theories"
          (E.read_text (base_theories store) = "min\nbool\n");

(* A host with only v2 can seed a store that does not exist yet. *)
val _ = seed_legacy (E.module_store_v2 (#holdir (tc "h2"))) "min\n";
val _ = E.seed_module_store (tc "h2");
val _ = check "the v2 store's base theories were not copied"
          (E.read_text (base_theories (E.module_store (tc "h2"))) = "min\n");
SML
(cd "$ROOT" && HOLBUILD_CACHE="$tmpdir/cache" \
  "${HOLBUILD_POLY:-poly}" -q --error-exit --script "$tmpdir/store.sml")
