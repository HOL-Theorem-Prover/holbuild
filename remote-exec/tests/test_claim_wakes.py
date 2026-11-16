"""Normal and ahead-only work have separate wake generations."""

import asyncio

import httpx
import pytest
import sqlalchemy as sa

from conftest import FakeCache
from remote_exec import coordinator as coordinator_module
from remote_exec.coordinator import Coordinator, _claim_rank
from test_coordinator import ac_key, claim_named, complete, input_key, result, submit, wait_until


@pytest.mark.parametrize("ahead", [False, True])
async def test_ahead_changes_retry_only_capable_inflight_claims(
    coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch, ahead: bool
) -> None:
    entered, go, retried = asyncio.Event(), asyncio.Event(), asyncio.Event()
    attempts = 0

    async def empty(tiers: list[str], worker: str, *_: object) -> None:
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            entered.set()
            await go.wait()
        else:
            retried.set()

    async def no_ahead(tiers: list[str], worker: str, **_: object) -> None:
        return None

    monkeypatch.setattr(coordinator, "_claim", empty)
    monkeypatch.setattr(coordinator, "_claim_ahead", no_ahead)
    monkeypatch.setattr(coordinator_module, "CLAIM_RECHECK_SECONDS", 60)
    waiting = asyncio.create_task(coordinator.claim(["standard"], "w", 30, ahead=ahead))
    try:
        await asyncio.wait_for(entered.wait(), 2)
        coordinator._ahead_changed()
        go.set()
        if ahead:
            await asyncio.wait_for(retried.wait(), 2)
        await asyncio.wait_for(wait_until(lambda: len(coordinator.claim_waiters) == 1), 2)
        assert attempts == (2 if ahead else 1)
        assert coordinator.made_ready == 0
    finally:
        waiting.cancel()
        await asyncio.gather(waiting, return_exceptions=True)


@pytest.mark.parametrize("ahead", [False, True])
async def test_passing_a_wake_preserves_its_kind_and_normal_generation(
    coordinator: Coordinator, ahead: bool
) -> None:
    loop = asyncio.get_running_loop()
    first, second = loop.create_future(), loop.create_future()
    rank = _claim_rank(["standard"], None)
    coordinator.claim_waiters += [
        (["standard"], rank, first, True),
        (["standard"], rank, second, True),
    ]
    coordinator._wake_claim("standard", ahead=ahead)
    assert first.result() == ("standard", ahead)
    assert not second.done()
    coordinator._pass_wake(first)
    assert second.result() == ("standard", ahead)
    assert coordinator.made_ready == (0 if ahead else 1)


@pytest.mark.parametrize("ended", ["built", "failed", "expired"])
async def test_plain_peer_lease_end_does_not_invalidate_ahead_candidates(
    http: httpx.AsyncClient, coordinator: Coordinator, cache: FakeCache, ended: str
) -> None:
    await submit(http, ["a"])
    token = await claim_named(http, "a")
    await submit(http, ["a"])
    changes = coordinator.ahead_changes
    if ended == "expired":
        async with coordinator.engine.begin() as conn:
            await conn.execute(sa.text("UPDATE leases SET expires_at = now() - interval '1 second'"))
        await coordinator.expire_leases()
        await coordinator.released()
    else:
        if ended == "built":
            cache.keys.add(ac_key("a"))
        record = result("a", ended, "proof" if ended == "failed" else None)
        assert (await complete(http, token, record)).status_code == 200
    assert coordinator.ahead_changes == changes


async def test_finishing_an_opted_in_peer_wakes_its_newly_eligible_child_ahead(
    http: httpx.AsyncClient, coordinator: Coordinator, cache: FakeCache, monkeypatch: pytest.MonkeyPatch
) -> None:
    coordinator.settings.claim_ranking_seconds = 3600
    monkeypatch.setattr(coordinator_module, "CLAIM_RECHECK_SECONDS", 60)
    await submit(http, ["p"])
    parent = await claim_named(http, "p")
    await submit(http, ["p", "q", "c"], [("c", "p"), ("c", "q")], speculative_loading="1")
    await claim_named(http, "q")
    changes = coordinator.ahead_changes
    waiting = asyncio.create_task(coordinator.claim(["standard"], "capable", 30, ahead=True))
    try:
        await asyncio.wait_for(wait_until(lambda: bool(coordinator.claim_waiters)), 2)
        cache.keys.add(ac_key("p"))
        assert (await complete(http, parent, result("p", "built"))).status_code == 200
        claimed = await asyncio.wait_for(waiting, 2)
        assert claimed is not None and claimed.theory == "pkg:c"
        assert [parent.input_key for parent in claimed.ahead_parents] == [input_key("q")]
        assert coordinator.ahead_changes > changes
    finally:
        waiting.cancel()
        await asyncio.gather(waiting, return_exceptions=True)
