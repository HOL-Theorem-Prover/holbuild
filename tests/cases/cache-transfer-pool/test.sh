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

cat > "$tmpdir/cache-transfer-pool-test.sml" <<'SML'
val root =
  case OS.Process.getEnv "HOLBUILD_ROOT" of
      SOME path => path
    | NONE => raise Fail "HOLBUILD_ROOT not set";
val tmp =
  case OS.Process.getEnv "CACHE_TRANSFER_POOL_TEST_TMP" of
      SOME path => path
    | NONE => raise Fail "CACHE_TRANSFER_POOL_TEST_TMP not set";
val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

structure T = HolbuildCacheTransfer
structure B = HolbuildCacheBackend

fun fail message = (TextIO.output (TextIO.stdErr, message ^ "\n");
                    OS.Process.exit OS.Process.failure)
fun assert message condition = if condition then () else fail message

val lock = Mutex.mutex ()
fun locked f = (Mutex.lock lock; f () before Mutex.unlock lock)
               handle e => (Mutex.unlock lock; raise e)

fun read_file path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end
fun write_file path text =
  let val out = TextIO.openOut path
  in TextIO.output (out, text); TextIO.closeOut out end
fun sleep_ms ms = OS.Process.sleep (Time.fromMilliseconds ms)

(* Fake backends record every operation.  A blob's content is its name, so a
   destination can check what it was handed.  Hashes starting "bad" fail to
   fetch, hashes starting "slow" take longer. *)
val in_flight = ref 0
val peak = ref 0
val events = ref ([] : string list)
val temp_paths = ref ([] : string list)
val published = ref ([] : string list)
val actions = ref ([] : string list)

fun record event = locked (fn () => events := event :: !events)

fun reset () =
  locked (fn () => (in_flight := 0; peak := 0; events := []; temp_paths := [];
                    published := []; actions := []))

fun manifest blobs = String.concat (map (fn hash => "blob=" ^ hash ^ "\n") blobs)

val manifests = ref ([] : (string * string) list)
fun set_manifests entries = manifests := map (fn (key, blobs) => (key, manifest blobs)) entries

fun counted f =
  let
    val _ = locked (fn () => (in_flight := !in_flight + 1;
                              if !in_flight > !peak then peak := !in_flight else ()))
  in
    (f () before locked (fn () => in_flight := !in_flight - 1))
    handle e => (locked (fn () => in_flight := !in_flight - 1); raise e)
  end

