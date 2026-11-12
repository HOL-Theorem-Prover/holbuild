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

(* Hydrating a new action can reuse blobs already held for another action. *)
val source_cache = HolbuildFSCacheBackend.filesystem (join (tmp, "source-cache"));
val _ = HolbuildFSCacheBackend.ensure_layout source_cache;
val _ = HolbuildFSCacheBackend.publish_blob source_cache {hash = hash, src = source};
val fetches = ref 0;
val transferred_inode = ref NONE;
val transfer_source : HolbuildCacheTransfer.source =
  {get_action = HolbuildFSCacheBackend.get_action source_cache,
   fetch_blob = fn request as {hash, dst} =>
     (fetches := !fetches + 1;
      case HolbuildFSCacheBackend.fetch_blob source_cache request of
          HolbuildCacheBackend.Hit =>
            (transferred_inode := SOME (Posix.FileSys.ST.ino (Posix.FileSys.stat dst));
             HolbuildCacheBackend.Hit)
        | result => result)};
fun transfer () = HolbuildCacheTransfer.copy_blob transfer_source
  (HolbuildBuildExec.fs_cache_destination cache)
  (HolbuildFSCacheBackend.tmp_dir cache) hash (0, 0);
val _ = assert "resident blob was not reused" (transfer () = (0, 1));
val _ = assert "resident blob was downloaded again" (!fetches = 0);
val _ = write_text (HolbuildFSCacheBackend.blob_path cache hash) "corrupt\n";
val _ = assert "corrupt resident blob was not replaced" (transfer () = (1, 0));
val _ = assert "repair did not fetch exactly once" (!fetches = 1);
val _ = assert "repair left corrupt bytes" (HolbuildFSCacheBackend.verify_blob cache hash);
val _ = assert "verified temporary blob was copied again"
  (!transferred_inode = SOME (Posix.FileSys.ST.ino
    (Posix.FileSys.stat (HolbuildFSCacheBackend.blob_path cache hash))));

(* A missing last blob in a chunk must not discard intact neighbours, and
   a present blob with corrupt bytes must still be classified as a miss. *)
val batch_hashes = List.tabulate (300, fn i =>
  let
    val text = "batch blob " ^ Int.toString i
    val hash = HolbuildHash.string_sha256 text
  in write_text (HolbuildFSCacheBackend.blob_path cache hash) text; hash end);
val _ = assert "batched verification changed valid hashes or their order"
  (HolbuildFSCacheBackend.verified_blobs cache batch_hashes = batch_hashes);
val missing = List.nth (batch_hashes, 255);
val corrupt = List.nth (batch_hashes, 5);
val _ = OS.FileSys.remove (HolbuildFSCacheBackend.blob_path cache missing);
val _ = write_text (HolbuildFSCacheBackend.blob_path cache corrupt) "corrupt batch blob";
val _ = assert "batched verification accepted a missing or corrupt blob, or lost a valid neighbour"
  (HolbuildFSCacheBackend.verified_blobs cache batch_hashes =
   List.filter (fn hash => hash <> missing andalso hash <> corrupt) batch_hashes);
val _ = assert "empty verification should need no external input"
  (HolbuildFSCacheBackend.verified_blobs cache [] = []);
val _ = OS.FileSys.remove (HolbuildFSCacheBackend.blob_path cache hash);
val _ = assert "missing blob was not transferred" (transfer () = (1, 0));
val _ = write_text source "invalid upload\n";
val _ = case HolbuildFSCacheBackend.publish_blob cache {hash = hash, src = source} of
    HolbuildCacheBackend.Conflict _ => ()
  | _ => fail "ordinary publication accepted an unverified source";
val _ = OS.FileSys.remove (HolbuildFSCacheBackend.blob_path cache hash);
val _ = write_text (HolbuildFSCacheBackend.blob_path source_cache hash) "corrupt source\n";
val _ = assert "corrupt transfer source was accepted"
  ((transfer (); false) handle HolbuildCacheTransfer.Error _ => true);
val _ = assert "failed transfer published a blob" (not (HolbuildFSCacheBackend.has_blob cache hash));

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

# The same missing/corrupt chunk must work when external hashing is unavailable.
mkdir -p "$tmpdir/no-sha" "$tmpdir/fallback"
printf '#!/bin/sh\nexit 1\n' > "$tmpdir/no-sha/sha256sum"
chmod +x "$tmpdir/no-sha/sha256sum"
PATH="$tmpdir/no-sha:$tmpdir/bin:$PATH" FS_CACHE_BACKEND_TEST_TMP="$tmpdir/fallback" \
  "${HOLBUILD_POLY:-poly}" < "$tmpdir/fs-cache-backend-test.sml" > "$tmpdir/fallback.log" 2>&1 || {
  cat "$tmpdir/fallback.log" >&2
  exit 1
}
grep -q "filesystem cache backend tests passed" "$tmpdir/fallback.log"

if [[ -s "$tmpdir/cp.log" ]]; then
  echo "the fetch started cp:" >&2
  cat "$tmpdir/cp.log" >&2
  exit 1
fi
