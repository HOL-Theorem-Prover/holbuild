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
  [[ -z "${tls_server_pid:-}" ]] || kill "$tls_server_pid" 2>/dev/null || true
  cleanup_temp_dir "$tmpdir"
}
trap cleanup EXIT

# An HTTP/1.1 server, so libcurl keeps its connection open between requests.
# Every request must carry the test credentials; /slow answers after 3 s,
# /trickle sends its 6-byte body a byte every 0.5 s,
# /gated once the file gate-release exists in the test directory (writing
# gate-event there on arrival), /missing with 404 and /error with 500, and
# PUT /store/<name> keeps a body that GET /store/<name> returns,
# /connections returns how many connections the server has accepted, and
# HEAD answers 200 with Content-Length -1.
cat > "$tmpdir/server.py" <<'PY'
import base64
import http.server
import pathlib
import sys
import threading
import time

credentials = "Basic " + base64.b64encode(b"name:secret").decode()
stored = {}
connections = 0
connections_lock = threading.Lock()
test_dir = pathlib.Path(sys.argv[2])

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        global connections
        with connections_lock:
            connections += 1
        super().setup()

    def reply(self, status, body):
        try:
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # the client gave up, as the timeout test does

    def do_GET(self):
        if self.headers.get("Authorization") != credentials:
            self.reply(401, b"")
        elif self.path == "/slow":
            time.sleep(3)
            self.reply(200, b"ok\n")
        elif self.path == "/trickle":
            try:
                self.send_response(200)
                self.send_header("Content-Length", "6")
                self.end_headers()
                for byte in b"slow!\n":
                    self.wfile.write(bytes([byte]))
                    self.wfile.flush()
                    time.sleep(0.5)
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif self.path == "/gated":
            (test_dir / "gate-event").write_text("arrived\n")
            while not (test_dir / "gate-release").exists():
                time.sleep(0.01)
            self.reply(200, b"ok\n")
        elif self.path == "/missing":
            self.reply(404, b"not found\n")
        elif self.path == "/error":
            self.reply(500, b"server error\n")
        elif self.path == "/connections":
            with connections_lock:
                count = connections
            self.reply(200, str(count).encode())
        elif self.path.startswith("/store/"):
            self.reply(200, stored[self.path])
        else:
            self.reply(200, b"ok\n")

    def do_HEAD(self):
        self.send_response(200)
        # What bazel-remote answers for a blob only in its S3 backend.
        self.send_header("Content-Length", "-1")
        self.end_headers()

    def do_PUT(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.headers.get("Authorization") != credentials:
            self.reply(401, b"")
        elif self.headers.get("X-Test") != "yes":
            self.reply(400, b"")
        else:
            stored[self.path] = body
            self.reply(201, b"")

    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_address[1]))
server.serve_forever()
PY
# The number of TCP sockets a process holds.
cat > "$tmpdir/tcp-sockets.py" <<'PY'
import os
import sys

inodes = set()
for table in ("/proc/net/tcp", "/proc/net/tcp6"):
    if os.path.exists(table):
        with open(table) as lines:
            next(lines)
            inodes.update(line.split()[9] for line in lines)
fd_dir = f"/proc/{sys.argv[1]}/fd"
links = []
for fd in os.listdir(fd_dir):
    try:
        links.append(os.readlink(os.path.join(fd_dir, fd)))
    except FileNotFoundError:
        pass  # closed since listed: the pool's reaper closes connections at any time
print(sum(link.startswith("socket:[") and link[8:-1] in inodes for link in links))
PY
python3 "$tmpdir/server.py" "$tmpdir/port" "$tmpdir" &
server_pid=$!
for _ in {1..100}; do
  [[ -s "$tmpdir/port" ]] && break
  sleep 0.01
done
[[ -s "$tmpdir/port" ]] || {
  echo "test HTTP server did not start" >&2
  exit 1
}
HTTP_TEST_URL="http://127.0.0.1:$(< "$tmpdir/port")"
export HTTP_TEST_URL HTTP_TEST_DIR=$tmpdir

# An HTTPS server with a self-signed certificate, which writes how many
# connections it has accepted to tls-accepted.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1 \
  -addext subjectAltName=IP:127.0.0.1 -keyout "$tmpdir/key.pem" -out "$tmpdir/cert.pem" 2>/dev/null
cat > "$tmpdir/tls-server.py" <<'PY'
import http.server
import pathlib
import ssl
import sys

