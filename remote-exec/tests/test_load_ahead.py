"""Claims ahead of running parents, for batches submitted with ``speculative_loading``."""

import asyncio
import time
from typing import Any

import httpx
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncEngine

from conftest import FakeCache
from remote_exec import coordinator as coordinator_module
from remote_exec.coordinator import CLAIM_RECHECK_SECONDS, Coordinator
from test_coordinator import (
    CLIENT,
    WORKER,
    ac_key,
    batch,
    build,
    claim,
    claim_named,
    complete,
    input_key,
    result,
    spec,
    states,
    submit,
)


async def claim_ahead(
    http: httpx.AsyncClient, tier: str = "standard", wait_s: float = 0, also_claim: list[str] | None = None
) -> dict[str, Any] | None:
    body = {"tier": tier, "also_claim": also_claim or [], "worker": "w2", "ahead": True, "wait_s": wait_s}
    response = await http.post("/v1/work/claim", json=body, headers=WORKER)
    if response.status_code == 204:
        return None
    assert response.status_code == 200, response.text
    return response.json()


def parents(*names: str) -> list[dict[str, str]]:
    return sorted(({"input_key": input_key(n), "spec_sha256": spec(n)} for n in names), key=lambda p: p["input_key"])


async def ahead_state(engine: AsyncEngine, name: str) -> tuple[str, str, int, int]:
    async with engine.connect() as conn:
        row = (
            await conn.execute(
                sa.text("SELECT state, ahead, attempts, remaining_deps FROM actions WHERE input_key = :key"),
                {"key": input_key(name)},
            )
        ).one()
    return row.state, row.ahead, row.attempts, row.remaining_deps


async def test_speculative_loading_is_checked_at_submit(http: httpx.AsyncClient) -> None:
    for value in ["0", "65", "x"]:
        response = await http.post(
            "/v1/batches", content="holbuild-action-batch-v1\n", headers=CLIENT, params={"speculative_loading": value}
        )
        assert response.status_code == 422, value


async def test_a_batch_without_speculative_loading_is_never_claimed_ahead(http: httpx.AsyncClient) -> None:
    await submit(http, ["a", "b"], [("b", "a")])
    claimed = await claim(http)
    assert claimed is not None and claimed["ahead_parents"] == []

    assert await claim_ahead(http) is None


async def test_a_child_is_claimed_ahead_of_its_running_parent_once_nothing_is_ready(
    http: httpx.AsyncClient, remote_exec_engine: AsyncEngine
) -> None:
    ahead = await submit(http, ["a", "b"], [("b", "a")], speculative_loading="4")
    await claim_named(http, "a")
    await submit(http, ["x"])

    # Ready work of any batch comes first; a worker that can't load ahead never gets a claim ahead.
    claimed = await claim_ahead(http)
    assert claimed is not None and (claimed["theory"], claimed["ahead_parents"]) == ("pkg:x", [])
    assert await claim(http) is None

    claimed = await claim_ahead(http)
    assert claimed is not None and claimed["theory"] == "pkg:b"
    assert claimed["ahead_parents"] == parents("a")
    assert await ahead_state(remote_exec_engine, "b") == ("running", "ahead", 1, 1)
    assert await states(http, ahead) == {"a": "running", "b": "running"}


async def test_claims_ahead_take_the_deepest_child_first_and_stop_at_the_cap(
    http: httpx.AsyncClient, cache: FakeCache
) -> None:
    await submit(
        http, ["a", "b", "c", "d", "e"], [("b", "a"), ("c", "a"), ("d", "a"), ("e", "c")], speculative_loading="2"
    )
    await claim_named(http, "a")

    claims = await asyncio.gather(*(claim_ahead(http) for _ in range(3)))
    claimed = sorted(c["theory"] for c in claims if c is not None)
    assert len(claimed) == 2 and "pkg:c" in claimed  # "c" has a child, so it goes first
    assert await claim_ahead(http) is None


