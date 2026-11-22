#!/usr/bin/env python3
"""A stub remote-execution coordinator for tests.

POST /v1/batches stores the batch as STATE/<id>.batch and answers 201 with its
id.  GET /v1/batches/<id>/events runs `RUN <batch file>` (a stand-in for the
workers), then streams one action event per action and the batch's final
event: done when RUN exits 0, failed otherwise.  In a failed batch, an action
RUN left a result for (STATE/result-<input key>, as exec-action writes it) is
reported as that result says: done, or failed with its failure, log and detail.  Each
action is reported running twice first, as a coordinator repeats unchanged
states.  A batch submitted with `?class=run` is a run batch: each action is
reported from its result (failed `internal` without one) and the batch ends
done all the same, as the coordinator ends a run batch whose actions failed;
its query is in the request log.  Control files in STATE change the answers: `refuse` makes POST answer
400, `unavailable`, holding a count, makes that many POSTs answer 502 (or the
status `unavailable-status` holds), `drop`
ends the next event stream before the final event (and is removed), `cut`
ends it midway through its first action event (and is removed), `replay`,
holding a count, makes that many event streams send the first action's running
state and then break, without running RUN, `down`
makes the event stream and POST /v1/batches/<id>/cancel answer 503, `ended`
makes the event stream answer 503 and the cancel answer that the batch is
already done, `watch`, holding a directory, makes each submitted batch <id> leave
STATE/<id>.watched: the sha256 of that directory's files, concatenated in name
order, or `absent` when it has none, `skip` reports the batch done without running RUN, `hang` streams one
running event and then nothing until `hang` is removed, without running RUN, `hold`
holds the stream after the first action's final event until `hold` is removed, and
`cancelled` reports every action and the batch cancelled without running RUN, and
`deadline` reports a failed action as the batch deadline leaves it: cancelled, then again
with the log its worker uploaded as it stopped, and the batch failed at the deadline.  `stopped`
reports a failed action as a cancel that stopped it leaves it: cancelled with the log its
worker uploaded, and the batch cancelled; holding `unlogged`, before that log arrived, and
holding a failure kind, after an earlier attempt failed with it (`deadline-retried`: stopped
by the batch deadline on a second attempt).  `cancel-done` reports an action that finished in a
failed batch as cancelled with an earlier attempt's failure and log, as when its second attempt's
result came after the batch failed; a later read of the ended batch gets the new log.  Holding
`streamed`, it streams the new log on the cancelled action, as when the result came before the
stream's last read.  STATE/<id>.events, when it exists, is batch
<id>'s recorded event stream: it is sent as it is, without running RUN.  When RUN
fails having written what it found missing to `missing` (which is removed), as
"theory <input key>" or "blob <sha256>", and on a second line the others it found missing,
comma-separated, the batch fails for resubmission naming them, as the coordinator does, and its
final events are recorded as STATE/<id>.events for a later read.  Otherwise
the cancel answers that it cancelled the batch.  Every request is logged to
STATE/requests.log, and each POST /v1/batches's Holbuild-Batch-Id header to
STATE/submitted-ids.
"""

