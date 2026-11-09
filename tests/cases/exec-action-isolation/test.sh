#!/usr/bin/env bash
set -euo pipefail
HOLBUILD_BIN=$1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
tmpdir=$(make_temp_dir)
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then kill "$server_pid"; wait "$server_pid" 2>/dev/null || true; fi
  for dir in "${tmp_worker:-}" "${var_tmp_worker:-}"; do [[ -z "$dir" ]] || rm -rf "$dir"; done
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
  for base in "$tmpdir/shared" "$tmpdir/worker"; do
    mkdir -p "$base/$dir"
    echo original > "$base/$dir/other"
  done
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
val _ = List.app (fn base => List.app (fn dir =>
  let val path = base ^ "/" ^ dir ^ "/other"
  in refuses "shared write" (fn () => TextIO.closeOut (TextIO.openOut path));
     refuses "shared delete" (fn () => OS.FileSys.remove path)
  end) ["actions", "blobs", "locks", "cooperate"]) ["$tmpdir/shared", "$tmpdir/worker"];
val lock = Posix.FileSys.createf ("lock", Posix.FileSys.O_WRONLY, Posix.FileSys.O.flags [],
                                  Posix.FileSys.S.flags [Posix.FileSys.S.irusr, Posix.FileSys.S.iwusr]);
val _ = Posix.IO.setlkw (lock, Posix.IO.FLock.flock {ltype = Posix.IO.F_WRLCK, whence = Posix.IO.SEEK_SET,
                                                     start = 0, len = 0, pid = NONE});
val _ = Posix.IO.close lock;
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
# A directory without owner access hides its contents from output
# validation and from cleanup.
cat > "$tmpdir/project/src/LockedScript.sml" <<'SML'
Theory Locked
Ancestors bool

val _ = Posix.FileSys.mkdir ("locked", Posix.FileSys.S.flags []);
Theorem locked: T
Proof
  simp[]
QED
SML
# Poly/ML creates OS.FileSys.tmpName files in /tmp whatever TMPDIR says.
# Two copies, since the first one's result would be reused.
for name in TmpWithheld TmpGranted; do
  cat > "$tmpdir/project/src/${name}Script.sml" <<SML
Theory $name
Ancestors bool

val _ = print ("tmpName " ^ OS.FileSys.tmpName () ^ "\\n")
        handle OS.SysErr _ => print "tmpName withheld\\n";
Theorem tmp: T
Proof
  simp[]
