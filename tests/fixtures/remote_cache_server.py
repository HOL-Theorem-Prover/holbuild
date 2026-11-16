#!/usr/bin/env python3
"""A stand-in for bazel-remote with --disable_http_ac_validation, as holbuild uses it.

holbuild stores a blob zstd-compressed under /ac/<blob key>, blob key =
sha256("holbuild-zstd-blob-v1\n" ^ digest ^ "\n"), and the server keeps /ac/
bodies as they are.  This stub tells a blob from an action entry by the zstd
frame magic its body starts with, refuses a blob PUT whose key doesn't match
its content, and logs each blob request with a trailing " blob" (a request
for a blob it doesn't hold can't be told from an action lookup).  The cas-*
controls act on blob requests.
"""

import hashlib
import http.server
import pathlib
import subprocess
import threading
import sys
import time
import urllib.parse


root = pathlib.Path(sys.argv[1]).resolve()
port_file = pathlib.Path(sys.argv[2])
request_log = pathlib.Path(sys.argv[3])
control = pathlib.Path(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else None

action_put_lock = threading.Lock()
action_put_count = 0


ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"


def blob_key(digest):
    return hashlib.sha256(f"holbuild-zstd-blob-v1\n{digest}\n".encode()).hexdigest()


def is_blob(path):
    try:
        with path.open("rb") as stored:
            return stored.read(4) == ZSTD_MAGIC
    except OSError:
        return False


def next_action_put():
    global action_put_count
    with action_put_lock:
        action_put_count += 1
        return action_put_count


class Handler(http.server.BaseHTTPRequestHandler):
    def object_path(self):
        relative = urllib.parse.urlparse(self.path).path.lstrip("/")
        if ".." in pathlib.PurePosixPath(relative).parts:
            self.send_response(400)
            self.end_headers()
            return None
        return root / relative

    def record_request(self, blob=False):
        path = urllib.parse.urlparse(self.path).path
        with request_log.open("a", encoding="utf-8") as log:
            log.write(f"{self.command} {path}{' blob' if blob else ''}\n")

    def key(self):
        return urllib.parse.urlparse(self.path).path.rsplit("/", 1)[-1]

    def blob_get_status(self):
        """The status a cas-get-status-<digest> control sets for the blob this GET names."""
        if control is None:
            return None
        for status in control.glob("cas-get-status-*"):
            if blob_key(status.name.removeprefix("cas-get-status-")) == self.key():
                return int(status.read_text())
        return None

    def authorized(self):
        required = control / "authorization" if control is not None else None
        if required is None or not required.exists():
            return True
        if self.headers.get("Authorization") == required.read_text().strip():
            return True
        self.send_response(401)
        self.end_headers()
        return False

    def gate_download(self):
        if control is None:
            return
        if not (control / "download-enable").exists():
            return
        (control / "download-event").write_text("observed\n", encoding="utf-8")
        while not (control / "download-release").exists():
            time.sleep(0.01)

    def gate_action_put(self, sequence, position):
        if control is None or sequence is None:
            return
        stem = f"action-put-{sequence}-{position}"
        if not (control / f"{stem}-enable").exists():
            return
        (control / f"{stem}-event").write_text("observed\n", encoding="utf-8")
        while not (control / f"{stem}-release").exists():
            time.sleep(0.01)

    def gate_action_get(self, blob) -> None:
        if control is None or blob or not self.path.startswith("/ac/"):
            return
        if not (control / "action-get-enable").exists():
            return
        with action_put_lock:
            count_file = control / "action-get-count"
            count = int(count_file.read_text()) if count_file.exists() else 0
            count_file.write_text(str(count + 1))
        while not (control / "action-get-release").exists():
            time.sleep(0.01)

    def gate_cas_put(self) -> None:
        if control is None:
            return
        if not (control / "cas-put-enable").exists():
            return
        with action_put_lock:
            count_file = control / "cas-put-count"
            count = int(count_file.read_text()) if count_file.exists() else 0
            count_file.write_text(str(count + 1))
        while not (control / "cas-put-release").exists():
            time.sleep(0.01)

    def cas_put_fail_once(self):
        """The status in control/cas-put-fail-once, answered to one blob PUT."""
        if control is None:
            return None
        with action_put_lock:
            status = control / "cas-put-fail-once"
            if not status.exists():
                return None
            code = int(status.read_text())
            status.unlink()
            return code

    def do_GET(self):
        path = self.object_path()
        if path is None:
            return
        blob = is_blob(path) or self.blob_get_status() is not None
        self.record_request(blob)
        self.gate_action_get(blob)
        if not self.authorized():
            return
        if control is not None and (control / "get-status").exists():
            self.send_response(int((control / "get-status").read_text()))
            self.end_headers()
            return
        if control is not None and not blob:
            for name in (f"ac-get-status-{self.key()}", "ac-get-status"):
                if (control / name).exists():
                    self.send_response(int((control / name).read_text()))
                    self.end_headers()
                    return
        status = self.blob_get_status()
        if status is not None:
            self.send_response(status)
            self.end_headers()
            return
        if not path.is_file():
            self.send_response(404)
            self.end_headers()
            return
        if blob:
            self.gate_download()
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_HEAD(self):
        path = self.object_path()
        if path is None:
            return
        self.record_request(is_blob(path))
        if not self.authorized():
            return
        if control is not None and (control / "head-disconnect").exists():
            self.close_connection = True
            return
        if control is not None and (control / "head-status").exists():
            self.send_response(int((control / "head-status").read_text()))
            self.end_headers()
            return
        self.send_response(200 if path.is_file() else 404)
        self.end_headers()

    def do_PUT(self):
        path = self.object_path()
        if path is None:
            return
        data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        blob = data.startswith(ZSTD_MAGIC)
        self.record_request(blob)
        if not self.authorized():
            return
        if blob:
            content = subprocess.run(["zstd", "-q", "-d", "-c"], input=data, capture_output=True)
            # The server would store a Content-Encoding body decoded; holbuild must send it as it is.
            if (
                content.returncode != 0
                or "Content-Encoding" in self.headers
                or not self.path.startswith("/ac/")
                or blob_key(hashlib.sha256(content.stdout).hexdigest()) != self.key()
            ):
                self.send_response(400)
                self.end_headers()
                return
            self.gate_cas_put()
            failure = self.cas_put_fail_once()
            if failure is not None:
                self.send_response(failure)
                self.end_headers()
                return
        if (
            control is not None
            and blob
            and (control / "cas-put-status").exists()
        ):
            self.send_response(int((control / "cas-put-status").read_text()))
            self.end_headers()
            return
        if (
            control is not None
            and not blob
            and self.path.startswith("/ac/")
            and (control / "ac-put-status").exists()
        ):
            self.send_response(int((control / "ac-put-status").read_text()))
            self.end_headers()
            return
        if (
            control is not None
            and blob
            and (control / "cas-put-reject-text").exists()
            and (control / "cas-put-reject-text").read_bytes() in content.stdout
        ):
            self.send_response(500)
            self.end_headers()
            return
        action_sequence = (
            next_action_put()
            if not blob and urllib.parse.urlparse(self.path).path.startswith("/ac/")
            else None
        )
        self.gate_action_put(action_sequence, "before")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.gate_action_put(action_sequence, "after")
        self.send_response(201)
        self.end_headers()

    def log_message(self, fmt, *args):
        pass


class Server(http.server.ThreadingHTTPServer):
    # The default listen backlog of 5 overflows when a burst of parallel
    # requests arrives while a loaded machine has this process waiting for a
    # CPU, and the client then sees its connections reset.
    request_queue_size = 1024


server = Server(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_address[1]), encoding="utf-8")
server.serve_forever()
