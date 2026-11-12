"""Bounded HTTP claimer herd against real Postgres and the coordinator's normal pool."""

import asyncio
import os
import socket
import sys
import time
from collections import defaultdict
from contextlib import AsyncExitStack
from pathlib import Path

import httpx
import sqlalchemy as sa
import uvicorn
from pydantic import SecretStr

from conftest import CLIENT_TOKEN, WORKER_TOKEN, FakeCache
from remote_exec import coordinator as coordinator_module
from remote_exec.app import create_app
from remote_exec.coordinator import Coordinator, Settings
from test_coordinator import CLIENT, WORKER, ac_key, input_key, result, submit


async def test_400_claimers_keep_http_live(coordinator: Coordinator) -> None:
    # A timeout on the server loop cannot interrupt a non-yielding completed-task retry.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("REMOTE_EXEC_", "HOLBUILD_REMOTE_CACHE_"))}
    env["PYTHONPATH"] = str(Path(coordinator_module.__file__).resolve().parents[1])
    process = await asyncio.create_subprocess_exec(
        sys.executable, str(Path(__file__).resolve()),
        coordinator.engine.url.render_as_string(hide_password=False), env=env,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    communicating = None
    try:
        # This watchdog runs outside the server process, including when its loop stops yielding.
        async with asyncio.timeout(18):
            assert process.stdout is not None
            address = (await process.stdout.readline()).decode().strip()
            communicating = asyncio.create_task(process.communicate())
            assert address.startswith("http://127.0.0.1:"), address
            limits = httpx.Limits(max_connections=450, max_keepalive_connections=450)
            async with httpx.AsyncClient(base_url=address, limits=limits, timeout=4, trust_env=False) as http:
                await herd(http)
    finally:
        if process.returncode is None:
            process.kill()
        output, _ = await communicating if communicating else await process.communicate()
        print(output.decode(), end="")
    assert b"400 HTTP waiters" in output and b"completed stale ranking installed" in output, output.decode()


async def serve(url: str) -> None:
    """Serve the normal coordinator pool independently of the HTTP load generator."""
    settings = Settings(database_url=url, client_token=SecretStr(CLIENT_TOKEN),
                        worker_token=SecretStr(WORKER_TOKEN), cache_url="http://cache.test")
    coordinator = Coordinator.from_settings(settings)
    cache = FakeCache()
    await coordinator.cache.aclose()
    coordinator.cache = httpx.AsyncClient(transport=httpx.MockTransport(cache.handle_async))
    # Establish the normal pool before the timed herd; keep its size, overflow and timeout unchanged.
    async with AsyncExitStack() as connections:
        for _ in range(settings.database_pool_size):
            conn = await connections.enter_async_context(coordinator.engine.connect())
            await conn.execute(sa.text("SELECT 1"))
    app = create_app(coordinator, settings)

    @app.put("/_test/cache/{key}")
    async def publish(key: str) -> None:
        cache.keys.add(key)

    @app.post("/_test/arm")
    async def arm() -> None:
        while len(coordinator.claim_waiters) != 400:
            await asyncio.sleep(0.01)
        print("400 HTTP waiters", flush=True)
        key = ("standard",)
        stale = asyncio.create_task(coordinator._current_ranking(key))
        await stale
        coordinator.rankings.clear()
        coordinator.ranking_reads[key] = stale
        coordinator.rankings_forgotten += 1
        print("completed stale ranking installed; waking HTTP claims", flush=True)

    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        sock.listen(2048)
        print(f"http://127.0.0.1:{sock.getsockname()[1]}", flush=True)
        # Keep idle sockets beyond this test's watchdog, so reuse cannot race a server keep-alive close.
        server = uvicorn.Server(uvicorn.Config(app, log_level="critical", timeout_graceful_shutdown=0,
                                             timeout_keep_alive=30))
        await server.serve(sockets=[sock])


async def herd(http: httpx.AsyncClient) -> None:
    """Drain layered, shared-key batches while monitoring HTTP and a held lease."""
    published: defaultdict[str, asyncio.Event] = defaultdict(asyncio.Event)
    submitted, ahead_seen = asyncio.Event(), asyncio.Event()
    retried: set[str] = set()
    completed = 0
    ahead_claims = 0
    probe_count = 0
    probe_max = 0.0
    heartbeat_after_complete = 0
    started = time.monotonic()
    # Warm OpenAPI generation before measuring latency under load.
    assert (await http.get("/openapi.json")).status_code == 200

    await submit(http, ["held"])
    response = await http.post("/v1/work/claim", headers=WORKER,
                               json={"tier": "standard", "worker": "held-probe"})
    assert response.status_code == 200 and response.json()["theory"] == "pkg:held", response.text
    held = response.json()["attempt_token"]

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
                response = await http.put(f"/_test/cache/{ac_key(name)}")
                assert response.status_code == 200, response.text
                record = result(name, "built")
            response = await http.post(f"/v1/work/{claim['attempt_token']}/complete",
                                       headers=WORKER, content=record)
            assert response.status_code == 200, f"complete: {response.status_code} {response.text}"
            if "status=built" in record:
                completed += 1
                published[input_key(name)].set()

    async def probes() -> None:
        nonlocal probe_count, probe_max, heartbeat_after_complete
        async with httpx.AsyncClient(base_url=str(http.base_url), timeout=2, trust_env=False) as probe:
            while True:
                for path in ("/openapi.json", "/v1/queue"):
                    at = time.monotonic()
                    response = await probe.get(path, headers=CLIENT)
                    elapsed = time.monotonic() - at
                    assert response.status_code == 200, f"{path}: {response.status_code} {response.text}"
                    assert elapsed < 2, f"{path} stalled for {elapsed:.2f}s"
                    probe_count += 1
                    probe_max = max(probe_max, elapsed)
                at = time.monotonic()
                response = await probe.post(f"/v1/work/{held}/heartbeat", headers=WORKER)
                elapsed = time.monotonic() - at
                assert response.status_code == 200, response.text
                assert elapsed < 2, f"heartbeat stalled for {elapsed:.2f}s"
                probe_max = max(probe_max, elapsed)
                if completed:
                    heartbeat_after_complete += 1
                await asyncio.sleep(0.05)

    async with asyncio.TaskGroup() as group:
        workers = [group.create_task(worker(i)) for i in range(400)]
        probing = group.create_task(probes())
        async with asyncio.timeout(12):
            response = await http.post("/_test/arm", timeout=12)
            assert response.status_code == 200, response.text
            probes_before = probe_count
            batches = []
            for i in range(40):
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
            while heartbeat_after_complete < 2:
                await asyncio.sleep(0.01)
            assert ahead_claims > 0 and completed >= 84 and len(retried) == 40
            assert probe_count - probes_before >= 4, "latency probes did not overlap load"
            # Stop heartbeats before completing their lease; the worker herd stays alive.
            probing.cancel()
            await asyncio.gather(probing, return_exceptions=True)
            response = await http.put(f"/_test/cache/{ac_key('held')}")
            assert response.status_code == 200, response.text
            at = time.monotonic()
            response = await http.post(f"/v1/work/{held}/complete", headers=WORKER,
                                       content=result("held", "built"), timeout=2)
            assert response.status_code == 200, response.text
            assert time.monotonic() - at < 2, "held-lease completion stalled"
        for task in workers:
            task.cancel()
    print(f"load passed: completed={completed}, ahead={ahead_claims}, retries={len(retried)}, "
          f"probes={probe_count}, heartbeats_after_complete={heartbeat_after_complete}, "
          f"max_probe_s={probe_max:.3f}, elapsed_s={time.monotonic()-started:.3f}",
          flush=True)


if __name__ == "__main__":
    uvicorn.Config("remote_exec.app:app").setup_event_loop()
    asyncio.run(serve(sys.argv[1]))
