#!/usr/bin/env python3

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

    def record_request(self):
        path = urllib.parse.urlparse(self.path).path
        with request_log.open("a", encoding="utf-8") as log:
            log.write(f"{self.command} {path}\n")

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
        if control is None or "/cas/" not in self.path:
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

    def gate_action_get(self) -> None:
        if control is None or not self.path.startswith("/ac/"):
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
        if control is None or not self.path.startswith("/cas/"):
            return
        if not (control / "cas-put-enable").exists():
            return
        with action_put_lock:
            count_file = control / "cas-put-count"
            count = int(count_file.read_text()) if count_file.exists() else 0
            count_file.write_text(str(count + 1))
        while not (control / "cas-put-release").exists():
            time.sleep(0.01)

    def do_GET(self):
        self.record_request()
        self.gate_action_get()
        if not self.authorized():
            return
        if control is not None and (control / "get-status").exists():
            self.send_response(int((control / "get-status").read_text()))
            self.end_headers()
            return
        if control is not None and self.path.startswith("/ac/"):
            key = urllib.parse.urlparse(self.path).path.rsplit("/", 1)[-1]
            for name in (f"ac-get-status-{key}", "ac-get-status"):
                if (control / name).exists():
                    self.send_response(int((control / name).read_text()))
                    self.end_headers()
                    return
        if control is not None and self.path.startswith("/cas/"):
            digest = urllib.parse.urlparse(self.path).path.rsplit("/", 1)[-1]
            status = control / f"cas-get-status-{digest}"
            if status.exists():
                self.send_response(int(status.read_text()))
                self.end_headers()
                return
        path = self.object_path()
        if path is None:
            return
        if not path.is_file():
            self.send_response(404)
            self.end_headers()
            return
        self.gate_download()
        data = path.read_bytes()
        compressed = "/cas/" in self.path and "zstd" in self.headers.get(
            "Accept-Encoding", ""
        )
        if compressed:
            data = subprocess.check_output(["zstd", "-q", "-c"], input=data)
        self.send_response(200)
        if compressed:
            self.send_header("Content-Encoding", "zstd")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_HEAD(self):
        self.record_request()
        if not self.authorized():
            return
        if control is not None and (control / "head-disconnect").exists():
            self.close_connection = True
            return
        if control is not None and (control / "head-status").exists():
            self.send_response(int((control / "head-status").read_text()))
            self.end_headers()
            return
        path = self.object_path()
        if path is None:
            return
        self.send_response(200 if path.is_file() else 404)
        self.end_headers()

    def do_PUT(self):
        self.record_request()
        if not self.authorized():
            return
        path = self.object_path()
        if path is None:
            return
        data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.gate_cas_put()
        if (
            control is not None
            and self.path.startswith("/cas/")
            and (control / "cas-put-status").exists()
        ):
            self.send_response(int((control / "cas-put-status").read_text()))
            self.end_headers()
            return
        if (
            control is not None
            and self.path.startswith("/ac/")
            and (control / "ac-put-status").exists()
        ):
            self.send_response(int((control / "ac-put-status").read_text()))
            self.end_headers()
            return
        if self.headers.get("Content-Encoding") == "zstd":
            data = subprocess.check_output(["zstd", "-q", "-d", "-c"], input=data)
        if (
            control is not None
            and self.path.startswith("/cas/")
            and (control / "cas-put-reject-text").exists()
            and (control / "cas-put-reject-text").read_bytes() in data
        ):
            self.send_response(500)
            self.end_headers()
            return
        action_sequence = (
            next_action_put()
            if urllib.parse.urlparse(self.path).path.startswith("/ac/")
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


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_address[1]), encoding="utf-8")
server.serve_forever()
