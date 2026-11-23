#!/usr/bin/env bash
# When the worker starts a theory-module writer: never for a HOL without
# the module helper, nor once a writer found the toolchain can't write
# modules, nor when a store with its base theories lacks fewer than 16 of
# the modules the action wants, nor while another process holds the
# store's writer lock.  A fake HOL stands in for the writer: it counts its
# runs, records its output directory's file system and leaves the files
# named in $tmpdir/writes there, each module with bytes of its own.  The worker cache cap's sweep leaves a
# store alone while its writer runs.  No writer starts too close to its
# deadline, and one killed at it still stores the modules it finished.  Where /dev/shm is another file
# system, a store there stands for one a worker's containers share on a
# mount of its own: the writer writes on that file system.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$ROOT/tests/lib.sh"
tmpdir=$(make_temp_dir)
other_fs=
server_pid=
server2_pid=
trap '[[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null; [[ -z $server2_pid ]] || kill "$server2_pid" 2>/dev/null; cleanup_temp_dir "$tmpdir"; [[ -z $other_fs ]] || rm -rf "$other_fs"' EXIT
mkdir -p "$tmpdir/cache" "$tmpdir/root/src" "$tmpdir/root/.holbuild"
# A second node, for a cache of two.
start_remote_cache_server "$tmpdir/remote2" "$tmpdir/server2"
server2_pid=$server_pid
remote2_url=$remote_url
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server" "$tmpdir/control"

sha() { sha1sum "$1" | cut -d' ' -f1; }
for hol in hol1 hol2 hol3 hol4 hol5 hol6 hol7 hol8; do
  mkdir -p "$tmpdir/$hol/bin" "$tmpdir/$hol/sigobj" "$tmpdir/$hol/tools-poly/poly"
  : > "$tmpdir/$hol/bin/hol.state"
  : > "$tmpdir/$hol/sigobj/boolTheory.uo"
  printf 'bool theory\n' > "$tmpdir/$hol/sigobj/boolTheory.dat"
  cat > "$tmpdir/$hol/bin/hol" <<SH
#!/usr/bin/env bash
echo run >> "$tmpdir/$hol.runs"
cp "\${@: -1}" "$tmpdir/$hol.script"
out=\$(dirname "\$(grep -o 'openOut "[^"]*/unsupported"' "\${@: -1}" | cut -d'"' -f2)")
stat -L -c %d "\$out" > "$tmpdir/$hol.output-device"
while read -r file; do
  case \$file in *.pmo) date +%s%N > "\$out/\$file" ;; *) : > "\$out/\$file" ;; esac
done < "$tmpdir/writes"
[[ ! -e "$tmpdir/plant" ]] || { bash "$tmpdir/plant"; rm "$tmpdir/plant"; }
[[ ! -e "$tmpdir/hang" ]] || sleep 20
SH
  chmod +x "$tmpdir/$hol/bin/hol"
done
bool_sha=$(sha "$tmpdir/hol1/sigobj/boolTheory.dat")
printf '(("bool" . "%s"))\n' "$bool_sha" > "$tmpdir/root/src/ATheory.dat"
a_sha=$(sha "$tmpdir/root/src/ATheory.dat")
printf '(("A" . "%s") ("bool" . "%s"))\n' "$a_sha" "$bool_sha" > "$tmpdir/root/src/BTheory.dat"
b_sha=$(sha "$tmpdir/root/src/BTheory.dat")
# Sixteen more theories, so that an action can lack enough modules for a
# writer on a store with its base theories.
for i in $(seq 1 16); do
  printf '(("bool" . "%s"))\n' "$bool_sha" > "$tmpdir/root/src/P${i}Theory.dat"
  echo "\"ab12-P$i-$(sha "$tmpdir/root/src/P${i}Theory.dat").pmo\""
done | paste -sd, > "$tmpdir/p-modules"

# Scripts the fake HOL starts in a session of its own (detach), so they
# outlive it.  replace-entry ENTRY FILE: once ENTRY is put on either node,
# it is replaced with FILE on both.
cat > "$tmpdir/replace-entry" <<SH
for _ in \$(seq 3000); do
  [[ -e "$tmpdir/remote/ac/\$1" || -e "$tmpdir/remote2/ac/\$1" ]] && break
  sleep 0.01
