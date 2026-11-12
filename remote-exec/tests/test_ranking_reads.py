"""Shared ranking task lifecycle, including a race that can stop the event loop."""

import asyncio
import gc
import os
import sys
from pathlib import Path
from typing import Any
from uuid import uuid4

import httpx
import pytest
import sqlalchemy as sa
from pydantic import SecretStr
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from remote_exec import coordinator as coordinator_module
from remote_exec.coordinator import Coordinator, Settings, _Ranking


@pytest.mark.parametrize("freshness", ["invalidation", "after"])
async def test_completed_shared_read_with_callbacks_pending_does_not_spin(
    remote_exec_engine: AsyncEngine, freshness: str
) -> None:
    # An event-loop timeout cannot interrupt this regression's non-yielding loop.
    process = await asyncio.create_subprocess_exec(
        sys.executable, str(Path(__file__).resolve()),
        remote_exec_engine.url.render_as_string(hide_password=False), freshness,
        env=os.environ | {"PYTHONPATH": str(Path(coordinator_module.__file__).resolve().parents[1])},
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    communicating = asyncio.create_task(process.communicate())
    try:
        output, _ = await asyncio.wait_for(asyncio.shield(communicating), 10)
    except TimeoutError:
        process.kill()
        output, _ = await communicating
        pytest.fail(f"completed shared read starved the event loop: {output.decode()}")
    assert process.returncode == 0, output.decode()
    assert b"completed read observed before callbacks" in output


async def completed_read_race(url: str, freshness: str) -> None:
    """Queue a late caller before the stale shared read's completion callbacks."""
    engine = create_async_engine(url)
    settings = Settings(database_url=url, client_token=SecretStr("c"), worker_token=SecretStr("w"),
                        cache_url="http://cache.test")
    async with httpx.AsyncClient() as cache:
        coordinator = Coordinator(engine, cache, settings)
        key = ("standard",)
        entered, go = asyncio.Event(), asyncio.Event()
        rank = coordinator._rank
        calls = 0

        async def held(conn: Any, tiers: tuple[str, ...]) -> _Ranking:
            nonlocal calls
            calls += 1
            ranking = await rank(conn, tiers)
            if calls == 1:
                entered.set()
                await go.wait()
            return ranking

        coordinator._rank = held
        early = asyncio.create_task(coordinator._current_ranking(key))
        await entered.wait()
        read = coordinator.ranking_reads[key]
        callbacks_ran = False

        def done(_: object) -> None:
            nonlocal callbacks_ran
            callbacks_ran = True

        read.add_done_callback(done)
        if freshness == "invalidation":
            coordinator._forget_rankings(uuid4(), {"standard"})
        after = asyncio.get_running_loop().time() if freshness == "after" else 0
        forgotten = coordinator.rankings_forgotten

        async def late() -> _Ranking:
            # Always ready to run, so we observe completion before its newly queued callbacks.
            while not read.done():
                await asyncio.sleep(0)
            assert not callbacks_ran
            print("completed read observed before callbacks", flush=True)
            return await coordinator._current_ranking(key, after=after)

        later = asyncio.create_task(late())
        await asyncio.sleep(0)  # queue late before allowing the shared read to finish
        go.set()
        first, fresh = await asyncio.gather(early, later)
        assert first is not fresh
        assert fresh.forgotten >= forgotten and fresh.at >= after
        assert calls == 2
        assert key not in coordinator.ranking_reads
        assert coordinator.rankings[key] is fresh
    await engine.dispose()


@pytest.mark.parametrize("cancel_all", [False, True])
@pytest.mark.parametrize("failure", [False, True])
async def test_cancelled_ranking_waiters_leave_read_shared_and_slot_cleared(
    coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch, cancel_all: bool, failure: bool
) -> None:
    entered, go = asyncio.Event(), asyncio.Event()
    rank = coordinator._rank
    calls = 0

    async def held(conn: Any, key: tuple[str, ...]) -> _Ranking:
        nonlocal calls
        calls += 1
        entered.set()
        await go.wait()
        if failure:
            raise sa.exc.TimeoutError("shared read failed")
        return await rank(conn, key)

    monkeypatch.setattr(coordinator, "_rank", held)
    key = ("standard",)
    first = asyncio.create_task(coordinator._current_ranking(key))
    second = asyncio.create_task(coordinator._current_ranking(key))
    await asyncio.wait_for(entered.wait(), 2)
    read = coordinator.ranking_reads[key]
    first.cancel()
    if cancel_all:
        second.cancel()
    await asyncio.gather(first, *([second] if cancel_all else []), return_exceptions=True)
    assert not read.done()
    assert coordinator.ranking_reads[key] is read
    go.set()
    results = await asyncio.gather(read, second, return_exceptions=True)
    assert calls == 1
    assert key not in coordinator.ranking_reads
    if failure:
        assert isinstance(results[0], sa.exc.TimeoutError)
        if not cancel_all:
            assert results[1] is results[0]
        assert key not in coordinator.rankings
        monkeypatch.setattr(coordinator, "_rank", rank)
        await coordinator._current_ranking(key)
    else:
        assert coordinator.rankings[key] is results[0]
        if not cancel_all:
            assert results[1] is results[0]


async def test_failure_after_every_waiter_cancels_is_observed(
    coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    entered, go = asyncio.Event(), asyncio.Event()
    errors: list[dict[str, Any]] = []
    monkeypatch.setattr(asyncio.get_running_loop(), "call_exception_handler", errors.append)

    async def failed(conn: Any, key: tuple[str, ...]) -> _Ranking:
        entered.set()
        await go.wait()
        raise sa.exc.TimeoutError("abandoned read failed")

    monkeypatch.setattr(coordinator, "_rank", failed)
    key = ("standard",)
    waiter = asyncio.create_task(coordinator._current_ranking(key))
    await asyncio.wait_for(entered.wait(), 2)
    waiter.cancel()
    await asyncio.gather(waiter, return_exceptions=True)
    del waiter
    go.set()
    async with asyncio.timeout(2):
        while key in coordinator.ranking_reads:
            await asyncio.sleep(0)
    await asyncio.sleep(0)  # let the exception observer run
    gc.collect()
    # Python 3.14's shield logs abandoned failures even after their exception was retrieved.
    assert all(error["message"] == "TimeoutError exception in shielded future"
               and isinstance(error["exception"], sa.exc.TimeoutError) for error in errors)
    assert key not in coordinator.rankings


@pytest.mark.parametrize("ttl", [0, 3600])
async def test_completed_read_left_in_slot_is_replaced(
    coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch, ttl: float
) -> None:
    coordinator.settings.claim_ranking_seconds = ttl
    key = ("standard",)
    stale = asyncio.create_task(coordinator._current_ranking(key))
    await stale
    coordinator.rankings.clear()
    coordinator.ranking_reads[key] = stale
    coordinator.rankings_forgotten += 1
    # Bound an attempted reawait independently of yielding: a broken implementation must fail before it spins.
    shield = asyncio.shield

    def refuse_stale(awaitable: Any) -> Any:
        assert awaitable is not stale, "completed task was reused from the shared slot"
        return shield(awaitable)

    monkeypatch.setattr(asyncio, "shield", refuse_stale)
    fresh = await coordinator._current_ranking(key)
    assert fresh.forgotten == coordinator.rankings_forgotten
    assert key not in coordinator.ranking_reads


if __name__ == "__main__":
    asyncio.run(completed_read_race(sys.argv[1], sys.argv[2]))
