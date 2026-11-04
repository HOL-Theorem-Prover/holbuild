import argparse
import io
import json
import tarfile
import threading
from collections.abc import Iterator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from remote_exec.worker import Coordinator, Protection, Releases, Unreleased, parse_args, rejected_record, run_one

SPEC = "5" * 64
RECORD = f"holbuild-action-result-v1\nspec={SPEC}\ninput-key={'6' * 64}\nstatus=built\n"

# A stand-in holbuild source tree: `make bin/holbuild` installs a script that logs its arguments and writes RECORD
# to its --result file.
FAKE_HOLBUILD = f"""#!/bin/sh
echo "$@" >> "$FAKE_HOLBUILD_LOG"
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


def release_tarball(path: Path, version: str) -> None:
    with tarfile.open(path, "w:gz") as tar:
        for name, text in {"Makefile": FAKE_MAKEFILE, "fake-holbuild": FAKE_HOLBUILD}.items():
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
            if self.path.endswith("/complete"):
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
    monkeypatch.setenv("FAKE_HOLBUILD_LOG", str(holbuild_log))
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
    *held, released = (tmp_path / "protection").read_text().split()  # "on" again on each heartbeat
    assert (set(held), released) == ({"on"}, "off")


def test_action_of_an_unreleased_holbuild_is_rejected(tmp_path: Path, server: Server, logs: tuple[Path, Path]) -> None:
    server.specs[SPEC] = "holbuild-action-spec-v1\nholbuild-version=1.2.4\n"

    run_one(
        Coordinator(server.url, "w"),
        worker_args(tmp_path, server),
        releases(tmp_path, server),
        Protection(None, None),
        claim(),
    )

    assert server.completed == [rejected_record(SPEC)]
    assert not logs[1].exists()


def test_ecs_task_protection_is_set_and_cleared(server: Server) -> None:
    protection = Protection(None, server.url)

    protection.set(enabled=True)
    protection.set(enabled=False)

    assert server.protection == [{"ProtectionEnabled": True, "ExpiresInMinutes": 10}, {"ProtectionEnabled": False}]


def test_also_claim_accepts_repeats_and_commas(tmp_path: Path, server: Server) -> None:
    args = worker_args(tmp_path, server, "--tier", "high", "--also-claim", "standard,high", "--also-claim", "standard")

    assert args.also_claim == ["standard", "high", "standard"]
