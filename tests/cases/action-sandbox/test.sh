#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$ROOT/tests/lib.sh"
tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
mkdir -p "$tmpdir/home/bin" "$tmpdir/home/lib" "$tmpdir/action" "$tmpdir/checkpoints" "$tmpdir/toolchain" "$tmpdir/cache" "$tmpdir/store" "$tmpdir/out"
touch "$tmpdir/home/bin/poly" "$tmpdir/home/lib/libpolyml.so" "$tmpdir/store/a.pmo"
cat > "$tmpdir/grants.sml" <<'SML'
use "sml/holbuild-script.sml";
val root = valOf (OS.Process.getEnv "HOLBUILD_SANDBOX_TEST_ROOT");
val home = root ^ "/home";
val _ = HolbuildActionSandbox.enable (root ^ "/action", root ^ "/checkpoints");
val _ = HolbuildActionSandbox.toolchain_root := root ^ "/toolchain";
val _ = HolbuildActionSandbox.poly_executable := home ^ "/bin/poly";
val args = HolbuildActionSandbox.grant_options
             {writable = [root ^ "/action", root ^ "/checkpoints"], readable = [], toolchain = false};
fun reads ("--read" :: path :: rest) = path :: reads rest
  | reads (_ :: rest) = reads rest
  | reads [] = [];
val grants = reads args;
fun contains path = List.exists (fn grant => grant = path) grants;
val _ = if contains home orelse contains (home ^ "/bin") then
          raise Fail "Poly executable path exposed its whole installation parent" else ();
val _ = if contains (home ^ "/bin/poly") andalso contains (home ^ "/lib") then ()
        else raise Fail "Poly executable or shared library was not granted";