val source : T.source =
  {get_action = fn key =>
     counted (fn () => (sleep_ms 5; Option.map #2 (List.find (fn (k, _) => k = key) (!manifests)))),
   fetch_blob = fn {hash, dst} =>
     counted (fn () =>
       (locked (fn () => temp_paths := dst :: !temp_paths);
        sleep_ms (if String.isPrefix "slow" hash then 300 else 20);
        if String.isPrefix "bad" hash then B.Corrupt "injected failure"
        else (write_file dst hash; record ("fetched " ^ hash); B.Hit)))}

val destination : T.destination =
  {put_action = fn _ => fn {key, text} =>
     (record ("action " ^ key);
      List.app (fn hash =>
                  assert ("action " ^ key ^ " written before blob " ^ hash)
                    (locked (fn () => List.exists (fn h => h = hash) (!published))))
               (T.unique_blobs text);
      locked (fn () => actions := key :: !actions);
      B.Published),
   publish_blob = fn {hash, src} =>
     (assert ("blob " ^ hash ^ " handed over with wrong content") (read_file src = hash);
      locked (fn () => published := hash :: !published);
      record ("published " ^ hash);
      B.Published)}

val tmp_dir = OS.Path.concat (tmp, "transfer-tmp")
val transfer = {source = source, destination = destination, tmp_dir = tmp_dir}

fun tmp_empty () =
  let
    val dir = OS.FileSys.openDir tmp_dir
    val entry = OS.FileSys.readDir dir
  in
    OS.FileSys.closeDir dir; not (Option.isSome entry)
  end

fun index_of event =
  let
    val ordered = rev (!events)
    fun loop (_, []) = NONE
      | loop (i, e :: rest) = if e = event then SOME i else loop (i + 1, rest)
  in
    loop (0, ordered)
  end

fun distinct [] = true
  | distinct (x :: xs) = not (List.exists (fn y => y = x) xs) andalso distinct xs

fun copied (T.Copied _) = true
  | copied _ = false

(* Blobs before the action; a repeated blob ref is copied once. *)
val _ = reset ()
val _ = set_manifests [("k1", ["a1", "a2", "a1", "a3"])]
val _ =
  case T.with_pool 2 (fn pool => T.copy_entry pool transfer "k1") of
      T.Copied {blobs, uploaded_blobs, ...} =>
        (assert "repeated blob counted twice" (blobs = 3);
         assert "uploads miscounted" (uploaded_blobs = 3))
    | _ => fail "entry k1 not copied"
val _ = assert "action not last"
          (valOf (index_of "action k1") > valOf (index_of "published a3") andalso
           valOf (index_of "action k1") > valOf (index_of "published a1"))
val _ = assert "temp files left after success" (tmp_empty ())

(* A failed blob leaves no action and reports only once the entry's other
   started blobs have finished. *)
val _ = reset ()
val _ = set_manifests [("k2", ["slow2", "bad2", "b2"])]
val _ =
  case T.with_pool 3 (fn pool => T.copy_entry pool transfer "k2") of
      T.Failed _ =>
        (assert "failed entry returned with a blob still running" (!in_flight = 0);
         assert "slow blob did not finish before the failure was reported"
           (Option.isSome (index_of "published slow2")))
    | _ => fail "entry k2 with a failing blob did not fail"
val _ = assert "action written after a failed blob" (null (!actions))
val _ = assert "temp files left after failure" (tmp_empty ())

(* Missing manifest. *)
val _ =
  case T.with_pool 1 (fn pool => T.copy_entry pool transfer "absent") of
      T.Missing => ()
    | _ => fail "missing entry not reported as Missing"

(* copy_entries raises the first failed key's error after all entries finish. *)
val _ = reset ()
val _ = set_manifests [("e1", ["c1"]), ("e2", ["bad-e2"]), ("e3", ["c3"])]
val _ =
  (T.with_pool 2 (fn pool => T.copy_entries pool transfer ["e1", "e2", "e3"]);
   fail "copy_entries ignored a failed entry")
  handle T.Error message =>
    assert ("unexpected copy_entries error: " ^ message) (String.isSubstring "bad-e2" message)
val _ = assert "copy_entries returned before every entry finished" (!in_flight = 0)
val _ = assert "copy_entries skipped healthy entries"
          (List.exists (fn k => k = "e1") (!actions) andalso List.exists (fn k => k = "e3") (!actions))

(* Size 1 makes progress, and entries that share blobs copy them under
   distinct temp paths. *)
val _ = reset ()
val shared = List.tabulate (6, fn i => ("s" ^ Int.toString i, ["shared1", "shared2", "own" ^ Int.toString i]))
val _ = set_manifests shared
val results = T.with_pool 1 (fn pool => T.copy_entries pool transfer (map #1 shared))
val _ = assert "size-1 pool lost entries" (length results = 6)
val _ = assert "temp paths collided" (distinct (!temp_paths))
val _ = assert "size-1 pool ran operations concurrently" (!peak = 1)

(* Demand, publish and prefetch together never exceed the pool size. *)
val _ = reset ()
val many = List.tabulate (12, fn i => ("m" ^ Int.toString i, ["x" ^ Int.toString i, "y" ^ Int.toString i, "z" ^ Int.toString i]))
val _ = set_manifests many
val finished = ref 0
fun count_finish _ = locked (fn () => finished := !finished + 1)
fun await_finished n = if locked (fn () => !finished) >= n then () else (sleep_ms 10; await_finished n)
val _ =
  T.with_pool 2 (fn pool =>
    let
      val (prefetch, rest) = (List.take (many, 4), List.drop (many, 4))
      val (publish, demand) = (List.take (rest, 4), List.drop (rest, 4))
      val _ = List.app (fn (key, _) => T.start_entry pool T.Background transfer key count_finish) prefetch
      val _ = List.app (fn (key, _) => T.start_entry pool T.Urgent transfer key count_finish) publish
      val _ = List.app (fn (key, _) =>
                          ignore (Thread.fork (fn () =>
                            (assert ("demand entry " ^ key ^ " not copied") (copied (T.copy_entry pool transfer key));
                             count_finish ()), [])))
                       demand
    in
      await_finished 12
    end)
val _ = assert ("pool exceeded its size: peak " ^ Int.toString (!peak)) (!peak <= 2)
val _ = assert "pool of 2 never overlapped work" (!peak = 2)
val _ = assert "temp files left after mixed load" (tmp_empty ())

(* A demand restore runs ahead of queued prefetch: with one worker, at most
   the prefetch entry already running finishes first. *)
val _ = reset ()
val queued = List.tabulate (5, fn i => ("p" ^ Int.toString i, ["pa" ^ Int.toString i, "pb" ^ Int.toString i]))
val _ = set_manifests (("demand", ["da", "db"]) :: queued)
val _ =
  T.with_pool 1 (fn pool =>
    (List.app (fn (key, _) => T.start_entry pool T.Background transfer key (fn _ => ())) queued;
     assert "demand entry not copied" (copied (T.copy_entry pool transfer "demand"))))
val _ = assert ("demand entry waited behind prefetch: " ^ String.concatWith "," (rev (!actions)))
          (length (List.filter (fn k => k <> "demand") (!actions)) <= 1)

(* Shutdown drops queued background work and leaves no partial entry. *)
val _ = assert "dropped prefetch wrote a partial entry"
          (List.all (fn (key, blobs) =>
                       not (List.exists (fn k => k = key) (!actions)) orelse
                       List.all (fn hash => List.exists (fn h => h = hash) (!published)) blobs)
                    queued)
val _ = assert "temp files left after shutdown" (tmp_empty ())

val _ = print "cache transfer pool tests passed\n";
SML

CACHE_TRANSFER_POOL_TEST_TMP="$tmpdir" "${HOLBUILD_POLY:-poly}" < "$tmpdir/cache-transfer-pool-test.sml" > "$tmpdir/cache-transfer-pool-test.log" 2>&1 || {
  cat "$tmpdir/cache-transfer-pool-test.log" >&2
  exit 1
}

grep -q "cache transfer pool tests passed" "$tmpdir/cache-transfer-pool-test.log" || {
  cat "$tmpdir/cache-transfer-pool-test.log" >&2
  exit 1
}
