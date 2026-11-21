import argparse
import contextlib
import errno
import fcntl
import io
import itertools
import json
import os
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
from collections.abc import Iterator
from dataclasses import dataclass, field, replace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

import pytest

from remote_exec import worker
from remote_exec.auth import cache_discovery_token
from remote_exec.cache import blob_key
from remote_exec.formats import parse_result
from remote_exec.worker import (
    DISK_FLOOR,
    DRAINING,
    CacheUnavailable,
    Coordinator,
    ExecSpans,
    HostMemory,
    HostTelemetry,
    Lease,
    Phases,
    Protection,
    Releases,
    Unreleased,
    child_charge,
    claim_reporting,
    cpu_times,
    failed_record,
    free_bytes,
    parse_args,
    recordless_failure,
    run_one,
    runs_hol,
    wait_for_memory,
)

SPEC = "5" * 64
RECORD = f"holbuild-action-result-v1\nspec={SPEC}\ninput-key={'6' * 64}\nstatus=built\n"
# What exec-action writes once it has stopped an interrupted action: the log it uploaded so far.
LOG = f"log={'7' * 64} 12"
INTERRUPTED = f"holbuild-action-result-v1\nspec={SPEC}\ninput-key={'6' * 64}\nstatus=failed\nfailure=unavailable\n{LOG}\n"

# A stand-in holbuild source tree: `make bin/holbuild` installs a script that logs its arguments and environment and
# writes RECORD (or HOLBUILD_FAKE_RECORD) to its --result file, or ends without one when HOLBUILD_FAKE_CRASH is set:
# exit 70 for 1, else killed by the signal it names. Its `sandbox-check` logs its environment and passes.
FAKE_HOLBUILD = f"""#!/bin/sh
if [ "$1" = sandbox-check ]; then [ -z "$HOLBUILD_FAKE_LOG" ] || env > "$HOLBUILD_FAKE_LOG.sandbox-env"; exit 0; fi
echo $$ > "$HOLBUILD_FAKE_LOG.pid"
# HOLBUILD_FAKE_LOCK: hold the action-root lock until the result is written, as exec-action does
locker=
if [ -n "$HOLBUILD_FAKE_LOCK" ]; then
  mkdir -p "$HOLBUILD_CACHE"
  python3 -c 'import fcntl, os, sys, time; fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT); fcntl.lockf(fd, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(600)' "$HOLBUILD_CACHE/action.lock" "$HOLBUILD_FAKE_LOG.locked" &
  locker=$!
  while [ ! -e "$HOLBUILD_FAKE_LOG.locked" ]; do sleep 0.01; done
fi
if [ -n "$HOLBUILD_FAKE_HANG" ]; then
  trap '' TERM
  (while :; do sleep 1; done) &
  echo $! > "$HOLBUILD_FAKE_LOG.child"
  wait
fi
echo "$@" >> "$HOLBUILD_FAKE_LOG"
env > "$HOLBUILD_FAKE_LOG.env"
# HOLBUILD_FAKE_PUBLISH: on TERM, publish for 3 s, then write INTERRUPTED, as exec-action does when interrupted
if [ -n "$HOLBUILD_FAKE_PUBLISH" ]; then
  result=; previous=
  for arg in "$@"; do [ "$previous" != --result ] || result=$arg; previous=$arg; done
  sleep 120 &
  child=$!
  trap 'sleep 0.1; kill -0 "$child" || exit 1; kill "$child"; wait "$child" || true; sleep 3; echo published > "$HOLBUILD_FAKE_LOG.published"; printf "%s" "{INTERRUPTED}" > "$result.tmp"; mv "$result.tmp" "$result"; exit 1' TERM
  echo ready > "$HOLBUILD_FAKE_LOG.ready"
  wait
fi
# Keep each lease state until the worker has sampled it; bound waits so a broken worker fails the test.
if [ -n "$HOLBUILD_FAKE_LEASE" ]; then
  wait_sample() {{
    n=0
    while [ ! -e "$HOLBUILD_FAKE_LEASE.$1" ]; do
      [ "$n" -lt 300 ] || exit 1
      n=$((n + 1))
      sleep 0.1
    done
  }}
  wait_sample before
  (exec 3>"$HOLBUILD_FAKE_LEASE"; wait_sample hol) || exit 1
  wait_sample after
else sleep 2; fi
[ -z "$HOLBUILD_FAKE_CRASH" ] || [ "$HOLBUILD_FAKE_CRASH" != 1 ] || exit 70
[ -z "$HOLBUILD_FAKE_CRASH" ] || kill -s "$HOLBUILD_FAKE_CRASH" $$
while [ "$#" -gt 0 ]; do
  # HOLBUILD_FAKE_OUTLINE: publish an outline a second before the result, as exec-action --pipeline does
  if [ "$1" = --result ] && [ -n "$HOLBUILD_FAKE_OUTLINE" ]; then : > "$2.outline"; sleep 1; fi
  if [ "$1" = --result ]; then printf '%s' "${{HOLBUILD_FAKE_RECORD:-{RECORD}}}" > "$2.tmp"; mv "$2.tmp" "$2"; fi
  shift
done
[ -z "$locker" ] || {{ kill "$locker"; wait "$locker"; }}
# HOLBUILD_FAKE_AFTER: go on for that many seconds after the result, as exec-action publishes for later actions
if [ -n "$HOLBUILD_FAKE_AFTER" ]; then
  trap 'echo termed > "$HOLBUILD_FAKE_LOG.termed"; exit 1' TERM
  sleep "$HOLBUILD_FAKE_AFTER" &
  wait
  echo done > "$HOLBUILD_FAKE_LOG.after"
fi
"""
FAKE_MAKEFILE = """bin/holbuild:
\techo build >> "$$FAKE_BUILD_LOG"
\tmkdir -p bin
\tcp fake-holbuild bin/holbuild
\tchmod +x bin/holbuild
"""


def release_tarball(path: Path, version: str, makefile: str = FAKE_MAKEFILE) -> None:
    with tarfile.open(path, "w:gz") as tar:
        for name, text in {"Makefile": makefile, "fake-holbuild": FAKE_HOLBUILD}.items():
            data = text.encode()
            info = tarfile.TarInfo(f"holbuild-{version}/{name}")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))


@dataclass
class Server:
    """The coordinator's worker endpoints, the remote cache's ``/cas/``, and the ECS agent's task protection."""

    url: str = ""
    specs: dict[str, str] = field(default_factory=dict)  # under /cas/
    zstd_specs: dict[str, str] = field(default_factory=dict)  # as 0.15.0 and later write them, compressed under /ac/
    completed: list[str] = field(default_factory=list)
    protection: list[dict[str, object]] = field(default_factory=list)
    claims: list[dict[str, object]] = field(default_factory=list)
    heartbeats: list[dict[str, object]] = field(default_factory=list)
    lease_posts: list[str] = field(default_factory=list)  # "heartbeat", "outlined", "complete", in the order they came
    reports: list[dict[str, object]] = field(default_factory=list)
    report_status: int = 204  # 404 from a coordinator older than /v1/work/report
    lease_lost: bool = False
    unavailable: int = 0  # how many more completes answer 502, as a proxy does while the coordinator restarts
    cut_short: bool = False  # whether /cas/ answers close the connection before the body they announce is sent
    next_claim: dict[str, object] | None = None
    claim_started: threading.Event = field(default_factory=threading.Event)
    hold_claim: threading.Event | None = None
    protection_reply: dict[str, object] = field(default_factory=dict)
    protection_status: int = 200


@pytest.fixture
def server() -> Iterator[Server]:
    state = Server()

    class Handler(BaseHTTPRequestHandler):
        def body(self) -> str:
            return self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()

        def reply(self, status: int, body: str = "") -> None:
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                self.end_headers()
                self.wfile.write(body.encode())

        def do_GET(self) -> None:
            if state.cut_short:
                self.send_response(200)
                self.send_header("Content-Length", "1000")
                self.end_headers()
                self.wfile.write(b"holbuild-action-spec-v1\n")
                self.close_connection = True
                return
            compressed = {f"/ac/{blob_key(digest)}": spec for digest, spec in state.zstd_specs.items()}
            if self.path in compressed:
                body = subprocess.run(["zstd", "-qc"], input=compressed[self.path].encode(), capture_output=True,
                                      check=True).stdout
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            spec = state.specs.get(self.path.removeprefix("/cas/"))
            self.reply(404) if spec is None else self.reply(200, spec)

        def do_POST(self) -> None:
            body = self.body()
            if self.path.startswith("/moved/"):
                self.send_response(303)
                self.send_header("Location", self.path.removeprefix("/moved"))
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if self.path == "/v1/work/claim":
                state.claims.append(json.loads(body))
                state.claim_started.set()
                if state.hold_claim is not None:
                    state.hold_claim.wait(15)
                claimed, state.next_claim = state.next_claim, None
                return self.reply(204) if claimed is None else self.reply(200, json.dumps(claimed))
            if self.path == "/v1/work/report":
                state.reports.append(json.loads(body))
                return self.reply(state.report_status)
            if self.path.endswith(("/heartbeat", "/complete", "/outlined")):
                state.lease_posts.append(self.path.rsplit("/", 1)[1])
            if self.path.endswith("/outlined"):
                return self.reply(204)
            if self.path.endswith("/complete"):
                if state.unavailable > 0:
                    state.unavailable -= 1
                    return self.reply(502)
                state.completed.append(body)
            if self.path.endswith("/heartbeat"):
                state.heartbeats.append(json.loads(body))
                if state.lease_lost:
                    return self.reply(409)
            self.reply(200, json.dumps({"accepted": True}) if self.path.endswith("/complete") else '{"lease_s": 3}')

        def do_PUT(self) -> None:
            state.protection.append(json.loads(self.body()))
            self.reply(state.protection_status, json.dumps(state.protection_reply))

        def log_message(self, format: str, *args: object) -> None:
            pass

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    state.url = f"http://127.0.0.1:{httpd.server_address[1]}"
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield state
    finally:
        httpd.shutdown()


@pytest.fixture
def logs(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> tuple[Path, Path]:
    build_log, holbuild_log = tmp_path / "builds", tmp_path / "holbuild-calls"
    monkeypatch.setenv("FAKE_BUILD_LOG", str(build_log))
    monkeypatch.setenv("HOLBUILD_FAKE_LOG", str(holbuild_log))
    return build_log, holbuild_log


@pytest.fixture(autouse=True)
def roomy_disk(monkeypatch: pytest.MonkeyPatch) -> None:
    """Whatever the test machine's disk has free, the worker sees room for actions, unless a test says otherwise."""
    monkeypatch.setattr(worker, "free_bytes", lambda _path: 100 * GIB)


def releases(tmp_path: Path, server: Server) -> Releases:
    return Releases(str(tmp_path / "releases"), f"file://{tmp_path}/holbuild-{{version}}.tar.gz", server.url, None)



def test_baked_release_needs_no_writable_cache_or_download(tmp_path: Path, server: Server) -> None:
    baked = tmp_path / "baked/v1.2.3/bin/holbuild"
    baked.parent.mkdir(parents=True)
    baked.write_text("#!/bin/sh\nexit 0\n")
    baked.chmod(0o755)
    root = tmp_path / "not-a-directory"
    root.touch()
    release = replace(releases(tmp_path, server), root=str(root), baked_root=str(tmp_path / "baked"))

    assert release.holbuild("1.2.3") == str(baked)
    with pytest.raises(Unreleased):
        release.holbuild("../1.2.3")


@pytest.mark.parametrize("version", ["0.13.52", "0.13.53", "0.13.54", "0.13.55", "0.13.56", "0.13.57"])
def test_old_release_is_rejected_before_baked_lookup(tmp_path: Path, server: Server, version: str) -> None:
    release = releases(tmp_path, server)
    with pytest.raises(Unreleased, match="mandatory action isolation"):
        release.holbuild(version)
    assert not (tmp_path / "releases").exists()


def test_baked_release_must_support_sandbox(tmp_path: Path, server: Server) -> None:
    baked = tmp_path / "baked/v1.2.3/bin/holbuild"
    baked.parent.mkdir(parents=True)
    baked.write_text("#!/bin/sh\nexit 125\n")
    baked.chmod(0o755)
    release = replace(releases(tmp_path, server), baked_root=str(tmp_path / "baked"))
    with pytest.raises(subprocess.CalledProcessError):
        release.holbuild("1.2.3")


@pytest.mark.parametrize("candidate", ["missing", "non-executable", "directory"])
def test_unusable_baked_release_falls_back_to_build(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], candidate: str
) -> None:
    baked = tmp_path / "baked/v1.2.3/bin/holbuild"
    if candidate == "directory":
        baked.mkdir(parents=True)
    elif candidate == "non-executable":
        baked.parent.mkdir(parents=True)
        baked.write_text("unusable")
        baked.chmod(0o644)
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    release = replace(releases(tmp_path, server), baked_root=str(tmp_path / "baked"))

    assert release.holbuild("1.2.3") == str(tmp_path / "releases/v1.2.3/bin/holbuild")
    assert logs[0].read_text() == "build\n"


