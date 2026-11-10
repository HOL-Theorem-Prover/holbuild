#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib.sh"
tmpdir=$(make_temp_dir)
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

mkdir -p "$tmpdir/control"
echo 1048576 > "$tmpdir/control/cas-put-max-size"
start_remote_cache_server "$tmpdir/remote" "$tmpdir/server" "$tmpdir/control"
truncate -s 268435456 "$tmpdir/log"
cat > "$tmpdir/test.sml" <<'SML'
val _ = OS.FileSys.chDir (valOf (OS.Process.getEnv "HOLBUILD_ROOT"));
use "sml/holbuild-script.sml";
val dir = valOf (OS.Process.getEnv "ACTION_LOG_TEST_DIR");
val cache = HolbuildRemoteCache.remote (valOf (OS.Process.getEnv "ACTION_LOG_TEST_URL"));
val source = OS.Path.concat (dir, "log");
val dst = OS.Path.concat (dir, "restored");
fun assert message condition = if condition then () else raise Fail message;
val hash = HolbuildHash.file_sha256 source;
val failed = HolbuildRemoteCache.publish_blob cache {hash = hash, src = source};
val _ = assert "raw-size reservation must be rejected" (failed <> HolbuildCacheBackend.Published);
val (published, log, _) = HolbuildRemoteCache.publish_action_log cache source;
val _ = assert "compressed log must publish" (published = HolbuildCacheBackend.Published);
val _ = assert "log must use compressed format"
  (case log of HolbuildRemoteCache.CompressedLog _ => true | _ => false);
val descriptor = case log of HolbuildRemoteCache.CompressedLog {sha256, size, raw_sha256, raw_size} =>
                   String.concatWith " " [sha256, size, raw_sha256, raw_size]
                 | _ => raise Fail "missing compressed log";
val _ = assert "event must decode the same log"
  (HolbuildRemoteExec.action_log ("{\"log_zstd\":\"" ^ descriptor ^ "\"}") = SOME log);
val result = HolbuildBuildExec.result_text ("spec", "key")
  {status = "built", failure = NONE, wall_ms = 0, phases = [], peak = NONE,
   log = SOME (log, "268435456"), log_error = NONE};
val _ = assert "result must carry the compressed descriptor"
  (String.isSubstring ("log-zstd=" ^ descriptor ^ "\n") result);
val lost = HolbuildBuildExec.result_text ("spec", "key")
  {status = "built", failure = NONE, wall_ms = 0, phases = [], peak = NONE,
   log = NONE, log_error = SOME "cache unavailable"};
val _ = assert "success must report a publication failure"
  (String.isSubstring "status=built\n" lost andalso String.isSubstring "log-error=cache unavailable\n" lost);
val _ = assert "compressed log must restore" (HolbuildRemoteCache.fetch_action_log cache {log = log, dst = dst}
                                               = HolbuildCacheBackend.Hit);
val _ = assert "restored bytes must match" (HolbuildHash.file_sha256 dst = hash);
val _ = OS.FileSys.remove dst;
val bad = case log of HolbuildRemoteCache.CompressedLog {sha256, size, raw_sha256, ...} =>
            HolbuildRemoteCache.CompressedLog {sha256 = sha256, size = size, raw_sha256 = raw_sha256, raw_size = "1"}
          | _ => raise Fail "missing compressed log";
val _ = assert "oversized expansion must fail" (HolbuildRemoteCache.fetch_action_log cache {log = bad, dst = dst}
                                                <> HolbuildCacheBackend.Hit);
val _ = assert "failed restore must not install a file" (not (OS.FileSys.access (dst, [])));
val (compressed_sha, raw_sha, raw_size) =
  case log of HolbuildRemoteCache.CompressedLog {sha256, raw_sha256, raw_size, ...} =>
    (sha256, raw_sha256, raw_size) | _ => raise Fail "missing compressed log";
val input = BinIO.openIn (OS.Path.concat (OS.Path.concat (dir, "remote/cas"), compressed_sha));
val prefix = BinIO.inputN (input, 10) before BinIO.closeIn input;
val truncated = OS.Path.concat (dir, "truncated");
val output = BinIO.openOut truncated;
val _ = (BinIO.output (output, prefix); BinIO.closeOut output);
val truncated_sha = HolbuildHash.file_sha256 truncated;
val _ = assert "truncated blob fixture must publish"
  (HolbuildRemoteCache.publish_opaque_blob cache {hash = truncated_sha, src = truncated} = HolbuildCacheBackend.Published);
val corrupt = HolbuildRemoteCache.CompressedLog
  {sha256 = truncated_sha, size = "10", raw_sha256 = raw_sha, raw_size = raw_size};
val _ = assert "truncated stream must fail" (HolbuildRemoteCache.fetch_action_log cache {log = corrupt, dst = dst}
                                              <> HolbuildCacheBackend.Hit);
val _ = assert "truncated stream must not install a file" (not (OS.FileSys.access (dst, [])));
SML
ACTION_LOG_TEST_DIR="$tmpdir" ACTION_LOG_TEST_URL="$remote_url" poly -q --error-exit < "$tmpdir/test.sml"
