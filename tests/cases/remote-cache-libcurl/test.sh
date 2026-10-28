#!/usr/bin/env bash
set -euo pipefail

HOLBUILD_BIN=$1
HOLDIR=$2
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../lib.sh
source "$SCRIPT_DIR/../../lib.sh"

tmpdir=$(make_temp_dir)
cleanup() {
  [[ -z "${server_pid:-}" ]] || kill "$server_pid" 2>/dev/null || true
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

# An HTTP/1.1 server, so libcurl keeps its connection open between requests.
# Every request must carry the test credentials; /slow answers after 3 s, and
# PUT /stored keeps a body that GET /stored returns.
cat > "$tmpdir/server.py" <<'PY'
import base64
import http.server
import pathlib
import sys
import time

credentials = "Basic " + base64.b64encode(b"name:secret").decode()
stored = b""

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def reply(self, status, body):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.headers.get("Authorization") != credentials:
            self.reply(401, b"")
            return
        if self.path == "/slow":
            time.sleep(3)
        self.reply(200, stored if self.path == "/stored" else b"ok\n")

    def do_PUT(self):
        global stored
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.headers.get("Authorization") != credentials:
            self.reply(401, b"")
        elif self.headers.get("X-Test") != "yes":
            self.reply(400, b"")
        else:
            stored = body
            self.reply(201, b"")

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_address[1]))
server.serve_forever()
PY
# The established TCP connections of a process.
cat > "$tmpdir/tcp-sockets.py" <<'PY'
import os
import sys

inodes = set()
for table in ("/proc/net/tcp", "/proc/net/tcp6"):
    with open(table) as lines:
        next(lines)
        inodes.update(line.split()[9] for line in lines)
fd_dir = f"/proc/{sys.argv[1]}/fd"
links = [os.readlink(os.path.join(fd_dir, fd)) for fd in os.listdir(fd_dir)]
print(sum(link.startswith("socket:[") and link[8:-1] in inodes for link in links))
PY
python3 "$tmpdir/server.py" "$tmpdir/port" &
server_pid=$!
for _ in {1..100}; do
  [[ -s "$tmpdir/port" ]] && break
  sleep 0.01
done
HTTP_TEST_URL="http://127.0.0.1:$(< "$tmpdir/port")"
export HTTP_TEST_URL HTTP_TEST_DIR=$tmpdir

cat > "$tmpdir/http-test.sml" <<'SML'
val root =
  case OS.Process.getEnv "HOLBUILD_ROOT" of
      SOME path => path
    | NONE => raise Fail "HOLBUILD_ROOT not set";

val _ = OS.FileSys.chDir root;
use "sml/holbuild-script.sml";

fun fail message = (TextIO.output (TextIO.stdErr, message ^ "\n");
                    OS.Process.exit OS.Process.failure)
fun assert message condition = if condition then () else fail message

fun user text = HolbuildHttp.curl_config_user text
val _ = assert "unquoted user" (user "user = name:secret\n" = SOME "name:secret")
val _ = assert "user with colon separator" (user "user: name:secret" = SOME "name:secret")
val _ = assert "user with space separator" (user "  user name:secret  \n" = SOME "name:secret")
val _ = assert "--user" (user "--user name:secret" = SOME "name:secret")
val _ = assert "quoted user with escapes"
               (user "user = \"na me:se\\\"cr\\\\et\"\n" = SOME "na me:se\"cr\\et")
val _ = assert "comments and blank lines"
               (user "# credentials\n\n# user = other:one\nuser = name:secret\n" = SOME "name:secret")
val _ = assert "no user" (user "# nothing here\n" = NONE)
val _ = assert "an unsupported option is reported by name"
               ((ignore (user "user = name:secret\nproxy = http://proxy\n"); false)
                handle HolbuildHttp.Error message => String.isSubstring "proxy" message)

val url = valOf (OS.Process.getEnv "HTTP_TEST_URL")
val dir = valOf (OS.Process.getEnv "HTTP_TEST_DIR")
val _ = HolbuildHttp.setup {user = SOME "name:secret"}

fun read_file path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end

val fast = HolbuildHttp.get {url = url ^ "/fast", dst = dir ^ "/fast.out", timeout = 30}
val _ = assert "GET sends the credentials and returns the HTTP status" (fast = HolbuildHttp.Response 200)
val _ = assert "GET writes the response body" (read_file (dir ^ "/fast.out") = "ok\n")