def test_baked_releases_option_overrides_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    args = ["--coordinator", "http://coordinator.test", "--remote-cache", "http://cache.test", "--cache-limit-gb", "1"]
    monkeypatch.delenv("REMOTE_EXEC_BAKED_RELEASES", raising=False)
    assert parse_args(args).baked_releases == "/opt/holbuild-baked"
    monkeypatch.setenv("REMOTE_EXEC_BAKED_RELEASES", "/image/releases")
    assert parse_args(args).baked_releases == "/image/releases"
    assert parse_args([*args, "--baked-releases", "/override"]).baked_releases == "/override"


def test_release_is_built_once_for_concurrent_workers(tmp_path: Path, server: Server, logs: tuple[Path, Path]) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    found: list[str] = []
    threads = [
        threading.Thread(target=lambda: found.append(releases(tmp_path, server).holbuild("1.2.3"))) for _ in range(4)
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert found == [str(tmp_path / "releases/v1.2.3/bin/holbuild")] * 4
    assert logs[0].read_text() == "build\n"
    assert (tmp_path / "releases/v1.2.3/.complete").exists()


def test_a_release_builds_while_another_version_is_being_built(
    tmp_path: Path, server: Server, logs: tuple[Path, Path]
) -> None:
    hold = tmp_path / "hold"
    hold.touch()
    slow_makefile = FAKE_MAKEFILE.replace(
        "bin/holbuild:\n", f"bin/holbuild:\n\twhile [ -e {hold} ]; do sleep 0.1; done\n"
    )
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3", slow_makefile)
    release_tarball(tmp_path / "holbuild-1.2.4.tar.gz", "1.2.4")
    slow = threading.Thread(target=lambda: releases(tmp_path, server).holbuild("1.2.3"))
    slow.start()
    try:
        for _ in range(300):
            if (tmp_path / "releases/v1.2.3/Makefile").exists():
                break
            time.sleep(0.1)
        other = threading.Thread(target=lambda: releases(tmp_path, server).holbuild("1.2.4"), daemon=True)
        other.start()
        other.join(timeout=30)
        assert not other.is_alive()
        assert (tmp_path / "releases/v1.2.4/.complete").exists()
        assert not (tmp_path / "releases/v1.2.3/.complete").exists()
    finally:
        hold.unlink()
        slow.join()


def test_versions_without_a_release_are_refused(tmp_path: Path, server: Server, logs: tuple[Path, Path]) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3-dev.tar.gz", "1.2.3-dev")
    for version in ["1.2.4", "1.2.3-dev"]:
        with pytest.raises(Unreleased):
            releases(tmp_path, server).holbuild(version)
    assert not logs[0].exists()


def worker_args(tmp_path: Path, server: Server, *extra: str) -> argparse.Namespace:
    return parse_args(
        [
            "--coordinator",
            server.url,
            "--remote-cache",
            server.url,
            "--cache-limit-gb",
            "50",
            "--share-heaps",
            "--holbuild-releases-dir",
            str(tmp_path / "releases"),
            *extra,
        ]
    )


def claim() -> dict[str, object]:
    return {"attempt_token": "t1", "spec_sha256": SPEC, "input_key": "6" * 64, "theory": "pkg:A", "lease_s": 3}


@contextlib.contextmanager
def running_worker(tmp_path: Path, server: Server, drain: str, *extra: str) -> Iterator[subprocess.Popen[bytes]]:
    env = {**os.environ, "REMOTE_EXEC_WORKER_TOKEN": "w", "HOLBUILD_CACHE": str(tmp_path / "cache")}
    with (tmp_path / "worker.log").open("wb") as log:
        process = subprocess.Popen(
            [sys.executable, "-m", "remote_exec.worker", "--coordinator", server.url, "--remote-cache", server.url,
             "--cache-limit-gb", "50", "--holbuild-releases-dir", str(tmp_path / "releases"),
             "--holbuild-source-url", f"file://{tmp_path}/holbuild-{{version}}.tar.gz", "--drain-seconds", drain, *extra],
            env=env, stdout=log, stderr=log, start_new_session=True,
        )
        try:
            yield process
        finally:
            if process.poll() is None:
                worker.stop_group(process)


def wait_for_file(path: Path) -> None:
    deadline = time.monotonic() + 10
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert path.exists(), f"worker did not create {path}"


# What the worker reports of an action it stopped at its drain deadline.
DRAINED = failed_record(SPEC, "unavailable", "the worker's drain deadline passed before exec-action finished")


@pytest.mark.parametrize(("drain", "expected"), [("5", RECORD), ("0", DRAINED)])
def test_sigterm_finishes_or_releases_the_action_without_claiming_again(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], drain: str, expected: str,
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    server.next_claim = claim()
    with running_worker(tmp_path, server, drain) as process:
        wait_for_file(logs[1])
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=10) == 0, (tmp_path / "worker.log").read_text()
    assert server.completed == [expected]
    assert len(server.claims) == 1


@pytest.mark.parametrize("share_heaps", [False, True])
def test_sigterm_kills_descendants_that_ignore_term_and_repeated_signals_do_not_reset_the_drain(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch, share_heaps: bool,
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    server.next_claim = claim()
    monkeypatch.setenv("HOLBUILD_FAKE_HANG", "1")
    child_file = Path(f"{logs[1]}.child")
    with running_worker(tmp_path, server, "0.1", *(["--share-heaps"] if share_heaps else [])) as process:
        wait_for_file(child_file)
        group = int(Path(f"{logs[1]}.pid").read_text())
        try:
            process.send_signal(signal.SIGTERM)
            time.sleep(0.2)
            process.send_signal(signal.SIGTERM)
            assert process.wait(timeout=15) == 0, (tmp_path / "worker.log").read_text()
            child = Path(f"/proc/{int(child_file.read_text())}/stat")
            assert not child.exists() or child.read_text().split()[2] == "Z"
        finally:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(group, signal.SIGKILL)
    assert server.completed == [DRAINED]
    assert len(server.claims) == 1


@pytest.mark.parametrize("share_heaps", [False, True])
@pytest.mark.parametrize("stop", ["drain", "lease-loss"])
def test_an_interrupted_action_publishes_its_checkpoints_and_reports_its_log(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch, stop: str,
    share_heaps: bool,
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    server.next_claim = claim()
    monkeypatch.setenv("HOLBUILD_FAKE_PUBLISH", "1")
    with running_worker(tmp_path, server, "0", *(["--share-heaps"] if share_heaps else [])) as process:
        wait_for_file(Path(f"{logs[1]}.ready"))
        if stop == "drain":
            process.send_signal(signal.SIGTERM)
        else:
            server.lease_lost = True
        wait_for_file(Path(f"{logs[1]}.published"))
        if stop == "lease-loss":
            process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=10) == 0, (tmp_path / "worker.log").read_text()
    # A drained action is retried at once, keeping the log; a lost lease's report gives the coordinator the log.
    assert server.completed == ([f"{DRAINED}{LOG}\n"] if stop == "drain" else [INTERRUPTED])


def test_the_result_is_reported_before_exec_action_exits_and_a_lost_lease_then_stops_nothing(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch,
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    server.next_claim = claim()
    monkeypatch.setenv("HOLBUILD_FAKE_AFTER", "4")
    with running_worker(tmp_path, server, "0", "--share-heaps") as process:
        deadline = time.monotonic() + 20
        while not server.completed and time.monotonic() < deadline:
            time.sleep(0.05)
        assert server.completed == [RECORD], (tmp_path / "worker.log").read_text()
        assert not Path(f"{logs[1]}.after").exists()
        # The token is stale once completed; the worker no longer heartbeats, so this is never seen.
        server.lease_lost = True
        wait_for_file(Path(f"{logs[1]}.after"))
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=10) == 0, (tmp_path / "worker.log").read_text()
    assert server.completed == [RECORD]
    assert not Path(f"{logs[1]}.termed").exists()


def test_the_worker_claims_again_once_exec_action_lets_go_of_the_action_root_and_a_drain_stops_its_rest(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch,
) -> None:
    """exec-action's cache sweep and module writer run on after it releases the action-root lock, while the
    worker claims its next action; a drain stops them."""
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    server.next_claim = claim()
    monkeypatch.setenv("HOLBUILD_FAKE_LOCK", "1")
    monkeypatch.setenv("HOLBUILD_FAKE_AFTER", "60")
    with running_worker(tmp_path, server, "0") as process:
        deadline = time.monotonic() + 20
        while len(server.claims) < 2 and time.monotonic() < deadline:
            time.sleep(0.05)
        assert server.completed == [RECORD], (tmp_path / "worker.log").read_text()
        assert len(server.claims) >= 2, (tmp_path / "worker.log").read_text()
        assert Path(f"/proc/{Path(f'{logs[1]}.pid').read_text().strip()}").exists()
        assert not Path(f"{logs[1]}.after").exists()
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=10) == 0, (tmp_path / "worker.log").read_text()
    assert Path(f"{logs[1]}.termed").exists()


def test_the_reaper_stops_its_exec_action_at_the_deadline_and_holds_one_at_a_time() -> None:
    reaper = worker.Reaper(worker.Drain(), "/nonexistent/action.lock")
    first = subprocess.Popen(["sleep", "60"], start_new_session=True)
    reaper.hand(first, time.monotonic() + 60, "pkg:A")
    second = subprocess.Popen(["sleep", "60"], start_new_session=True)
    reaper.hand(second, time.monotonic() + 0.5, "pkg:B")
    assert first.returncode is not None
    deadline = time.monotonic() + 5
    while second.poll() is None and time.monotonic() < deadline:
        time.sleep(0.05)
    assert second.returncode is not None
    reaper.stop()


def test_an_outline_exec_action_published_is_reported_once_before_the_result(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch,
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    server.next_claim = {**claim(), "pipeline": True}
    monkeypatch.setenv("HOLBUILD_FAKE_OUTLINE", "1")
    with running_worker(tmp_path, server, "0") as process:
        deadline = time.monotonic() + 20
        while not server.completed and time.monotonic() < deadline:
            time.sleep(0.05)
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=20) == 0, (tmp_path / "worker.log").read_text()
    assert server.completed == [RECORD]
    assert "--pipeline" in logs[1].read_text().split()
    posts = [post for post in server.lease_posts if post != "heartbeat"]
    assert posts == ["outlined", "complete"], (tmp_path / "worker.log").read_text()


def test_a_drain_after_the_result_completes_the_action_once(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch,
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    server.next_claim = claim()
    monkeypatch.setenv("HOLBUILD_FAKE_AFTER", "60")
    with running_worker(tmp_path, server, "0", "--share-heaps") as process:
        deadline = time.monotonic() + 20
        while not server.completed and time.monotonic() < deadline:
            time.sleep(0.05)
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=20) == 0, (tmp_path / "worker.log").read_text()
    assert server.completed == [RECORD]
    assert Path(f"{logs[1]}.termed").exists()


def test_a_result_that_cannot_be_posted_is_not_completed_again_as_an_internal_failure(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Posting the result retries for the lease's length, then gives up; the coordinator retries the action once
    the lease expires, so the worker doesn't post a second, different result."""
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    server.next_claim = claim()
    server.unavailable = 1_000_000
    monkeypatch.setenv("HOLBUILD_FAKE_AFTER", "60")
    with running_worker(tmp_path, server, "0", "--share-heaps") as process:
        log = tmp_path / "worker.log"
        # Once posting gives up, the worker stops exec-action.
        wait_for_file(Path(f"{logs[1]}.termed"))
        server.unavailable = 0
        time.sleep(1)
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=20) == 0, log.read_text()
    assert server.completed == [], (tmp_path / "worker.log").read_text()


