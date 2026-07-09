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

cat > "$tmpdir/stat-cache-test.sml" <<'SML'
val root =
  case OS.Process.getEnv "HOLBUILD_ROOT" of
      SOME path => path
    | NONE => raise Fail "HOLBUILD_ROOT not set";
val tmp =
  case OS.Process.getEnv "STAT_CACHE_TEST_TMP" of
      SOME path => path
    | NONE => raise Fail "STAT_CACHE_TEST_TMP not set";

val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

fun fail message = (TextIO.output (TextIO.stdErr, message ^ "\n");
                    OS.Process.exit OS.Process.failure)
fun assert message condition = if condition then () else fail message

fun join (a, b) = OS.Path.concat (a, b)

fun write_text path text =
  let val out = TextIO.openOut path
  in TextIO.output (out, text); TextIO.closeOut out end

fun raw path = HolbuildHash.file_sha1 path

fun ident path =
  case HolbuildStatCache.stat_ident path of
      SOME ident => ident
    | NONE => fail ("stat_ident failed for " ^ path)

fun cache_line path ({dev, ino, size, mtime_ns, ctime_ns} : HolbuildStatCache.ident) sha1 =
  String.concat
    [String.toString path, "\t", dev, "\t", ino, "\t", Int.toString size, "\t",
     LargeInt.toString mtime_ns, "\t", LargeInt.toString ctime_ns, "\t", sha1, "\n"]

fun write_cache cache_path version lines =
  write_text cache_path (version ^ "\n" ^ String.concat lines)

