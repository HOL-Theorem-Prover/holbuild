#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

write_server() {
  local script=$1
  cat > "$script" <<'PY'
import http.server
import os
import pathlib
import sys
import urllib.parse

root = pathlib.Path(sys.argv[1]).resolve()
port_file = pathlib.Path(sys.argv[2])

class Handler(http.server.BaseHTTPRequestHandler):
    def object_path(self):
        path = urllib.parse.urlparse(self.path).path.lstrip('/')
        if '..' in pathlib.PurePosixPath(path).parts:
            self.send_response(400)
            self.end_headers()
            return None
        return root / path

    def do_GET(self):
        path = self.object_path()
        if path is None:
            return
        if not path.is_file():
            self.send_response(404)
            self.end_headers()
            return
        data = path.read_bytes()
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_PUT(self):
        path = self.object_path()
        if path is None:
            return
        length = int(self.headers.get('Content-Length', '0'))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(self.rfile.read(length))
        self.send_response(201)
        self.end_headers()

    def log_message(self, fmt, *args):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
port_file.write_text(str(server.server_address[1]))
server.serve_forever()
PY
}

start_server() {
  local root=$1
  local script=$tmpdir/server.py
  local port_file=$tmpdir/server.port
  write_server "$script"
  python3 "$script" "$root" "$port_file" &
  server_pid=$!
  for _ in {1..50}; do
    [[ -s "$port_file" ]] && break
    sleep 0.1
  done
  [[ -s "$port_file" ]] || { echo "remote cache server did not start" >&2; exit 1; }
  remote_url="http://127.0.0.1:$(cat "$port_file")"
}

write_project() {
  local project=$1
  mkdir -p "$project/src"
  cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "remote-cache-test"

[build]
members = ["src"]
TOML
  cat > "$project/src/AScript.sml" <<'SML'
Theory A
Ancestors bool

Theorem a_thm:
  T
Proof
  simp[]
QED
SML
}

remote_root=$tmpdir/remote
mkdir -p "$remote_root"
start_server "$remote_root"

first=$tmpdir/first
second=$tmpdir/second
write_project "$first"
write_project "$second"

first_cache=$tmpdir/cache-first
second_cache=$tmpdir/cache-second
link_hol_toolchain_cache "$first_cache"
link_hol_toolchain_cache "$second_cache"

first_log=$tmpdir/first.log
(cd "$first" && HOLBUILD_CACHE="$first_cache" HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build ATheory) > "$first_log" 2>&1
require_grep "ATheory built" "$first_log"
require_grep "remote cache published:" "$first_log"

rm -rf "$second/.holbuild"
second_log=$tmpdir/second.log
(cd "$second" && HOLBUILD_CACHE="$second_cache" HOLBUILD_CACHE_TRACE=1 \
  "$HOLBUILD_BIN" --remote-cache "$remote_url" build ATheory) > "$second_log" 2>&1
require_grep "remote cache hydrated:" "$second_log"
require_grep "cache hit: ATheory" "$second_log"
require_grep "ATheory restored from cache" "$second_log"
if grep -q "ATheory built" "$second_log"; then
  echo "second build rebuilt instead of restoring from remote cache" >&2
  cat "$second_log" >&2
  exit 1
fi