done
for node in remote remote2; do cp "\$2" "$tmpdir/\$node-entry"; mv "$tmpdir/\$node-entry" "$tmpdir/\$node/ac/\$1"; done
SH
# put-during-upload ENTRY FILE: puts FILE as ENTRY once a blob upload is held.
cat > "$tmpdir/put-during-upload" <<SH
for _ in \$(seq 3000); do [[ -e "$tmpdir/control/cas-put-count" ]] && break; sleep 0.01; done
mv "\$2" "$tmpdir/remote/ac/\$1"
touch "$tmpdir/control/cas-put-release"
SH
# hold-lookups: lets the held entry GETs go after 16 s.
cat > "$tmpdir/hold-lookups" <<SH
sleep 16
touch "$tmpdir/control/action-get-release"
SH
# drop-new-entry baseline: lists the entries on both nodes, run while the
# fake HOL runs, before the writer puts any.  drop-new-entry: then removes
# from both nodes the first entry put that the list lacks.
cat > "$tmpdir/drop-new-entry" <<SH
list() { ls "$tmpdir/remote/ac" "$tmpdir/remote2/ac" 2>/dev/null | grep -v -e : -e '^\$' | LC_ALL=C sort -u; }
[[ \${1:-} != baseline ]] || { list > "$tmpdir/entries-before"; exit; }
for _ in \$(seq 3000); do
  new=\$(LC_ALL=C comm -13 "$tmpdir/entries-before" <(list))
  [[ -n \$new ]] && break
  sleep 0.01
done
for entry in \$new; do rm -f "$tmpdir/remote/ac/\$entry" "$tmpdir/remote2/ac/\$entry"; done
SH

cat > "$tmpdir/writer.sml" <<SML
use "sml/holbuild-script.sml";
structure E = HolbuildBuildExec;
fun check message condition = if condition then () else raise Fail message;
fun exists path = OS.FileSys.access (path, []);
fun runs hol =
  let val path = "$tmpdir/" ^ hol ^ ".runs"
  in if exists path then length (String.tokens Char.isSpace (E.read_text path)) else 0 end;
fun writes files = E.write_text "$tmpdir/writes" (String.concat (map (fn f => f ^ "\n") files));
fun dep name = {target = "p:" ^ name ^ "Theory", stem = "src/" ^ name ^ "Theory", key = ""};
val ps = [$(cat "$tmpdir/p-modules")];
val wanted = {deps = [dep "A", dep "B"] @ List.tabulate (16, fn i => dep ("P" ^ Int.toString (i + 1))),
              loads = [E.LoadTheory "boolTheory"]};
fun tc hol = {holdir = "$tmpdir/" ^ hol, maxheap = NONE,
              kernel_variant = HolbuildToolchain.StandardKernel};
val remote = HolbuildRemoteCache.remote "$remote_url";
fun fill_by hol seconds =
  E.fill_module_store remote "$tmpdir/root" (tc hol) wanted (Time.+ (Time.now (), Time.fromSeconds seconds));
fun fill hol = ignore (fill_by hol 100);
fun store hol = E.module_store ("$tmpdir/" ^ hol);
fun stored hol file = exists (OS.Path.concat (store hol, file));
val a = "ab12-A-$a_sha.pmo";
val b = "ab12-B-$b_sha.pmo";
fun detach script = "setsid bash $tmpdir/" ^ script ^ " </dev/null >/dev/null 2>&1 &\n";
fun script_has hol text = String.isSubstring text (E.read_text ("$tmpdir/" ^ hol ^ ".script"));

(* A HOL without the module helper. *)
val _ = writes [a, b];
val _ = fill "hol1";
val _ = check "a writer ran for a HOL without the module helper" (runs "hol1" = 0);
val _ = check "a HOL without the module helper got a store" (not (exists (store "hol1")));

(* The first writer also records the base state's theories, and runs
   for however few modules are missing. *)
val _ = E.write_text "$tmpdir/hol1/tools-poly/poly/theory_modules.ML" "";
val _ = OS.FileSys.mkDir (E.module_stores ()) handle OS.SysErr _ => ();
val _ = OS.FileSys.mkDir (store "hol1");
val _ = List.app (fn p => E.write_text (OS.Path.concat (store "hol1", p)) "") ps;
val _ = writes [a, b, "base-theories", "ab12-C-$b_sha.pmo", "other"];
val _ = fill "hol1";
val _ = check "no writer ran for an empty store" (runs "hol1" = 1);
val _ = check "the writer was not asked for the base theories" (script_has "hol1" "Theory.ancestry");
val _ = check "the writer was not given the action's theories"
          (script_has "hol1" "ATheory.sml" andalso script_has "hol1" "BTheory.sml");
