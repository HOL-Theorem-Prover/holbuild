#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$ROOT/tests/lib.sh"
tmpdir=$(make_temp_dir)
trap 'cleanup_temp_dir "$tmpdir"' EXIT
mkdir -p "$tmpdir/home/bin" "$tmpdir/home/lib" "$tmpdir/action" "$tmpdir/checkpoints" "$tmpdir/toolchain" "$tmpdir/cache"
touch "$tmpdir/home/bin/poly" "$tmpdir/home/lib/libpolyml.so"
cat > "$tmpdir/grants.sml" <<'SML'
use "sml/holbuild-script.sml";
val root = valOf (OS.Process.getEnv "HOLBUILD_SANDBOX_TEST_ROOT");
val home = root ^ "/home";
val _ = HolbuildActionSandbox.enable (root ^ "/action", root ^ "/checkpoints");
val _ = HolbuildActionSandbox.toolchain_root := root ^ "/toolchain";
val _ = HolbuildActionSandbox.poly_executable := home ^ "/bin/poly";
val args = HolbuildActionSandbox.wrap (root ^ "/completed") ["true"];
fun reads ("--read" :: path :: rest) = path :: reads rest
  | reads (_ :: rest) = reads rest
  | reads [] = [];
val grants = reads args;
fun contains path = List.exists (fn grant => grant = path) grants;
val _ = if contains home orelse contains (home ^ "/bin") then
          raise Fail "Poly executable path exposed its whole installation parent" else ();
val _ = if contains (home ^ "/bin/poly") andalso contains (home ^ "/lib") then ()
        else raise Fail "Poly executable or shared library was not granted";
SML
(cd "$ROOT" && env -u HOLBUILD_ACTION_READ_DIRS HOLBUILD_CACHE="$tmpdir/cache" \
  HOLBUILD_SANDBOX_TEST_ROOT="$tmpdir" "${HOLBUILD_POLY:-poly}" -q --error-exit --script "$tmpdir/grants.sml")
python3 "$ROOT/tests/fixtures/action_sandbox_probe.py" "$ROOT/sml/action_sandbox.py"
