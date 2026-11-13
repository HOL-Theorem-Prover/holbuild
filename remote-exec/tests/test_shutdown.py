"""The coordinator image's entrypoint stops promptly on SIGTERM while clients hold requests open."""

import asyncio
import os
import signal
import socket
import sys
from pathlib import Path

import httpx

from conftest import CLIENT_TOKEN, REMOTE_EXEC_DIR, WORKER_TOKEN
from remote_exec.coordinator import Coordinator
from test_coordinator import CLIENT, WORKER, submit


async def test_sigterm_exits_promptly_with_open_events_stream_and_claim(coordinator: Coordinator) -> None:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    env = {k: v for k, v in os.environ.items() if not k.startswith(("REMOTE_EXEC_", "HOLBUILD_REMOTE_CACHE_"))}
    env |= {
        "PATH": f"{Path(sys.executable).parent}{os.pathsep}{env.get('PATH', '')}",
        "REMOTE_EXEC_DATABASE_URL": coordinator.engine.url.render_as_string(hide_password=False),
        "REMOTE_EXEC_CLIENT_TOKEN": CLIENT_TOKEN,
        "REMOTE_EXEC_WORKER_TOKEN": WORKER_TOKEN,
        "REMOTE_EXEC_CACHE_URL": "http://127.0.0.1:1",
    }
    process = await asyncio.create_subprocess_exec(
        "sh", str(REMOTE_EXEC_DIR / "entrypoint.sh"), "coordinator", "--host", "127.0.0.1", "--port", str(port),
        cwd=REMOTE_EXEC_DIR, env=env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    try:
        async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}", timeout=60, trust_env=False) as http:
            async with asyncio.timeout(20):
                while True:
                    try:
                        if (await http.get("/v1/queue", headers=CLIENT)).status_code == 200:
                            break
                    except httpx.TransportError:
                        pass
                    await asyncio.sleep(0.1)
            batch_id = await submit(http, ["a"])
            taken = await http.post("/v1/work/claim", headers=WORKER, json={"tier": "standard", "worker": "w1"})
            assert taken.status_code == 200, taken.text
            # The batch stays running, so its events stream stays open; with nothing left to claim, so does this claim.
            claim = asyncio.create_task(http.post("/v1/work/claim", headers=WORKER,
                                                  json={"tier": "standard", "worker": "w2", "wait_s": 50}))
            try:
                async with http.stream("GET", f"/v1/batches/{batch_id}/events", headers=CLIENT) as events:
                    assert events.status_code == 200
                    # Hold the iterator: dropping it would close the stream before the signal.
                    lines = events.aiter_lines()
                    assert '"type": "action"' in await anext(lines)
                    assert not claim.done()
                    process.send_signal(signal.SIGTERM)
                    async with asyncio.timeout(3):  # the 2 s graceful limit, then lifespan shutdown
                        await process.wait()
            finally:
                claim.cancel()
                await asyncio.gather(claim, return_exceptions=True)
    finally:
        if process.returncode is None:
            process.kill()
        output, _ = await process.communicate()
        print(output.decode(), end="")
    # uvicorn re-raises the SIGTERM it handled once shutdown is done, whether or not lifespan shutdown succeeded.
    assert process.returncode == -signal.SIGTERM, process.returncode
    assert b"Application shutdown complete" in output, output.decode()