import hashlib
import json
import pathlib
import subprocess
import sys
import time
from urllib.parse import parse_qs
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
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        if self.path.startswith("/v1/batches/") and self.path.endswith("/cancel"):
            if (state / "ended").exists():
                return self.answer(200, {"state": "done"})
            if (state / "down").exists():
                return self.answer(503, {"detail": "restarting"})
            return self.answer(200, {"state": "cancelled"})
        path, _, query = self.path.partition("?")
        if path != "/v1/batches":
            return self.answer(404, {"detail": "Not Found"})
        with open(state / "submitted-ids", "a") as ids:
            ids.write(f"{self.headers.get('Holbuild-Batch-Id', '-')}\n")
        if (state / "refuse").exists():
            return self.answer(400, {"detail": "batch refused by the stub"})
        unavailable = state / "unavailable"
        if unavailable.exists() and int(unavailable.read_text()) > 0:
            unavailable.write_text(str(int(unavailable.read_text()) - 1))
            status_file = state / "unavailable-status"
            status = int(status_file.read_text()) if status_file.exists() else 502
            return self.answer(status, {"detail": "restarting"})
        batch_id = f"b{len(list(state.glob('*.batch'))) + 1}"
        (state / f"{batch_id}.batch").write_text(body)
        watch = state / "watch"
        if watch.exists():
            files = sorted(p for p in pathlib.Path(watch.read_text().strip()).glob("*") if p.is_file())
            digest = hashlib.sha256(b"".join(p.read_bytes() for p in files)).hexdigest() if files else "absent"
            (state / f"{batch_id}.watched").write_text(digest)
        heap = parse_qs(query).get("max_heap_mb")
        if heap:
            (state / f"{batch_id}.heap").write_text(heap[0])
        if "class=run" in query.split("&"):
            (state / f"{batch_id}.run").touch()
        # What happens elsewhere while the client submits.
        if (state / "on-submit").exists():
            subprocess.run(["bash", str(state / "on-submit")], check=True)
        # Whitespace around the colon is valid JSON the client must accept.
        self.answer(201, {"batch_id": batch_id}, separators=(", ", " : "))

    def do_GET(self):
        self.log_request_line()
        parts = self.path.split("/")
        batch = state / f"{parts[3]}.batch" if len(parts) == 5 and parts[4] == "events" else None
        if batch is None or not batch.exists():
            return self.answer(404, {"detail": "no such batch"})
        if (state / "down").exists() or (state / "ended").exists():
            return self.answer(503, {"detail": "restarting"})
        recorded = state / f"{parts[3]}.events"
        if recorded.exists():
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.end_headers()
            self.wfile.write(recorded.read_bytes())
            return
        if (state / "hang").exists():
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.end_headers()
            action = next(line.split() for line in batch.read_text().splitlines() if line.startswith("action "))
            running = {"type": "action", "input_key": action[1], "theory": action[4], "state": "running",
                       "tier": "standard", "attempts": 1, "last_failure": None, "log_sha256": None}
            self.wfile.write((json.dumps(running) + "\n").encode())
            self.wfile.flush()
            for _ in range(600):
                if not (state / "hang").exists():
                    break
                time.sleep(0.1)
            return
        replay = state / "replay"
        if replay.exists() and int(replay.read_text()) > 0:
            replay.write_text(str(int(replay.read_text()) - 1))
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            # More than is sent, so curl reports the stream cut short.
            self.send_header("Content-Length", "1000")
            self.end_headers()
            action = next(line.split() for line in batch.read_text().splitlines() if line.startswith("action "))
            running = {"type": "action", "input_key": action[1], "theory": action[4], "state": "running",
                       "tier": "standard", "attempts": 1, "last_failure": None, "log_sha256": None}
            self.wfile.write((json.dumps(running) + "\n").encode())
            return
        cancelled = (state / "cancelled").exists()
        run_class = batch.with_suffix(".run").exists()
        ok = cancelled or (state / "skip").exists() or subprocess.run([run, str(batch)]).returncode == 0
        # A failed action of a run batch fails only itself.
        final_state = "cancelled" if cancelled else "done" if ok or run_class else "failed"
        cut = (state / "cut").exists()
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        if cut:
            # More than is sent, so curl reports the stream cut short.
            (state / "cut").unlink()
            self.send_header("Content-Length", "1000")
        self.end_headers()
        snapshot = []
        for line in batch.read_text().splitlines():
            fields = line.split()
            if fields[0] == "action":
                if (state / "retried").exists():
                    # A retry after a memory failure, as the coordinator reports it.
                    retried = {"type": "action", "input_key": fields[1], "theory": fields[4], "state": "waiting",
                               "tier": "high", "attempts": 1, "last_failure": "memory",
                               "log_sha256": "c" * 64, "failure_detail": "killed by SIGKILL"}
                    self.wfile.write((json.dumps(retried) + "\n").encode())
                for _ in range(2):
                    running = {"type": "action", "input_key": fields[1], "theory": fields[4],
                               "state": "running", "tier": "standard", "attempts": 1,
                               "last_failure": None, "log_sha256": None}
                    if cut:
                        self.wfile.write(json.dumps(running)[:30].encode())
                        return
                    self.wfile.write((json.dumps(running) + "\n").encode())
                event = {"type": "action", "input_key": fields[1], "theory": fields[4],
                         "state": final_state, "tier": "standard", "attempts": 1,
                         "last_failure": None if ok else "proof", "log_sha256": None}
                result = state / f"result-{fields[1]}"
                if run_class and not cancelled:
                    record = dict(line.split("=", 1) for line in result.read_text().splitlines()[1:]) \
                        if result.exists() else {"status": "failed", "failure": "internal"}
                    if record["status"] == "failed":
                        event["state"], event["last_failure"] = "failed", record["failure"]
                        event["log_sha256"] = record["log"].split()[0] if "log" in record else None
                        event["failure_detail"] = record.get("detail")
                    else:
                        event["state"], event["last_failure"] = "done", None
                elif not ok and result.exists():
                    record = dict(line.split("=", 1) for line in result.read_text().splitlines()[1:])
                    if record["status"] == "skipped":
                        event["state"], event["last_failure"] = "cancelled", record["failure"]
                    elif record["status"] == "failed":
                        event["last_failure"] = record["failure"]
                        event["log_sha256"] = record["log"].split()[0] if "log" in record else None
                        event["failure_detail"] = record.get("detail")
                        if (state / "stopped").exists():
                            # As the coordinator sends an action someone's cancel stopped while it
                            # ran: cancelled, with the log its worker uploaded as it stopped.
                            how = (state / "stopped").read_text().strip()
                            event["state"], event["failure_detail"] = "cancelled", None
                            event["last_failure"] = how if how and how != "unlogged" else None
                            if how == "deadline-retried":
                                event["last_failure"], event["attempts"] = "deadline", 2
                            if how == "unlogged":
                                event["log_sha256"] = None
                        elif (state / "deadline").exists():
                            # As the coordinator sends it: cancelled at the deadline, then the log its
                            # worker reports as it stops.
                            event["state"], event["last_failure"] = "cancelled", "deadline"
                            event["failure_detail"] = "still running after 12 h"
                            self.wfile.write((json.dumps(dict(event, log_sha256=None)) + "\n").encode())
                    else:
                        event["state"], event["last_failure"] = "done", None
                elif not ok and not (state / "fail").exists():
                    event["state"], event["last_failure"] = "cancelled", None
                if event["state"] == "done" and result.exists() and not cancelled:
                    record = dict(line.split("=", 1) for line in result.read_text().splitlines()[1:])
                    event["log_sha256"] = record["log"].split()[0] if "log" in record else None
                if result.exists():
                    recorded = dict(line.split("=", 1) for line in result.read_text().splitlines()[1:] if "=" in line)
                    if "phase-ms" in recorded:
                        event["timings"] = {name: int(ms) for name, ms in
                                            (part.split(":") for part in recorded["phase-ms"].split(","))}
                        event["timings"]["wall"] = int(recorded["wall-ms"])
                late = event["state"] == "done" and not ok and (state / "cancel-done").exists()
                if late:
                    # As the coordinator leaves an action whose second attempt's result came after
                    # its batch failed: cancelled with the first attempt's failure, and the log
                    # only after the stream ended, for a later read.
                    event["state"], event["last_failure"], event["attempts"] = "cancelled", "unavailable", 2
                snapshot.append(event)
                if event["state"] == "done" and (state / "requeue-log").exists():
                    # The first execution's log was evicted; only the final
                    # execution's log is usable after the action is requeued.
                    self.wfile.write((json.dumps(dict(event, log_sha256="0" * 64)) + "\n").encode())
                    if not (state / "requeue-snapshot").exists():
                        self.wfile.write((json.dumps(dict(event, state="waiting", log_sha256=None)) + "\n").encode())
                if late and (state / "cancel-done").read_text().strip() != "streamed":
                    event_sent = dict(event, log_sha256="c" * 64)
                else:
                    event_sent = event
                self.wfile.write((json.dumps(event_sent) + "\n").encode())
                self.wfile.flush()
                for _ in range(600):
                    if not (state / "hold").exists():
                        break
                    time.sleep(0.1)
        if (state / "drop").exists():
            (state / "drop").unlink()
            return
        failure = None if ok else "deadline: still running after 12 h" if (state / "deadline").exists() \
            else "an action failed"
        missing = state / "missing"
        if not ok and missing.exists():
            what, *more = missing.read_text().splitlines() or [""]
            missing.unlink()
            also = f"; also missing {', '.join(more[0].split(','))}" if more and more[0] else ""
            if what:
                failure = f"resubmit: an action is still missing {what} after 3 attempts{also}"
        cancel_after = (state / "cancel-after-actions").exists() or (state / "stopped").exists()
        final = {"type": "batch", "state": "cancelled" if cancel_after else final_state,
                 "failure": failure}
        self.wfile.write((json.dumps(final) + "\n").encode())
        if failure and failure.startswith("resubmit:"):
            # What a later read of the ended batch replays, as the coordinator does.
            (state / f"{parts[3]}.events").write_text("".join(json.dumps(event) + "\n" for event in snapshot + [final]))


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_address[1]))
server.serve_forever()
