#!/usr/bin/env python3

import http.server
import os
import pathlib
import subprocess
import threading
import sys
import time
import urllib.parse

from zstd_frames import zstd_encode


root = pathlib.Path(sys.argv[1]).resolve()
port_file = pathlib.Path(sys.argv[2])
request_log = pathlib.Path(sys.argv[3])
control = pathlib.Path(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else None
# A port to listen on, as a restarted server takes its predecessor's; by default any free one.
port = int(sys.argv[5]) if len(sys.argv) > 5 else 0

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
        key = control / "action-get-key"
        if key.exists() and self.path != f"/ac/{key.read_text().strip()}":
            return
        with action_put_lock:
            count_file = control / "action-get-count"
            count = int(count_file.read_text()) if count_file.exists() else 0
            count_file.write_text(str(count + 1))
        while not (control / "action-get-release").exists():
            time.sleep(0.01)

    def hold_stale_get(self, key: str) -> None:
        """control/ac-stale-hold-<key>: the first GET served the stale entry
        of <key> (a prefetch's) is held until a GET with Cache-Control:
        no-cache for <key> arrives, or 10 s pass, and then answered with the
        stale entry; control/ac-stale-hold-<key>-released says which."""
        if not (control / f"ac-stale-hold-{key}").exists():
            return
        try:
            os.close(os.open(control / f"ac-stale-hold-{key}-held", os.O_CREAT | os.O_EXCL | os.O_WRONLY))
        except FileExistsError:
            return
        recheck = control / f"ac-stale-hold-{key}-recheck"
        deadline = time.monotonic() + 10
        while not recheck.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        released = "recheck" if recheck.exists() else "timeout"
        (control / f"ac-stale-hold-{key}-released").write_text(released + "\n", encoding="utf-8")

    def release_stale_hold(self, key: str) -> None:
        """Releases the GET hold_stale_get holds, then waits up to 2 s for the
        path in control/ac-stale-hold-<key> (the client's local manifest of
        <key>) to appear before answering, so the released copy can land
        first."""
        hold = control / f"ac-stale-hold-{key}"
        if not hold.exists() or not (control / f"ac-stale-hold-{key}-held").exists():
            return
        (control / f"ac-stale-hold-{key}-recheck").write_text("observed\n", encoding="utf-8")
        watched = pathlib.Path(hold.read_text(encoding="utf-8").strip())
        deadline = time.monotonic() + 2
        while not watched.exists() and time.monotonic() < deadline:
            time.sleep(0.01)

    def gate_cas_put(self, size: int) -> None:
        """Hold a CAS PUT until control/cas-put-release exists: every one while control/cas-put-enable exists, and
        those of at least the byte count in control/cas-put-enable-min-bytes while that exists."""
        if control is None or not self.path.startswith("/cas/"):
            return
        min_bytes = control / "cas-put-enable-min-bytes"
        if not (control / "cas-put-enable").exists() and not (
            min_bytes.exists() and size >= int(min_bytes.read_text())
        ):
            return
        with action_put_lock:
            count_file = control / "cas-put-count"
            count = int(count_file.read_text()) if count_file.exists() else 0
            count_file.write_text(str(count + 1))
        while not (control / "cas-put-release").exists():
            time.sleep(0.01)

    def cas_put_fail_once(self) -> int | str | None:
        """The first line of control/cas-put-fail-once, taken by one CAS PUT:
        a status to answer, or "drop" to leave it unanswered."""
        if control is None or not self.path.startswith("/cas/"):
            return None
        with action_put_lock:
            status = control / "cas-put-fail-once"
            if not status.exists():
                return None
            first, *rest = status.read_text().split()
            if rest:
                status.write_text("".join(f"{line}\n" for line in rest))
            else:
                status.unlink()
            return first if first == "drop" else int(first)

    def cas_put_drop_once(self) -> bool:
        """Whether to leave this CAS PUT unanswered: once per control/cas-put-drop-once."""
        if control is None or not self.path.startswith("/cas/"):
            return False
        with action_put_lock:
            marker = control / "cas-put-drop-once"
            if not marker.exists():
                return False
            marker.unlink()
            return True

    def do_GET(self):
        self.record_request()
        self.gate_action_get()
        if not self.authorized():
            return
        if control is not None and (control / "get-status").exists():
            self.send_response(int((control / "get-status").read_text()))
            self.end_headers()
            return
        if (
            control is not None
            and self.path.startswith("/ac/")
            and (control / "ac-get-drop").exists()
        ):
            # Close the connection unanswered: a transport failure.
            self.close_connection = True
            return
        if control is not None and self.path.startswith("/ac/"):
            key = urllib.parse.urlparse(self.path).path.rsplit("/", 1)[-1]
            # control/no-cache-gets: the keys GETs with Cache-Control:
            # no-cache asked for, one a line.
            no_cache = "no-cache" in self.headers.get("Cache-Control", "").lower()
            if no_cache:
                with open(control / "no-cache-gets", "a") as log:
                    log.write(key + "\n")
            for name in (f"ac-get-status-{key}", "ac-get-status"):
                if (control / name).exists():
                    self.send_response(int((control / name).read_text()))
                    self.end_headers()
                    return
            # control/ac-stale-<key>: an entry a cache in front of the store
            # still serves after the store's was replaced, until a GET with
            # Cache-Control: no-cache has it check its copy.  A
            # control/ac-stale-next-<key> then takes its place: the store's
            # entry was replaced again after that check.
            stale = control / f"ac-stale-{key}"
            if stale.exists():
                if no_cache:
                    stale.unlink()
                    following = control / f"ac-stale-next-{key}"
                    if following.exists():
                        following.rename(stale)
                    self.release_stale_hold(key)
                else:
                    data = stale.read_bytes()
                    self.hold_stale_get(key)
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
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
            data = zstd_encode(data)
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
        if control is not None and (control / "head-status").exists():
            self.send_response(int((control / "head-status").read_text()))
            self.end_headers()
            return
        if control is not None and self.path.startswith("/cas/"):
            digest = urllib.parse.urlparse(self.path).path.rsplit("/", 1)[-1]
            status = control / f"cas-head-status-{digest}"
            if status.exists():
                self.send_response(int(status.read_text()))
                self.end_headers()
                return
            # control/cas-cached-<digest>: a cache in front of the store
            # still answers for a blob the store may have lost, until a HEAD
            # with Cache-Control: no-cache has it ask the store, and drop
            # its copy (the control file) if the store lacks the blob.
            no_cache = "no-cache" in self.headers.get("Cache-Control", "").lower()
            cached = control / f"cas-cached-{digest}"
            if cached.exists() and not no_cache:
                self.send_response(200)
                self.end_headers()
                return
            if cached.exists() and not (root / "cas" / digest).is_file():
                cached.unlink()
        path = self.object_path()
        if path is None:
            return
        self.send_response(200 if path.is_file() else 404)
        self.end_headers()

    def note_watched_put(self):
        """control/put-watch-<key>: a path; each PUT of /ac/<key> then appends to control/put-seen-<key> whether
        that path existed when the PUT arrived."""
        if control is None or not self.path.startswith("/ac/"):
            return
        key = urllib.parse.urlparse(self.path).path.rsplit("/", 1)[-1]
        watch = control / f"put-watch-{key}"
        if not watch.exists():
            return
        seen = "present" if pathlib.Path(watch.read_text().strip()).exists() else "absent"
        with open(control / f"put-seen-{key}", "a") as log:
            log.write(seen + "\n")

    def do_PUT(self):
        self.record_request()
        if not self.authorized():
            return
        path = self.object_path()
        if path is None:
            return
        data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.note_watched_put()
        self.gate_cas_put(len(data))
        if self.cas_put_drop_once():
            self.close_connection = True
            return
        failure = self.cas_put_fail_once()
        if failure == "drop":
            self.close_connection = True
            return
        if failure is not None:
            self.send_response(failure)
            self.end_headers()
            return
        if (
            control is not None
            and self.path.startswith("/cas/")
            and (control / "cas-put-status").exists()
        ):
            self.send_response(int((control / "cas-put-status").read_text()))
            self.end_headers()
            return
        while (
            control is not None
            and self.path.startswith("/ac/")
            and (control / "ac-put-hold").exists()
        ):
            time.sleep(0.01)
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
        if (
            control is not None
            and self.path.startswith("/ac/")
            and (control / "ac-put-reject-text").exists()
            and (control / "ac-put-reject-text").read_bytes() in data
        ):
            self.send_response(403)
            self.end_headers()
            return
        action_sequence = (
            next_action_put()
            if urllib.parse.urlparse(self.path).path.startswith("/ac/")
            else None
        )
        self.gate_action_put(action_sequence, "before")
        path.parent.mkdir(parents=True, exist_ok=True)
        # Into place whole, so a concurrent GET of the same object never reads it half-written.
        partial = path.with_name(f".{path.name}.{threading.get_ident()}.partial")
        partial.write_bytes(data)
        os.replace(partial, path)
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


server = Server(("127.0.0.1", port), Handler)
port_file.write_text(str(server.server_address[1]), encoding="utf-8")
server.serve_forever()