(* One thread, so the PUT and the GET reuse the kept-alive handle. *)
val body = dir ^ "/body"
val _ = let val output = TextIO.openOut body in TextIO.output (output, "uploaded\n"); TextIO.closeOut output end
val put = HolbuildHttp.put {url = url ^ "/stored", src = body, headers = ["X-Test: yes"], timeout = 30}
val _ = assert "PUT sends the body and headers" (put = HolbuildHttp.Response 201)
val stored = HolbuildHttp.get {url = url ^ "/stored", dst = dir ^ "/stored.out", timeout = 30}
val _ = assert "a GET after a PUT on the same handle" (stored = HolbuildHttp.Response 200)
val _ = assert "the GET returns the uploaded body" (read_file (dir ^ "/stored.out") = "uploaded\n")

val refused = HolbuildHttp.get {url = "http://127.0.0.1:1/", dst = dir ^ "/refused.out", timeout = 30}
val _ = assert "a refused connection is a transport failure with libcurl's message"
               (case refused of
                    HolbuildHttp.Failed message => String.isSubstring "127.0.0.1 port 1" message
                  | _ => false)

(* The pooled connection is still open; a child must not inherit it. *)
fun count_connections pid =
  #output (HolbuildSpawn.run
             {program = "python3", args = [dir ^ "/tcp-sockets.py", pid], stderr = HolbuildSpawn.Inherit})
fun spawned_count () =
  #output (HolbuildSpawn.run
             {program = "sh", args = ["-c", "python3 \"$0\" $$", dir ^ "/tcp-sockets.py"],
              stderr = HolbuildSpawn.Inherit})
val self = Int.toString (SysWord.toInt (Posix.Process.pidToWord (Posix.ProcEnv.getpid ())))
val _ =
  if OS.FileSys.access ("/proc/self/fd", []) then
    (assert "the parent holds the pooled connection" (count_connections self <> "0\n");
     assert "a spawned child inherits no connection" (spawned_count () = "0\n"))
  else ()

(* A transfer waiting on a slow response must not hold up another thread's GC. *)
val slow_done = ref false
val _ = Thread.fork (fn () =>
          (ignore (HolbuildHttp.get {url = url ^ "/slow", dst = dir ^ "/slow.out", timeout = 30});
           slow_done := true), [])
val _ = OS.Process.sleep (Time.fromMilliseconds 500)
val start = Time.now ()
val _ = PolyML.fullGC ()
val gc_time = Time.- (Time.now (), start)
val _ = assert "the slow transfer is still running during the GC" (not (!slow_done))
val _ = assert ("GC waited " ^ Time.toString gc_time ^ " s for the transfer")
               (Time.< (gc_time, Time.fromMilliseconds 1000))
fun wait_slow () = if !slow_done then () else (OS.Process.sleep (Time.fromMilliseconds 50); wait_slow ())
val _ = wait_slow ()

val _ = print "http tests passed\n"
SML

"${HOLBUILD_POLY:-poly}" < "$tmpdir/http-test.sml" > "$tmpdir/http-test.log" 2>&1 || {
  cat "$tmpdir/http-test.log" >&2
  exit 1
}
grep -q "http tests passed" "$tmpdir/http-test.log" || {
  cat "$tmpdir/http-test.log" >&2
  exit 1
}

# When the HTTP client can't be set up, a build warns once and runs without
# the remote cache.
project=$tmpdir/project
mkdir -p "$project/src"
cat > "$project/holproject.toml" <<TOML
$(write_schema2_prelude)
[project]
name = "remote-cache-libcurl-test"

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
printf 'user = "name:secret"\nproxy = "http://proxy.invalid"\n' > "$tmpdir/proxy.curl"

build_without_remote() {
  local name=$1
  local expected=$2
  shift 2
  local cache=$tmpdir/cache-$name
  local log=$tmpdir/$name.log
  link_hol_toolchain_cache "$cache"
  rm -rf "$project/.holbuild"
  (cd "$project" && env "$@" HOLBUILD_CACHE="$cache" \
     "$HOLBUILD_BIN" --remote-cache "$HTTP_TEST_URL" build ATheory) > "$log" 2>&1 || {
    cat "$log" >&2
    exit 1
  }
  require_grep "ATheory built" "$log"
  require_grep "remote cache disabled: $expected" "$log"
  if [[ $(grep -c "remote cache disabled" "$log") -ne 1 ]]; then
    echo "expected one remote cache warning in $log" >&2
    cat "$log" >&2
    exit 1
  fi
}

build_without_remote unloadable "could not load libcurl" \
  HOLBUILD_TEST_LIBCURL=libholbuild-test-no-such-curl.so
build_without_remote no-asynchdns "libcurl .* has no asynchronous DNS resolver" \
  HOLBUILD_TEST_LIBCURL_NO_ASYNCHDNS=1
build_without_remote unsupported-config "curl config .*: unsupported option proxy" \
  HOLBUILD_REMOTE_CACHE_CURL_CONFIG="$tmpdir/proxy.curl"
