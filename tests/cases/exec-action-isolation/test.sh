#!/usr/bin/env bash
set -euo pipefail
HOLBUILD_BIN=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
tmpdir=$(make_temp_dir)
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then kill "$server_pid"; wait "$server_pid" 2>/dev/null || true; fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT
unset HOLBUILD_REMOTE_CACHE_URL HOLBUILD_REMOTE_CACHE_CURL_CONFIG
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server"
use_case_cache "$tmpdir/client"
mkdir -p "$tmpdir/project/src"
cat > "$tmpdir/project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "isolation"
[build]
members = ["src"]
TOML
for dir in actions blobs locks cooperate; do
  mkdir -p "$tmpdir/shared/$dir"
  echo original > "$tmpdir/shared/$dir/other"
done
printf 'user = "sentinel:credential"\n' > "$tmpdir/cache.curl"
chmod 600 "$tmpdir/cache.curl"
cat > "$tmpdir/project/src/IsolatedScript.sml" <<SML
Theory Isolated
Ancestors bool

fun refuses name f =
  if (f (); true) handle OS.SysErr _ => false | IO.Io _ => false
  then raise Fail ("sandbox allowed " ^ name) else ();
fun read path () = let val input = TextIO.openIn path in TextIO.closeIn input end;
val _ = if Option.isSome (OS.Process.getEnv "HOLBUILD_REMOTE_CACHE_CURL_CONFIG") orelse
           Option.isSome (OS.Process.getEnv "REMOTE_EXEC_WORKER_TOKEN")
        then raise Fail "credential environment leaked" else ();
val pid = valOf (OS.Process.getEnv "HOLBUILD_RUN_PROBE_PID");
val _ = refuses "worker environ" (read ("/proc/" ^ pid ^ "/environ"));
val _ = refuses "cache credential" (read "$tmpdir/cache.curl");
val _ = List.app (fn dir =>
  let val path = "$tmpdir/shared/" ^ dir ^ "/other"
  in refuses "shared write" (fn () => TextIO.closeOut (TextIO.openOut path));
     refuses "shared delete" (fn () => OS.FileSys.remove path)
  end) ["actions", "blobs", "locks", "cooperate"];
val _ = refuses "symlink output" (fn () => Posix.FileSys.symlink {old = "$tmpdir/cache.curl", new = "stolen"});
val _ = if OS.Process.isSuccess (OS.Process.system "/bin/sh -c 'exit 0'") then () else raise Fail "child failed";
val timer = Timer.startRealTimer ();
val timeout = OS.Process.system "/usr/bin/timeout 0.1 /bin/sleep 2";
val _ = case Posix.Process.fromStatus timeout of
            Posix.Process.W_EXITSTATUS 0wx7c => ()
          | _ => raise Fail "subprocess timeout failed";
val _ = if Time.toReal (Timer.checkRealTimer timer) < 1.5 then ()
        else raise Fail "subprocess timeout did not stop its child";
val _ = print "credential and cache attacks denied\n";
Theorem checked: T
Proof
  simp[]
QED
SML
(cd "$tmpdir/project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload IsolatedTheory) > "$tmpdir/batch"
spec=$(awk '$1 == "action" && $5 == "isolation:IsolatedTheory" {print $4}' "$tmpdir/batch")
[[ -n "$spec" ]]
link_hol_toolchain_cache "$tmpdir/worker"
# A policy/setup failure is retryable infrastructure failure, never a final
# failed proof. The protected completion marker is not writable by HOL.
set +e
HOLBUILD_ACTION_READ_DIRS="$tmpdir" HOLBUILD_CACHE="$tmpdir/worker" "$HOLBUILD_BIN" \
  --max-heap 1024 --remote-cache "$remote_url" exec-action "$spec" --cache-limit-gb 1000 \
  --result "$tmpdir/setup.result" > "$tmpdir/setup.log" 2>&1
setup_status=$?
set -e
[[ $setup_status == 3 ]] || { cat "$tmpdir/setup.log" "$tmpdir/setup.result" >&2; exit 1; }
require_grep '^failure=internal$' "$tmpdir/setup.result"
require_grep 'sandbox did not complete cleanup and output validation' "$tmpdir/setup.log"
# A trusted parent process starts with sentinel credentials in its original
# environment, so /proc/PID/environ tests the actual leak rather than setenv.
env REMOTE_EXEC_WORKER_TOKEN=worker-sentinel HOLBUILD_REMOTE_CACHE_CURL_CONFIG="$tmpdir/cache.curl" \
  bash -c 'export HOLBUILD_RUN_PROBE_PID=$$; "$@"' worker \
  env HOLBUILD_CACHE="$tmpdir/worker" "$HOLBUILD_BIN" --max-heap 1024 --remote-cache "$remote_url" \
  exec-action "$spec" --cache-limit-gb 1000 --result "$tmpdir/result" > "$tmpdir/worker.log" 2>&1 ||
  { cat "$tmpdir/worker.log" "$tmpdir/result" >&2; exit 1; }
require_grep '^status=built$' "$tmpdir/result"
log=$(sed -n 's/^log=\([^ ]*\) .*/\1/p' "$tmpdir/result")
require_grep 'credential and cache attacks denied' "$tmpdir/remote/cas/$log"
for dir in actions blobs locks cooperate; do require_grep '^original$' "$tmpdir/shared/$dir/other"; done
[[ ! -e "$tmpdir/worker/action" && ! -e "$tmpdir/worker/checkpoints" ]]

# Trust rejection is final, even for a warm/cached action. No source from an
# unconfigured repository may reach toolchain bootstrap.
sed 's|^toolchain git=[^ ]* |toolchain git=https://untrusted.invalid/HOL.git |' \
  "$tmpdir/remote/cas/$spec" > "$tmpdir/rejected-spec"
rejected=$(sha256sum "$tmpdir/rejected-spec" | cut -d' ' -f1)
cp "$tmpdir/rejected-spec" "$tmpdir/remote/cas/$rejected"
set +e
HOLBUILD_CACHE="$tmpdir/worker" "$HOLBUILD_BIN" --remote-cache "$remote_url" \
  exec-action "$rejected" --cache-limit-gb 1000 --result "$tmpdir/rejected.result" \
  > "$tmpdir/rejected.log" 2>&1
status=$?
set -e
[[ $status == 4 ]] || { cat "$tmpdir/rejected.log" "$tmpdir/rejected.result" >&2; exit 1; }
require_grep '^failure=spec-rejected$' "$tmpdir/rejected.result"
require_grep 'HOL repository is not trusted' "$tmpdir/rejected.log"