fun with_size ({dev, ino, size, mtime_ns, ctime_ns} : HolbuildStatCache.ident) size' =
  {dev = dev, ino = ino, size = size', mtime_ns = mtime_ns, ctime_ns = ctime_ns}

fun with_mtime ({dev, ino, size, mtime_ns, ctime_ns} : HolbuildStatCache.ident) mtime' =
  {dev = dev, ino = ino, size = size, mtime_ns = mtime', ctime_ns = ctime_ns}

fun stats instance = HolbuildStatCache.stats instance

val sentinel1 = "1111111111111111111111111111111111111111"
val sentinel2 = "2222222222222222222222222222222222222222"
val sentinel3 = "3333333333333333333333333333333333333333"
val sentinel4 = "4444444444444444444444444444444444444444"
val sentinel5 = "5555555555555555555555555555555555555555"

val corpus_a = join (tmp, "corpus-a.txt")
val corpus_b = join (tmp, "corpus-b.txt")
val _ = write_text corpus_a "alpha\n"
val _ = write_text corpus_b "beta\n"
val _ = HolbuildStatCache.clear_current_instance ()
val _ =
  List.app
    (fn path =>
        assert ("default instance mismatch for " ^ path)
               (HolbuildStatCache.file_sha1 (HolbuildStatCache.current_instance ()) path = raw path))
    [corpus_a, corpus_b]

val hit_file = join (tmp, "hit.txt")
val hit_cache = join (tmp, "hit.cache")
val _ = write_text hit_file "unchanged\n"
val _ = write_cache hit_cache HolbuildStatCache.version [cache_line hit_file (ident hit_file) sentinel1]
val hit_instance = HolbuildStatCache.load {path = hit_cache}
val _ = assert "unchanged file should return stored sha1" (HolbuildStatCache.file_sha1 hit_instance hit_file = sentinel1)
val _ = assert "unchanged hit counter" (#hits (stats hit_instance) = 1 andalso #recomputes (stats hit_instance) = 0)

val size_file = join (tmp, "size.txt")
val size_cache = join (tmp, "size.cache")
val _ = write_text size_file "small"
val size_ident = ident size_file
val _ = write_cache size_cache HolbuildStatCache.version [cache_line size_file (with_size size_ident (#size size_ident + 1)) sentinel2]
val size_instance = HolbuildStatCache.load {path = size_cache}
val _ = assert "size mismatch should rehash" (HolbuildStatCache.file_sha1 size_instance size_file = raw size_file)
val _ = assert "size miss counters" (#hits (stats size_instance) = 0 andalso #recomputes (stats size_instance) = 1)

val mtime_file = join (tmp, "mtime.txt")
val mtime_cache = join (tmp, "mtime.cache")
val _ = write_text mtime_file "mtime"
val mtime_ident = ident mtime_file
val _ = write_cache mtime_cache HolbuildStatCache.version [cache_line mtime_file (with_mtime mtime_ident (#mtime_ns mtime_ident + 1)) sentinel3]
val mtime_instance = HolbuildStatCache.load {path = mtime_cache}
val _ = assert "mtime mismatch should rehash" (HolbuildStatCache.file_sha1 mtime_instance mtime_file = raw mtime_file)

val ctime_file = join (tmp, "ctime.txt")
val ctime_ref = join (tmp, "ctime.ref")
val ctime_cache = join (tmp, "ctime.cache")
val _ = write_text ctime_file "aaaa"
val _ = write_text ctime_ref "ref"
val _ = assert "touch -r seed failed" (OS.Process.isSuccess (OS.Process.system (HolbuildHash.quote "touch" ^ " -r " ^ HolbuildHash.quote ctime_file ^ " " ^ HolbuildHash.quote ctime_ref)))
val ctime_before = ident ctime_file
val _ = write_cache ctime_cache HolbuildStatCache.version [cache_line ctime_file ctime_before sentinel4]
val _ = assert "sleep failed" (OS.Process.isSuccess (OS.Process.system "sleep 1"))
val _ = write_text ctime_file "bbbb"
val _ = assert "touch -r restore failed" (OS.Process.isSuccess (OS.Process.system (HolbuildHash.quote "touch" ^ " -r " ^ HolbuildHash.quote ctime_ref ^ " " ^ HolbuildHash.quote ctime_file)))
val ctime_after = ident ctime_file
val _ = assert "same-second edit fixture did not preserve size" (#size ctime_before = #size ctime_after)
val _ = assert "same-second edit fixture did not preserve mtime" (#mtime_ns ctime_before = #mtime_ns ctime_after)
val _ = assert "same-second edit fixture did not change ctime" (#ctime_ns ctime_before <> #ctime_ns ctime_after)
val ctime_instance = HolbuildStatCache.load {path = ctime_cache}
val _ = assert "ctime mismatch should rehash" (HolbuildStatCache.file_sha1 ctime_instance ctime_file = raw ctime_file)

val unknown_file = join (tmp, "unknown.txt")
val unknown_cache = join (tmp, "unknown.cache")
val _ = write_text unknown_file "unknown\n"
val _ = write_cache unknown_cache "holbuild-stat-cache-v2" [cache_line unknown_file (ident unknown_file) sentinel5]
val unknown_instance = HolbuildStatCache.load {path = unknown_cache}
val _ = assert "unknown version should load empty and rehash" (HolbuildStatCache.file_sha1 unknown_instance unknown_file = raw unknown_file)

val corrupt_file = join (tmp, "corrupt.txt")
val corrupt_cache = join (tmp, "corrupt.cache")
val missing_cache = join (tmp, "missing.cache")
val _ = write_text corrupt_file "corrupt\n"
val _ = write_text corrupt_cache (HolbuildStatCache.version ^ "\nnot\ta\tvalid\tentry\n")
val corrupt_instance = HolbuildStatCache.load {path = corrupt_cache}
val missing_instance = HolbuildStatCache.load {path = missing_cache}
val _ = assert "corrupt cache should load empty and rehash" (HolbuildStatCache.file_sha1 corrupt_instance corrupt_file = raw corrupt_file)
val _ = assert "missing cache should load empty and rehash" (HolbuildStatCache.file_sha1 missing_instance corrupt_file = raw corrupt_file)

val flush_file = join (tmp, "flush.txt")
val flush_cache = join (tmp, "flush.cache")
val _ = write_text flush_file "flush\n"
val flush_instance = HolbuildStatCache.load {path = flush_cache}
val flush_hash = HolbuildStatCache.file_sha1 flush_instance flush_file
val _ = HolbuildStatCache.flush flush_instance
val reloaded = HolbuildStatCache.load {path = flush_cache}
val _ = assert "flushed cache should reload as a hit" (HolbuildStatCache.file_sha1 reloaded flush_file = flush_hash)
val _ = assert "flush reload hit counter" (#hits (stats reloaded) = 1)

val _ = print "stat-cache unit tests passed\n"
SML

STAT_CACHE_TEST_TMP="$tmpdir" "${HOLBUILD_POLY:-poly}" < "$tmpdir/stat-cache-test.sml" > "$tmpdir/stat-cache-test.log" 2>&1 || {
  cat "$tmpdir/stat-cache-test.log" >&2
  exit 1
}

grep -q "stat-cache unit tests passed" "$tmpdir/stat-cache-test.log"