val _ = check "a module or the base theories were not stored"
          (List.all (stored "hol1") [a, b, "base-theories"]);
val _ = check "an unwanted file was stored"
          (not (stored "hol1" "ab12-C-$b_sha.pmo") andalso not (stored "hol1" "other"));

(* Every module stored: bool is a base theory. *)
val _ = E.write_text (OS.Path.concat (store "hol1", "base-theories")) "min\nbool\n";
val _ = fill "hol1";
val _ = check "a writer ran for a filled store" (runs "hol1" = 1);

(* Fewer than 16 modules missing: the action loads them from .dat files. *)
fun remove files = List.app (fn f => OS.FileSys.remove (OS.Path.concat (store "hol1", f))) files;
val _ = remove (b :: List.take (ps, 14));
val _ = fill "hol1";
val _ = check "a writer ran for 15 missing modules" (runs "hol1" = 1);

(* No writer while another process writes to the store. *)
val _ = remove [List.nth (ps, 14)];
val holder = Posix.Process.fork ();
val _ = case holder of
            NONE => (ignore (HolbuildFileLock.try_acquire_path
                               {path = OS.Path.concat (store "hol1", "writer.lock"), obsolete_kind = NONE});
                     E.write_text "$tmpdir/locked" "";
                     OS.Process.sleep (Time.fromSeconds 60);
                     Posix.Process.exit 0w0)
          | SOME _ => ();
fun await () = if exists "$tmpdir/locked" then () else (OS.Process.sleep (Time.fromMilliseconds 50); await ());
val _ = await ();
val _ = fill "hol1";
val _ = check "a writer ran while another held the store's lock" (runs "hol1" = 1);
val _ = Posix.Process.kill (Posix.Process.K_PROC (valOf holder), Posix.Signal.kill);
val _ = Posix.Process.waitpid (Posix.Process.W_CHILD (valOf holder), []);

(* 16 missing once B, which the first writer published, is fetched: the
   writer runs, without asking for the base theories again. *)
val _ = remove [List.nth (ps, 15)];
val _ = writes (ps @ ["base-theories"]);
val _ = E.write_text (OS.Path.concat (store "hol1", "base-theories")) "bool\n";
val {installed, fetched, ...} = fill_by "hol1" 100;
val _ = check "B was not fetched" (fetched = 1);
val _ = check "no writer ran for 16 missing modules" (runs "hol1" = 2 andalso installed = 16);
val _ = check "the missing modules were not stored" (List.all (stored "hol1") (b :: ps));
val _ = check "the base theories were asked for again" (not (script_has "hol1" "Theory.ancestry"));
val _ = check "the base theories were replaced"
          (E.read_text (OS.Path.concat (store "hol1", "base-theories")) = "bool\n");

