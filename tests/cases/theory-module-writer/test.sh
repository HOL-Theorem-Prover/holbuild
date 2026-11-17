#!/usr/bin/env bash
# When the worker starts a theory-module writer: never for a HOL without
# the module helper, nor once a writer found the toolchain can't write
# modules, nor when a store with its base theories lacks fewer than 16 of
# the modules the action wants, nor while another process holds the
# store's writer lock.  A fake HOL stands in for the writer: it counts its
# runs, records its output directory's file system and leaves the files
# named in $tmpdir/writes there.  The worker cache cap's sweep leaves a
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
trap '[[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null; cleanup_temp_dir "$tmpdir"; [[ -z $other_fs ]] || rm -rf "$other_fs"' EXIT
mkdir -p "$tmpdir/cache" "$tmpdir/root/src" "$tmpdir/root/.holbuild"
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"

sha() { sha1sum "$1" | cut -d' ' -f1; }
for hol in hol1 hol2 hol3 hol4; do
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
while read -r file; do : > "\$out/\$file"; done < "$tmpdir/writes"
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
val _ = check "the writer was not asked for the base theories" (script_has "hol1" "TheoryReader.is_canonical");
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
val _ = check "the base theories were asked for again" (not (script_has "hol1" "TheoryReader.is_canonical"));
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
val {installed, missing, ...} = fill_by "hol4" 6;
val _ = OS.FileSys.remove "$tmpdir/hang";
val _ = check "the writer was not stopped at its deadline"
          (runs "hol4" = 1 andalso Time.< (Time.- (Time.now (), t0), Time.fromSeconds 15));
val _ = check "a stopped writer's modules were not stored"
          (installed = 2 andalso missing > 2 andalso List.all (stored "hol4") [a, b]);
val _ = check "a stopped writer left its output" (not (exists (OS.Path.concat (store "hol4", ".writer"))));
val _ = check "a stopped writer left its script or log"
          (not (exists "$tmpdir/root/.holbuild/theory-module-writer.sml") andalso
           not (exists "$tmpdir/root/.holbuild/theory-module-writer.log"));

(* The writer published the modules it stored.  A store of the same
   toolchain on another host fetches them instead of writing them. *)
fun remove_store hol =
  (List.app OS.FileSys.remove (HolbuildCache.children (store hol));
   OS.FileSys.rmDir (store hol));
val _ = remove_store "hol4";
val _ = writes [];
val {installed, fetched, published, ...} = fill_by "hol4" 100;
val _ = check "published modules were not fetched"
          (fetched = 2 andalso installed = 0 andalso published = 0 andalso List.all (stored "hol4") [a, b]);
val _ = check "the writer did not run for the modules still missing" (runs "hol4" = 2);

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
