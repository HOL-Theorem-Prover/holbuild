"""Explicit native-client checks; run after building holbuild and its HOL test toolchain."""

import asyncio
import contextlib
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

import httpx
import pytest
import uvicorn

from conftest import CLIENT_TOKEN, WORKER_TOKEN
from remote_exec.app import create_app
from remote_exec.coordinator import Coordinator
from remote_exec.worker import stop_group
from test_coordinator import CLIENT, batch_text, spec
from test_worker import Server, logs, release_tarball, server, wait_for_file  # noqa: F401

ROOT = Path(__file__).resolve().parents[2]


def wait_for_following(path: Path) -> None:
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if "pkg:loop: ready" in path.read_text():
            return
        time.sleep(0.05)
    raise AssertionError(path.read_text())


@pytest.mark.parametrize("stop", ["client-budget", "drain"])
async def test_native_client_retrieves_interrupted_output_at_production_heartbeat(
    coordinator: Coordinator, server: Server, tmp_path: Path, logs: tuple[Path, Path],
    monkeypatch: pytest.MonkeyPatch, stop: str,
) -> None:
    coordinator.settings.lease_seconds = 120  # Production's 40-second heartbeat, without shortening cleanup.
    server.specs[spec("loop")] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    monkeypatch.setenv("HOLBUILD_FAKE_OUTPUT", "1")
    monkeypatch.setenv("HOLBUILD_FAKE_HANG", "1")
    project = tmp_path / "project"
    (project / "src").mkdir(parents=True)
    revision = (ROOT / "vendor/hol/REV").read_text().strip()
    (project / "holproject.toml").write_text(
        '[holbuild]\nschema = 2\nminimum_version = "0.10.0"\n'
        f'[dependencies.hol]\ngit = "https://github.com/HOL-Theorem-Prover/HOL.git"\nrev = "{revision}"\n'
        '[project]\nname = "pkg"\n[build]\nmembers = ["src"]\n'
    )
    (project / "src/LoopScript.sml").write_text("Theory Loop\nAncestors bool\n")
    client_cache = tmp_path / "client-cache"
    client_cache.mkdir()
    shared = (Path(os.environ.get("HOLBUILD_CACHE", Path.home() / ".cache/holbuild")) / "hol-toolchains").resolve()
    (client_cache / "hol-toolchains").symlink_to(shared, target_is_directory=True)
    config = tmp_path / "client.curl"
    config.write_text(f'header = "Authorization: Bearer {CLIENT_TOKEN}"\n')
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    url = f"http://127.0.0.1:{listener.getsockname()[1]}"
    api = uvicorn.Server(uvicorn.Config(create_app(coordinator, coordinator.settings), lifespan="off", log_level="error"))
    serving = asyncio.create_task(api.serve(sockets=[listener]))
    processes: list[subprocess.Popen[bytes]] = []
    try:
        async with httpx.AsyncClient(base_url=url, timeout=15) as http:
            response = await http.post("/v1/batches", content=batch_text(["loop"]), headers=CLIENT)
            assert response.status_code == 201, response.text
            batch_id = response.json()["batch_id"]
            command = [str(ROOT / "bin/holbuild"), "--remote-cache", server.url, "build", "--remote-exec", url,
                       "--remote-only", "--attach", batch_id, "LoopTheory"]
            environment = {**os.environ, "HOLBUILD_CACHE": str(client_cache),
                           "HOLBUILD_REMOTE_EXEC_CURL_CONFIG": str(config)}
            with (tmp_path / "client.log").open("wb") as client_log, (tmp_path / "worker.log").open("wb") as worker_log:
                client = subprocess.Popen(command, cwd=project, env=environment, stdout=client_log, stderr=client_log,
                                          start_new_session=True)
                processes.append(client)
                await asyncio.to_thread(wait_for_following, tmp_path / "client.log")
                worker = subprocess.Popen(
                    [sys.executable, "-m", "remote_exec.worker", "--coordinator", url,
                     "--remote-cache", server.url, "--cache-limit-gb", "50", "--drain-seconds", "0",
                     "--claim-wait-seconds", "0", "--holbuild-releases-dir", str(tmp_path / "releases"),
                     "--holbuild-source-url", f"file://{tmp_path}/holbuild-{{version}}.tar.gz"],
                    env={**os.environ, "REMOTE_EXEC_WORKER_TOKEN": WORKER_TOKEN,
                         "HOLBUILD_CACHE": str(tmp_path / "worker-cache")},
                    stdout=worker_log, stderr=worker_log, start_new_session=True,
                )
                processes.append(worker)
                await asyncio.to_thread(wait_for_file, Path(f"{logs[1]}.output-ready"))
                if stop == "client-budget":
                    client.send_signal(signal.SIGTERM)
                    assert await asyncio.to_thread(client.wait, timeout=15) == 1
                    assert "HOL interrupted marker" not in (tmp_path / "client.log").read_text()
                    assert "cancelled remote batch" in (tmp_path / "client.log").read_text()
                else:
                    worker.send_signal(signal.SIGTERM)
                    assert await asyncio.to_thread(worker.wait, timeout=15) == 0
                    assert (await http.post(f"/v1/batches/{batch_id}/cancel", headers=CLIENT)).status_code == 200
                    assert await asyncio.to_thread(client.wait, timeout=30) == 1
                    assert "HOL interrupted marker" in (tmp_path / "client.log").read_text()
            with (tmp_path / "reattach.log").open("wb") as log:
                reattached = subprocess.Popen(command, cwd=project, env=environment, stdout=log, stderr=log,
                                              start_new_session=True)
                processes.append(reattached)
                assert await asyncio.to_thread(reattached.wait, timeout=90) == 1
            printed = (tmp_path / "reattach.log").read_text()
            assert "output from interrupted attempt" in printed, printed
            assert "HOL interrupted marker" in printed, printed
    finally:
        for process in processes:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try:
                    await asyncio.to_thread(process.wait, timeout=15)
                except subprocess.TimeoutExpired:
                    await asyncio.to_thread(stop_group, process)
        api.should_exit = True
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(serving, timeout=10)
        listener.close()