directory = pathlib.Path(sys.argv[2])
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(directory / "cert.pem", directory / "key.pem")
accepted = 0

class Server(http.server.ThreadingHTTPServer):
    def get_request(self):
        global accepted
        sock, address = super().get_request()
        accepted += 1
        (directory / "tls-accepted").write_text(str(accepted))
        # The handshake runs in the request's thread, so a failed one blocks nothing.
        return context.wrap_socket(sock, server_side=True, do_handshake_on_connect=False), address

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "3")
        self.end_headers()
        self.wfile.write(b"ok\n")

    def log_message(self, *args):
        pass

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (ssl.SSLError, OSError):
            self.close_connection = True

server = Server(("127.0.0.1", 0), Handler)
(directory / "tls-port").write_text(str(server.server_address[1]))
server.serve_forever()
PY
python3 "$tmpdir/tls-server.py" "$tmpdir/tls-port" "$tmpdir" &
tls_server_pid=$!
for _ in {1..100}; do
  [[ -s "$tmpdir/tls-port" ]] && break
  sleep 0.01
done
[[ -s "$tmpdir/tls-port" ]] || {
  echo "test HTTPS server did not start" >&2
  exit 1
}
HTTPS_TEST_URL="https://127.0.0.1:$(< "$tmpdir/tls-port")"
export HTTPS_TEST_URL

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

fun user text = HolbuildRemoteCacheConfig.parse_curl_config_user text
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
                handle HolbuildRemoteCacheConfig.Error message => String.isSubstring "proxy" message)

val url = valOf (OS.Process.getEnv "HTTP_TEST_URL")
val dir = valOf (OS.Process.getEnv "HTTP_TEST_DIR")
val _ = HolbuildRemoteCacheConfig.set_url url
(* Until the client is set up, requests go through the curl command. *)
val _ = assert "the curl command takes a HEAD answered with Content-Length -1"
               (HolbuildRemoteCache.head_status (url ^ "/negative-length") = HolbuildHttp.Response 200)
val _ = HolbuildRemoteCacheConfig.setup_client ()
val _ = assert "libcurl is set up with the configured user" (HolbuildRemoteCacheConfig.uses_libcurl ())

fun read_file path =
  let val input = TextIO.openIn path
  in TextIO.inputAll input before TextIO.closeIn input end

fun wait_for what condition deadline =
  if condition () then ()
  else if Time.> (Time.now (), deadline) then fail ("timed out waiting for " ^ what)
  else (OS.Process.sleep (Time.fromMilliseconds 10); wait_for what condition deadline)
fun in_10s () = Time.+ (Time.now (), Time.fromSeconds 10)

val fast = HolbuildHttp.get {url = url ^ "/fast", dst = dir ^ "/fast.out", timeout = 30}
val _ = assert "GET sends the credentials and returns the HTTP status" (fast = HolbuildHttp.Response 200)
val _ = assert "GET writes the response body" (read_file (dir ^ "/fast.out") = "ok\n")

(* One thread, so the PUT and the GET reuse the kept-alive handle. *)
val body = dir ^ "/body"
val _ = let val output = TextIO.openOut body in TextIO.output (output, "uploaded\n"); TextIO.closeOut output end
val put = HolbuildHttp.put {url = url ^ "/store/single", src = body, headers = ["X-Test: yes"], timeout = 30}
val _ = assert "PUT sends the body and headers" (put = HolbuildHttp.Response 201)
val stored = HolbuildHttp.get {url = url ^ "/store/single", dst = dir ^ "/stored.out", timeout = 30}
val _ = assert "a GET after a PUT on the same handle" (stored = HolbuildHttp.Response 200)
val _ = assert "the GET returns the uploaded body" (read_file (dir ^ "/stored.out") = "uploaded\n")

val refused = HolbuildHttp.get {url = "http://127.0.0.1:1/", dst = dir ^ "/refused.out", timeout = 30}
val _ = assert "a refused connection is a transport failure with libcurl's message"
               (case refused of
                    HolbuildHttp.Failed message => String.isSubstring "127.0.0.1 port 1" message
                  | _ => false)

(* An error status is a response, not a transport failure; the remote cache
   reads a 404 as a miss whatever body it wrote. *)
val _ = assert "a 404 is a response"
               (HolbuildHttp.get {url = url ^ "/missing", dst = dir ^ "/missing.out", timeout = 30}
                = HolbuildHttp.Response 404)
val _ = assert "a 500 is a response"
               (HolbuildHttp.get {url = url ^ "/error", dst = dir ^ "/error.out", timeout = 30}
                = HolbuildHttp.Response 500)
