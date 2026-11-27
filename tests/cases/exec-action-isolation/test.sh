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
printf 'user = "sentinel:credential"\n' > "$tmpdir/cache.curl"
chmod 600 "$tmpdir/cache.curl"
# A remote action's child gets a home and temporary directory of its own in
# the action root, and none of the worker's credentials.
cat > "$tmpdir/project/src/IsolatedScript.sml" <<'SML'
Theory Isolated
Ancestors bool

val _ = if Option.isSome (OS.Process.getEnv "HOLBUILD_REMOTE_CACHE_CURL_CONFIG") orelse
           Option.isSome (OS.Process.getEnv "REMOTE_EXEC_WORKER_TOKEN")
        then raise Fail "credential environment leaked" else ();
fun env name = getOpt (OS.Process.getEnv name, "unset");
val _ = print ("action env: " ^ String.concatWith " "
                 (map (fn name => name ^ "=" ^ env name)
                      ["HOLBUILD_ACTION_ROOT", "HOME", "TMPDIR", "TMP", "TEMP"]) ^ "\n");
Theorem checked: T
Proof
  simp[]
QED
SML
# A directory without owner access doesn't survive the action's cleanup.
cat > "$tmpdir/project/src/LockedScript.sml" <<'SML'
Theory Locked
Ancestors bool

val _ = Posix.FileSys.mkdir ("locked", Posix.FileSys.S.flags []);
Theorem locked: T
Proof
  simp[]
QED
SML
(cd "$tmpdir/project" && "$HOLBUILD_BIN" --remote-cache "$remote_url" action-spec --upload \
  IsolatedTheory LockedTheory) > "$tmpdir/batch"
spec=$(awk '$1 == "action" && $5 == "isolation:IsolatedTheory" {print $4}' "$tmpdir/batch")
locked=$(awk '$1 == "action" && $5 == "isolation:LockedTheory" {print $4}' "$tmpdir/batch")
[[ -n "$spec" && -n "$locked" ]]
link_hol_toolchain_cache "$tmpdir/worker"

HOLBUILD_CACHE="$tmpdir/worker" "$HOLBUILD_BIN" --max-heap 1024 --remote-cache "$remote_url" \
  exec-action "$locked" --cache-limit-gb 1000 --result "$tmpdir/locked.result" > "$tmpdir/locked.log" 2>&1 ||
  { cat "$tmpdir/locked.log" "$tmpdir/locked.result" >&2; exit 1; }
require_grep '^status=built$' "$tmpdir/locked.result"
[[ ! -e "$tmpdir/worker/action/.holbuild/stage" ]] || { echo 'an inaccessible directory survived cleanup' >&2; exit 1; }

(cd "$tmpdir" && env REMOTE_EXEC_WORKER_TOKEN=worker-sentinel HOLBUILD_REMOTE_CACHE_CURL_CONFIG=cache.curl \
  HOLBUILD_COOPERATE_DIR= HOLBUILD_CACHE="$tmpdir/worker" "$HOLBUILD_BIN" --max-heap 1024 \
  --remote-cache "$remote_url" exec-action "$spec" --cache-limit-gb 1000 --result "$tmpdir/result") \
  > "$tmpdir/worker.log" 2>&1 || { cat "$tmpdir/worker.log" "$tmpdir/result" >&2; exit 1; }
require_grep '^status=built$' "$tmpdir/result"
log=$(sed -n 's/^log=\([^ ]*\) .*/\1/p' "$tmpdir/result")
root=$(realpath "$tmpdir/worker/action")
home=$root/.holbuild/sandbox-home
require_grep "^action env: HOLBUILD_ACTION_ROOT=$root HOME=$home TMPDIR=$home/tmp TMP=$home/tmp TEMP=$home/tmp\$" \
  "$tmpdir/remote/cas/$log"
[[ ! -e "$home" ]] || { echo 'the action home survived the action' >&2; exit 1; }

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
require_grep '^detail=exec-action HOL repository is not trusted by this worker: https://untrusted.invalid/HOL.git$' \
  "$tmpdir/rejected.result"
if grep -q '^log=' "$tmpdir/rejected.result"; then
  echo 'a rejected spec uploaded a log' >&2
  exit 1
fi
