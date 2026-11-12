"""A real worker and coordinator retain output after the following client is gone."""

import asyncio
import contextlib
import json
import os
import signal
import socket
import subprocess
import sys
from pathlib import Path

import httpx
import pytest
import uvicorn

from conftest import CLIENT_TOKEN, WORKER_TOKEN
from remote_exec.app import create_app
from remote_exec.coordinator import Coordinator
from remote_exec.worker import stop_group
from test_coordinator import CLIENT, batch_text, spec
from test_worker import Server, release_tarball, server, logs, wait_for_file  # noqa: F401


@pytest.mark.parametrize("stop", ["client-budget", "drain"])
async def test_output_is_retrievable_by_batch_id_after_interruption(
    coordinator: Coordinator, server: Server, tmp_path: Path, logs: tuple[Path, Path],
    monkeypatch: pytest.MonkeyPatch, stop: str,
) -> None:
    coordinator.settings.lease_seconds = 3
    server.specs[spec("loop")] = "holbuild-action-spec-v1\nholbuild-version=1.2.3\n"
    release_tarball(tmp_path / "holbuild-1.2.3.tar.gz", "1.2.3")
    monkeypatch.setenv("HOLBUILD_FAKE_OUTPUT", "1")
    monkeypatch.setenv("HOLBUILD_FAKE_HANG", "1")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    url = f"http://127.0.0.1:{listener.getsockname()[1]}"
    api = uvicorn.Server(uvicorn.Config(create_app(coordinator, coordinator.settings), lifespan="off", log_level="error"))
    serving = asyncio.create_task(api.serve(sockets=[listener]))
    process: subprocess.Popen[bytes] | None = None
    follower: subprocess.Popen[bytes] | None = None
    try:
        async with httpx.AsyncClient(base_url=url, timeout=15) as client:
            response = await client.post("/v1/batches", content=batch_text(["loop"]), headers=CLIENT)
            assert response.status_code == 201, response.text
            batch_id = response.json()["batch_id"]
            with (tmp_path / "worker.log").open("wb") as log, (tmp_path / "client.log").open("wb") as client_log:
                process = subprocess.Popen(
                    [sys.executable, "-m", "remote_exec.worker", "--coordinator", url,
                     "--remote-cache", server.url, "--cache-limit-gb", "50", "--drain-seconds", "0",
                     "--claim-wait-seconds", "0", "--holbuild-releases-dir", str(tmp_path / "releases"),
                     "--holbuild-source-url", f"file://{tmp_path}/holbuild-{{version}}.tar.gz"],
                    env={**os.environ, "REMOTE_EXEC_WORKER_TOKEN": WORKER_TOKEN,
                         "HOLBUILD_CACHE": str(tmp_path / "cache")},
                    stdout=log, stderr=log, start_new_session=True,
                )
                await asyncio.to_thread(wait_for_file, Path(f"{logs[1]}.output-ready"))
                if stop == "client-budget":
                    follower = subprocess.Popen(
                        ["curl", "-sN", "-H", f"Authorization: Bearer {CLIENT_TOKEN}",
                         f"{url}/v1/batches/{batch_id}/events"], stdout=client_log, stderr=client_log,
                    )
                    await asyncio.sleep(0.1)
                    follower.kill()
                    assert await asyncio.to_thread(follower.wait, timeout=5) == -signal.SIGKILL
                    # An independent client cancels the abandoned batch, then reads the worker's late report.
                    assert (await client.post(f"/v1/batches/{batch_id}/cancel", headers=CLIENT)).status_code == 200
                else:
                    process.send_signal(signal.SIGTERM)
                    assert await asyncio.to_thread(process.wait, timeout=10) == 0, (tmp_path / "worker.log").read_text()
                response = await client.get(f"/v1/batches/{batch_id}/interrupted-output?wait_s=10", headers=CLIENT)
                assert response.status_code == 200, response.text
                records = [json.loads(line) for line in response.text.splitlines()]
                assert len(records) == 1
                assert records[0]["theory"] == "pkg:loop"
                assert records[0]["output"].endswith("HOL interrupted marker\n")
                assert len(records[0]["output"].encode()) <= 65536
                state = (await client.get(f"/v1/batches/{batch_id}", headers=CLIENT)).json()
                assert state["state"] == ("cancelled" if stop == "client-budget" else "running")
                assert state["actions"][0]["attempts"] == (1 if stop == "client-budget" else 0)
    finally:
        if follower is not None and follower.poll() is None:
            follower.kill()
            await asyncio.to_thread(follower.wait)
        if process is not None and process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try:
                await asyncio.to_thread(process.wait, timeout=10)
            except subprocess.TimeoutExpired:
                await asyncio.to_thread(stop_group, process)
        api.should_exit = True
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(serving, timeout=10)
        listener.close()
