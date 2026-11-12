"""Bounded HTTP claimer herd against real Postgres and the coordinator's normal pool."""

import asyncio
import os
import socket
import sys
import time
from collections import defaultdict
from pathlib import Path

import httpx
import pytest
import uvicorn
from pydantic import SecretStr

from conftest import CLIENT_TOKEN, WORKER_TOKEN, FakeCache
from remote_exec import coordinator as coordinator_module
from remote_exec.app import create_app
from remote_exec.coordinator import Coordinator, Settings
from test_coordinator import CLIENT, WORKER, ac_key, input_key, result, submit


async def test_http_claim_herd_stays_live(coordinator: Coordinator) -> None:
    # A timeout on the server loop cannot interrupt a non-yielding completed-task retry.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("REMOTE_EXEC_", "HOLBUILD_REMOTE_CACHE_"))}
    env["PYTHONPATH"] = str(Path(coordinator_module.__file__).resolve().parents[1])
    process = await asyncio.create_subprocess_exec(
        sys.executable, str(Path(__file__).resolve()),
        coordinator.engine.url.render_as_string(hide_password=False), env=env,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    communicating = asyncio.create_task(process.communicate())
    try:
        output, _ = await asyncio.wait_for(asyncio.shield(communicating), 18)
    except TimeoutError:
        process.kill()
        output, _ = await communicating
        pytest.fail(f"coordinator load exceeded 18s (possible event-loop spin): {output.decode()}")
    finally:
        if process.returncode is None:
            process.kill()
        await communicating
    print(output.decode(), end="")
    assert process.returncode == 0, output.decode()
    assert b"300 HTTP waiters" in output and b"load passed" in output, output.decode()


async def load(url: str) -> None:
    """Submit shared-key DAGs into a sleeping HTTP herd, including ahead claims and interrupted leases."""
    settings = Settings(database_url=url, client_token=SecretStr(CLIENT_TOKEN),
                        worker_token=SecretStr(WORKER_TOKEN), cache_url="http://cache.test")
    coordinator = Coordinator.from_settings(settings)
    cache = FakeCache()
    await coordinator.cache.aclose()
    coordinator.cache = httpx.AsyncClient(transport=httpx.MockTransport(cache.handle_async))
    published: defaultdict[str, asyncio.Event] = defaultdict(asyncio.Event)
    submitted, ahead_seen = asyncio.Event(), asyncio.Event()
    retried: set[str] = set()
    completed = 0
    ahead_claims = 0
    probe_count = 0
    probe_max = 0.0
    started = time.monotonic()
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        server = uvicorn.Server(uvicorn.Config(create_app(coordinator, settings), log_level="critical",
                                             timeout_graceful_shutdown=0))
        serving = asyncio.create_task(server.serve(sockets=[sock]))
        try:
            while not server.started:
                assert not serving.done(), "HTTP server exited before startup"
                await asyncio.sleep(0.01)
            base_url = f"http://127.0.0.1:{sock.getsockname()[1]}"
            limits = httpx.Limits(max_connections=320, max_keepalive_connections=320)
            async with httpx.AsyncClient(base_url=base_url, limits=limits, timeout=4) as http:
                # Warm OpenAPI generation before measuring latency under load.
                assert (await http.get("/openapi.json")).status_code == 200

                async def worker(index: int) -> None:
                    nonlocal completed, ahead_claims
                    while True:
                        response = await http.post("/v1/work/claim", headers=WORKER, json={
                            "tier": "standard", "worker": f"load-{index}", "wait_s": 20, "ahead": bool(index % 2),
                        }, timeout=25)
                        if response.status_code == 204:
                            continue
                        assert response.status_code == 200, f"claim: {response.status_code} {response.text}"
                        claim = response.json()
                        name = claim["theory"].removeprefix("pkg:")
                        parents = claim["ahead_parents"]
                        if parents:
                            assert index % 2, "plain worker received an ahead lease"
                            ahead_claims += 1
                            ahead_seen.set()
                            for parent in parents:
                                await published[parent["input_key"]].wait()
                        await submitted.wait()
                        if name.startswith("root-"):
                            await ahead_seen.wait()
                        if name.startswith("retry-") and name not in retried:
                            retried.add(name)
                            record = result(name, "failed", "unavailable")
                        else:
                            cache.keys.add(ac_key(name))
                            record = result(name, "built")
                        response = await http.post(f"/v1/work/{claim['attempt_token']}/complete",
                                                   headers=WORKER, content=record)
                        assert response.status_code == 200, f"complete: {response.status_code} {response.text}"
                        if "status=built" in record:
                            completed += 1
                            published[input_key(name)].set()

                async def probes() -> None:
                    nonlocal probe_count, probe_max
                    async with httpx.AsyncClient(base_url=base_url, timeout=2) as probe:
                        while True:
                            for path in ("/openapi.json", "/v1/queue"):
                                at = time.monotonic()
                                response = await probe.get(path, headers=CLIENT)
                                elapsed = time.monotonic() - at
                                assert response.status_code == 200, f"{path}: {response.status_code} {response.text}"
                                assert elapsed < 2, f"{path} stalled for {elapsed:.2f}s"
                                probe_count += 1
                                probe_max = max(probe_max, elapsed)
                            await asyncio.sleep(0.05)

                async with asyncio.TaskGroup() as group:
                    workers = [group.create_task(worker(i)) for i in range(300)]
                    probing = group.create_task(probes())
                    async with asyncio.timeout(12):
                        while len(coordinator.claim_waiters) != 300:
                            await asyncio.sleep(0.01)
                        probes_before = probe_count
                        print("300 HTTP waiters", flush=True)
                        # The state a stale read leaves before its queued cleanup callback can run.
                        key = ("standard",)
                        stale = asyncio.create_task(coordinator._current_ranking(key))
                        await stale
                        coordinator.rankings.clear()
                        coordinator.ranking_reads[key] = stale
                        coordinator.rankings_forgotten += 1
                        print("completed stale ranking installed; waking HTTP claims", flush=True)
                        batches = []
                        for i in range(16):
                            root, child, retry = f"root-{i % 4}", f"child-{i}", f"retry-{i}"
                            batches.append(await submit(http, [root, child, retry], [(child, root)],
                                                        **({"speculative_loading": "2"} if i % 2 else {})))
                        submitted.set()
                        for batch_id in batches:
                            while True:
                                response = await http.get(f"/v1/batches/{batch_id}", headers=CLIENT)
                                assert response.status_code == 200, response.text
                                state = response.json()["state"]
                                if state != "running":
                                    assert state == "done", response.text
                                    break
                                await asyncio.sleep(0.01)
                        assert ahead_claims > 0 and completed >= 36 and len(retried) == 16
                        assert probe_count - probes_before >= 4, "latency probes did not overlap load"
                    for task in [*workers, probing]:
                        task.cancel()
                print(f"load passed: completed={completed}, ahead={ahead_claims}, retries={len(retried)}, "
                      f"probes={probe_count}, max_probe_s={probe_max:.3f}, elapsed_s={time.monotonic()-started:.3f}",
                      flush=True)
        finally:
            server.should_exit = True
            await serving


if __name__ == "__main__":
    uvicorn.Config("remote_exec.app:app").setup_event_loop()
    asyncio.run(load(sys.argv[1]))