def test_exec_action_is_stopped_on_time_after_its_result_while_the_result_is_still_being_posted(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch,
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    server.unavailable = 1_000_000
    monkeypatch.setenv("HOLBUILD_FAKE_AFTER", "60")
    monkeypatch.setattr(worker, "POST_RESULT_SECONDS", 1.0)
    done = threading.Event()

    def run() -> None:
        run_one(Coordinator(server.url, "w"), worker_args(tmp_path, server), releases(tmp_path, server),
                Protection(None, None), {**claim(), "lease_s": 30}, Phases())
        done.set()

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    wait_for_file(Path(f"{logs[1]}.pid"))
    leader = Path(f"/proc/{int(Path(f'{logs[1]}.pid').read_text())}/stat")
    deadline = time.monotonic() + 10
    while leader.exists() and leader.read_text().split()[2] != "Z" and time.monotonic() < deadline:
        time.sleep(0.05)
    assert not leader.exists() or leader.read_text().split()[2] == "Z", "exec-action outlived the bound"
    assert not done.is_set()  # still posting the result
    server.unavailable = 0
    assert done.wait(15)
    assert server.completed == [RECORD]


def test_sigterm_interrupts_an_idle_long_poll(tmp_path: Path, server: Server) -> None:
    server.hold_claim = threading.Event()
    try:
        with running_worker(tmp_path, server, "0") as process:
            assert server.claim_started.wait(10)
            process.send_signal(signal.SIGTERM)
            assert process.wait(timeout=3) == 0, (tmp_path / "worker.log").read_text()
        assert server.completed == []
        assert len(server.claims) == 1
    finally:
        server.hold_claim.set()


def test_sigterm_interrupts_release_make_and_releases_the_lease(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch,
) -> None:
    marker = tmp_path / "making"
    makefile = f"bin/holbuild:\n\ttouch {marker}\n\tsleep 60\n" + FAKE_MAKEFILE.split("bin/holbuild:\n")[1]
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3", makefile)
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    server.next_claim = claim()
    monkeypatch.setenv("ECS_AGENT_URI", server.url)
    with running_worker(tmp_path, server, "20") as process:
        wait_for_file(marker)
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=8) == 0, (tmp_path / "worker.log").read_text()
    assert server.completed == [failed_record(SPEC, "unavailable", DRAINING)]
    assert server.protection[-1] == {"ProtectionEnabled": False}
    assert not (tmp_path / "releases/v1.2.3/.complete").exists()
    assert not logs[1].exists()
    with (tmp_path / "releases/v1.2.3.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)


@pytest.mark.parametrize("field", ["failure", "error"])
def test_ecs_protection_rejection_in_a_success_response_is_logged(
    server: Server, capsys: pytest.CaptureFixture[str], field: str,
) -> None:
    server.protection_reply = {field: {"Reason": "DEPLOYMENT_BLOCKED"}}
    Protection(None, server.url).set(enabled=True)
    assert "DEPLOYMENT_BLOCKED" in capsys.readouterr().err


def test_ecs_protection_refused_with_an_http_error_is_logged(
    server: Server, capsys: pytest.CaptureFixture[str]
) -> None:
    server.protection_status = 400
    Protection(None, server.url).set(enabled=True)
    assert "HTTP Error 400" in capsys.readouterr().err


@pytest.mark.parametrize("text", ["-1", "nan", "inf"])
def test_drain_seconds_must_be_finite_and_nonnegative(tmp_path: Path, server: Server, text: str) -> None:
    with pytest.raises(SystemExit):
        worker_args(tmp_path, server, f"--drain-seconds={text}")


def test_shutdown_while_entering_an_interruptible_wait_does_not_enter_the_wait(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    drain = worker.Drain()
    is_set = drain.stop.is_set

    def check() -> bool:
        stopped = is_set()
        if not stopped:
            drain.request()
        return stopped

    monkeypatch.setattr(drain.stop, "is_set", check)
    with pytest.raises(worker.DrainStopped), drain.interruptible():
        pytest.fail("entered a blocking call after shutdown")
    assert not drain.interrupt


@pytest.mark.parametrize(
    ("worker_heap", "batch_heap", "expected_heap"),
    [(None, None, 12000), (14000, None, 14000), (14000, 4096, 4096), (None, 16000, 16000)],
)
def test_worker_runs_the_action_on_the_release_that_exported_it(
    tmp_path: Path,
    server: Server,
    logs: tuple[Path, Path],
    worker_heap: int | None,
    batch_heap: int | None,
    expected_heap: int,
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    switch = tmp_path / "protect"
    switch.write_text(f'#!/bin/sh\necho "$1" >> {tmp_path}/protection\n')
    switch.chmod(0o755)
    extra = [] if worker_heap is None else ["--max-heap", str(worker_heap)]
    args = worker_args(tmp_path, server, "--protection-cmd", str(switch), *extra)
    claimed = {**claim(), "max_heap_mb": batch_heap}

    run_one(
        Coordinator(server.url, "w"), args, releases(tmp_path, server), Protection(str(switch), None), claimed, Phases()
    )

    assert server.completed == [RECORD]
    assert logs[1].read_text().split() == [
        "--remote-cache",
        server.url,
        "--max-heap",
        str(expected_heap),
        "exec-action",
        SPEC,
        "--cache-limit-gb",
        "50",
        "--cache-min-free-gb",
        "16",
        "--result",
        logs[1].read_text().split()[11],
        "--share-heaps",
    ]
    *held, released = (tmp_path / "protection").read_text().split()
    assert (set(held), released) == ({"on"}, "off")
    assert len(held) >= 2  # renewed on a heartbeat


@pytest.mark.parametrize(("version", "floor"), [("0.14.56", False), ("0.14.57", True)])
def test_worker_passes_the_free_space_floor_only_to_releases_that_take_it(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], version: str, floor: bool
) -> None:
    release_tarball(tmp_path / f"holbuild-{version}.tar.gz", version)
    server.specs[SPEC] = f"holbuild-action-spec-v1\nholbuild-version={version}\n"

    run_one(
        Coordinator(server.url, "w"), worker_args(tmp_path, server), releases(tmp_path, server),
        Protection(None, None), claim(), Phases(),
    )

    assert server.completed == [RECORD]
    assert ("--cache-min-free-gb" in logs[1].read_text().split()) == floor


@pytest.mark.parametrize(
    ("lines", "deps_key"),
    [(f"deps-key={'c' * 64}\n", "c" * 64), ("", None), ("deps-key=nope\n", None), (f"deps-key={'c' * 64}\n" * 2, None)],
)
def test_worker_adds_the_specs_dependency_context_to_the_result_it_reports(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], lines: str, deps_key: str | None
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = f"holbuild-action-spec-v1\nholbuild-version=1.2.3\n{lines}"

    run_one(
        Coordinator(server.url, "w"), worker_args(tmp_path, server), releases(tmp_path, server),
        Protection(None, None), claim(), Phases(),
    )

    assert server.completed == [RECORD if deps_key is None else f"{RECORD}deps-key={deps_key}\n"]


@pytest.mark.parametrize(("extra", "line"), [
    ({"batch_id": "b1"}, f"running pkg:A ({'6' * 64}) in batch b1"),
    ({}, f"running pkg:A ({'6' * 64})"),  # a coordinator before 0.14.80 names no batch
])
def test_worker_logs_the_action_it_runs_with_its_batch(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], capsys: pytest.CaptureFixture[str],
    extra: dict[str, str], line: str,
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"

    run_one(
        Coordinator(server.url, "w"), worker_args(tmp_path, server), releases(tmp_path, server),
        Protection(None, None), {**claim(), **extra}, Phases(),
    )

    assert line in capsys.readouterr().err.splitlines()


AHEAD_PARENTS = [{"input_key": "7" * 64, "spec_sha256": "8" * 64}, {"input_key": "9" * 64, "spec_sha256": "a" * 64}]


def test_worker_passes_an_ahead_claims_late_parents_to_exec_action(
    tmp_path: Path, server: Server, logs: tuple[Path, Path]
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"

    run_one(
        Coordinator(server.url, "w"),
        worker_args(tmp_path, server),
        releases(tmp_path, server),
        Protection(None, None),
        {**claim(), "ahead_parents": AHEAD_PARENTS},
        Phases(),
    )

    assert server.completed == [RECORD]
    assert logs[1].read_text().split()[-5:] == [
        "--share-heaps", "--ahead-parent", f"{'7' * 64}:{'8' * 64}", "--ahead-parent", f"{'9' * 64}:{'a' * 64}",
    ]


@pytest.mark.parametrize(("version", "passed"), [("0.14.74", False), ("0.14.75", True)])
def test_worker_asks_a_release_that_can_to_build_a_pipelined_claim_pipelined(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], version: str, passed: bool
) -> None:
    release_tarball(tmp_path / f"holbuild-{version}.tar.gz", version)
    server.specs[SPEC] = f"holbuild-action-spec-v1\nholbuild-version={version}\n"

    run_one(
        Coordinator(server.url, "w"),
        worker_args(tmp_path, server),
        releases(tmp_path, server),
        Protection(None, None),
        {**claim(), "pipeline": True},
        Phases(),
    )

    assert server.completed == [RECORD]
    assert ("--pipeline" in logs[1].read_text().split()) == passed


def test_an_ahead_claim_for_a_release_without_ahead_mode_is_abandoned_unrun(
    tmp_path: Path, server: Server, logs: tuple[Path, Path]
) -> None:
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=0.14.25\n"

    run_one(
        Coordinator(server.url, "w"),
        worker_args(tmp_path, server),
        releases(tmp_path, server),
        Protection(None, None),
        {**claim(), "ahead_parents": AHEAD_PARENTS},
        Phases(),
    )

    [record] = server.completed
    result = parse_result(record)
    assert (result.failure, result.detail) == ("ahead-abandoned", "holbuild 0.14.25 predates loading ahead")
    assert not logs[1].exists()


@pytest.mark.parametrize("version", ["0.13.58", "0.13.68", "0.14.0", "0.14.1"])
@pytest.mark.parametrize(
    ("trusted", "legacy"),
    [
        (None, None),
        ("*", None),
        (" *\t* ", None),
        ("https://example.org/HOL.git=main *", "https://example.org/HOL.git=main"),
        ("https://example.org/HOL.git=main", "https://example.org/HOL.git=main"),
        ("", ""),
        ("   ", "   "),
    ],
)
def test_action_trust_matches_the_client_version(
    monkeypatch: pytest.MonkeyPatch, version: str, trusted: str | None, legacy: str | None
) -> None:
    name = "HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES"
    if trusted is None:
        monkeypatch.delenv(name, raising=False)
    else:
        monkeypatch.setenv(name, trusted)
    env = worker.exec_action_env(version=version)
    expected = legacy if version in ("0.13.58", "0.13.68") else trusted
    if expected is None:
        assert name not in env
    else:
        assert env[name] == expected


@pytest.mark.parametrize(("version", "trusted"), [("0.13.68", None), ("0.14.0", "*")])
def test_action_runs_without_the_worker_token(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch,
    version: str, trusted: str | None,
) -> None:
    release_tarball(tmp_path / f"holbuild-{version}.tar.gz", version)
    server.specs[SPEC] = f"holbuild-action-spec-v1\nholbuild-version={version}\n"
    monkeypatch.setenv("HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES", "*")
    monkeypatch.setenv("REMOTE_EXEC_WORKER_TOKEN", "worker-secret")
    monkeypatch.setenv("HOLBUILD_REMOTE_CACHE_DISCOVERY_TOKEN", "worker-secret")
    monkeypatch.setenv("HOLBUILD_REMOTE_CACHE_DISCOVERY_CURL_CONFIG", str(tmp_path / "worker.curl"))
    monkeypatch.setenv("UNRELATED", "1")
    monkeypatch.setenv("HOLBUILD_CACHE", str(tmp_path / "cache"))
    monkeypatch.setenv("HOLBUILD_REMOTE_CACHE_CURL_CONFIG", str(tmp_path / "cache.curl"))
    monkeypatch.setenv("HTTPS_PROXY", "http://proxy.test:3128")
    for name in worker.SOLVER_ENV:
        monkeypatch.setenv(name, f"/opt/{name}")
    monkeypatch.setenv("HOL4_YICES_EXECUTABLE", "/opt/yices")

    run_one(
        Coordinator(server.url, "w"),
        worker_args(tmp_path, server),
        releases(tmp_path, server),
        Protection(None, None),
        claim(),
        Phases(),
    )

    sandbox_env = Path(f"{logs[1]}.sandbox-env").read_text().splitlines()
    assert "REMOTE_EXEC_WORKER_TOKEN=worker-secret" not in sandbox_env
    trust = [line for line in sandbox_env if line.startswith("HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES=")]
    assert trust == ([] if trusted is None else [f"HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES={trusted}"])
    env = dict(line.split("=", 1) for line in Path(f"{logs[1]}.env").read_text().splitlines() if "=" in line)
    assert "REMOTE_EXEC_WORKER_TOKEN" not in env
    assert "HOLBUILD_REMOTE_CACHE_DISCOVERY_TOKEN" not in env
    assert "HOLBUILD_REMOTE_CACHE_DISCOVERY_CURL_CONFIG" not in env
    assert "worker-secret" not in env.values()
    assert env.get("HOLBUILD_EXEC_TRUSTED_HOL_REPOSITORIES") == trusted
    assert "UNRELATED" not in env
    assert env["HTTPS_PROXY"] == "http://proxy.test:3128"
    assert env["HOLBUILD_CACHE"] == str(tmp_path / "cache")
    assert env["HOLBUILD_REMOTE_CACHE_CURL_CONFIG"] == str(tmp_path / "cache.curl")
    assert env["PATH"]
    assert all(env[name] == f"/opt/{name}" for name in worker.SOLVER_ENV)
    assert "HOL4_YICES_EXECUTABLE" not in env


def test_action_exec_action_found_the_cache_unavailable_for_is_reported_as_it_said(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    record = f"holbuild-action-result-v1\nspec={SPEC}\ninput-key={'6' * 64}\nstatus=failed\nfailure=unavailable\n"
    monkeypatch.setenv("HOLBUILD_FAKE_RECORD", record)

    unavailable = run_one(
        Coordinator(server.url, "w"),
        worker_args(tmp_path, server),
        releases(tmp_path, server),
        Protection(None, None),
        claim(),
        Phases(),
    )

    assert unavailable
    assert server.completed == [record]


def test_worker_waits_before_claiming_again_after_the_cache_was_unavailable(
    tmp_path: Path, server: Server, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("REMOTE_EXEC_WORKER_TOKEN", "w")
    monkeypatch.setenv("HOLBUILD_CACHE", str(tmp_path / "cache"))
    monkeypatch.setattr(worker, "parse_args", lambda: worker_args(tmp_path, server))
    events: list[str] = []
    monkeypatch.setattr(worker, "claim_reporting", lambda *_: events.append("claim") or claim())
    outcomes = iter([True, False, False])

    def run(*_: object, **__: object) -> bool:
        try:
            return next(outcomes)
        except StopIteration:
            raise KeyboardInterrupt from None

    monkeypatch.setattr(worker, "run_one", run)
    drain = worker.Drain()
    monkeypatch.setattr(drain.stop, "wait", lambda seconds: events.append(f"wait {seconds}"))
    monkeypatch.setattr(worker, "Drain", lambda *_: drain)

    with pytest.raises(KeyboardInterrupt):
        worker.main()

    # Only the unavailable action is followed by a wait.
    assert events == ["claim", f"wait {worker.CLAIM_RETRY_SECONDS}", "claim", "claim", "claim"]


def test_the_lease_runs_from_when_the_claim_was_sent(
    tmp_path: Path, server: Server, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The coordinator starts the lease before its answer travels back, so a slow answer mustn't move the worker's
    deadline later than the coordinator's."""
    monkeypatch.setenv("REMOTE_EXEC_WORKER_TOKEN", "w")
    monkeypatch.setenv("HOLBUILD_CACHE", str(tmp_path / "cache"))
    monkeypatch.setattr(worker, "parse_args", lambda: worker_args(tmp_path, server))
    sent: list[float] = []

    def slow_claim(*_: object) -> dict[str, object]:
        sent.append(time.monotonic())
        time.sleep(0.3)
        return claim()

    monkeypatch.setattr(worker, "claim_reporting", slow_claim)
    claim_sent: list[float] = []

    def run(*_: object, claimed: float, **__: object) -> bool:
        claim_sent.append(claimed)
        raise KeyboardInterrupt

    monkeypatch.setattr(worker, "run_one", run)

    with pytest.raises(KeyboardInterrupt):
        worker.main()

    assert claim_sent[0] <= sent[0]


def test_action_that_ends_without_a_record_is_reported_for_a_retry(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    monkeypatch.setenv("HOLBUILD_FAKE_CRASH", "1")

    with pytest.raises(RuntimeError, match="exited 70 without a result record"):
        run_one(
            Coordinator(server.url, "w"),
            worker_args(tmp_path, server),
            releases(tmp_path, server),
            Protection(None, None),
            claim(),
            Phases(),
        )

    assert server.completed == [failed_record(SPEC, "internal")]


@pytest.mark.parametrize(
    ("crash", "failure", "detail"),
    [
        ("KILL", "memory", "exec-action was killed by SIGKILL without a result, as by the kernel's OOM killer"),
        ("TERM", "unavailable", "exec-action was stopped by SIGTERM without a result"),
        ("INT", "unavailable", "exec-action was stopped by SIGINT without a result"),
    ],
)
def test_action_killed_by_a_signal_without_a_record_is_reported_by_the_signal(
    tmp_path: Path,
    server: Server,
    logs: tuple[Path, Path],
    monkeypatch: pytest.MonkeyPatch,
    crash: str,
    failure: str,
    detail: str,
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    monkeypatch.setenv("HOLBUILD_FAKE_CRASH", crash)

    unavailable = run_one(
        Coordinator(server.url, "w"),
        worker_args(tmp_path, server),
        releases(tmp_path, server),
        Protection(None, None),
        claim(),
        Phases(),
    )

    assert unavailable == (failure == "unavailable")
    assert server.completed == [failed_record(SPEC, failure, detail)]


def test_a_worker_on_a_full_disk_hands_the_action_back_and_claims_again_only_once_there_is_room(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    monkeypatch.setenv("REMOTE_EXEC_WORKER_TOKEN", "w")
    monkeypatch.setenv("HOLBUILD_CACHE", str(tmp_path / "cache"))  # not made yet: the disk it would be on is read
    source = f"file://{tmp_path}/holbuild-{{version}}.tar.gz"
    monkeypatch.setattr(worker, "parse_args", lambda: worker_args(tmp_path, server, "--holbuild-source-url", source))
    full = False
    statvfs = os.statvfs
    read: list[str] = []

    def disk(path: str) -> os.statvfs_result | SimpleNamespace:
        if not path.startswith(str(tmp_path)) and path != tempfile.gettempdir():
            return statvfs(path)
        read.append(path)
        return SimpleNamespace(f_bavail=GIB if full else 100 * GIB, f_frsize=1)

    temporary_directory = tempfile.TemporaryDirectory

    def scratch(*args: object, **kwargs: object) -> tempfile.TemporaryDirectory[str]:
        # What the worker makes in the temp dir fails as on 2026-11-16's full hosts; the release build's own does not.
        if full and kwargs.get("dir") is None:
            raise OSError(errno.ENOSPC, os.strerror(errno.ENOSPC), "/var/tmp/tmpfull")
        return temporary_directory(*args, **kwargs)  # type: ignore[call-overload]

    monkeypatch.setattr(worker, "free_bytes", free_bytes)
    monkeypatch.setattr(worker.os, "statvfs", disk)
    monkeypatch.setattr(worker.tempfile, "TemporaryDirectory", scratch)
    events: list[str] = []

    def claim_ready(*_: object) -> dict[str, object]:
        nonlocal full
        events.append("claim")
        if events.count("claim") == 1:
            full = True  # the disk fills between the worker's look at it and the claim, as siblings write
        if events.count("claim") == 3:
            raise KeyboardInterrupt
        return claim()

    monkeypatch.setattr(worker, "claim_reporting", claim_ready)
    drain = worker.Drain()

    def wait(seconds: float) -> bool:
        nonlocal full
        events.append(f"wait {seconds}")
        if seconds == worker.DISK_POLL_SECONDS:
            full = False  # space comes back while the worker waits for it
        return False

    monkeypatch.setattr(drain.stop, "wait", wait)
    monkeypatch.setattr(worker, "Drain", lambda *_: drain)

    with pytest.raises(KeyboardInterrupt):
        worker.main()

    # The action costs no attempt, and the worker claims no other while its disk is full.
    short = f"{tempfile.gettempdir()} has {GIB // 2**20} MiB free, below {DISK_FLOOR // 2**20} MiB"
    assert server.completed == [
        failed_record(
            SPEC, "unavailable", f"the worker's disk is full: [Errno 28] No space left on device: '/var/tmp/tmpfull'; {short}"
        ),
        RECORD,
    ]
    assert events == ["claim", f"wait {worker.CLAIM_RETRY_SECONDS}", f"wait {worker.DISK_POLL_SECONDS}", "claim", "claim"]
    assert str(tmp_path) in read  # the cache root's nearest existing ancestor
    # While it waits, the worker reports its host with the disk it waits for.
    [report] = server.reports
    assert report["host"]["disk_free"] == GIB  # type: ignore[index]


@pytest.mark.parametrize("report_status", [204, 404])
def test_a_worker_short_of_disk_cleans_its_own_action_and_temp_dirs_then_waits_reporting_its_host(
    tmp_path: Path, server: Server, monkeypatch: pytest.MonkeyPatch, report_status: int
) -> None:
    cache = tmp_path / "cache"
    (cache / "action" / "a1" / "ro").mkdir(parents=True)
    (cache / "action" / "a1" / "ro" / "theory.dat").write_text("x")
    (cache / "action" / "a1" / "ro").chmod(0o500)  # as HOL leaves its read-only directories
    (cache / "tmp").mkdir()
    (cache / "tmp" / "scratch").write_text("x")
    (cache / "store").mkdir()
    (cache / "store" / "kept").write_text("x")
    monkeypatch.setenv("HOLBUILD_CACHE", str(cache))
    server.report_status = report_status
    polls = 0

    def shortfall() -> str | None:
        return "short" if polls < 2 else None

    def wait(seconds: float) -> bool:
        nonlocal polls
        assert seconds == worker.DISK_POLL_SECONDS
        polls += 1
        return False

    drain = worker.Drain()
    monkeypatch.setattr(worker, "disk_shortfall", shortfall)
    monkeypatch.setattr(drain.stop, "wait", wait)

    worker.wait_for_disk(drain, Coordinator(server.url, "w"), ["high", "standard"], "w1", lambda: None)

    assert sorted(p.name for p in cache.rglob("*")) == [
        "action", "kept", "store", "tmp"
    ]
    assert [(r["tier"], r["also_claim"], r["worker"]) for r in server.reports] == [("high", ["standard"], "w1")] * 2


def test_a_worker_whose_cleaning_makes_room_waits_for_nothing(
    tmp_path: Path, server: Server, monkeypatch: pytest.MonkeyPatch
) -> None:
    (tmp_path / "action" / "a1").mkdir(parents=True)
    monkeypatch.setenv("HOLBUILD_CACHE", str(tmp_path))
    monkeypatch.setattr(worker, "disk_shortfall", lambda: "short" if (tmp_path / "action" / "a1").exists() else None)
    drain = worker.Drain()
    monkeypatch.setattr(drain.stop, "wait", lambda _: pytest.fail("waited"))

    worker.wait_for_disk(drain, Coordinator(server.url, "w"), ["standard"], "w1", lambda: None)

    assert server.reports == []


def test_an_idle_worker_short_of_disk_sweeps_the_cache_until_there_is_room_without_claiming(
    tmp_path: Path, server: Server, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Emptying its own scratch can't make room the shared cache and the checkpoints hold: the worker runs their
    eviction each poll while short, and the records of its action root and parked theories go before the
    directories they describe do."""
    (tmp_path / "action" / "a1").mkdir(parents=True)
    (tmp_path / "parked" / "p1").mkdir(parents=True)
    (tmp_path / "action-parked" / "p1").mkdir(parents=True)
    (tmp_path / "action-resident").write_text("holbuild-action-resident-v1\n")
    (tmp_path / "parked-records").write_text("holbuild-action-resident-v1\n")
    (tmp_path / "parked-stats").write_text("stats\n")
    monkeypatch.setenv("HOLBUILD_CACHE", str(tmp_path))
    sweeps = 0

    def sweep() -> None:
        nonlocal sweeps
        assert not (tmp_path / "action-resident").exists(), "the sweep ran before the action root's record went"
        assert not (tmp_path / "parked-records").exists(), "the sweep ran before the parked theories' record went"
        sweeps += 1

    monkeypatch.setattr(worker, "disk_shortfall", lambda: "short" if sweeps < 3 else None)
    drain = worker.Drain()
    waits = 0

    def wait(_: float) -> bool:
        nonlocal waits
        waits += 1
        return waits > 10

    monkeypatch.setattr(drain.stop, "wait", wait)

    worker.wait_for_disk(drain, Coordinator(server.url, "w"), ["standard"], "w1", sweep)

    assert (sweeps, waits, len(server.reports)) == (3, 2, 2)
    assert not (tmp_path / "action-resident").exists()
    assert not (tmp_path / "parked-records").exists()
    assert not (tmp_path / "parked-stats").exists()
    assert list((tmp_path / "parked").iterdir()) == []
    assert list((tmp_path / "action-parked").iterdir()) == []


@pytest.mark.parametrize("mode", [0o000, 0o300])
def test_cleaning_removes_directories_it_cannot_read(tmp_path: Path, mode: int) -> None:
    (tmp_path / "a1" / "locked" / "deeper").mkdir(parents=True)
    (tmp_path / "a1" / "locked" / "deeper" / "theory.dat").write_text("x")
    (tmp_path / "a1" / "locked" / "theory.uo").write_text("x")
    (tmp_path / "a1" / "locked").chmod(mode)
    (tmp_path / "top").mkdir()
    (tmp_path / "top").chmod(mode)

    worker.remove_children(str(tmp_path))

    assert list(tmp_path.iterdir()) == []


def test_the_cache_sweep_runs_the_newest_release_that_has_it(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    log = tmp_path / "argv"

    def release(root: Path, version: str, *, built: bool = True) -> None:
        executable = root / f"v{version}" / "bin" / "holbuild"
        executable.parent.mkdir(parents=True)
        executable.write_text(f"#!/bin/sh\necho {version} \"$@\" >> {log}\n")
        executable.chmod(0o755)
        if built:
            (root / f"v{version}" / worker.COMPLETE).touch()

    baked, built = tmp_path / "baked", tmp_path / "built"
    release(baked, "0.14.58")
    release(baked, "0.15.0")
    release(built, "0.15.1", built=False)  # a build that didn't finish
    release(built, "0.15.0")
    release(built, "0.14.60")
    releases = Releases(str(built), "unused", "http://cache.test", None, baked_root=str(baked))
    monkeypatch.setenv("HOLBUILD_CACHE", str(tmp_path / "cache"))

    worker.sweep_cache(releases, 200)

    assert log.read_text() == "0.15.0 exec-action --sweep-only --cache-limit-gb 200 --cache-min-free-gb 16\n"
    old = tmp_path / "old"
    release(old, "0.14.59")  # released before --sweep-only
    assert Releases(str(tmp_path / "none"), "unused", "", None, baked_root=str(old)).newest(
        worker.MIN_SWEEP_ONLY_RELEASE
    ) is None


def test_a_drain_stops_the_cache_sweep_at_once(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    executable = tmp_path / "baked" / "v0.15.0" / "bin" / "holbuild"
    executable.parent.mkdir(parents=True)
    executable.write_text(f"#!/bin/sh\necho $$ > {tmp_path}/pid\nexec sleep 60\n")
    executable.chmod(0o755)
    drain = worker.Drain()
    releases = Releases(str(tmp_path / "built"), "unused", "http://cache.test", None,
                        baked_root=str(tmp_path / "baked"), drain=drain)
    monkeypatch.setenv("HOLBUILD_CACHE", str(tmp_path / "cache"))

    def stop() -> None:
        while not (tmp_path / "pid").exists():
            time.sleep(0.05)
        os.kill(os.getpid(), signal.SIGTERM)

    threading.Thread(target=stop, daemon=True).start()
    started = time.monotonic()
    with drain.installed():
        worker.sweep_cache(releases, 200)

    assert drain.stop.is_set()
    assert time.monotonic() - started < 10, "the sweep outlived the drain"
    with pytest.raises(ProcessLookupError):
        os.kill(int((tmp_path / "pid").read_text()), 0)


def test_the_host_report_gives_the_disk_with_the_least_free(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TMPDIR", str(tmp_path / "tmp"))
    monkeypatch.setenv("HOLBUILD_CACHE", str(tmp_path / "cache"))
    monkeypatch.setattr(tempfile, "tempdir", str(tmp_path / "python"))
    free = {str(tmp_path / "python"): 50, str(tmp_path / "tmp"): 20, str(tmp_path): 30}
    monkeypatch.setattr(worker.os.path, "exists", lambda path: path in free)
    monkeypatch.setattr(worker.os, "statvfs", lambda path: SimpleNamespace(f_bavail=free[path], f_frsize=2))
    monkeypatch.setattr(worker, "free_bytes", free_bytes)

    assert worker.least_free_bytes() == 40


def test_action_that_ends_without_a_record_on_a_full_disk_is_handed_back(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    monkeypatch.setenv("HOLBUILD_FAKE_CRASH", "1")
    monkeypatch.setattr(worker, "free_bytes", lambda _path: GIB)

    with pytest.raises(RuntimeError, match="exited 70 without a result record"):
        run_one(
            Coordinator(server.url, "w"),
            worker_args(tmp_path, server),
            releases(tmp_path, server),
            Protection(None, None),
            claim(),
            Phases(),
        )

    short = f"{tempfile.gettempdir()} has {GIB // 2**20} MiB free, below {DISK_FLOOR // 2**20} MiB"
    detail = f"the worker's disk is full: exec-action exited 70 without a result record; {short}"
    assert server.completed == [failed_record(SPEC, "unavailable", detail)]


@pytest.mark.parametrize("tmpdir", ["full", None])
def test_the_disk_check_measures_exec_actions_temp_root_whatever_python_picked(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, tmpdir: str | None
) -> None:
    # exec-action writes under TMPDIR, else /tmp, even when Python's tempfile settled on another directory.
    full = str(tmp_path / "full") if tmpdir else "/tmp"
    if tmpdir:
        monkeypatch.setenv("TMPDIR", full)
    else:
        monkeypatch.delenv("TMPDIR", raising=False)
    monkeypatch.setattr(tempfile, "tempdir", str(tmp_path / "python"))
    monkeypatch.delenv("HOLBUILD_CACHE", raising=False)
    monkeypatch.setattr(worker, "free_bytes", lambda path: GIB if path == full else 100 * GIB)

    assert worker.disk_shortfall() == f"{full} has 1024 MiB free, below {DISK_FLOOR // 2**20} MiB"


@pytest.mark.parametrize(
    ("returncode", "draining", "failure", "cause"),
    [
        (-signal.SIGKILL, False, "memory", "SIGKILL"),
        (128 + signal.SIGKILL, False, "memory", "SIGKILL"),
        (-signal.SIGTERM, False, "unavailable", "SIGTERM"),
        (128 + signal.SIGTERM, False, "unavailable", "SIGTERM"),
        (-signal.SIGINT, False, "unavailable", "SIGINT"),
        (128 + signal.SIGINT, False, "unavailable", "SIGINT"),
        # Draining, whatever stopped it, the attempt is refunded.
        (-signal.SIGKILL, True, "unavailable", "drained"),
        (70, True, "unavailable", "drained"),
        (70, False, None, None),
        (1, False, None, None),
    ],
)
def test_recordless_failure_names_interruptions_and_kills(
    returncode: int, draining: bool, failure: str | None, cause: str | None
) -> None:
    recordless = recordless_failure(returncode, draining)
    if failure is None:
        assert recordless is None
    else:
        assert recordless is not None and recordless[0] == failure and cause in recordless[1]


def test_action_whose_spec_an_unreachable_cache_does_not_give_is_reported_unavailable(
    tmp_path: Path, server: Server, logs: tuple[Path, Path]
) -> None:
    unreachable = Releases(
        str(tmp_path / "releases"), f"file://{tmp_path}/holbuild-{{version}}.tar.gz", "http://127.0.0.1:1", None
    )
    with pytest.raises(CacheUnavailable, match="fetching spec"):
        run_one(
            Coordinator(server.url, "w"),
            worker_args(tmp_path, server),
            unreachable,
            Protection(None, None),
            claim(),
            Phases(),
        )

    [record] = server.completed
    assert record.startswith(failed_record(SPEC, "unavailable") + f"detail=fetching spec {SPEC}")
    assert not logs[1].exists()


def test_action_whose_spec_transfer_is_cut_short_is_reported_unavailable(
    tmp_path: Path, server: Server, logs: tuple[Path, Path]
) -> None:
    server.cut_short = True
    with pytest.raises(CacheUnavailable, match="fetching spec"):
        run_one(
            Coordinator(server.url, "w"),
            worker_args(tmp_path, server),
            releases(tmp_path, server),
            Protection(None, None),
            claim(),
            Phases(),
        )

    [record] = server.completed
    assert record.startswith(failed_record(SPEC, "unavailable") + f"detail=fetching spec {SPEC}")


def test_action_whose_spec_the_cache_lost_is_reported_for_a_counted_retry(
    tmp_path: Path, server: Server, logs: tuple[Path, Path]
) -> None:
    with pytest.raises(RuntimeError, match="404"):
        run_one(
            Coordinator(server.url, "w"),
            worker_args(tmp_path, server),
            releases(tmp_path, server),
            Protection(None, None),
            claim(),
            Phases(),
        )

    assert server.completed == [failed_record(SPEC, "internal")]
    assert not logs[1].exists()


def test_action_whose_release_does_not_build_is_reported_for_a_retry(
    tmp_path: Path, server: Server, logs: tuple[Path, Path]
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3", "bin/holbuild:\n\texit 1\n")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"

    with pytest.raises(subprocess.CalledProcessError):
        run_one(
            Coordinator(server.url, "w"),
            worker_args(tmp_path, server),
            releases(tmp_path, server),
            Protection(None, None),
            claim(),
            Phases(),
        )

    assert server.completed == [failed_record(SPEC, "internal")]
    assert not logs[1].exists()


@pytest.mark.parametrize(
    ("version", "reason"),
    [("1.2.4", "holbuild 1.2.4 has no release at "), ("0.13.57", "holbuild 0.13.57 predates mandatory action isolation")],
)
def test_action_of_an_unreleased_holbuild_is_rejected_saying_why(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], version: str, reason: str
) -> None:
    server.specs[SPEC] = f"holbuild-action-spec-v1\nholbuild-version={version}\n"

    run_one(
        Coordinator(server.url, "w"),
        worker_args(tmp_path, server),
        releases(tmp_path, server),
        Protection(None, None),
        claim(),
        Phases(),
    )

    [record] = server.completed
    assert record.startswith(failed_record(SPEC, "spec-rejected"))
    result = parse_result(record)
    assert (result.failure, result.log_sha256) == ("spec-rejected", None)
    assert result.detail is not None and result.detail.startswith(f"the worker refuses the action: {reason}")
    assert not logs[1].exists()


def test_a_failure_detail_is_one_line_of_printable_ascii() -> None:
    record = failed_record(SPEC, "spec-rejected", "bad\nspec=\x00\u00e9" + "x" * 600)
    assert record.endswith(f"\nfailure=spec-rejected\ndetail=bad spec=  {'x' * 489}\n")
    assert parse_result(record).detail == f"bad spec=  {'x' * 489}"


def test_a_result_is_reported_again_while_the_coordinator_restarts(
    server: Server, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(worker, "COMPLETE_RETRY_DELAYS", (0.01,))
    server.unavailable = 3

    Coordinator(server.url, "w").complete("t1", RECORD, 3)

    assert server.completed == [RECORD]
    assert server.unavailable == 0


def test_a_result_is_given_up_on_when_the_lease_would_run_out(server: Server, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(worker, "COMPLETE_RETRY_DELAYS", (0.01,))
    server.unavailable = 1000

    with pytest.raises(RuntimeError, match="complete answered 502"):
        Coordinator(server.url, "w").complete("t1", RECORD, 0.2)

    assert server.completed == []
    assert server.unavailable > 900


def test_a_result_is_reported_again_while_the_coordinator_is_unreachable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(worker, "COMPLETE_RETRY_DELAYS", (0.01,))
    attempts = []

    def unreachable(*args: object) -> tuple[int, object]:
        attempts.append(args)
        raise OSError("connection refused")

    monkeypatch.setattr(Coordinator, "post", unreachable)

    with pytest.raises(RuntimeError, match="complete failed"):
        Coordinator("http://127.0.0.1:9", "w").complete("t1", RECORD, 0.2)

    assert len(attempts) > 1


@pytest.mark.parametrize(("status", "raised"), [(409, False), (400, True)])
def test_a_result_the_coordinator_turns_down_is_not_reported_again(
    monkeypatch: pytest.MonkeyPatch, status: int, raised: bool
) -> None:
    attempts = []
    monkeypatch.setattr(Coordinator, "post", lambda *args: attempts.append(args) or (status, "no"))

    with pytest.raises(RuntimeError) if raised else contextlib.nullcontext():
        Coordinator("http://127.0.0.1:9", "w").complete("t1", RECORD, 60)

    assert len(attempts) == 1


def test_ecs_task_protection_is_set_and_cleared(server: Server) -> None:
    protection = Protection(None, server.url)

    protection.set(enabled=True)
    protection.set(enabled=False)

    assert server.protection == [{"ProtectionEnabled": True, "ExpiresInMinutes": 180}, {"ProtectionEnabled": False}]


def test_also_claim_accepts_repeats_and_commas(tmp_path: Path, server: Server) -> None:
    args = worker_args(tmp_path, server, "--tier", "high", "--also-claim", "standard,high", "--also-claim", "standard")

    assert args.also_claim == ["standard", "high", "standard"]


def test_claim_asks_the_coordinator_to_wait(server: Server) -> None:
    assert Coordinator(server.url, "w").claim(["standard", "high"], "w", 20, {"hol": 1.5}) is None
    assert server.claims == [
        {
            "tier": "standard", "also_claim": ["high"], "worker": "w", "wait_s": 20, "phases": {"hol": 1.5},
            "host": None,
        }
    ]


def test_only_a_worker_that_loads_ahead_claims_ahead(tmp_path: Path, server: Server) -> None:
    assert not worker_args(tmp_path, server).load_ahead
    assert worker_args(tmp_path, server, "--load-ahead").load_ahead
    assert Coordinator(server.url, "w", load_ahead=True).claim(["standard"], "w", 0, {}) is None
    assert server.claims[-1]["ahead"] is True


def test_claim_wait_is_at_most_50_seconds(tmp_path: Path, server: Server) -> None:
    assert worker_args(tmp_path, server, "--claim-wait-seconds", "50").claim_wait_seconds == 50
    with pytest.raises(SystemExit):
        worker_args(tmp_path, server, "--claim-wait-seconds", "51")


def test_coordinator_redirects_are_not_followed(server: Server) -> None:
    with pytest.raises(RuntimeError, match="claim answered 303"):
        Coordinator(server.url + "/moved", "w").claim(["standard"], "w", 0, {})


GIB = 1024**3


@dataclass
class Host:
    """A cooperate dir as holbuild leaves it, on a 64 GiB host (default budget 48 GiB, margin 16 GiB)."""

    dir: Path
    meminfo: Path
    held: contextlib.ExitStack

    def available(self, available: int) -> None:
        self.meminfo.write_text(f"MemTotal: {64 * GIB // 1024} kB\nMemAvailable: {available // 1024} kB\n")

    def lease(self, charge: int, *, held: bool = True, age_s: float = 60) -> None:
        """A lease of ``charge`` bytes, locked until the test ends when ``held``, created ``age_s`` ago."""
        path = self.dir / f"lease-{len(os.listdir(self.dir))}"
        path.write_text(f"{charge}\n")
        os.utime(path, (time.time() - age_s,) * 2)
        if held:
            fd = os.open(path, os.O_RDONLY)
            self.held.callback(os.close, fd)
            fcntl.flock(fd, fcntl.LOCK_EX)

    def memory(self) -> HostMemory:
        return HostMemory.read(str(self.dir))


@pytest.fixture
def host(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[Host]:
    directory = tmp_path / "cooperate"
    directory.mkdir()
    (directory / "lock").touch()
    monkeypatch.setenv("HOLBUILD_TEST_MEMINFO", str(tmp_path / "meminfo"))
    with contextlib.ExitStack() as held:
        state = Host(directory, tmp_path / "meminfo", held)
        state.available(40 * GIB)
        yield state


def test_a_child_charge_is_the_max_heap_up_to_3072_mib() -> None:
    assert [child_charge(m) for m in (None, 2048, 8192)] == [3072 * 2**20, 2048 * 2**20, 3072 * 2**20]


def test_memory_is_short_while_held_leases_leave_too_little_available(host: Host) -> None:
    host.lease(3 * GIB)
    assert host.memory().shortfall(3 * GIB) is None

    host.available(18 * GIB)
    assert "below 3072 MiB plus 16384 MiB kept free" in str(host.memory().shortfall(3 * GIB))


def test_children_still_starting_count_against_available_memory(host: Host) -> None:
    host.available(21 * GIB)
    host.lease(3 * GIB)
    assert host.memory().shortfall(3 * GIB) is None

    host.lease(3 * GIB, age_s=0)
    assert "less 3072 MiB for children starting" in str(host.memory().shortfall(3 * GIB))


def test_memory_is_short_while_held_leases_fill_the_budget(host: Host) -> None:
    (host.dir / "budget").write_text(f"{8 * GIB}\n")
    host.lease(3 * GIB)
    assert host.memory().shortfall(3 * GIB) is None

    host.lease(3 * GIB)
    assert host.memory().shortfall(3 * GIB) == "6144 of 8192 MiB reserved"


def test_leases_nobody_holds_do_not_count(host: Host) -> None:
    host.available(GIB)
    host.lease(60 * GIB, held=False)

    assert host.memory().reserved == 0
    assert host.memory().shortfall(3 * GIB) is None


def test_with_no_lease_held_a_child_starts_whatever_is_available(host: Host) -> None:
    host.available(GIB)
    assert host.memory().shortfall(3 * GIB) is None
    (host.dir / "lock").unlink()
    assert host.memory().shortfall(3 * GIB) is None


def test_worker_waits_for_memory_and_says_so_once(
    host: Host, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(worker, "MEMORY_POLL_SECONDS", 0.05)
    host.available(10 * GIB)
    host.lease(3 * GIB)
    waiter = threading.Thread(target=wait_for_memory, args=(str(host.dir), 3 * GIB), daemon=True)
    waiter.start()
    time.sleep(0.5)
    assert waiter.is_alive()

    host.available(20 * GIB)
    waiter.join(timeout=10)

    assert not waiter.is_alive()
    assert capsys.readouterr().err.count("waiting for memory before claiming") == 1


def test_wait_for_memory_says_whether_it_waited(host: Host, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(worker, "MEMORY_POLL_SECONDS", 0.05)
    assert not wait_for_memory(str(host.dir), 3 * GIB)
    host.available(10 * GIB)
    host.lease(3 * GIB)
    threading.Timer(0.2, host.available, (20 * GIB,)).start()
    assert wait_for_memory(str(host.dir), 3 * GIB)


def test_iowait_is_not_idle_cpu_time() -> None:
    # user nice system idle iowait irq softirq steal guest guest_nice
    assert cpu_times("cpu  10 1 5 100 20 0 2 0 7 0") == (100, 138)
    with pytest.raises(ValueError, match="cpu line"):
        cpu_times("cpu0 1 2 3 4 5 6 7 8")


@pytest.fixture
def telemetry(host: Host, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[tuple[HostTelemetry, Path]]:
    """A HostTelemetry over ``host``'s dir and a /proc/stat the test writes, with no least CPU sample time."""
    (tmp_path / "boot_id").write_text("b0a7\n")
    stat = tmp_path / "stat"
    stat.write_text("cpu  0 0 0 0 0 0 0 0 0 0\n")
    monkeypatch.setattr(worker, "BOOT_ID", str(tmp_path / "boot_id"))
    monkeypatch.setattr(worker, "PROC_STAT", str(stat))
    monkeypatch.setattr(worker, "CPU_SAMPLE_SECONDS", 0)
    yield HostTelemetry(str(host.dir), 3 * GIB), stat


def test_host_report_has_idle_cpu_since_the_last_report_and_admissions_view(
    host: Host, telemetry: tuple[HostTelemetry, Path]
) -> None:
    reporter, stat = telemetry
    host.lease(3 * GIB)
    host.lease(3 * GIB)
    first = reporter.report()
    assert first is not None
    assert (first.id, first.cpu_idle_pct, first.leases, first.reserved) == ("b0a7", None, 2, 6 * GIB)
    assert (first.mem_total, first.mem_available, first.memory_short) == (64 * GIB, 40 * GIB, False)

    stat.write_text("cpu  300 0 0 100 0 0 0 0 0 0\n")
    assert (report := reporter.report()) is not None and report.cpu_idle_pct == 25.0
    host.available(10 * GIB)
    stat.write_text("cpu  350 0 0 400 50 0 0 0 0 0\n")
    second = reporter.report()
    assert second is not None
    assert (second.cpu_idle_pct, second.memory_short) == (75.0, True)


def test_cpu_is_measured_over_at_least_the_least_sample_time(
    telemetry: tuple[HostTelemetry, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    reporter, stat = telemetry
    monkeypatch.setattr(worker, "CPU_SAMPLE_SECONDS", 3600)
    reporter.report()
    stat.write_text("cpu  300 0 0 100 0 0 0 0 0 0\n")
    assert reporter.report().cpu_idle_pct is None
    assert reporter.cpu is not None and reporter.cpu[2] == 0  # still measuring from the first sample


def test_claims_and_heartbeats_carry_the_host_report(telemetry: tuple[HostTelemetry, Path], server: Server) -> None:
    reporter, _ = telemetry
    coordinator = Coordinator(server.url, "w", reporter)
    assert coordinator.claim(["standard"], "w", 0, {}) is None
    assert coordinator.heartbeat("t")
    claimed, beat = server.claims[0]["host"], server.heartbeats[0]["host"]
    assert isinstance(claimed, dict) and isinstance(beat, dict)
    assert (claimed["id"], claimed["mem_total"], beat["id"]) == ("b0a7", 64 * GIB, "b0a7")


def test_host_rank_is_bounded_and_reported(telemetry: tuple[HostTelemetry, Path]) -> None:
    args = ["--coordinator", "http://coordinator.test", "--remote-cache", "http://cache.test", "--cache-limit-gb", "1"]
    assert parse_args(args).host_rank == 0
    assert parse_args([*args, "--host-rank", "1"]).host_rank == 1
    for bad in ("-1", "1001", "x"):
        with pytest.raises(SystemExit):
            parse_args([*args, "--host-rank", bad])
    reporter, _ = telemetry
    reporter.rank = 1
    assert (report := reporter.report()) is not None and report.rank == 1


def test_cpu_counters_going_backwards_give_no_idle_share(telemetry: tuple[HostTelemetry, Path]) -> None:
    reporter, stat = telemetry
    stat.write_text("cpu  100 0 0 100 50 0 0 0 0 0\n")
    reporter.report()
    stat.write_text("cpu  100 0 0 200 40 0 0 0 0 0\n")  # iowait fell by 10 while idle rose by 100
    assert reporter.report().cpu_idle_pct is None


def test_only_the_host_id_and_rank_while_an_admission_holds_the_lock_or_the_host_cannot_be_read(
    host: Host, telemetry: tuple[HostTelemetry, Path], server: Server
) -> None:
    reporter, stat = telemetry
    reporter.rank = 1
    host.lease(3 * GIB)
    coordinator = Coordinator(server.url, "w", reporter)
    with open(host.dir / "lock") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        assert coordinator.heartbeat("t")
        fcntl.flock(lock, fcntl.LOCK_UN)
        assert coordinator.heartbeat("t")
    stat.write_text("intr 1\n")
    assert coordinator.heartbeat("t")

    reports = [beat["host"] for beat in server.heartbeats]
    # The coordinator quarantines and packs hosts by id and rank, which need no reading.
    assert reports[0] == reports[2] == {"id": "b0a7", "rank": 1}
    assert isinstance(reports[1], dict) and reports[1]["leases"] == 1


def test_a_wait_for_memory_shows_as_memory_short_in_the_next_report(
    host: Host, telemetry: tuple[HostTelemetry, Path]
) -> None:
    reporter, _ = telemetry
    host.lease(3 * GIB)
    reporter.waited = True
    report = reporter.report()
    assert report is not None and report.memory_short
    report = reporter.report()
    assert report is not None and not report.memory_short


def test_a_worker_without_telemetry_sends_no_host(server: Server) -> None:
    coordinator = Coordinator(server.url, "w")
    assert coordinator.claim(["standard"], "w", 0, {}) is None
    assert coordinator.heartbeat("t")
    assert server.claims[0]["host"] is None and server.heartbeats[0]["host"] is None


def test_exec_time_splits_at_the_first_and_last_hol_child() -> None:
    spans = ExecSpans()
    for seconds, hol in [(2, False), (1, False), (1, True), (3, False), (1, True), (2, False), (0.5, False)]:
        spans.step(seconds, hol=hol)

    # The gap between the two HOL children counts as HOL.
    assert (spans.before_hol, spans.hol, spans.after_hol) == (3, 5, 2.5)


def test_exec_time_without_a_hol_child_is_all_before_hol() -> None:
    spans = ExecSpans()
    spans.step(2, hol=False)
    spans.step(1, hol=False)

    assert (spans.before_hol, spans.hol, spans.after_hol) == (3, 0, 0)


def test_phases_taken_start_again_and_can_be_put_back() -> None:
    phases = Phases()
    phases.add("hol", 2.0)
    phases.add("claim", 0.25)

    taken = phases.take()
    assert taken == {**dict.fromkeys(Phases.NAMES, 0.0), "hol": 2.0, "claim": 0.25}
    assert phases.take() == dict.fromkeys(Phases.NAMES, 0.0)
    phases.add("hol", 1.0)
    phases.put_back(taken)
    assert phases.take()["hol"] == 3.0


@pytest.mark.parametrize(("answer", "kept"), [((500, "busy"), 0.0), (OSError("refused"), 2.0)])
def test_reported_phases_start_again_once_the_coordinator_answered_the_claim(
    monkeypatch: pytest.MonkeyPatch, answer: tuple[int, str] | OSError, kept: float
) -> None:
    def post(*args: object) -> tuple[int, str]:
        if isinstance(answer, OSError):
            raise answer
        return answer

    monkeypatch.setattr(Coordinator, "post", post)
    phases = Phases()
    phases.add("hol", 2.0)

    assert claim_reporting(Coordinator("http://127.0.0.1:9", "w"), ["standard"], "w", 0, phases) is None
    assert phases.take()["hol"] == kept


def test_heartbeats_go_on_while_the_result_is_posted(
    tmp_path: Path, server: Server, logs: tuple[Path, Path],
) -> None:
    """Posting the result retries while the coordinator restarts; the lease is renewed meanwhile, so it doesn't
    expire and hand the action to another worker before the result gets in."""
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    server.unavailable = 2  # retried after 1 s and 2 s more, while the lease is renewed every 2 s

    run_one(Coordinator(server.url, "w"), worker_args(tmp_path, server), releases(tmp_path, server),
            Protection(None, None), {**claim(), "lease_s": 6}, Phases())

    assert server.completed == [RECORD]
    first, last = server.lease_posts.index("complete"), len(server.lease_posts) - 1
    assert server.lease_posts[last] == "complete"
    assert "heartbeat" in server.lease_posts[first:last], server.lease_posts


class FlakyCoordinator:
    """A coordinator whose heartbeats fail with ``errors`` first, then answer ``alive``."""

    def __init__(self, errors: int, alive: bool = True) -> None:
        self.drain = worker.Drain()
        self.errors = errors
        self.alive = alive
        self.beats: list[float] = []

    def heartbeat(self, token: str) -> bool:
        self.beats.append(time.monotonic())
        if len(self.beats) <= self.errors:
            raise OSError("unreachable")
        return self.alive


def test_a_failed_heartbeat_is_retried_soon(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(worker, "HEARTBEAT_RETRY_SECONDS", 0.2, raising=False)
    coordinator = FlakyCoordinator(errors=1)
    # Renewed every second.
    with Lease(coordinator, "t1", 3, Protection(None, None)).held(Phases()) as lease:  # type: ignore[arg-type]
        deadline = time.monotonic() + 5
        while len(coordinator.beats) < 2 and time.monotonic() < deadline:
            time.sleep(0.05)
    assert len(coordinator.beats) >= 2
    assert coordinator.beats[1] - coordinator.beats[0] < 0.45
    assert not lease.lost.is_set()


def test_a_lease_that_cannot_be_renewed_is_lost_when_it_expires(monkeypatch: pytest.MonkeyPatch) -> None:
    """While the coordinator can't be reached the action stops once its lease has run out, rather than running
    on beside the worker the coordinator handed it to."""
    monkeypatch.setattr(worker, "HEARTBEAT_RETRY_SECONDS", 0.2, raising=False)
    coordinator = FlakyCoordinator(errors=1_000_000)
    started = time.monotonic()
    with Lease(coordinator, "t1", 3, Protection(None, None)).held(Phases()) as lease:  # type: ignore[arg-type]
        lost = lease.lost.wait(6)
        lost_after = time.monotonic() - started
    assert lost and coordinator.drain.wake.is_set()
    assert 2.9 <= lost_after < 4, lost_after
    assert len(coordinator.beats) >= 3  # retried before the lease ran out


class ScriptedCoordinator(FlakyCoordinator):
    """A coordinator whose heartbeats fail where ``failures`` says, in order, and then succeed."""

    def __init__(self, failures: list[bool]) -> None:
        super().__init__(errors=0)
        self.failures = failures

    def heartbeat(self, token: str) -> bool:
        self.beats.append(time.monotonic())
        if len(self.beats) <= len(self.failures) and self.failures[len(self.beats) - 1]:
            raise OSError("unreachable")
        return True


def test_failed_heartbeats_back_off(monkeypatch: pytest.MonkeyPatch) -> None:
    """Each failure in a row doubles the wait before the next heartbeat, up to the heartbeat interval, so workers
    facing an overloaded coordinator don't keep adding to its load; each wait is jittered down to half, and a renewal
    starts the waits over."""
    monkeypatch.setattr(worker, "HEARTBEAT_RETRY_SECONDS", 0.6, raising=False)
    monkeypatch.setattr(worker.random, "uniform", lambda low, high: low)
    coordinator = ScriptedCoordinator([True, True, True, False, True, False])
    # Renewed every 2 s.
    with Lease(coordinator, "t1", 6, Protection(None, None)).held(Phases()) as lease:  # type: ignore[arg-type]
        deadline = time.monotonic() + 12
        while len(coordinator.beats) < 6 and time.monotonic() < deadline:
            time.sleep(0.05)
    gaps = [later - earlier for earlier, later in itertools.pairwise(coordinator.beats)]
    assert not lease.lost.is_set()
    # Half of 0.6, 1.2, then 2.4 capped at the 2 s interval; a renewal, then a failure waits half the base again.
    expected = [0.3, 0.6, 1.0, 2.0, 0.3]
    assert len(gaps) == len(expected) and all(abs(gap - want) < 0.1 for gap, want in zip(gaps, expected)), gaps


class StuckCoordinator:
    """A coordinator whose heartbeats block until ``release`` is set, as on a connection that stopped answering."""

    def __init__(self) -> None:
        self.drain = worker.Drain()
        self.release = threading.Event()

    def heartbeat(self, token: str) -> bool:
        self.release.wait()
        return True


def lost_after(lease: Lease) -> float:
    """Seconds until ``lease.check()``, polled as the action's loop polls it, finds the lease lost."""
    started = time.monotonic()
    while not lease.check() and time.monotonic() - started < 10:
        time.sleep(0.05)
    return time.monotonic() - started


def test_a_blocked_heartbeat_does_not_hold_the_action_past_its_lease() -> None:
    coordinator = StuckCoordinator()
    try:
        with Lease(coordinator, "t1", 3, Protection(None, None)).held(Phases()) as lease:  # type: ignore[arg-type]
            elapsed = lost_after(lease)
            assert 2.9 <= elapsed < 3.5, elapsed
            assert coordinator.drain.wake.is_set()
            coordinator.release.set()
    finally:
        coordinator.release.set()


def test_a_lease_runs_from_the_claim_time_it_is_given() -> None:
    coordinator = StuckCoordinator()
    try:
        claimed = time.monotonic() - 2
        with Lease(coordinator, "t1", 3, Protection(None, None), claimed=claimed).held(Phases()) as lease:  # type: ignore[arg-type]
            elapsed = lost_after(lease)
            assert elapsed < 1.5, elapsed
            coordinator.release.set()
    finally:
        coordinator.release.set()


def test_taking_and_giving_up_a_lease_counts_as_lease(tmp_path: Path, server: Server) -> None:
    switch = tmp_path / "protect"
    switch.write_text("#!/bin/sh\nsleep 0.5\n")
    switch.chmod(0o755)
    phases = Phases()

    with Lease(Coordinator(server.url, "w"), "t1", 60, Protection(str(switch), None)).held(phases):
        pass

    assert phases.take()["lease"] >= 1.0


@contextlib.contextmanager
def process_tree(tmp_path: Path, holder: str) -> Iterator[int]:
    """A shell whose child holds the file ``holder`` open, as holbuild's HOL child holds its lease."""
    ready = tmp_path / "ready"
    process = subprocess.Popen(
        ["sh", "-c", f'(exec 3>"{holder}"; touch "{ready}"; sleep 30) & wait'], start_new_session=True
    )
    try:
        deadline = time.monotonic() + 10
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        yield process.pid
    finally:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def test_a_descendant_holding_a_lease_runs_hol(tmp_path: Path) -> None:
    cooperate = tmp_path / "cooperate"
    cooperate.mkdir()
    with process_tree(tmp_path, str(cooperate / "lease-1")) as pid:
        assert runs_hol(pid, str(cooperate))
    with process_tree(tmp_path, str(cooperate / "lock")) as pid:
        assert not runs_hol(pid, str(cooperate))


def test_a_lease_the_process_itself_holds_is_not_a_hol_child(tmp_path: Path) -> None:
    cooperate = tmp_path / "cooperate"
    cooperate.mkdir()
    with open(cooperate / "lease-1", "w"):
        assert not runs_hol(os.getpid(), str(cooperate))


def test_an_action_s_time_is_split_around_its_hol_child(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    cooperate = tmp_path / "cooperate"
    cooperate.mkdir()
    monkeypatch.setenv("HOLBUILD_FAKE_LEASE", str(cooperate / "lease-1"))
    samples = iter(("before", "hol", "after"))
    expected = next(samples, None)

    def sample(pid: int, cooperate_dir: str) -> bool:
        nonlocal expected
        hol = runs_hol(pid, cooperate_dir)
        if expected is not None and hol == (expected == "hol"):
            (cooperate / f"lease-1.{expected}").touch()
            expected = next(samples, None)
        return hol

    monkeypatch.setattr(worker, "runs_hol", sample)
    phases = Phases()
    timed_phases: list[str] = []
    original_timed = phases.timed

    @contextlib.contextmanager
    def timed(name: str) -> Iterator[None]:
        timed_phases.append(name)
        with original_timed(name):
            yield

    monkeypatch.setattr(phases, "timed", timed)

    started = time.monotonic()
    run_one(
        Coordinator(server.url, "w"),
        worker_args(tmp_path, server, "--cooperate-dir", str(cooperate)),
        releases(tmp_path, server),
        Protection(None, None),
        claim(),
        phases,
    )

    seconds = phases.take()
    assert server.completed == [RECORD]
    assert seconds["before_hol"] >= 0.5 and seconds["hol"] >= 1 and seconds["after_hol"] >= 0.5
    assert timed_phases == ["lease", "release", "complete", "lease"]
    assert seconds["exec"] == 0
    assert sum(seconds.values()) == pytest.approx(time.monotonic() - started, abs=0.5)


def test_without_a_cooperate_dir_an_action_s_time_is_all_exec(
    tmp_path: Path, server: Server, logs: tuple[Path, Path]
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    phases = Phases()

    run_one(
        Coordinator(server.url, "w"),
        worker_args(tmp_path, server),
        releases(tmp_path, server),
        Protection(None, None),
        claim(),
        phases,
    )

    seconds = phases.take()
    assert seconds["exec"] >= 2 and seconds["before_hol"] == seconds["hol"] == seconds["after_hol"] == 0


def test_bootstrap_spec_uses_second_node_when_primary_is_unreachable(tmp_path: Path, server: Server) -> None:
    import hashlib

    from remote_exec.cache import ranked_nodes

    nodes = ["http://127.0.0.1:1", server.url]
    digest = next(
        key for i in range(100)
        if ranked_nodes(nodes, key := hashlib.sha256(str(i).encode()).hexdigest())[0] == nodes[0]
    )
    server.specs[digest] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    ring = Releases(str(tmp_path), "unused", ",".join(nodes), None)
    assert ring.read_spec(digest).version == "1.2.3"


@pytest.mark.parametrize("status", [404, 429, 503])
def test_bootstrap_spec_falls_back_before_parsing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, status: int
) -> None:
    from remote_exec.cache import ranked_nodes

    nodes = ["http://one.test", "http://two.test"]
    asked: list[str] = []

    def fetch(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[bytes]:
        asked.append(command[-1])
        assert "--retry" not in command
        if len(asked) == 1:
            return subprocess.CompletedProcess(command, 22, f"\n{status}".encode(), b"HTTP error")
        return subprocess.CompletedProcess(command, 0, b"holbuild-version=1.2.3\n\n200", b"")

    monkeypatch.setattr(subprocess, "run", fetch)
    assert Releases(str(tmp_path), "unused", ",".join(nodes), None).read_spec(SPEC).version == "1.2.3"
    assert asked == [f"{node}/cas/{SPEC}" for node in ranked_nodes(nodes, SPEC)]


def test_worker_cache_ring_from_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("HOLBUILD_REMOTE_CACHE_URL", "http://one.test/,http://two.test///,http://one.test")
    args = parse_args(["--coordinator", "http://exec.test", "--cache-limit-gb", "2"])
    assert args.remote_cache == "http://one.test,http://two.test"


@pytest.mark.parametrize("statuses", [(503, 404), (404, 503), (404, 404), (503, 429), (404, 403), (403,)])
def test_bootstrap_spec_distinguishes_miss_from_outage(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, statuses: tuple[int, ...]
) -> None:
    asked: list[str] = []

    def fetch(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[bytes]:
        # /cas/ answers as given; /ac/, asked only after 404s from every node, misses.
        status = statuses[len(asked)] if len(asked) < len(statuses) else 404
        asked.append(command[-1])
        return subprocess.CompletedProcess(command, 22, f"\n{status}".encode(), f"HTTP {status}".encode())

    monkeypatch.setattr(subprocess, "run", fetch)
    ring = Releases(str(tmp_path), "unused", "http://one.test,http://two.test", None)
    # A spec must be there: a node that fails leaves it unavailable, even beside a 404.
    error = RuntimeError if 403 in statuses or statuses == (404, 404) else CacheUnavailable
    message = "HTTP 403" if 403 in statuses else "HTTP 404" if error is RuntimeError else "HTTP 429|HTTP 503"
    with pytest.raises(error, match=message) as caught:
        ring.read_spec(SPEC)
    assert type(caught.value) is error
    assert len(asked) == (4 if statuses == (404, 404) else len(statuses))
    if statuses == (404, 404):
        from remote_exec.cache import ranked_nodes

        nodes = ["http://one.test", "http://two.test"]
        assert asked[2:] == [f"{node}/ac/{blob_key(SPEC)}" for node in ranked_nodes(nodes, blob_key(SPEC))]


def test_blob_key_is_the_clients() -> None:
    # The value holbuild's SML blob_key gives, pinned so neither side drifts alone.
    assert blob_key("0" * 64) == "f88baeae5f54f92e61dcaf2cc69cd2577dd9d5891059c52ee988f0bf3391c9e9"


def test_bootstrap_spec_reads_one_written_compressed_under_ac(tmp_path: Path, server: Server) -> None:
    server.zstd_specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=0.15.0\n"
    assert Releases(str(tmp_path), "unused", server.url, None).read_spec(SPEC).version == "0.15.0"


def test_bootstrap_spec_under_ac_that_does_not_decompress_is_corrupt(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    run = subprocess.run

    def fetch(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[bytes]:
        if command[0] == "zstd":
            return run(command, **kwargs)
        if "/cas/" in command[-1]:
            return subprocess.CompletedProcess(command, 22, b"\n404", b"HTTP 404")
        return subprocess.CompletedProcess(command, 0, b"holbuild-version=1.2.3\n\n200", b"")

    monkeypatch.setattr(subprocess, "run", fetch)
    with pytest.raises(RuntimeError, match="corrupt"):
        Releases(str(tmp_path), "unused", "http://one.test", None).read_spec(SPEC)


def test_worker_discovery_exposes_only_a_scoped_token_to_the_action_and_cleans_it_on_exit(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    token = "worker-secret-discovery-test"
    inherited_config = tmp_path / "coordinator.curl"
    inherited_config.write_text(token)
    monkeypatch.setattr(os, "environ", {
        "PATH": os.environ["PATH"], "HOME": str(tmp_path),
        "FAKE_BUILD_LOG": str(logs[0]), "HOLBUILD_FAKE_LOG": str(logs[1]),
        "REMOTE_EXEC_WORKER_TOKEN": token,
        "HOLBUILD_CACHE": str(tmp_path / "cache"),
        "HOLBUILD_REMOTE_CACHE_DISCOVERY_URL": server.url + "/v1/cache/members",
        "HOLBUILD_REMOTE_CACHE_DISCOVERY_TOKEN": token,
        "HOLBUILD_REMOTE_CACHE_DISCOVERY_CURL_CONFIG": str(inherited_config),
        "HOLBUILD_REMOTE_EXEC_CURL_CONFIG": str(inherited_config),
        "HOLBUILD_REMOTE_EXEC_TOKEN": token,
    })
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    monkeypatch.setattr(worker, "parse_args", lambda: worker_args(
        tmp_path, server, "--holbuild-source-url", f"file://{tmp_path}/holbuild-{{version}}.tar.gz",
    ))
    monkeypatch.setattr(worker, "refresh_cache_members", lambda _c, membership, _url, now: membership.current(now))
    paths: list[Path] = []
    claims = iter([claim()])

    def claim_then_exit(*_: object) -> dict[str, object]:
        claimed = next(claims, None)
        if claimed is not None:
            return claimed
        env = dict(line.split("=", 1) for line in Path(f"{logs[1]}.env").read_text().splitlines() if "=" in line)
        assert "REMOTE_EXEC_WORKER_TOKEN" not in env
        assert "HOLBUILD_REMOTE_CACHE_DISCOVERY_TOKEN" not in env
        assert not any(name.startswith("HOLBUILD_REMOTE_EXEC_") for name in env)
        assert all(token not in value for value in env.values())
        for value in env.values():
            path = Path(value)
            if path.is_file():
                assert token.encode() not in path.read_bytes()
        assert env["HOLBUILD_REMOTE_CACHE_DISCOVERY_URL"] == server.url + "/v1/cache/members"
        config = Path(env["HOLBUILD_REMOTE_CACHE_DISCOVERY_CURL_CONFIG"])
        paths.append(config)
        assert config != inherited_config
        assert config.stat().st_mode & 0o777 == 0o600
        assert config.parent.stat().st_mode & 0o777 == 0o700
        assert config.read_text() == f'header = "Authorization: Bearer {cache_discovery_token(token)}"\n'
        raise KeyboardInterrupt

    monkeypatch.setattr(worker, "claim_reporting", claim_then_exit)
    with pytest.raises(KeyboardInterrupt):
        worker.main()
    assert server.completed == [RECORD]
    assert logs[1].read_text().split()[:2] == ["--remote-cache", server.url]
    assert len(paths) == 1 and not paths[0].exists()


@pytest.mark.parametrize("newline", ["\r", "\n", "\r\n"])
def test_worker_rejects_newlines_before_an_http_error_can_print_its_token(
    tmp_path: Path, server: Server, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], newline: str
) -> None:
    token = "worker-secret" + newline
    monkeypatch.setenv("REMOTE_EXEC_WORKER_TOKEN", token)
    monkeypatch.setattr(worker, "parse_args", lambda: worker_args(tmp_path, server))
    with pytest.raises(SystemExit) as error:
        worker.main()
    assert str(error.value) == "worker token must not contain a newline"
    captured = capsys.readouterr()
    assert "worker-secret" not in captured.out + captured.err


def test_worker_refuses_plain_http_discovery_with_a_cache_curl_config(
    tmp_path: Path, server: Server, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("REMOTE_EXEC_WORKER_TOKEN", "worker-secret")
    monkeypatch.setenv("HOLBUILD_CACHE", str(tmp_path / "cache"))
    monkeypatch.setenv("HOLBUILD_REMOTE_CACHE_DISCOVERY_URL", server.url + "/v1/cache/members")
    monkeypatch.setenv("HOLBUILD_REMOTE_CACHE_CURL_CONFIG", str(tmp_path / "cache.curl"))
    monkeypatch.setenv("HOLBUILD_REMOTE_CACHE_ALLOWED_URLS", "http://burst.example")
    monkeypatch.setattr(worker, "parse_args", lambda: worker_args(tmp_path, server))
    monkeypatch.setattr(worker, "claim_reporting", lambda *_: pytest.fail("claimed with an unsafe cache allowlist"))
    with pytest.raises(SystemExit, match="plain-HTTP endpoint"):
        worker.main()


def test_worker_refreshes_bootstrap_membership_after_memory_and_claim_waits(
    tmp_path: Path, server: Server, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("REMOTE_EXEC_WORKER_TOKEN", "worker-secret")
    monkeypatch.setenv("HOLBUILD_CACHE", str(tmp_path / "cache"))
    monkeypatch.setenv("HOLBUILD_REMOTE_CACHE_DISCOVERY_URL", server.url + "/v1/cache/members")
    args = worker_args(tmp_path, server)
    args.cooperate_dir = str(tmp_path / "cooperate")
    monkeypatch.setattr(worker, "parse_args", lambda: args)
    monkeypatch.setattr(worker, "HostTelemetry", lambda *_: None)
    events: list[str] = []
    monkeypatch.setattr(worker, "wait_for_memory", lambda *_: events.append("memory") or False)
    monkeypatch.setattr(worker, "claim_reporting", lambda *_: events.append("claim") or claim())

    def refresh(_coordinator, membership, _url, now):
        events.append("refresh")
        membership.allowed.append("https://joined.example")
        membership.update("holbuild-cache-members-v1\n" + server.url + "\nhttps://joined.example\n", now)
        return membership.current(now)

    def run(_coordinator, _args, releases, *_rest, **_kwargs):
        assert "https://joined.example" in releases.remote_cache
        events.append("run")
        raise KeyboardInterrupt

    monkeypatch.setattr(worker, "refresh_cache_members", refresh)
    monkeypatch.setattr(worker, "run_one", run)
    with pytest.raises(KeyboardInterrupt):
        worker.main()
    assert events == ["memory", "claim", "refresh", "run"]


def test_the_default_worker_name_carries_the_image_digest_the_task_runs(monkeypatch: pytest.MonkeyPatch) -> None:
    args = ["--coordinator", "http://coordinator.test", "--remote-cache", "http://cache.test", "--cache-limit-gb", "1"]
    plain = f"{socket.gethostname()}:{os.getpid()}"
    monkeypatch.delenv("REMOTE_EXEC_IMAGE", raising=False)
    assert parse_args(args).name == plain
    monkeypatch.setenv("REMOTE_EXEC_IMAGE", "123.dkr.ecr.eu-west-1.amazonaws.com/holbuild-remote-exec@sha256:" + "ab12" * 16)
    assert parse_args(args).name == plain + "@ab12ab12ab12"
    assert parse_args([*args, "--name", "w1"]).name == "w1"
    monkeypatch.setenv("REMOTE_EXEC_IMAGE", "holbuild-remote-exec:latest")
    assert parse_args(args).name == plain