QED
SML
done
(cd "$tmpdir/project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload \
  IsolatedTheory LockedTheory TmpWithheldTheory TmpGrantedTheory) > "$tmpdir/batch"
spec=$(awk '$1 == "action" && $5 == "isolation:IsolatedTheory" {print $4}' "$tmpdir/batch")
locked=$(awk '$1 == "action" && $5 == "isolation:LockedTheory" {print $4}' "$tmpdir/batch")
withheld=$(awk '$1 == "action" && $5 == "isolation:TmpWithheldTheory" {print $4}' "$tmpdir/batch")
granted=$(awk '$1 == "action" && $5 == "isolation:TmpGrantedTheory" {print $4}' "$tmpdir/batch")
[[ -n "$spec" && -n "$locked" && -n "$withheld" && -n "$granted" ]]
# /tmp is granted only when no worker state lies beneath it.
run_tmp_action() {
  local worker=$1 tmp_spec=$2
  link_hol_toolchain_cache "$worker/cache"
  TMPDIR=$worker HOLBUILD_COOPERATE_DIR= HOLBUILD_CACHE="$worker/cache" "$HOLBUILD_BIN" --max-heap 1024 \
    --remote-cache "$remote_url" exec-action "$tmp_spec" --cache-limit-gb 1000 --result "$worker/result" \
    > "$worker/log" 2>&1 || { cat "$worker/log" "$worker/result" >&2; exit 1; }
  grep -q "^status=built$" "$worker/result" || { cat "$worker/log" "$worker/result" >&2; exit 1; }
  local log
  log=$(sed -n 's/^log=\([^ ]*\) .*/\1/p' "$worker/result")
  grep '^tmpName ' "$tmpdir/remote/cas/$log"
}
tmp_worker=$(mktemp -d /tmp/holbuild-test-tmp.XXXXXX)
[[ $(run_tmp_action "$tmp_worker" "$withheld") == "tmpName withheld" ]] || { echo '/tmp granted over worker state' >&2; exit 1; }
var_tmp_worker=$(mktemp -d /var/tmp/holbuild-test-tmp.XXXXXX)
granted=$(run_tmp_action "$var_tmp_worker" "$granted")
[[ $granted == "tmpName /tmp/MLTEMP"* ]] || { echo "/tmp not granted: $granted" >&2; exit 1; }
link_hol_toolchain_cache "$tmpdir/worker"
set +e
HOLBUILD_CACHE="$tmpdir/worker" "$HOLBUILD_BIN" --max-heap 1024 --remote-cache "$remote_url" \
  exec-action "$locked" --cache-limit-gb 1000 --result "$tmpdir/locked.result" > "$tmpdir/locked.log" 2>&1
locked_status=$?
set -e
[[ $locked_status == 3 ]] || { cat "$tmpdir/locked.log" "$tmpdir/locked.result" >&2; exit 1; }
require_grep '^failure=internal$' "$tmpdir/locked.result"
require_grep 'sandbox did not complete cleanup and output validation' "$tmpdir/locked.log"
[[ ! -e "$tmpdir/worker/action" ]] || { echo 'an inaccessible directory survived cleanup' >&2; exit 1; }
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
if grep -q '^log=' "$tmpdir/setup.result"; then
  echo 'failed confinement harvested an unvalidated log' >&2
  exit 1
fi
require_grep 'sandbox did not complete cleanup and output validation' "$tmpdir/setup.log"

# A failed output check must bypass checkpoint recovery and diagnostics that
# inspect child-written logs. Use an isolated runtime to inject the failure.
fault_runtime=$tmpdir/fault-runtime
mkdir -p "$fault_runtime/bin" "$fault_runtime/share/holbuild"
cp "${REAL_HOLBUILD_BIN:-$HOLBUILD_BIN}" "$fault_runtime/bin/holbuild"
cp -R "$SCRIPT_DIR/../../../sml" "$fault_runtime/share/holbuild/"
python3 - "$fault_runtime/share/holbuild/sml/action_sandbox.py" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
old = "    policy.validate_outputs()\n"
assert source.count(old) == 2  # Empty-tree check before launch, harvest check after cleanup.
before, after = source.rsplit(old, 1)
path.write_text(before + '''    for root in policy.writable:
        for log in root.rglob("holbuild-build.log"):
            log.write_text("HOL message: forged unvalidated diagnostic\\nStatic Errors\\n")
    raise SandboxError("injected post-run output rejection")
''' + after)
PY
set +e
HOLBUILD_RUN_PROBE_PID=$$ HOLBUILD_CACHE="$tmpdir/worker" "$fault_runtime/bin/holbuild" \
  --max-heap 1024 --remote-cache "$remote_url" exec-action "$spec" --cache-limit-gb 1000 \
  --result "$tmpdir/rejected-output.result" > "$tmpdir/rejected-output.log" 2>&1
output_status=$?
set -e
[[ $output_status == 3 ]] || { cat "$tmpdir/rejected-output.log" "$tmpdir/rejected-output.result" >&2; exit 1; }
require_grep '^failure=internal$' "$tmpdir/rejected-output.result"
require_grep 'sandbox did not complete cleanup and output validation' "$tmpdir/rejected-output.log"
if grep -q '^log=' "$tmpdir/rejected-output.result" || grep -q 'forged unvalidated diagnostic' "$tmpdir/rejected-output.log"; then
  echo 'failed confinement inspected or published child-written diagnostics' >&2
  exit 1
fi
# A trusted parent process starts with sentinel credentials in its original
# environment, so /proc/PID/environ tests the actual leak rather than setenv.
(cd "$tmpdir" && env REMOTE_EXEC_WORKER_TOKEN=worker-sentinel HOLBUILD_REMOTE_CACHE_CURL_CONFIG=cache.curl \
  HOLBUILD_COOPERATE_DIR= \
  bash -c 'export HOLBUILD_RUN_PROBE_PID=$$; "$@"' worker \
  env HOLBUILD_CACHE="$tmpdir/worker" "$HOLBUILD_BIN" --max-heap 1024 --remote-cache "$remote_url" \
  exec-action "$spec" --cache-limit-gb 1000 --result "$tmpdir/result") > "$tmpdir/worker.log" 2>&1 ||
  { cat "$tmpdir/worker.log" "$tmpdir/result" >&2; exit 1; }
require_grep '^status=built$' "$tmpdir/result"
log=$(sed -n 's/^log=\([^ ]*\) .*/\1/p' "$tmpdir/result")
require_grep 'credential and cache attacks denied' "$tmpdir/remote/cas/$log"
for dir in actions blobs locks cooperate; do
  for base in "$tmpdir/shared" "$tmpdir/worker"; do require_grep '^original$' "$base/$dir/other"; done
done
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
