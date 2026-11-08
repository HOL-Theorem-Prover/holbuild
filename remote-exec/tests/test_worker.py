import argparse
import contextlib
import fcntl
import io
import json
import os
import signal
import subprocess
import sys
import tarfile
import threading
import time
from collections.abc import Iterator
from dataclasses import dataclass, field, replace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from remote_exec import worker
from remote_exec.auth import cache_discovery_token
from remote_exec.worker import (
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
    parse_args,
    run_one,
    runs_hol,
    wait_for_memory,
)

SPEC = "5" * 64
RECORD = f"holbuild-action-result-v1\nspec={SPEC}\ninput-key={'6' * 64}\nstatus=built\n"

# A stand-in holbuild source tree: `make bin/holbuild` installs a script that logs its arguments and environment and
# writes RECORD (or HOLBUILD_FAKE_RECORD) to its --result file, or crashes without one when HOLBUILD_FAKE_CRASH is set.
FAKE_HOLBUILD = f"""#!/bin/sh
[ "$1" != sandbox-check ] || exit 0
echo $$ > "$HOLBUILD_FAKE_LOG.pid"
if [ -n "$HOLBUILD_FAKE_HANG" ]; then
  trap '' TERM
  (while :; do sleep 1; done) &
  echo $! > "$HOLBUILD_FAKE_LOG.child"
  wait
fi
echo "$@" >> "$HOLBUILD_FAKE_LOG"
env > "$HOLBUILD_FAKE_LOG.env"
# long enough for a heartbeat at the 1 s interval of a 3 s lease; HOLBUILD_FAKE_LEASE: in a child holding that file
# open, as a HOL child holds its admission lease
if [ -n "$HOLBUILD_FAKE_LEASE" ]; then sleep 1; (exec 3>"$HOLBUILD_FAKE_LEASE"; sleep 2); sleep 1; else sleep 2; fi
[ -z "$HOLBUILD_FAKE_CRASH" ] || exit 70
while [ "$#" -gt 0 ]; do
  if [ "$1" = --result ]; then printf '%s' "${{HOLBUILD_FAKE_RECORD:-{RECORD}}}" > "$2"; fi
  shift
done
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
    specs: dict[str, str] = field(default_factory=dict)
    completed: list[str] = field(default_factory=list)
    protection: list[dict[str, object]] = field(default_factory=list)
    claims: list[dict[str, object]] = field(default_factory=list)
    heartbeats: list[dict[str, object]] = field(default_factory=list)
    unavailable: int = 0  # how many more completes answer 502, as a proxy does while the coordinator restarts
    cut_short: bool = False  # whether /cas/ answers close the connection before the body they announce is sent
    next_claim: dict[str, object] | None = None
    claim_started: threading.Event = field(default_factory=threading.Event)
    hold_claim: threading.Event | None = None
    protection_reply: dict[str, object] = field(default_factory=dict)


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
            if self.path.endswith("/complete"):
                if state.unavailable > 0:
                    state.unavailable -= 1
                    return self.reply(502)
                state.completed.append(body)
            if self.path.endswith("/heartbeat"):
                state.heartbeats.append(json.loads(body))
            self.reply(200, json.dumps({"accepted": True}) if self.path.endswith("/complete") else '{"lease_s": 3}')

        def do_PUT(self) -> None:
            state.protection.append(json.loads(self.body()))
            self.reply(200, json.dumps(state.protection_reply))

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


@pytest.mark.parametrize("version", ["0.13.52", "0.13.53", "0.13.54", "0.13.55", "0.13.56"])
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
def running_worker(tmp_path: Path, server: Server, drain: str) -> Iterator[subprocess.Popen[bytes]]:
    env = {**os.environ, "REMOTE_EXEC_WORKER_TOKEN": "w", "HOLBUILD_CACHE": str(tmp_path / "cache")}
    with (tmp_path / "worker.log").open("wb") as log:
        process = subprocess.Popen(
            [sys.executable, "-m", "remote_exec.worker", "--coordinator", server.url, "--remote-cache", server.url,
             "--cache-limit-gb", "50", "--holbuild-releases-dir", str(tmp_path / "releases"),
             "--holbuild-source-url", f"file://{tmp_path}/holbuild-{{version}}.tar.gz", "--drain-seconds", drain],
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


@pytest.mark.parametrize(("drain", "expected"), [("5", RECORD), ("0", failed_record(SPEC, "unavailable"))])
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


def test_sigterm_kills_descendants_that_ignore_term_and_repeated_signals_do_not_reset_the_drain(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch,
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    server.next_claim = claim()
    monkeypatch.setenv("HOLBUILD_FAKE_HANG", "1")
    child_file = Path(f"{logs[1]}.child")
    with running_worker(tmp_path, server, "0.1") as process:
        wait_for_file(child_file)
        group = int(Path(f"{logs[1]}.pid").read_text())
        try:
            process.send_signal(signal.SIGTERM)
            time.sleep(0.2)
            process.send_signal(signal.SIGTERM)
            assert process.wait(timeout=8) == 0, (tmp_path / "worker.log").read_text()
            child = Path(f"/proc/{int(child_file.read_text())}/stat")
            assert not child.exists() or child.read_text().split()[2] == "Z"
        finally:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(group, signal.SIGKILL)
    assert server.completed == [failed_record(SPEC, "unavailable")]
    assert len(server.claims) == 1


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
    assert server.completed == [failed_record(SPEC, "unavailable")]
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
        "--result",
        logs[1].read_text().split()[9],
        "--share-heaps",
    ]
    *held, released = (tmp_path / "protection").read_text().split()
    assert (set(held), released) == ({"on"}, "off")
    assert len(held) >= 2  # renewed on a heartbeat


def test_action_runs_without_the_worker_token(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    monkeypatch.setenv("REMOTE_EXEC_WORKER_TOKEN", "worker-secret")
    monkeypatch.setenv("HOLBUILD_REMOTE_CACHE_DISCOVERY_TOKEN", "worker-secret")
    monkeypatch.setenv("HOLBUILD_REMOTE_CACHE_DISCOVERY_CURL_CONFIG", str(tmp_path / "worker.curl"))
    monkeypatch.setenv("UNRELATED", "1")
    monkeypatch.setenv("HOLBUILD_CACHE", str(tmp_path / "cache"))
    monkeypatch.setenv("HOLBUILD_REMOTE_CACHE_CURL_CONFIG", str(tmp_path / "cache.curl"))
    monkeypatch.setenv("HTTPS_PROXY", "http://proxy.test:3128")

    run_one(
        Coordinator(server.url, "w"),
        worker_args(tmp_path, server),
        releases(tmp_path, server),
        Protection(None, None),
        claim(),
        Phases(),
    )

    env = dict(line.split("=", 1) for line in Path(f"{logs[1]}.env").read_text().splitlines() if "=" in line)
    assert "REMOTE_EXEC_WORKER_TOKEN" not in env
    assert "HOLBUILD_REMOTE_CACHE_DISCOVERY_TOKEN" not in env
    assert "HOLBUILD_REMOTE_CACHE_DISCOVERY_CURL_CONFIG" not in env
    assert "worker-secret" not in env.values()
    assert "UNRELATED" not in env
    assert env["HTTPS_PROXY"] == "http://proxy.test:3128"
    assert env["HOLBUILD_CACHE"] == str(tmp_path / "cache")
    assert env["HOLBUILD_REMOTE_CACHE_CURL_CONFIG"] == str(tmp_path / "cache.curl")
    assert env["PATH"]


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

    def run(*_: object) -> bool:
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

    assert server.completed == [failed_record(SPEC, "unavailable")]
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

    assert server.completed == [failed_record(SPEC, "unavailable")]


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


def test_action_of_an_unreleased_holbuild_is_rejected(tmp_path: Path, server: Server, logs: tuple[Path, Path]) -> None:
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.4\n"

    run_one(
        Coordinator(server.url, "w"),
        worker_args(tmp_path, server),
        releases(tmp_path, server),
        Protection(None, None),
        claim(),
        Phases(),
    )

    assert server.completed == [failed_record(SPEC, "spec-rejected")]
    assert not logs[1].exists()


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

    assert server.protection == [{"ProtectionEnabled": True, "ExpiresInMinutes": 10}, {"ProtectionEnabled": False}]


def test_also_claim_accepts_repeats_and_commas(tmp_path: Path, server: Server) -> None:
    args = worker_args(tmp_path, server, "--tier", "high", "--also-claim", "standard,high", "--also-claim", "standard")

    assert args.also_claim == ["standard", "high", "standard"]


def test_claim_asks_the_coordinator_to_wait(server: Server) -> None:
    assert Coordinator(server.url, "w").claim(["standard", "high"], "w", 20, {"hol": 1.5}) is None
    assert server.claims == [
        {"tier": "standard", "also_claim": ["high"], "worker": "w", "wait_s": 20, "phases": {"hol": 1.5}, "host": None}
    ]


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


def test_no_report_while_an_admission_holds_the_lock_or_the_host_cannot_be_read(
    host: Host, telemetry: tuple[HostTelemetry, Path], server: Server
) -> None:
    reporter, stat = telemetry
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
    assert reports[0] is None and reports[2] is None
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
    assert ring.spec_version(digest) == "1.2.3"


@pytest.mark.parametrize("status", [404, 429, 503])
def test_bootstrap_spec_falls_back_before_parsing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, status: int
) -> None:
    from remote_exec.cache import ranked_nodes

    nodes = ["http://one.test", "http://two.test"]
    asked: list[str] = []

    def fetch(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        asked.append(command[-1])
        assert "--retry" not in command
        if len(asked) == 1:
            return subprocess.CompletedProcess(command, 22, f"\n{status}", "HTTP error")
        return subprocess.CompletedProcess(command, 0, "holbuild-version=1.2.3\n\n200", "")

    monkeypatch.setattr(subprocess, "run", fetch)
    assert Releases(str(tmp_path), "unused", ",".join(nodes), None).spec_version(SPEC) == "1.2.3"
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

    def fetch(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        status = statuses[len(asked)]
        asked.append(command[-1])
        return subprocess.CompletedProcess(command, 22, f"\n{status}", f"HTTP {status}")

    monkeypatch.setattr(subprocess, "run", fetch)
    ring = Releases(str(tmp_path), "unused", "http://one.test,http://two.test", None)
    error = CacheUnavailable if statuses == (503, 429) else RuntimeError
    message = "HTTP 403" if 403 in statuses else "HTTP 429" if error is CacheUnavailable else "HTTP 404"
    with pytest.raises(error, match=message) as caught:
        ring.spec_version(SPEC)
    assert type(caught.value) is error
    assert len(asked) == len(statuses)


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

    def run(_coordinator, _args, releases, *_rest):
        assert "https://joined.example" in releases.remote_cache
        assert releases.joining
        events.append("run")
        raise KeyboardInterrupt

    monkeypatch.setattr(worker, "refresh_cache_members", refresh)
    monkeypatch.setattr(worker, "run_one", run)
    with pytest.raises(KeyboardInterrupt):
        worker.main()
    assert events == ["memory", "claim", "refresh", "run"]