val _ = assert "the remote cache reads a 404 as a miss"
               (HolbuildRemoteCache.curl_get {url = url ^ "/missing", dst = dir ^ "/missing.out"}
                = HolbuildCacheBackend.Miss)
val _ = assert "the remote cache reads a 500 as corrupt"
               (case HolbuildRemoteCache.curl_get {url = url ^ "/error", dst = dir ^ "/error.out"} of
                    HolbuildCacheBackend.Corrupt message => String.isSubstring "HTTP 500" message
                  | _ => false)

(* A timeout fails the transfer when it fires, and the handle still works. *)
val start = Time.now ()
val timed_out = HolbuildHttp.get {url = url ^ "/slow", dst = dir ^ "/timeout.out", timeout = 1}
val elapsed = Time.- (Time.now (), start)
val _ = assert "a timeout is a transport failure"
               (case timed_out of HolbuildHttp.Failed _ => true | _ => false)
val _ = assert ("the 1 s timeout took " ^ Time.toString elapsed ^ " s")
               (Time.< (elapsed, Time.fromMilliseconds 2000))
val _ = assert "the handle works after a timeout"
               (HolbuildHttp.get {url = url ^ "/fast", dst = dir ^ "/after-timeout.out", timeout = 30}
                = HolbuildHttp.Response 200)

(* The timeout bounds a stall, not the transfer: a body that keeps arriving
   for longer than it completes. *)
val _ = assert "a transfer that keeps moving outlasts the timeout"
               (HolbuildHttp.get {url = url ^ "/trickle", dst = dir ^ "/trickle.out", timeout = 1}
                = HolbuildHttp.Response 200)

(* Concurrent requests share the pool without mixing up transfers: each of
   16 threads uploads 25 bodies and reads each back, reusing pooled
   connections, so the server accepts at most one connection per thread. *)
fun write_file path text =
  let val output = TextIO.openOut path in TextIO.output (output, text); TextIO.closeOut output end
val results_mutex = Mutex.mutex ()
val failures = ref [] : string list ref
val finished = ref 0
fun record f = (Mutex.lock results_mutex; f (); Mutex.unlock results_mutex)
fun client thread =
  let
    fun request i =
      let
        val name = Int.toString thread ^ "-" ^ Int.toString i
        val src = dir ^ "/put-" ^ name
        val dst = dir ^ "/get-" ^ name
        val _ = write_file src ("body " ^ name ^ "\n")
        val put = HolbuildHttp.put {url = url ^ "/store/" ^ name, src = src,
                                    headers = ["X-Test: yes"], timeout = 30}
        val get = HolbuildHttp.get {url = url ^ "/store/" ^ name, dst = dst, timeout = 30}
      in
        if put = HolbuildHttp.Response 201 andalso get = HolbuildHttp.Response 200
           andalso read_file dst = "body " ^ name ^ "\n"
        then ()
        else record (fn () => failures := name :: !failures)
      end
  in
    List.app request (List.tabulate (25, fn i => i))
    handle e => record (fn () => failures := (Int.toString thread ^ ": " ^ General.exnMessage e) :: !failures);
    record (fn () => finished := !finished + 1)
  end
fun burst () =
  (finished := 0;
   List.app (fn thread => ignore (Thread.fork (fn () => client thread, []))) (List.tabulate (16, fn i => i));
   wait_for "the concurrent requests" (fn () => !finished = 16) (Time.+ (Time.now (), Time.fromSeconds 60));
   assert ("concurrent requests failed: " ^ String.concatWith ", " (!failures)) (null (!failures)))
fun accepted () =
  (assert "GET /connections"
          (HolbuildHttp.get {url = url ^ "/connections", dst = dir ^ "/connections.out", timeout = 30}
           = HolbuildHttp.Response 200);
   valOf (Int.fromString (read_file (dir ^ "/connections.out"))))

val accepted_before = accepted ()
val _ = assert "a HEAD answered with Content-Length -1 returns its status"
               (HolbuildHttp.head {url = url ^ "/negative-length", timeout = 30} = HolbuildHttp.Response 200)
val _ = assert "a GET after it on the same handle reads its body by its length"
               (HolbuildHttp.get {url = url ^ "/fast", dst = dir ^ "/after-head.out", timeout = 30}
                = HolbuildHttp.Response 200
                andalso read_file (dir ^ "/after-head.out") = "ok\n")