async def test_claims_ahead_go_one_generation_deep_and_follow_a_parent_finishing(
    http: httpx.AsyncClient, cache: FakeCache, remote_exec_engine: AsyncEngine
) -> None:
    batch_id = await submit(http, ["a", "b", "c"], [("b", "a"), ("c", "b")], speculative_loading="4")
    a = await claim_named(http, "a")
    b = await claim_ahead(http)
    assert b is not None and b["theory"] == "pkg:b"
    # "c"'s parent waits for a parent of its own.
    assert await claim_ahead(http) is None

    cache.keys.add(ac_key("a"))
    assert (await complete(http, a, result("a", "built"))).status_code == 200
    # The child claimed ahead keeps running; it now waits for no parent, so its own child may go ahead.
    assert await ahead_state(remote_exec_engine, "b") == ("running", "ahead", 1, 0)
    c = await claim_ahead(http)
    assert c is not None and (c["theory"], c["ahead_parents"]) == ("pkg:c", parents("b"))

    cache.keys.add(ac_key("b"))
    assert (await complete(http, b["attempt_token"], result("b", "built"))).status_code == 200
    cache.keys.add(ac_key("c"))
    assert (await complete(http, c["attempt_token"], result("c", "built"))).status_code == 200
    assert (await batch(http, batch_id))["state"] == "done"


async def test_an_abandoned_claim_ahead_costs_no_attempt_and_is_built_plainly_after_its_parents(
    http: httpx.AsyncClient, cache: FakeCache, remote_exec_engine: AsyncEngine
) -> None:
    batch_id = await submit(http, ["a", "b"], [("b", "a")], speculative_loading="4")
    a = await claim_named(http, "a")
    b = await claim_ahead(http)
    assert b is not None
    assert (await complete(http, b["attempt_token"], result("b", "failed", "ahead-abandoned"))).status_code == 200
    assert await ahead_state(remote_exec_engine, "b") == ("waiting", "abandoned", 0, 1)
    assert await claim_ahead(http) is None

    cache.keys.add(ac_key("a"))
    assert (await complete(http, a, result("a", "built"))).status_code == 200
    plain = await claim_ahead(http)
    assert plain is not None and (plain["theory"], plain["ahead_parents"]) == ("pkg:b", [])
    assert await ahead_state(remote_exec_engine, "b") == ("running", "abandoned", 1, 0)
    cache.keys.add(ac_key("b"))
    assert (await complete(http, plain["attempt_token"], result("b", "built"))).status_code == 200
    assert (await batch(http, batch_id))["state"] == "done"


async def test_ahead_abandoned_from_a_plain_claim_counts_as_an_internal_failure(
    http: httpx.AsyncClient, remote_exec_engine: AsyncEngine
) -> None:
    await submit(http, ["a"], speculative_loading="4")
    a = await claim_named(http, "a")
    assert (await complete(http, a, result("a", "failed", "ahead-abandoned"))).status_code == 200
    assert await ahead_state(remote_exec_engine, "a") == ("ready", "no", 1, 0)


async def test_a_failed_parent_cancels_the_child_claimed_ahead_of_it(http: httpx.AsyncClient) -> None:
    batch_id = await submit(http, ["a", "b"], [("b", "a")], speculative_loading="4")
    a = await claim_named(http, "a")
    b = await claim_ahead(http)
    assert b is not None

    assert (await complete(http, a, result("a", "failed", "proof"))).status_code == 200
    assert await states(http, batch_id) == {"a": "failed", "b": "cancelled"}
    assert (await http.post(f"/v1/work/{b['attempt_token']}/heartbeat", headers=WORKER)).status_code == 409


async def test_a_requeued_parent_revokes_the_child_claimed_ahead_as_abandoned(
    http: httpx.AsyncClient, cache: FakeCache, remote_exec_engine: AsyncEngine
) -> None:
    await submit(http, ["p1", "p2", "c", "d"], [("c", "p1"), ("c", "p2"), ("d", "p1")], speculative_loading="4")
    await build(http, cache, "p1")
    await claim_named(http, "p2")
    d = await claim_named(http, "d")
    c = await claim_ahead(http)
    assert c is not None and (c["theory"], c["ahead_parents"]) == ("pkg:c", parents("p2"))

    cache.keys.discard(ac_key("p1"))
    missing = result("d", "failed", "input-missing", missing=f"theory {input_key('p1')}")
    assert (await complete(http, d, missing)).status_code == 200
    assert await ahead_state(remote_exec_engine, "c") == ("waiting", "abandoned", 0, 2)
    assert (await http.post(f"/v1/work/{c['attempt_token']}/heartbeat", headers=WORKER)).status_code == 409


