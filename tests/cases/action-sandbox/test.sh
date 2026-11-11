#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$ROOT/tests/lib.sh"
tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
mkdir -p "$tmpdir/home/bin" "$tmpdir/home/lib" "$tmpdir/action" "$tmpdir/checkpoints" "$tmpdir/toolchain" "$tmpdir/cache" "$tmpdir/store" "$tmpdir/out"
touch "$tmpdir/home/bin/poly" "$tmpdir/home/lib/libpolyml.so"
cat > "$tmpdir/grants.sml" <<'SML'
use "sml/holbuild-script.sml";
val root = valOf (OS.Process.getEnv "HOLBUILD_SANDBOX_TEST_ROOT");
val home = root ^ "/home";
val _ = HolbuildActionSandbox.enable (root ^ "/action", root ^ "/checkpoints");
val _ = HolbuildActionSandbox.toolchain_root := root ^ "/toolchain";
val _ = HolbuildActionSandbox.poly_executable := home ^ "/bin/poly";
val args = HolbuildActionSandbox.wrap (root ^ "/completed")
             {writable = [root ^ "/action", root ^ "/checkpoints"], readable = [], toolchain = false} ["true"];
fun reads ("--read" :: path :: rest) = path :: reads rest
  | reads (_ :: rest) = reads rest
  | reads [] = [];
val grants = reads args;
fun contains path = List.exists (fn grant => grant = path) grants;
val _ = if contains home orelse contains (home ^ "/bin") then
          raise Fail "Poly executable path exposed its whole installation parent" else ();
val _ = if contains (home ^ "/bin/poly") andalso contains (home ^ "/lib") then ()
        else raise Fail "Poly executable or shared library was not granted";
(* The host's theory-module store: every child reads it, none writes it;
   the worker's module writer writes only its own output directory. *)
fun writes ("--write" :: path :: rest) = path :: writes rest
  | writes (_ :: rest) = writes rest
  | writes [] = [];
val _ = HolbuildActionSandbox.shared_reads := [root ^ "/store"];
fun launched () =
  HolbuildActionSandbox.wrap (root ^ "/completed")
    (HolbuildActionSandbox.action_grants (root ^ "/action", root ^ "/checkpoints")) ["true"];
val action = launched ();
val writer = HolbuildActionSandbox.with_output_dirs [root ^ "/out"] launched;
fun has path paths = List.exists (fn p => p = path) paths;
val _ = if writes action = [root ^ "/action", root ^ "/checkpoints"] then ()
        else raise Fail "an action writes more than its roots";
val _ = if has (root ^ "/store") (reads action) then ()
        else raise Fail "an action cannot read the module store";
val _ = if writes writer = [root ^ "/out"] then ()
        else raise Fail "the module writer writes more than its output directory";
val _ = if List.all (fn p => has p (reads writer))
             [root ^ "/action", root ^ "/checkpoints", root ^ "/store"] then ()
        else raise Fail "the module writer cannot read the action root or the store";
val _ = if writes (launched ()) = writes action then ()
        else raise Fail "the writer's grants outlived it";
SML
(cd "$ROOT" && env -u HOLBUILD_ACTION_READ_DIRS HOLBUILD_CACHE="$tmpdir/cache" \
  HOLBUILD_SANDBOX_TEST_ROOT="$tmpdir" "${HOLBUILD_POLY:-poly}" -q --error-exit --script "$tmpdir/grants.sml")

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

python3 "$ROOT/tests/fixtures/action_sandbox_probe.py" "$ROOT/sml/action_sandbox.py"