(* A toolchain that can't write modules is not asked again. *)
val _ = E.write_text "$tmpdir/hol2/tools-poly/poly/theory_modules.ML" "";
val _ = writes ["unsupported"];
val _ = fill "hol2";
val _ = check "the unsupported marker was not stored" (runs "hol2" = 1 andalso stored "hol2" "unsupported");
val _ = fill "hol2";
val _ = check "a writer ran for an unsupported toolchain" (runs "hol2" = 1);

(* The cache cap's sweep skips a store while its writer holds the lock. *)
fun lock_store hol =
  case Posix.Process.fork () of
      NONE => (ignore (HolbuildFileLock.try_acquire_path
                         {path = OS.Path.concat (store hol, "writer.lock"), obsolete_kind = NONE});
               E.write_text ("$tmpdir/locked-" ^ hol) "";
               OS.Process.sleep (Time.fromSeconds 60);
               Posix.Process.exit 0w0)
    | SOME pid =>
        let fun await () = if exists ("$tmpdir/locked-" ^ hol) then ()
                           else (OS.Process.sleep (Time.fromMilliseconds 50); await ())
        in await (); pid end;
fun unlock pid =
  (Posix.Process.kill (Posix.Process.K_PROC pid, Posix.Signal.kill);
   ignore (Posix.Process.waitpid (Posix.Process.W_CHILD pid, [])));
fun sweep () = List.app (fn {evict, ...} => ignore (evict ())) (E.module_cache_families "$tmpdir/cache");
val writer = lock_store "hol1";
val _ = sweep ();
val _ = check "the sweep evicted a store its writer was filling" (stored "hol1" b);
val _ = check "the sweep kept an idle store" (not (exists (store "hol2")));
val _ = unlock writer;
val _ = sweep ();
val _ = check "the sweep kept an idle store once its writer finished" (not (exists (store "hol1")));
val _ = check "the sweep left an evicted store behind"
          (null (HolbuildCache.children (E.module_stores ())));

(* Too close to its deadline, no writer starts; one that runs past it is
   killed there, and the modules it finished are stored. *)
val _ = E.write_text "$tmpdir/hol4/tools-poly/poly/theory_modules.ML" "";
val _ = writes [a, b];
val _ = check "a writer started with 3 s left" (#installed (fill_by "hol4" 3) = 0 andalso runs "hol4" = 0);
val _ = E.write_text "$tmpdir/hang" "";
val t0 = Time.now ();
val {installed, missing, published, ...} = fill_by "hol4" 6;
val _ = OS.FileSys.remove "$tmpdir/hang";
val _ = check "the writer was not stopped at its deadline"
          (runs "hol4" = 1 andalso Time.< (Time.- (Time.now (), t0), Time.fromSeconds 15));
val _ = check "a stopped writer's modules were not stored"
          (installed = 2 andalso missing > 2 andalso List.all (stored "hol4") [a, b]);
val _ = check "a module was published without the time for a stalled request"
          (published = 0);
val _ = check "a stopped writer left its output" (not (exists (OS.Path.concat (store "hol4", ".writer"))));
val _ = check "a stopped writer left its script or log"
          (not (exists "$tmpdir/root/.holbuild/theory-module-writer.sml") andalso
           not (exists "$tmpdir/root/.holbuild/theory-module-writer.log"));

(* A writer with the time publishes the modules it stored.  A store of
   the same toolchain on another host fetches them instead of writing
   them. *)
fun remove_store hol =
  (List.app OS.FileSys.remove (HolbuildCache.children (store hol));
   OS.FileSys.rmDir (store hol));
val _ = remove_store "hol4";
val {installed, published, ...} = fill_by "hol4" 100;
val _ = check "the writer did not publish the modules it stored" (installed = 2 andalso published = 2);
val _ = remove_store "hol4";
val _ = writes [];
val {installed, fetched, published, ...} = fill_by "hol4" 100;
val _ = check "published modules were not fetched"
          (fetched = 2 andalso installed = 0 andalso published = 0 andalso List.all (stored "hol4") [a, b]);
val _ = check "the writer did not run for the modules still missing" (runs "hol4" = 3);

(* The cache lost A's blob, before its entry: the next writer rewrites A
   and replaces the entry, so a store after it fetches both again. *)
fun blob_path hol file = "$tmpdir/remote/cas/" ^ HolbuildHash.file_sha256 (OS.Path.concat (store hol, file));
val _ = OS.FileSys.remove (blob_path "hol4" a);
val _ = remove_store "hol4";
val _ = writes [a, b];
val {fetched, published, ...} = fill_by "hol4" 100;
val _ = check "A's lost blob was not replaced" (fetched = 1 andalso published = 1);
val _ = remove_store "hol4";
val _ = writes [];
val {fetched, ...} = fill_by "hol4" 100;
val _ = check "A's replaced entry was not fetched" (fetched = 2);

(* The cache loses A's blob again, and another host puts it back while
   this writer runs: the module is fetched, and the entry stays. *)
val a_blob_path = blob_path "hol4" a;
val _ = E.copy_binary a_blob_path "$tmpdir/a-blob";
val _ = OS.FileSys.remove a_blob_path;
val _ = remove_store "hol4";
val _ = writes [a];
val _ = E.write_text "$tmpdir/plant" ("cp $tmpdir/a-blob " ^ a_blob_path ^ "\n");
val {fetched, published, ...} = fill_by "hol4" 100;
val _ = check "an entry healed while the writer ran was replaced" (fetched = 2 andalso published = 0);

(* An entry the writer can't fetch from, but that names a blob the cache
   holds, stays, and the module the writer wrote for it isn't uploaded. *)
fun cas_puts () =
  length (List.filter (String.isPrefix "PUT /cas/")
            (String.tokens (fn c => c = #"\n") (E.read_text "$tmpdir/server/requests.log")));
val _ = E.write_text (blob_path "hol4" b) "corrupt\n";
val _ = remove_store "hol4";
val _ = writes [a, b];
val puts = cas_puts ();
val {fetched, published, ...} = fill_by "hol4" 100;
val _ = check "a module of a present entry was published"
          (fetched = 1 andalso published = 0 andalso cas_puts () = puts);

(* Another host published A while this writer ran, with other bytes:
   its module is stored, not this writer's, which isn't uploaded. *)
val _ = E.write_text "$tmpdir/hol5/tools-poly/poly/theory_modules.ML" "";
fun entries dir = E.sort_strings (map OS.Path.file (HolbuildCache.children dir));
val earlier = entries "$tmpdir/remote/ac";
val _ = writes [a];
val _ = fill_by "hol5" 100;
val a_entry = hd (List.filter (fn e => not (List.exists (fn x => x = e) earlier)) (entries "$tmpdir/remote/ac"));
val winner = E.read_text (OS.Path.concat (store "hol5", a));
val _ = E.copy_binary ("$tmpdir/remote/ac/" ^ a_entry) "$tmpdir/a-entry-saved";
val _ = OS.FileSys.rename {old = "$tmpdir/remote/ac/" ^ a_entry, new = "$tmpdir/a-entry"};
val _ = remove_store "hol5";
val _ = E.write_text "$tmpdir/plant" ("mv $tmpdir/a-entry $tmpdir/remote/ac/" ^ a_entry ^ "\n");
val puts = cas_puts ();
val {installed, fetched, published, ...} = fill_by "hol5" 100;
val _ = check "the writer's module was stored over the published one"
          (runs "hol5" = 2 andalso installed = 0 andalso fetched = 1 andalso published = 0 andalso
           E.read_text (OS.Path.concat (store "hol5", a)) = winner);
val _ = check "a module another host published was uploaded" (cas_puts () = puts);

(* A module a restore put in the store while the writer ran stays. *)
val _ = remove_store "hol5";
val _ = OS.FileSys.remove ("$tmpdir/remote/ac/" ^ a_entry);
val _ = E.write_text "$tmpdir/plant" ("printf restored > " ^ OS.Path.concat (store "hol5", a) ^ "\n");
val {installed, published, ...} = fill_by "hol5" 100;
val _ = check "a module in the store was replaced"
          (installed = 0 andalso published = 1 andalso E.read_text (OS.Path.concat (store "hol5", a)) = "restored");
(* On a cache of one node, an entry put is not read back. *)
val requests_after_put =
  List.foldl (fn (line, after) => if line = "PUT /ac/" ^ a_entry then [] else line :: after) []
    (String.tokens (fn c => c = #"\n") (E.read_text "$tmpdir/server/requests.log"));
val _ = check "an entry put on a cache of one node was read back"
          (not (List.exists (fn line => line = "GET /ac/" ^ a_entry) requests_after_put));

(* Another host publishes A while this writer uploads its module: the
   put conflicts, and the other host's module is stored. *)
val _ = OS.FileSys.rename {old = "$tmpdir/remote/ac/" ^ a_entry, new = "$tmpdir/a-mine"};
val _ = remove_store "hol5";
val _ = E.write_text "$tmpdir/plant"
          ("touch $tmpdir/control/cas-put-enable\n" ^
           detach ("put-during-upload " ^ a_entry ^ " $tmpdir/a-entry-winner"));
val _ = E.copy_binary "$tmpdir/a-entry-saved" "$tmpdir/a-entry-winner";
val {installed, fetched, published, ...} = fill_by "hol5" 100;
val _ = List.app (fn f => OS.FileSys.remove ("$tmpdir/control/" ^ f) handle OS.SysErr _ => ())
          ["cas-put-enable", "cas-put-count", "cas-put-release"];
val _ = check "a module whose put conflicted was stored over the published one"
          (installed = 0 andalso fetched = 1 andalso published = 0 andalso
           E.read_text (OS.Path.concat (store "hol5", a)) = winner);

(* A malformed entry holds A's key: nothing is stored or uploaded. *)
val _ = OS.FileSys.remove ("$tmpdir/remote/ac/" ^ a_entry);
(* A blob line with no role, naming A's blob. *)
val a_blob =
  hd (List.mapPartial
        (fn line => if String.isPrefix "blob=" line andalso String.isSubstring " file " line
                    then SOME (hd (String.tokens (fn c => c = #" ") (String.extract (line, 5, NONE))))
                    else NONE)
        (String.tokens (fn c => c = #"\n") (E.read_text "$tmpdir/a-entry-saved")));
val earlier = entries "$tmpdir/remote/ac";
val _ = check "a malformed entry was not put"
          (HolbuildRemoteCache.put_action remote HolbuildCacheBackend.PutIfAbsent
             {key = "malformed", text = "blob=" ^ a_blob ^ "\n"} = HolbuildCacheBackend.Published);
val _ = OS.FileSys.rename
          {old = "$tmpdir/remote/ac/" ^ hd (List.filter (fn e => not (List.exists (fn x => x = e) earlier))
                                              (entries "$tmpdir/remote/ac")),
           new = "$tmpdir/remote/ac/" ^ a_entry};
val _ = remove_store "hol5";
val puts = cas_puts ();
val {installed, fetched, published, ...} = fill_by "hol5" 100;
val _ = check "a module was stored or uploaded under a malformed entry"
          (installed = 0 andalso fetched = 0 andalso published = 0 andalso not (stored "hol5" a) andalso
           cas_puts () = puts);
val _ = E.copy_binary "$tmpdir/a-entry-saved" ("$tmpdir/remote/ac/" ^ a_entry);

(* On a cache of two nodes, a writer stores the modules it published once
   it reads their entries back, and puts them on the other node too. *)
val remote2 = HolbuildRemoteCache.remote "$remote_url,$remote2_url";
val _ = E.write_text "$tmpdir/hol6/tools-poly/poly/theory_modules.ML" "";
val _ = writes [a, b];
val {installed, published, ...} =
  E.fill_module_store remote2 "$tmpdir/root" (tc "hol6") wanted (Time.+ (Time.now (), Time.fromSeconds 100));
val _ = check "a writer on two nodes did not store or publish its modules"
          (installed = 2 andalso published = 2 andalso List.all (stored "hol6") [a, b]);
val _ = check "an entry is not on both nodes"
          (length (entries "$tmpdir/remote2/ac") >= 2 andalso
           List.all (fn e => exists ("$tmpdir/remote/ac/" ^ e)) (entries "$tmpdir/remote2/ac"));

(* Another host publishes a module between this writer's entry and its
   read back: its module is stored, not this writer's, and this writer's
   entry is on neither node. *)
val p16 = List.nth (ps, 15);
fun fill6 () =
  E.fill_module_store remote2 "$tmpdir/root" (tc "hol6") wanted (Time.+ (Time.now (), Time.fromSeconds 100));
val earlier = entries "$tmpdir/remote/ac";
val _ = writes [p16];
val _ = fill6 ();
val p16_entry = hd (List.filter (fn e => not (List.exists (fn x => x = e) earlier)) (entries "$tmpdir/remote/ac"));
val winner = E.read_text (OS.Path.concat (store "hol6", p16));
val _ = OS.FileSys.rename {old = "$tmpdir/remote/ac/" ^ p16_entry, new = "$tmpdir/p16-entry"};
val _ = OS.FileSys.remove ("$tmpdir/remote2/ac/" ^ p16_entry);
val _ = OS.FileSys.remove (OS.Path.concat (store "hol6", p16));
val _ = E.write_text "$tmpdir/plant" (detach ("replace-entry " ^ p16_entry ^ " $tmpdir/p16-entry"));
fun entry_puts () =
  length (List.filter (fn line => line = "PUT /ac/" ^ p16_entry)
            (List.concat (map (fn log => String.tokens (fn c => c = #"\n") (E.read_text log))
                              ["$tmpdir/server/requests.log", "$tmpdir/server2/requests.log"])));
val puts_before = entry_puts ();
val {installed, fetched, published, ...} = fill6 ();
val _ = check "the writer's entry was sent to a second node" (entry_puts () = puts_before + 1);
val _ = check "the writer's module was stored over the one published before its read back"
          (installed = 0 andalso fetched = 1 andalso published = 0 andalso
           E.read_text (OS.Path.concat (store "hol6", p16)) = winner);
val _ = check "the writer's entry was put on a node over the one published before its read back"
          (List.all (fn node => E.read_text ("$tmpdir/" ^ node ^ "/ac/" ^ p16_entry) = E.read_text "$tmpdir/p16-entry")
                    ["remote", "remote2"]);
(* Its entry gone at the read back, the writer stores its module. *)
val p15 = List.nth (ps, 14);
val _ = OS.FileSys.remove (OS.Path.concat (store "hol6", p16));
val _ = List.app (fn node => OS.FileSys.remove ("$tmpdir/" ^ node ^ "/ac/" ^ p16_entry)) ["remote", "remote2"];
val earlier = entries "$tmpdir/remote/ac" @ entries "$tmpdir/remote2/ac";
fun fresh dir = List.filter (fn e => not (List.exists (fn x => x = e) earlier)) (entries dir);
val _ = writes [p15];
val _ = E.write_text "$tmpdir/plant" ("bash $tmpdir/drop-new-entry baseline\n" ^ detach "drop-new-entry");
val {installed, fetched, published, ...} = fill6 ();
val _ = check "a writer whose entry was gone at its read back did not store its module"
          (installed = 1 andalso fetched = 0 andalso published = 1 andalso stored "hol6" p15 andalso
           null (fresh "$tmpdir/remote/ac") andalso null (fresh "$tmpdir/remote2/ac"));

(* P14's blob is only on the node a fetch asks second: the writer asks
   both, and fetches P14's module rather than replacing its entry. *)
val p14 = List.nth (ps, 13);
val _ = writes [p14];
val _ = check "a writer on two nodes did not publish P14" (#published (fill6 ()) = 1);
val p14_bytes = E.read_text (OS.Path.concat (store "hol6", p14));
val p14_sha = HolbuildHash.file_sha256 (OS.Path.concat (store "hol6", p14));
val (first_node, second_node) =
  if String.isPrefix "$remote2_url/cas/" (hd (HolbuildRemoteCache.cas_urls remote2 p14_sha))
  then ("remote2", "remote") else ("remote", "remote2");
val _ = E.write_text ("$tmpdir/" ^ second_node ^ "/cas/" ^ p14_sha) p14_bytes;
val _ = OS.FileSys.remove ("$tmpdir/" ^ first_node ^ "/cas/" ^ p14_sha) handle OS.SysErr _ => ();
val _ = OS.FileSys.remove (OS.Path.concat (store "hol6", p14));
val {installed, fetched, published, ...} = fill6 ();
val _ = check "a module whose blob one node lacks was not fetched from the other"
          (installed = 0 andalso fetched = 1 andalso published = 0 andalso
           E.read_text (OS.Path.concat (store "hol6", p14)) = p14_bytes);

(* Before an action's first child, a new store fetches what another host
   published, once it has its base theories (from the v1 store) and lacks
   16 or more modules not found unpublished before; it records those found
   unpublished, and gives the store's lock up after a while. *)
val _ = E.write_text "$tmpdir/hol7/tools-poly/poly/theory_modules.ML" "";
val _ = OS.FileSys.mkDir (E.module_store_v1 "$tmpdir/hol7");
val _ = E.write_text (OS.Path.concat (E.module_store_v1 "$tmpdir/hol7", "base-theories")) "bool\n";
val published16 = a :: b :: List.take (ps, 14);
val _ = writes published16;
val {published, ...} = fill_by "hol7" 100;
val _ = check "the first writer did not publish 16 modules" (published = 16 andalso runs "hol7" = 1);
(* A's entry outlives its blob. *)
val a7_blob = blob_path "hol7" a;
val a7_bytes = E.read_text a7_blob;
val _ = OS.FileSys.remove a7_blob;
val _ = remove_store "hol7";
fun requests () = length (String.tokens (fn c => c = #"\n") (E.read_text "$tmpdir/server/requests.log"));
fun prefetch () = E.prefetch_modules remote "$tmpdir/root" (tc "hol7") wanted;
val _ = prefetch ();
val probed = OS.Path.concat (store "hol7", ".probed-missing");
val _ = check "published modules were not prefetched" (List.all (stored "hol7") (tl published16));
val _ = check "a module whose blob is gone was stored" (not (stored "hol7" a));
val _ = check "the unpublished modules were not recorded, or one whose blob is gone was"
          (exists probed andalso
           E.sort_strings (String.tokens Char.isSpace (E.read_text probed)) =
           E.sort_strings (List.mapPartial E.module_file_theory_part (List.drop (ps, 14))));
val _ = E.write_text a7_blob a7_bytes;
val _ = E.write_text (OS.Path.concat (store "hol7", a)) a7_bytes;
val _ = check "a writer ran to prefetch" (runs "hol7" = 1);
fun remove7 files = List.app (fn f => OS.FileSys.remove (OS.Path.concat (store "hol7", f))) files;
val _ = remove7 (List.take (published16, 15));
val before_requests = requests ();
val _ = prefetch ();
val _ = check "a store lacking 15 modules, besides 2 unpublished, was prefetched"
          (requests () = before_requests);
val _ = remove7 [List.nth (published16, 15)];
val holder = lock_store "hol7";
val t0 = Time.now ();
val _ = prefetch ();
val _ = check "a prefetch didn't give a held lock up in time"
          (Time.< (Time.- (Time.now (), t0), Time.fromSeconds 25) andalso requests () = before_requests);
val _ = unlock holder;
val _ = prefetch ();
val _ = check "16 missing modules were not prefetched" (List.all (stored "hol7") published16);

(* With a cache, the writer's child is stopped in time for a stalled
   request before the publishing deadline, 10 s past the writer's. *)
val _ = E.write_text "$tmpdir/hol8/tools-poly/poly/theory_modules.ML" "";
val _ = writes [a, b];
val _ = E.write_text "$tmpdir/hang" "";
val {installed, published, ...} = fill_by "hol8" 33;
val _ = OS.FileSys.remove "$tmpdir/hang";
val _ = check "a writer's child ran past the time to publish its modules"
          (installed = 2 andalso published = 2);
(* A lookup that ends with no time left for an upload: the module is
   stored, and not uploaded. *)
val _ = writes [List.nth (ps, 0)];
val _ = E.write_text "$tmpdir/plant"
          ("touch $tmpdir/control/action-get-enable\n" ^
           detach "hold-lookups");
val puts = cas_puts ();
val {installed, published, ...} = fill_by "hol8" 33;
val _ = List.app (fn f => OS.FileSys.remove ("$tmpdir/control/" ^ f) handle OS.SysErr _ => ())
          ["action-get-enable", "action-get-count", "action-get-release"];
val _ = check "a module with no time left to publish was not stored, or was uploaded"
          (installed = 1 andalso published = 0 andalso stored "hol8" (List.nth (ps, 0)) andalso cas_puts () = puts);

(* The remote key of a module is the v1 store's. *)
val _ = check "a module's remote key changed"
          (E.module_remote_keys (tc "hol1") [("w", "$tmpdir/root/src/ATheory.dat")] =
           [("w", HolbuildHash.string_sha256
                    ("holbuild-theory-module-v1\ntoolchain=" ^ HolbuildToolchain.toolchain_key (tc "hol1") ^
                     "\nstore=" ^ HolbuildHash.string_sha256 "$tmpdir/hol1" ^ "\nmodule=w\ndat-sha256=" ^
                     HolbuildHash.file_sha256 "$tmpdir/root/src/ATheory.dat" ^ "\n"))]);

(* A writer whose lock file the sweep unlinked between its open and its
   lock holds a lock nobody else sees: it must not write. *)
val stale = valOf (HolbuildFileLock.try_acquire_path {path = "$tmpdir/stale.lock", obsolete_kind = NONE});
val _ = check "a fresh lock is not at its path" (HolbuildFileLock.at_path stale);
val _ = OS.FileSys.remove "$tmpdir/stale.lock";
val _ = E.write_text "$tmpdir/stale.lock" "";
val _ = check "an unlinked lock is at its path" (not (HolbuildFileLock.at_path stale));
val _ = HolbuildFileLock.release stale;
SML
if [[ -d /dev/shm && -w /dev/shm && $(stat -c %d /dev/shm) != $(stat -c %d "$tmpdir") ]]; then
  other_fs=$(mktemp -d /dev/shm/holbuild-module-writer.XXXXXX)
  cat >> "$tmpdir/writer.sml" <<SML
(* A store on another file system: rename can't reach it, so modules are copied in. *)
val _ = E.write_text "$tmpdir/hol3/tools-poly/poly/theory_modules.ML" "";
val _ = Posix.FileSys.symlink {old = "$other_fs", new = store "hol3"};
val _ = writes [a, b, "base-theories"];
val _ = fill "hol3";
val _ = check "modules were not stored on another file system"
          (runs "hol3" = 1 andalso List.all (stored "hol3") [a, b, "base-theories"]);
val _ = check "the writer wrote off the store's file system"
          (E.read_text "$tmpdir/hol3.output-device" =
           Int.toString (SysWord.toInt (Posix.FileSys.devToWord (Posix.FileSys.ST.dev
             (Posix.FileSys.stat "$other_fs")))) ^ "\n");
SML
else
  echo "skipping the store on another file system: no /dev/shm on another file system"
fi
(cd "$ROOT" && HOLBUILD_CACHE="$tmpdir/cache" \
  "${HOLBUILD_POLY:-poly}" -q --error-exit --script "$tmpdir/writer.sml")
