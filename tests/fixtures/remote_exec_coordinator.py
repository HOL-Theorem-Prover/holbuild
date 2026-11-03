#!/usr/bin/env python3
"""A stub remote-execution coordinator for tests.

POST /v1/batches stores the batch as STATE/<id>.batch and answers 201 with its
id.  GET /v1/batches/<id>/events runs `RUN <batch file>` (a stand-in for the
workers), then streams one action event per action and the batch's final
event: done when RUN exits 0, failed otherwise.  Each action is reported
running twice first, as a coordinator repeats unchanged states.  Control
files in STATE change the answers: `refuse` makes POST answer 400, `drop`
ends the event stream before the final event, `skip` reports the batch done
without running RUN.  Every request is logged to STATE/requests.log.
"""

import json
import pathlib
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state = pathlib.Path(sys.argv[2])
run = sys.argv[3]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def log_request_line(self):
        with open(state / "requests.log", "a") as log:
            log.write(f"{self.command} {self.path} {self.headers.get('Authorization', '-')}\n")

    def answer(self, code, body, separators=(",", ":")):
        data = json.dumps(body, separators=separators).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self.log_request_line()
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        if self.path != "/v1/batches":
            return self.answer(404, {"detail": "Not Found"})
        if (state / "refuse").exists():
            return self.answer(400, {"detail": "batch refused by the stub"})
        batch_id = f"b{len(list(state.glob('*.batch'))) + 1}"
        (state / f"{batch_id}.batch").write_text(body)
        # Whitespace around the colon is valid JSON the client must accept.
        self.answer(201, {"batch_id": batch_id}, separators=(", ", " : "))

    def do_GET(self):
        self.log_request_line()
        parts = self.path.split("/")
        batch = state / f"{parts[3]}.batch" if len(parts) == 5 and parts[4] == "events" else None
        if batch is None or not batch.exists():
            return self.answer(404, {"detail": "no such batch"})
        ok = (state / "skip").exists() or subprocess.run([run, str(batch)]).returncode == 0
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.end_headers()
        for line in batch.read_text().splitlines():
            fields = line.split()
            if fields[0] == "action":
                for _ in range(2):
                    running = {"type": "action", "input_key": fields[1], "theory": fields[4],
                               "state": "running", "tier": "standard", "attempts": 1,
                               "last_failure": None, "log_sha256": None}
                    self.wfile.write((json.dumps(running) + "\n").encode())
                event = {"type": "action", "input_key": fields[1], "theory": fields[4],
                         "state": "done" if ok else "failed", "tier": "standard", "attempts": 1,
                         "last_failure": None if ok else "proof", "log_sha256": None}
                self.wfile.write((json.dumps(event) + "\n").encode())
        if (state / "drop").exists():
            return
        final = {"type": "batch", "state": "done" if ok else "failed",
                 "failure": None if ok else "an action failed"}
        self.wfile.write((json.dumps(final) + "\n").encode())


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_address[1]))
server.serve_forever()
