"""Bound real coordinator HTTP liveness independently of its event loop."""

import asyncio
import contextlib
import os
import socket
import sys
from pathlib import Path
from typing import Any

import httpx
import sqlalchemy as sa
import uvicorn
from pydantic import SecretStr
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from remote_exec import coordinator as coordinator_module
from remote_exec.app import create_app
from remote_exec.coordinator import Coordinator, Settings
from conftest import CLIENT_TOKEN, WORKER_TOKEN, FakeCache
from test_coordinator import CLIENT, WORKER, ac_key, complete, result, submit


async def test_400_claimers_keep_http_live(remote_exec_engine: AsyncEngine) -> None:
    # The load generator must not compete for the coordinator's event loop, and an asyncio timeout
    # inside that loop cannot interrupt a non-yielding ranking regression.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("REMOTE_EXEC_", "HOLBUILD_REMOTE_CACHE_"))}
    env["PYTHONPATH"] = str(Path(coordinator_module.__file__).resolve().parents[1])
    process = await asyncio.create_subprocess_exec(
        sys.executable, str(Path(__file__).resolve()),
        remote_exec_engine.url.render_as_string(hide_password=False), env=env,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    communicating: asyncio.Task[tuple[bytes, bytes | None]] | None = None
    try:
        async with asyncio.timeout(50):
            assert process.stdout is not None
            address = (await asyncio.wait_for(process.stdout.readline(), 8)).decode().strip()
            communicating = asyncio.create_task(process.communicate())
            assert address.startswith("http://127.0.0.1:"), address
            limits = httpx.Limits(max_connections=450, max_keepalive_connections=450)
            async with httpx.AsyncClient(base_url=address, limits=limits, timeout=30, trust_env=False) as http:
                await herd(http)
    finally:
        if process.returncode is None:
            process.kill()
        await process.wait()
        output, _ = await communicating if communicating else await process.communicate()
        print(output.decode())
    assert b"400 HTTP claimers arrived; invalidated completed ranking installed" in output


async def serve(url: str) -> None:
    """Serve the candidate app with a fake cache and a deterministic completed-ranking race."""
    settings = Settings(database_url=url, client_token=SecretStr(CLIENT_TOKEN),
                        worker_token=SecretStr(WORKER_TOKEN), cache_url="http://cache.test")
    engine = create_async_engine(url, pool_size=settings.database_pool_size, max_overflow=0)
    async with engine.begin() as conn:
        await conn.execute(sa.text("TRUNCATE batches, actions, edges, leases, peak_hints, burst_demand"))
    cache = FakeCache()
    async with httpx.AsyncClient(transport=httpx.MockTransport(cache.handle_async)) as cache_http:
        coordinator = Coordinator(engine, cache_http, settings)
        app = create_app(coordinator, settings)

        @app.put("/_test/cache/{key}")
        async def publish(key: str) -> None:
            cache.keys.add(key)

        initial = 0
        go = asyncio.Event()
        claim = coordinator.claim

        async def gated_claim(tiers: list[str], worker: str, *args: Any, **kwargs: Any) -> Any:
            nonlocal initial
            if worker.startswith("load-") and initial < 400:
                initial += 1
                if initial == 400:
                    key = ("standard",)
                    coordinator.rankings.clear()
                    stale = asyncio.create_task(coordinator._current_ranking(key))
                    await stale
                    await asyncio.sleep(0)  # let every original cleanup callback run
                    # Model the completed read observed before its scheduled slot cleanup. Keeping it stale
                    # makes the race deterministic even on a fast runner, without changing ranking code.
                    coordinator.rankings.clear()
                    coordinator.ranking_reads[key] = stale
                    coordinator.rankings_forgotten += 1
                    print("400 HTTP claimers arrived; invalidated completed ranking installed", flush=True)
                    go.set()
                await go.wait()
            return await claim(tiers, worker, *args, **kwargs)

        coordinator.claim = gated_claim
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            sock.listen(2048)
            print(f"http://127.0.0.1:{sock.getsockname()[1]}", flush=True)
            server = uvicorn.Server(uvicorn.Config(app, log_level="error"))
            await server.serve(sockets=[sock])


async def herd(http: httpx.AsyncClient) -> None:
    """Drain layered shared-key batches while probing HTTP and a held lease."""
    await submit(http, ["held"])
    response = await http.post("/v1/work/claim", headers=WORKER,
                               json={"tier": "standard", "worker": "held-probe"})
    assert response.status_code == 200, response.text
    held = response.json()["attempt_token"]
    batches: list[str] = []
    for batch in range(40):
        layers = [[f"shared-{layer}-{lane}" if lane < 2 else f"b{batch}-{layer}-{lane}"
                   for lane in range(4)] for layer in range(4)]
        names = [name for layer in layers for name in layer]
        edges = [(layers[layer][lane], layers[layer - 1][lane]) for layer in range(1, 4) for lane in range(4)]
        batches.append(await submit(http, names, edges))

    completions = 0
    probes = 0
    first_complete = asyncio.Event()

    async def worker(number: int) -> None:
        nonlocal completions
        while True:
            response = await http.post("/v1/work/claim", headers=WORKER,
                                       json={"tier": "standard", "worker": f"load-{number}", "wait_s": 20})
            if response.status_code == 204:
                continue
            assert response.status_code == 200, response.text
            claimed = response.json()
            name = claimed["theory"].removeprefix("pkg:")
            await asyncio.sleep(0.02 + number % 5 * 0.01)
            response = await http.put(f"/_test/cache/{ac_key(name)}")
            assert response.status_code == 200, response.text
            response = await complete(http, claimed["attempt_token"], result(name, "built", peak_rss_mb="100"))
            assert response.status_code == 200, response.text
            completions += 1
            first_complete.set()

    async def probe() -> None:
        nonlocal probes
        # Separate connections ensure long polls cannot hide HTTP liveness behind a client pool wait.
        async with httpx.AsyncClient(base_url=str(http.base_url), timeout=3, trust_env=False) as monitor:
            while True:
                for path in ("/openapi.json", "/v1/queue"):
                    response = await monitor.get(path, headers=CLIENT)
                    assert response.status_code == 200, response.text
                response = await monitor.post(f"/v1/work/{held}/heartbeat", headers=WORKER)
                assert response.status_code == 200, response.text
                if completions:
                    probes += 1
                await asyncio.sleep(0.1)

    async with asyncio.TaskGroup() as group:
        workers = [group.create_task(worker(number)) for number in range(400)]
        monitor = group.create_task(probe())
        await first_complete.wait()
        while True:
            responses = await asyncio.gather(*(http.get(f"/v1/batches/{batch}", headers=CLIENT) for batch in batches))
            assert all(response.status_code == 200 for response in responses)
            if all(response.json()["state"] == "done" for response in responses) and probes >= 2:
                break
            await asyncio.sleep(0.1)
        assert completions >= 40, completions
        monitor.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await monitor
        # Complete the held lease while the 400 claim loops are still running.
        response = await http.put(f"/_test/cache/{ac_key('held')}")
        assert response.status_code == 200, response.text
        response = await complete(http, held, result("held", "built", peak_rss_mb="100"))
        assert response.status_code == 200, response.text
        for worker_task in workers:
            worker_task.cancel()
    print(f"400-claimer HTTP liveness passed: 40 batches, {completions} completions, {probes} probes", flush=True)


if __name__ == "__main__":
    asyncio.run(serve(sys.argv[1]))
