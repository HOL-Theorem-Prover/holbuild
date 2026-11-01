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

cat > "$tmpdir/fs-cache-backend-test.sml" <<'SML'
val root =
  case OS.Process.getEnv "HOLBUILD_ROOT" of
      SOME path => path
    | NONE => raise Fail "HOLBUILD_ROOT not set";
val tmp =
  case OS.Process.getEnv "FS_CACHE_BACKEND_TEST_TMP" of
      SOME path => path
    | NONE => raise Fail "FS_CACHE_BACKEND_TEST_TMP not set";
val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

fun fail message = (TextIO.output (TextIO.stdErr, message ^ "\n");
                    OS.Process.exit OS.Process.failure)
fun assert message condition = if condition then () else fail message
fun join (a, b) = OS.Path.concat (a, b)
fun write_text path text =
  let val out = TextIO.openOut path
  in TextIO.output (out, text); TextIO.closeOut out end

val _ = (let
val cache = HolbuildFSCacheBackend.filesystem (join (tmp, "cache"));
val _ = HolbuildFSCacheBackend.ensure_layout cache;
val source = join (tmp, "source");
val _ = write_text source "valid cache blob\n";
val hash = HolbuildHash.file_sha256 source;
val _ =
  case HolbuildFSCacheBackend.publish_blob cache {hash = hash, src = source} of
      HolbuildCacheBackend.Published => ()
    | result => fail "could not seed filesystem cache";

(* A fetch result is trusted by generic cache transfer callers, so a corrupt
   content-addressed source must not be reported as Hit. *)
val _ = write_text (HolbuildFSCacheBackend.blob_path cache hash) "corrupt\n";
val corrupt_dst = join (tmp, "corrupt-dst");
val _ =
  case HolbuildFSCacheBackend.fetch_blob cache {hash = hash, dst = corrupt_dst} of
      HolbuildCacheBackend.Corrupt _ => ()
    | _ => fail "corrupt cache blob was accepted as a hit";
val _ = assert "corrupt fetch wrote a destination" (not (OS.FileSys.access (corrupt_dst, []) handle OS.SysErr _ => false));

val _ =
  case HolbuildFSCacheBackend.publish_blob cache {hash = hash, src = source} of
      HolbuildCacheBackend.Published => ()
    | result => fail "could not repair filesystem cache";
val dst = join (tmp, "dst");
val _ =
  case HolbuildFSCacheBackend.fetch_blob cache {hash = hash, dst = dst} of
      HolbuildCacheBackend.Hit => ()
    | _ => fail "valid cache blob was not fetched";
val _ = assert "materialized blob hash mismatch" (HolbuildHash.file_sha256 dst = hash);
val key = HolbuildHash.string_sha256 "timeout theory";
fun manifest timeout =
  HolbuildBuildExec.cache_manifest_text
    {input_key = key, sig_hash = hash, sml_hash = hash, dat_hash = hash,
     trace_hash = NONE, extra_hashes = [], parents = ["bool"], mldeps = [],
     proof_timeout = timeout};
fun put text = HolbuildFSCacheBackend.put_action cache
                 HolbuildCacheBackend.PutIfAbsentOrSame {key = key, text = text};
fun resident_is text =
  assert "resident manifest changed unexpectedly"
    (HolbuildFSCacheBackend.get_action cache key = SOME text);
fun check_merge (old, incoming, best, changed) =
  let
    val _ = HolbuildFSCacheBackend.write_action cache {key = key, text = old}
    val result = put incoming
    val _ = assert "wrong merge publication result"
      (if changed then result = HolbuildCacheBackend.Published
       else result = HolbuildCacheBackend.AlreadyPresent)
    val _ = resident_is best
    val _ = assert "reimport was not idempotent"
      (put incoming = HolbuildCacheBackend.AlreadyPresent)
  in resident_is best end;
val weak = manifest NONE;
val strong = manifest (SOME 2.5);
val strongest = manifest (SOME 1.0);
(* Older holbuild versions used directory locks. Transfers must migrate them
   just like build-time cache publication does. *)
val _ = OS.FileSys.mkDir (HolbuildFSCacheBackend.locks_dir cache);
val _ = OS.FileSys.mkDir
  (join (HolbuildFSCacheBackend.locks_dir cache, "action-" ^ key ^ ".lock"));
val _ = List.app check_merge
  [(strong, weak, strong, false), (weak, strong, strong, true),
   (strongest, strong, strongest, false), (strong, strongest, strongest, true),
   (strong, strong, strong, false)];
fun replace_line prefix replacement text =
  String.concatWith "\n"
    (map (fn line => if String.isPrefix prefix line then replacement else line)
      (String.fields (fn c => c = #"\n") text));
fun check_conflict_pair (old, incoming) =
  let
    val _ = HolbuildFSCacheBackend.write_action cache {key = key, text = old}
    val _ = case put incoming of HolbuildCacheBackend.Conflict _ => ()
              | _ => fail "incompatible theory manifest was accepted"
    val _ = resident_is old
    val _ = HolbuildFSCacheBackend.write_action cache {key = key, text = incoming}
    val _ = case put old of HolbuildCacheBackend.Conflict _ => ()
              | _ => fail "incompatible resident theory manifest was accepted"
  in resident_is incoming end;
fun check_conflict incoming = check_conflict_pair (strong, incoming);
val _ = List.app check_conflict
  [replace_line "blob dat " ("blob dat " ^ HolbuildHash.string_sha256 "different output") weak,
   replace_line "parent " "parent arithmetic" weak,
   replace_line "input_key=" ("input_key=" ^ HolbuildHash.string_sha256 "other action") weak,
   replace_line "kind=" "kind=library" weak,
   replace_line "holbuild-cache-action-" "holbuild-cache-action-v99" weak,
   replace_line "blob dat " "blob dat invalid" weak,
   replace_line "blob dat " "" weak,
   weak ^ "unknown-field=true\n",
   weak ^ "proof-timeout=2.5\n"];
val _ = List.app
  (fn transform => check_conflict_pair (transform strong, transform weak))
  [replace_line "input_key=" ("input_key=" ^ HolbuildHash.string_sha256 "other action"),
   replace_line "kind=" "kind=library",
   replace_line "holbuild-cache-action-" "holbuild-cache-action-v99",
   replace_line "blob dat " "blob dat invalid",
   replace_line "blob dat " "",
   (fn text => text ^ "unknown-field=true\n"),
   (fn text => text ^ "proof-timeout=2.5\n")];
val _ = List.app
  (fn value => check_conflict (replace_line "proof-timeout=" ("proof-timeout=" ^ value) weak))
  ["", "0", "~1", "-1", "nan", "inf", "1e999", "2.5junk"];
val _ = HolbuildFSCacheBackend.write_action cache {key = key, text = weak};
val _ = case HolbuildFSCacheBackend.put_action cache HolbuildCacheBackend.PutIfAbsent
                {key = key, text = strong} of
            HolbuildCacheBackend.Conflict _ => ()
          | _ => fail "PutIfAbsent replaced a resident action";
val _ = resident_is weak;
in
  print "filesystem cache backend tests passed\n"
end) handle e => fail (General.exnMessage e);
SML

# A cp that logs its arguments, to check that the fetch copies in-process and
# starts no cp at all.
real_cp=$(command -v cp)
mkdir -p "$tmpdir/bin"
cat > "$tmpdir/bin/cp" <<CP
#!/bin/sh
printf '%s\n' "\$@" >> "$tmpdir/cp.log"
exec "$real_cp" "\$@"
CP
chmod +x "$tmpdir/bin/cp"

PATH="$tmpdir/bin:$PATH" FS_CACHE_BACKEND_TEST_TMP="$tmpdir" "${HOLBUILD_POLY:-poly}" < "$tmpdir/fs-cache-backend-test.sml" > "$tmpdir/fs-cache-backend-test.log" 2>&1 || {
  cat "$tmpdir/fs-cache-backend-test.log" >&2
  exit 1
}

grep -q "filesystem cache backend tests passed" "$tmpdir/fs-cache-backend-test.log"

if [[ -s "$tmpdir/cp.log" ]]; then
  echo "the fetch started cp:" >&2
  cat "$tmpdir/cp.log" >&2
  exit 1
fi
