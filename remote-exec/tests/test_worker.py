import argparse
import contextlib
import fcntl
import io
import json
import os
import tarfile
import threading
import time
from collections.abc import Iterator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from remote_exec import worker
from remote_exec.worker import (
    Coordinator,
    HostMemory,
    Protection,
    Releases,
    Unreleased,
    child_charge,
    failed_record,
    parse_args,
    run_one,
    wait_for_memory,
)

SPEC = "5" * 64
RECORD = f"holbuild-action-result-v1\nspec={SPEC}\ninput-key={'6' * 64}\nstatus=built\n"

# A stand-in holbuild source tree: `make bin/holbuild` installs a script that logs its arguments and environment and
# writes RECORD to its --result file, or crashes without one when HOLBUILD_FAKE_CRASH is set.
FAKE_HOLBUILD = f"""#!/bin/sh
echo "$@" >> "$HOLBUILD_FAKE_LOG"
env > "$HOLBUILD_FAKE_LOG.env"
sleep 2  # long enough for a heartbeat at the 1 s interval of a 3 s lease
[ -z "$HOLBUILD_FAKE_CRASH" ] || exit 70
while [ "$#" -gt 0 ]; do
  if [ "$1" = --result ]; then printf '{RECORD}' > "$2"; fi
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
    unavailable: int = 0  # how many more completes answer 502, as a proxy does while the coordinator restarts


@pytest.fixture
def server() -> Iterator[Server]:
    state = Server()

    class Handler(BaseHTTPRequestHandler):
        def body(self) -> str:
            return self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()

        def reply(self, status: int, body: str = "") -> None:
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body.encode())

        def do_GET(self) -> None:
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
                return self.reply(204)
            if self.path.endswith("/complete"):
                if state.unavailable > 0:
                    state.unavailable -= 1
                    return self.reply(502)
                state.completed.append(body)
            self.reply(200, json.dumps({"accepted": True}) if self.path.endswith("/complete") else '{"lease_s": 3}')

        def do_PUT(self) -> None:
            state.protection.append(json.loads(self.body()))
            self.reply(200, "{}")

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


def test_worker_runs_the_action_on_the_release_that_exported_it(
    tmp_path: Path, server: Server, logs: tuple[Path, Path]
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    switch = tmp_path / "protect"
    switch.write_text(f'#!/bin/sh\necho "$1" >> {tmp_path}/protection\n')
    switch.chmod(0o755)
    args = worker_args(tmp_path, server, "--protection-cmd", str(switch))

    run_one(Coordinator(server.url, "w"), args, releases(tmp_path, server), Protection(str(switch), None), claim())

    assert server.completed == [RECORD]
    assert logs[1].read_text().split() == [
        "--remote-cache",
        server.url,
        "exec-action",
        SPEC,
        "--cache-limit-gb",
        "50",
        "--result",
        logs[1].read_text().split()[7],
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
    )

    env = dict(line.split("=", 1) for line in Path(f"{logs[1]}.env").read_text().splitlines() if "=" in line)
    assert "REMOTE_EXEC_WORKER_TOKEN" not in env
    assert "UNRELATED" not in env
    assert env["HTTPS_PROXY"] == "http://proxy.test:3128"
    assert env["HOLBUILD_CACHE"] == str(tmp_path / "cache")
    assert env["HOLBUILD_REMOTE_CACHE_CURL_CONFIG"] == str(tmp_path / "cache.curl")
    assert env["PATH"]


def test_action_that_ends_without_a_record_is_reported_for_a_retry(
    tmp_path: Path, server: Server, logs: tuple[Path, Path], monkeypatch: pytest.MonkeyPatch
) -> None:
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    monkeypatch.setenv("HOLBUILD_FAKE_CRASH", "1")

    run_one(
        Coordinator(server.url, "w"),
        worker_args(tmp_path, server),
        releases(tmp_path, server),
        Protection(None, None),
        claim(),
    )

    assert server.completed == [failed_record(SPEC, "internal")]


def test_action_of_an_unreleased_holbuild_is_rejected(tmp_path: Path, server: Server, logs: tuple[Path, Path]) -> None:
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.4\n"

    run_one(
        Coordinator(server.url, "w"),
        worker_args(tmp_path, server),
        releases(tmp_path, server),
        Protection(None, None),
        claim(),
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


def test_ecs_task_protection_is_set_and_cleared(server: Server) -> None:
    protection = Protection(None, server.url)

    protection.set(enabled=True)
    protection.set(enabled=False)

    assert server.protection == [{"ProtectionEnabled": True, "ExpiresInMinutes": 10}, {"ProtectionEnabled": False}]


def test_also_claim_accepts_repeats_and_commas(tmp_path: Path, server: Server) -> None:
    args = worker_args(tmp_path, server, "--tier", "high", "--also-claim", "standard,high", "--also-claim", "standard")

    assert args.also_claim == ["standard", "high", "standard"]


def test_claim_asks_the_coordinator_to_wait(server: Server) -> None:
    assert Coordinator(server.url, "w").claim(["standard", "high"], "w", 20) is None
    assert server.claims == [{"tier": "standard", "also_claim": ["high"], "worker": "w", "wait_s": 20}]


def test_claim_wait_is_at_most_50_seconds(tmp_path: Path, server: Server) -> None:
    assert worker_args(tmp_path, server, "--claim-wait-seconds", "50").claim_wait_seconds == 50
    with pytest.raises(SystemExit):
        worker_args(tmp_path, server, "--claim-wait-seconds", "51")


def test_coordinator_redirects_are_not_followed(server: Server) -> None:
    with pytest.raises(RuntimeError, match="claim answered 303"):
        Coordinator(server.url + "/moved", "w").claim(["standard"], "w", 0)


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
