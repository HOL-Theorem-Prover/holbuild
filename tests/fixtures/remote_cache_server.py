#!/usr/bin/env python3

import http.server
import pathlib
import subprocess
import sys
import time
import urllib.parse


root = pathlib.Path(sys.argv[1]).resolve()
port_file = pathlib.Path(sys.argv[2])
request_log = pathlib.Path(sys.argv[3])
control = pathlib.Path(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else None


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

    def publisher_label(self):
        label = self.headers.get("X-Holbuild-Test-Publisher", "holbuild")
        if not label.replace("-", "").isalnum():
            return "publisher"
        return label

    def gate_action_miss(self):
        if control is None or "/ac/" not in self.path:
            return
        if not (control / "action-miss-enable").exists():
            return
        label = self.publisher_label()
        (control / f"action-miss-event-{label}").write_text(
            "observed\n", encoding="utf-8"
        )
        release = control / f"action-miss-release-{label}"
        while not release.exists():
            time.sleep(0.01)
        release.unlink()

    def gate_action_put_response(self):
        if control is None or "/ac/" not in self.path:
            return
        if self.headers.get("X-Holbuild-Test-Publisher") is not None:
            return
        if not (control / "action-put-enable").exists():
            return
        (control / "action-put-event").write_text("observed\n", encoding="utf-8")
        release = control / "action-put-release"
        while not release.exists():
            time.sleep(0.01)
        release.unlink()

    def gate_download(self):
        if control is None or "/cas/" not in self.path:
            return
        if not (control / "download-enable").exists():
            return
        (control / "download-event").write_text("observed\n", encoding="utf-8")
        while not (control / "download-release").exists():
            time.sleep(0.01)

    def do_GET(self):
        self.record_request()
        path = self.object_path()
        if path is None:
            return
        if not path.is_file():
            self.gate_action_miss()
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

    def do_PUT(self):
        self.record_request()
        path = self.object_path()
        if path is None:
            return
        data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.headers.get("Content-Encoding") == "zstd":
            data = subprocess.check_output(["zstd", "-q", "-d", "-c"], input=data)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.gate_action_put_response()
        self.send_response(201)
        self.end_headers()

    def log_message(self, fmt, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_address[1]), encoding="utf-8")
server.serve_forever()