(* The host's theory-module store: theory children read the modules they
   are given, never the store itself, and none writes it; the worker's
   module writer writes only its own output directory and, running once
   the action's checkpoints are removed, reads none. *)
fun writes ("--write" :: path :: rest) = path :: writes rest
  | writes (_ :: rest) = writes rest
  | writes [] = [];
val _ = if contains (root ^ "/store") then raise Fail "a confined command reads the module store" else ();
val _ = HolbuildActionSandbox.module_reads := (fn () => [root ^ "/store/a.pmo"]);
val _ = if List.exists (fn path => path = root ^ "/store/a.pmo")
                       (reads (HolbuildActionSandbox.grant_options
                                 {writable = [root ^ "/action"], readable = [], toolchain = false}))
        then raise Fail "a command other than a theory child reads a module" else ();
fun launched () =
  HolbuildActionSandbox.grant_options
    (HolbuildActionSandbox.action_grants (root ^ "/action", root ^ "/checkpoints"));
val action = launched ();
val _ = OS.FileSys.rmDir (root ^ "/checkpoints");
val writer = HolbuildActionSandbox.with_output_dirs [root ^ "/out"] launched;
val _ = OS.FileSys.mkDir (root ^ "/checkpoints");
fun has path paths = List.exists (fn p => p = path) paths;
val _ = if writes action = [root ^ "/action", root ^ "/checkpoints"] then ()
        else raise Fail "an action writes more than its roots";
val _ = if has (root ^ "/store/a.pmo") (reads action) andalso not (has (root ^ "/store") (reads action)) then ()
        else raise Fail "an action reads the module store, or not its module";
val _ = if writes writer = [root ^ "/out"] then ()
        else raise Fail "the module writer writes more than its output directory";
val _ = if List.all (fn p => has p (reads writer)) [root ^ "/action", root ^ "/store/a.pmo"] andalso
           not (has (root ^ "/store") (reads writer)) then ()
        else raise Fail "the module writer reads the store, or not the action root or its module";
val _ = if has (root ^ "/checkpoints") (reads writer) then
          raise Fail "the module writer reads the action's checkpoints" else ();
val _ = if writes (launched ()) = writes action then ()
        else raise Fail "the writer's grants outlived it";
SML
(cd "$ROOT" && env -u HOLBUILD_ACTION_READ_DIRS HOLBUILD_CACHE="$tmpdir/cache" \
  HOLBUILD_SANDBOX_TEST_ROOT="$tmpdir" "${HOLBUILD_POLY:-poly}" -q --error-exit --script "$tmpdir/grants.sml")

# A theory with hundreds of checkpoints, one restored as a link into the
# store, grants each unlinked sibling directory: more than the kernel takes
# in the one argument the launch shell gets (E2BIG, then no completion).
# And when the supervisor fails, its reason reaches the caller.
cat > "$tmpdir/many-grants.sml" <<'SML'
use "sml/holbuild-script.sml";
val root = valOf (OS.Process.getEnv "HOLBUILD_SANDBOX_TEST_ROOT");
fun hex i = let val s = Int.fmt StringCvt.HEX i in CharVector.tabulate (64 - size s, fn _ => #"0") ^ s end;
val action = root ^ "/many/action";
val checkpoints = action ^ "/.holbuild/checkpoints";
val family = checkpoints ^ "/pkg/proofs/manyScript.theorems/" ^ hex 1 ^ "/hol4";
val store = root ^ "/cache/checkpoint-store/family";
val _ = HolbuildToolchain.ensure_dir family;
val _ = HolbuildToolchain.ensure_dir store;
val _ = List.app (fn i => OS.FileSys.mkDir (family ^ "/" ^ hex i)) (List.tabulate (700, fn i => i));
val _ = TextIO.closeOut (TextIO.openOut (store ^ "/state"));
val _ = Posix.FileSys.symlink {old = store ^ "/state", new = family ^ "/" ^ hex 0 ^ "/context.save"};
val _ = HolbuildToolchain.ensure_dir (action ^ "/.holbuild/stage");
val _ = HolbuildActionSandbox.enable (action, checkpoints);
val _ = HolbuildActionSandbox.action_write_dirs := SOME [action ^ "/.holbuild/stage"];
val _ = HolbuildActionSandbox.toolchain_root := root ^ "/toolchain";
val _ = HolbuildActionSandbox.poly_executable := root ^ "/home/bin/poly";
val options = HolbuildActionSandbox.grant_options
                (HolbuildActionSandbox.action_grants (action, checkpoints));
val _ = if foldl (fn (option, n) => n + size option + 3) 0 options > 131072 then ()
        else raise Fail "the grants no longer exceed one argument's limit";
fun run argv = HolbuildToolchain.run_in_dir_to_file action argv (root ^ "/many/log");
val _ = run ["/bin/sh", "-c", ": > " ^ family ^ "/" ^ hex 699 ^ "/saved"];
val _ = if OS.FileSys.access (family ^ "/" ^ hex 699 ^ "/saved", []) then ()
        else raise Fail "the confined child did not save its checkpoint";
val _ = HolbuildActionSandbox.result_file := SOME (action ^ "/result");
val reason = (run ["true"]; "") handle HolbuildToolchain.Error msg => msg;
val _ = if String.isSubstring "contains protected worker state" reason then ()
        else raise Fail ("the supervisor's failure was not reported: " ^ reason);
SML
(cd "$ROOT" && env -u HOLBUILD_ACTION_READ_DIRS HOLBUILD_CACHE="$tmpdir/cache" \
  HOLBUILD_SANDBOX_TEST_ROOT="$tmpdir" "${HOLBUILD_POLY:-poly}" -q --error-exit --script "$tmpdir/many-grants.sml")

# A confined theory child reads the modules it is given and nothing else
# of the module stores: it can't list them, nor open another module even
# by its exact name, nor write there through /tmp scratch when the cache
# is under /tmp.
cat > "$tmpdir/module-grants.sml" <<'SML'
use "sml/holbuild-script.sml";
val root = valOf (OS.Process.getEnv "HOLBUILD_SANDBOX_TEST_ROOT");
val action = root ^ "/modules/action";
val checkpoints = root ^ "/modules/checkpoints";
val stores = root ^ "/cache/theory-modules";
val store = stores ^ "/store";
fun write path text = let val out = TextIO.openOut path in TextIO.output (out, text); TextIO.closeOut out end;
val _ = List.app HolbuildToolchain.ensure_dir [action ^ "/.holbuild/stage", checkpoints, store];
val _ = List.app (fn name => write (store ^ "/" ^ name) "module\n") ["0a-ownTheory-1.pmo", "0a-otherTheory-2.pmo"];
val _ = HolbuildActionSandbox.enable (action, checkpoints);
val _ = HolbuildActionSandbox.action_write_dirs := SOME [action ^ "/.holbuild/stage"];
val _ = HolbuildActionSandbox.toolchain_root := root ^ "/toolchain";
val _ = HolbuildActionSandbox.poly_executable := root ^ "/home/bin/poly";
(* A module swept from the store after it was listed loses its grant
   instead of failing the launch. *)
val _ = HolbuildActionSandbox.module_reads :=
  (fn () => [store ^ "/0a-ownTheory-1.pmo", store ^ "/0a-goneTheory-3.pmo"]);
val report = action ^ "/.holbuild/stage/report";
val probe =
  "{ cat \"$1/0a-ownTheory-1.pmo\" && echo own; cat \"$1/0a-otherTheory-2.pmo\" || echo other-denied; " ^
  "ls \"$1\" || echo store-denied; ls \"$2\" || echo stores-denied; " ^
  "echo module > \"$1/planted.pmo\" || echo write-denied; } > \"$3\" 2>/dev/null";
val _ = HolbuildToolchain.run_in_dir_to_file action ["/bin/sh", "-c", probe, "sh", store, stores, report]
          (root ^ "/modules/log");
val got = let val input = TextIO.openIn report in TextIO.inputAll input before TextIO.closeIn input end;
val want = "module\nown\nother-denied\nstore-denied\nstores-denied\nwrite-denied\n";
val _ = if got = want then () else raise Fail ("the module grants leaked or failed:\n" ^ got);
val _ = if OS.FileSys.access (store ^ "/planted.pmo", []) then raise Fail "a theory child wrote the module store" else ();
SML
(cd "$ROOT" && env -u HOLBUILD_ACTION_READ_DIRS HOLBUILD_CACHE="$tmpdir/cache" \
  HOLBUILD_SANDBOX_TEST_ROOT="$tmpdir" "${HOLBUILD_POLY:-poly}" -q --error-exit --script "$tmpdir/module-grants.sml")

# The worker's venv must stay outside every grant, including scratch.
python3 -m venv --without-pip "$tmpdir/worker-venv"
ln -s "$tmpdir/worker-venv/bin" "$tmpdir/venv-bin"
cat > "$tmpdir/action/python-probe.py" <<'PY'
import os
from pathlib import Path
import sys

assert sys.prefix == sys.base_prefix, (sys.prefix, sys.base_prefix)
assert os.environ["PATH"] == "/usr/local/bin:/usr/bin:/bin:"
try:
    Path(sys.argv[1]).read_text()
except PermissionError:
    pass
else:
    raise AssertionError("worker venv became readable")
print("action Python uses system prefix; worker venv denied")
PY
grants=()
for directory in /usr /bin /lib /lib64; do
  [[ ! -e "$directory" ]] || grants+=(--read "$directory")
done
PATH="$tmpdir/worker-venv/bin:$tmpdir/venv-bin:/usr/local/bin:/usr/bin:/bin:" \
  "$tmpdir/worker-venv/bin/python3" -I "$ROOT/sml/action_sandbox.py" \
    --write "$tmpdir/action" "${grants[@]}" --forbid "$tmpdir/worker-venv" \
    -- /bin/sh -c 'python3 "$@"' sh "$tmpdir/action/python-probe.py" "$tmpdir/worker-venv/pyvenv.cfg"

# So does one gone between holbuild's listing and the helper's start.
python3 -I "$ROOT/sml/action_sandbox.py" --write "$tmpdir/action" "${grants[@]}" \
  --read "$tmpdir/cache/theory-modules/store/0a-goneTheory-3.pmo" -- /bin/true

# HOL's solver locations reach the action; other variables, credentials above all, don't.
solvers=(HOL4_Z3_EXECUTABLE HOL4_CVC_EXECUTABLE HOL4_CSDP_EXECUTABLE HOL4_EPROVER_EXECUTABLE
         HOL4_VAMPIRE_EXECUTABLE HOL4_ZIPPERPOSITION_EXECUTABLE HOL4_JAVA_EXECUTABLE HOL4_KODKODI MINISAT_HOME)
solver_env=()
for name in "${solvers[@]}"; do solver_env+=("$name=/opt/provers/$name"); done
env "${solver_env[@]}" HOL4_YICES_EXECUTABLE=/opt/yices REMOTE_EXEC_WORKER_TOKEN=secret \
  python3 -I "$ROOT/sml/action_sandbox.py" --write "$tmpdir/action" "${grants[@]}" \
    -- /bin/sh -c 'env > "$1"' sh "$tmpdir/action/env"
for name in "${solvers[@]}"; do require_grep "^$name=/opt/provers/$name\$" "$tmpdir/action/env"; done
if grep -E '^(HOL4_YICES_EXECUTABLE|REMOTE_EXEC_WORKER_TOKEN)=' "$tmpdir/action/env"; then
  echo "action inherited a variable outside the allowlist" >&2
  exit 1
fi

# The scratch input reaches the action only as a file it can read but not
# change.  As on a worker, the action reads the tree it writes.
mkdir -p "$tmpdir/scratch"
printf 'scratch data\n' > "$tmpdir/scratch/input"
cp "$tmpdir/scratch/input" "$tmpdir/action/input"
scratch_run() {
  python3 -I "$ROOT/sml/action_sandbox.py" --write "$tmpdir/action" --read "$tmpdir/action" --read "$tmpdir/scratch" "${grants[@]}" \
    -- env "HOLBUILD_SCRATCH_INPUT=$1" /bin/sh -c 'cat "$HOLBUILD_SCRATCH_INPUT" > "$1"' sh "$tmpdir/action/scratch-copy"
}
scratch_run "$tmpdir/scratch/input"
cmp "$tmpdir/scratch/input" "$tmpdir/action/scratch-copy"
for refused in "$tmpdir/action/input:inside a writable directory" "$tmpdir/home/bin/poly:outside the read grants" \
               "$tmpdir/scratch:is not a regular file"; do
  if scratch_run "${refused%%:*}" 2> "$tmpdir/scratch.err"; then
    echo "the sandbox admitted the scratch input ${refused%%:*}" >&2; exit 1
  fi
  require_grep "scratch input ${refused#*:}" "$tmpdir/scratch.err"
done

python3 "$ROOT/tests/fixtures/action_sandbox_probe.py" "$ROOT/sml/action_sandbox.py"