val _ = assert "the HEAD and the GET kept the connection" (accepted () = accepted_before)

val accepted_before = accepted ()
val _ = burst ()
val opened = accepted () - accepted_before
val _ = assert ("the burst opened " ^ Int.toString opened ^ " connections for 16 threads")
               (opened <= 16)

(* The pooled connections stay open for the next requests, and a child
   must not inherit them. *)
fun socket_count request =
  let val result = HolbuildSpawn.run request
  in
    case (HolbuildSpawn.succeeded result, Int.fromString (#output result)) of
        (true, SOME count) => count
      | _ => fail ("tcp-sockets.py failed: " ^ #output result)
  end
val self = Int.toString (SysWord.toInt (Posix.Process.pidToWord (Posix.ProcEnv.getpid ())))
val has_proc = OS.FileSys.access ("/proc/self/fd", [])
fun sockets () =
  socket_count {program = "python3", args = [dir ^ "/tcp-sockets.py", self],
                stderr = HolbuildSpawn.Inherit}

(* HOLBUILD_TEST_HTTP_IDLE_MS, set for this script, closes a connection
   unused for 3 s.  A request soon after the last reuses its connection;
   the pool empties without another request, and one after the timeout
   opens a new connection. *)
val accepted_after_burst = accepted ()
val _ = assert "a request soon after the last reuses its connection"
               (accepted () = accepted_after_burst)
val _ =
  if has_proc then
    (assert "the burst's connections are pooled" (sockets () > 0);
     assert "a spawned child inherits no connection"
            (socket_count {program = "sh", args = ["-c", "python3 \"$0\" $$", dir ^ "/tcp-sockets.py"],
                           stderr = HolbuildSpawn.Inherit} = 0);
     wait_for "the idle connections to be closed" (fn () => sockets () = 0) (in_10s ()))
  else OS.Process.sleep (Time.fromSeconds 5)
val _ = assert "a request after the idle timeout opens a new connection"
               (accepted () = accepted_after_burst + 1)
val _ =
  if has_proc then
    (assert "its connection is pooled" (sockets () = 1);
     wait_for "that connection to be closed" (fn () => sockets () = 0) (in_10s ()))
  else ()

(* A transfer waiting on a response must not hold up another thread's GC.
   The server holds /gated until gate-release exists. *)
val gated_done = ref false
val _ = Thread.fork (fn () =>
          ((ignore (HolbuildHttp.get {url = url ^ "/gated", dst = dir ^ "/gated.out", timeout = 30})
            handle _ => ());
           gated_done := true), [])
val _ = wait_for "the gated request" (fn () => OS.FileSys.access (dir ^ "/gate-event", [])) (in_10s ())
val start = Time.now ()
val _ = PolyML.fullGC ()
val gc_time = Time.- (Time.now (), start)
val _ = assert "the gated transfer is still running during the GC" (not (!gated_done))
val _ = write_file (dir ^ "/gate-release") ""
val _ = assert ("GC waited " ^ Time.toString gc_time ^ " s for the transfer")
               (Time.< (gc_time, Time.fromMilliseconds 1000))
val _ = wait_for "the gated transfer" (fn () => !gated_done) (in_10s ())

(* CA settings come from the environment variables the curl command reads,
   with its precedence. *)
local
  val libc = Foreign.getSymbol (Foreign.loadExecutable ())
  val setenv =
    Foreign.buildCall3 (libc "setenv", (Foreign.cString, Foreign.cString, Foreign.cInt), Foreign.cInt)
  val unsetenv = Foreign.buildCall1 (libc "unsetenv", Foreign.cString, Foreign.cInt)
in
  fun ca_options_with settings =
    (List.app (fn (name, SOME value) => ignore (setenv (name, value, 1))
                | (name, NONE) => ignore (unsetenv name))
              settings;
     map (fn (name, _, value) => (name, value)) (HolbuildHttp.ca_options ()))
end
val _ = assert "CURL_CA_BUNDLE wins over SSL_CERT_DIR and SSL_CERT_FILE"
               (ca_options_with [("CURL_CA_BUNDLE", SOME "/bundle"), ("SSL_CERT_DIR", SOME "/dir"),
                                 ("SSL_CERT_FILE", SOME "/file")]
                = [("CAINFO", "/bundle")])
val _ = assert "SSL_CERT_DIR and SSL_CERT_FILE"
               (ca_options_with [("CURL_CA_BUNDLE", NONE)] = [("CAPATH", "/dir"), ("CAINFO", "/file")])
val _ = assert "SSL_CERT_FILE alone" (ca_options_with [("SSL_CERT_DIR", NONE)] = [("CAINFO", "/file")])
val _ = assert "no CA settings" (ca_options_with [("SSL_CERT_FILE", NONE)] = [])

(* A handle made while the default CA directory is cleared clears it before
   applying the environment's settings; one made after the fallback doesn't. *)
fun connection_ca_options no_ca_directory =
  map (fn (name, _, value) => (name, value)) (HolbuildHttp.connection_ca_options no_ca_directory)
val _ = assert "the default CA directory is cleared"
               (connection_ca_options true = [("CAPATH", NONE)])
val _ = assert "the default CA directory is kept" (connection_ca_options false = [])
val _ = ca_options_with [("SSL_CERT_DIR", SOME "/dir")]
val _ = assert "a CA directory the environment names is set after the default is cleared"
               (connection_ca_options true = [("CAPATH", NONE), ("CAPATH", SOME "/dir")])
val _ = assert "a CA directory the environment names is set"
               (connection_ca_options false = [("CAPATH", SOME "/dir")])
val _ = ca_options_with [("SSL_CERT_DIR", NONE)]

(* HTTPS to a server whose self-signed certificate only CURL_CA_BUNDLE names.
   With a libcurl that caches the parsed CA bundle, new handles start without
   libcurl's default CA directory; the bundle alone verifies the server. *)
val tls_url = valOf (OS.Process.getEnv "HTTPS_TEST_URL")
fun tls_accepted () =
  if OS.FileSys.access (dir ^ "/tls-accepted", []) then valOf (Int.fromString (read_file (dir ^ "/tls-accepted")))
  else 0
fun tls_get () = HolbuildHttp.get {url = tls_url ^ "/", dst = dir ^ "/tls.out", timeout = 30}
(* A handle takes the CA settings when it is made, so let the pool close the
   ones the requests above left. *)
fun wait_for_empty_pool () =
  if has_proc then wait_for "the pooled connections to be closed" (fn () => sockets () = 0) (in_10s ())
  else OS.Process.sleep (Time.fromSeconds 5)
val clearing = !HolbuildHttp.clear_ca_directory
val _ = wait_for_empty_pool ()
val _ = ca_options_with [("CURL_CA_BUNDLE", SOME (dir ^ "/cert.pem"))]
val _ = assert "HTTPS verifies the server against the CA bundle" (tls_get () = HolbuildHttp.Response 200)
val _ = assert "a verified server keeps the CA directory cleared" (!HolbuildHttp.clear_ca_directory = clearing)

(* After the fallback, a pooled handle made without the default CA directory
   is closed rather than reused. *)
val accepted_before = tls_accepted ()
val _ = HolbuildHttp.clear_ca_directory := false
val _ = assert "a request after the fallback succeeds" (tls_get () = HolbuildHttp.Response 200)
val _ = assert "it doesn't reuse a handle made without the default CA directory"
               (tls_accepted () = accepted_before + (if clearing then 1 else 0))
val _ = HolbuildHttp.clear_ca_directory := clearing

(* Once the pool has closed that handle, a certificate the default CAs don't
   verify fails, after one retry on a handle with libcurl's default CA
   directory when the first had none, and later handles keep that default. *)
val _ = wait_for_empty_pool ()
val _ = ca_options_with [("CURL_CA_BUNDLE", NONE)]
val accepted_before = tls_accepted ()
val _ = assert "an unverified certificate is a transport failure"
               (case tls_get () of HolbuildHttp.Failed _ => true | _ => false)
val _ = assert "the request was retried once if the CA directory was cleared"
               (tls_accepted () = accepted_before + (if clearing then 2 else 1))
val _ = assert "the CA directory is no longer cleared" (not (!HolbuildHttp.clear_ca_directory))
val accepted_before = tls_accepted ()
val _ = assert "a later request fails without a retry"
               (case tls_get () of HolbuildHttp.Failed _ => true | _ => false)
val _ = assert "a later request connects once" (tls_accepted () = accepted_before + 1)

val _ = print "http tests passed\n"
SML

printf 'user = "name:secret"\n' > "$tmpdir/user.curl"
# --error-exit makes an uncaught exception fail the script; without it, the
# REPL reports the exception and carries on with the next declaration.
HOLBUILD_TEST_HTTP_IDLE_MS=3000 HOLBUILD_REMOTE_CACHE_CURL_CONFIG=$tmpdir/user.curl "${HOLBUILD_POLY:-poly}" --error-exit < "$tmpdir/http-test.sml" > "$tmpdir/http-test.log" 2>&1 || {
  cat "$tmpdir/http-test.log" >&2
  exit 1
}
grep -q "http tests passed" "$tmpdir/http-test.log" || {
  cat "$tmpdir/http-test.log" >&2
  exit 1
}
kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
server_pid=

# When libcurl can't be used, a build says why once and makes its requests
# with the curl command: a first build publishes to the remote cache and a
# second, with an empty local cache, restores from it.
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
printf 'connect-timeout = 10\n' > "$tmpdir/connect-timeout.curl"

build_with_curl_command() {
  local name=$1
  local expected=$2
  shift 2
  local log
  start_remote_cache_server "$tmpdir/remote-$name" "$tmpdir/server-$name"
  for run in publish restore; do
    log=$tmpdir/$name-$run.log
    link_hol_toolchain_cache "$tmpdir/cache-$name-$run"
    rm -rf "$project/.holbuild"
    (cd "$project" && env -u HOLBUILD_REMOTE_CACHE_CURL_CONFIG "$@" HOLBUILD_CACHE="$tmpdir/cache-$name-$run" HOLBUILD_CACHE_TRACE=1 \
       "$HOLBUILD_BIN" --remote-cache "$remote_url" build ATheory) > "$log" 2>&1 || {
      cat "$log" >&2
      exit 1
    }
    require_grep "remote cache: using the curl command, since $expected" "$log"
    if [[ $(grep -c "using the curl command" "$log") -ne 1 ]]; then
      echo "expected one curl command note in $log" >&2
      cat "$log" >&2
      exit 1
    fi
  done
  require_grep "remote cache published:" "$tmpdir/$name-publish.log"
  require_grep "remote cache \(hydrated\|prefetched\):" "$tmpdir/$name-restore.log"
  kill "$server_pid"
  wait "$server_pid" 2>/dev/null || true
  server_pid=
}

build_with_curl_command unloadable "libcurl could not be loaded" \
  HOLBUILD_TEST_LIBCURL=libholbuild-test-no-such-curl.so
build_with_curl_command no-asynchdns "libcurl .* has no asynchronous DNS resolver" \
  HOLBUILD_TEST_LIBCURL_NO_ASYNCHDNS=1
build_with_curl_command other-config-option "curl config .*: unsupported option connect-timeout" \
  HOLBUILD_REMOTE_CACHE_CURL_CONFIG="$tmpdir/connect-timeout.curl"

# Through libcurl, a build takes its credentials from the curl config named
# in .holconfig.toml: a first build publishes to a remote cache that requires
# them and a second, with an empty local cache, restores from it.
mkdir -p "$tmpdir/no-curl"
cat > "$tmpdir/no-curl/curl" <<'SH'
#!/usr/bin/env bash
echo "unexpected curl command" >&2
exit 99
SH
chmod +x "$tmpdir/no-curl/curl"
start_remote_cache_server "$tmpdir/remote-auth" "$tmpdir/server-auth" "$tmpdir/control-auth"
printf 'Basic %s\n' "$(printf 'name:secret' | base64)" > "$tmpdir/control-auth/authorization"
cat > "$project/.holconfig.toml" <<TOML
[remote_cache]
url = "$remote_url"
curl_config = "$tmpdir/user.curl"
TOML
for run in publish restore; do
  log=$tmpdir/holconfig-$run.log
  link_hol_toolchain_cache "$tmpdir/cache-holconfig-$run"
  rm -rf "$project/.holbuild"
  (cd "$project" && env -u HOLBUILD_REMOTE_CACHE_URL -u HOLBUILD_REMOTE_CACHE_CURL_CONFIG \
     PATH="$tmpdir/no-curl:$PATH" HOLBUILD_CACHE="$tmpdir/cache-holconfig-$run" HOLBUILD_CACHE_TRACE=1 \
     "$HOLBUILD_BIN" build ATheory) > "$log" 2>&1 || {
    cat "$log" >&2
    exit 1
  }
  if grep -q 'using the curl command\|unexpected curl command' "$log"; then
    echo "expected libcurl requests in $log" >&2
    cat "$log" >&2
    exit 1
  fi
done
require_grep "remote cache published:" "$tmpdir/holconfig-publish.log"
require_grep "remote cache \(hydrated\|prefetched\):" "$tmpdir/holconfig-restore.log"