async def test_actions_waiting_ahead_ask_for_no_burst_worker_until_their_parents_are_done(
    http: httpx.AsyncClient, coordinator: Coordinator, cache: FakeCache
) -> None:
    await submit(http, ["a", "b"], [("b", "a")], speculative_loading="4")
    a = await claim_named(http, "a")
    assert await claim_ahead(http) is not None

    queue = (await http.get("/v1/queue", headers=CLIENT)).json()
    assert (queue["running_standard"], queue["waiting_ahead"]) == (1, 1)
    async with coordinator.engine.connect() as conn:
        assert (await coordinator._counts(conn, coordinator_module.COUNT_ACTIVE)).running_standard == 1

    cache.keys.add(ac_key("a"))
    assert (await complete(http, a, result("a", "built"))).status_code == 200
    queue = (await http.get("/v1/queue", headers=CLIENT)).json()
    assert (queue["running_standard"], queue["waiting_ahead"]) == (1, 0)


async def test_a_parent_claimed_wakes_a_waiting_claim_ahead(
    http: httpx.AsyncClient, remote_exec_engine: AsyncEngine
) -> None:
    await submit(http, ["a", "b"], [("b", "a")], speculative_loading="4")
    async with remote_exec_engine.begin() as conn:
        await conn.execute(sa.text("UPDATE actions SET tier = 'high' WHERE input_key = :key"), {"key": input_key("a")})

    started = time.monotonic()
    waiting = asyncio.create_task(claim_ahead(http, wait_s=CLAIM_RECHECK_SECONDS * 2))
    await asyncio.sleep(0.2)
    assert await claim_named(http, "a", "high")
    claimed = await waiting
    assert claimed is not None and claimed["theory"] == "pkg:b"
    assert time.monotonic() - started < CLAIM_RECHECK_SECONDS


async def test_a_child_is_not_claimed_ahead_while_any_of_its_parents_waits_ahead(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: AsyncEngine
) -> None:
    await submit(http, ["a", "x", "b", "c"], [("b", "x"), ("c", "a"), ("c", "b")], speculative_loading="4")
    await claim_named(http, "x")
    await claim_named(http, "a")
    b = await claim_ahead(http)
    assert b is not None and b["theory"] == "pkg:b"

    # "c" is a child of the running "a", but its other parent "b" still waits for "x", as a fresh read sees.
    coordinator.ahead_read = None
    assert await claim_ahead(http) is None
    assert await ahead_state(remote_exec_engine, "c") == ("waiting", "no", 0, 2)


async def test_claims_ahead_sharing_a_read_take_the_deepest_child_of_any_batch_next(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    coordinator.settings.claim_ranking_seconds = 3600
    await submit(
        http, ["a", "x", "x2", "x3", "y"], [("x", "a"), ("x2", "x"), ("x3", "x2"), ("y", "a")], speculative_loading="4"
    )
    await submit(http, ["b", "z", "z2"], [("z", "b"), ("z2", "z")], speculative_loading="4")
    await claim_named(http, "a")
    await claim_named(http, "b")

    claimed = [await claim_ahead(http) for _ in range(3)]
    assert [c["theory"] for c in claimed if c is not None] == ["pkg:x", "pkg:z", "pkg:y"]


async def test_a_claim_ahead_of_several_tiers_takes_the_deepest_child_whatever_its_tier(
    http: httpx.AsyncClient, remote_exec_engine: AsyncEngine
) -> None:
    await submit(
        http, ["a", "x", "x2", "x3", "y"], [("x", "a"), ("x2", "x"), ("x3", "x2"), ("y", "a")], speculative_loading="4"
    )
    await submit(http, ["b", "z", "z2"], [("z", "b"), ("z2", "z")], speculative_loading="4")
    async with remote_exec_engine.begin() as conn:
        await conn.execute(
            sa.text("UPDATE actions SET tier = 'high' WHERE input_key = ANY(CAST(:keys AS text[]))"),
            {"keys": [input_key("y"), input_key("z")]},
        )
    await claim_named(http, "a")
    await claim_named(http, "b")

    claimed = await claim_ahead(http, "high", also_claim=["standard"])
    assert claimed is not None and claimed["theory"] == "pkg:x"
