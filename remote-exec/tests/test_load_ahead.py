"""Claims ahead of running parents, for batches submitted with ``speculative_loading``."""

import asyncio
import time
from datetime import UTC, datetime
from typing import Any
from uuid import UUID, uuid4

import httpx
import pytest
import sqlalchemy as sa
from conftest import FakeCache
from sqlalchemy.ext.asyncio import AsyncEngine
from test_coordinator import (
    CLIENT,
    WORKER,
    ac_key,
    batch,
    build,
    claim,
    claim_all,
    claim_named,
    complete,
    input_key,
    result,
    spec,
    states,
    submit,
)

from remote_exec import coordinator as coordinator_module
from remote_exec.coordinator import CLAIM_RECHECK_SECONDS, Coordinator, _claim_rank, _Ranking


async def claim_ahead(
    http: httpx.AsyncClient, tier: str = "standard", wait_s: float = 0, also_claim: list[str] | None = None
) -> dict[str, Any] | None:
    # A worker not seen before: one that claims again holds none of its leases.
    body = {"tier": tier, "also_claim": also_claim or [], "worker": f"w-{uuid4().hex[:8]}", "ahead": True, "wait_s": wait_s}
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
    response = await http.post(
        "/v1/batches", content="holbuild-action-batch-v1\n", headers=CLIENT,
        params={"speculative_loading": "4", "class": "run"},
    )
    assert response.status_code == 400 and "speculative_loading" in response.text


async def test_a_batch_without_speculative_loading_is_never_claimed_ahead(http: httpx.AsyncClient) -> None:
    await submit(http, ["a", "b"], [("b", "a")])
    claimed = await claim(http)
    assert claimed is not None and claimed["ahead_parents"] == []

    assert await claim_ahead(http) is None


async def test_builds_of_a_batch_that_loads_ahead_are_claimed_pipelined_unless_the_setting_is_off(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    await submit(http, ["a", "b"], [("b", "a")], speculative_loading="4")
    claimed = await claim(http)
    assert claimed is not None and claimed["pipeline"] is True
    claimed = await claim_ahead(http)
    assert claimed is not None and claimed["theory"] == "pkg:b" and claimed["pipeline"] is True

    # Nothing would start on the outline of a leaf claimed plain.
    await submit(http, ["l"], speculative_loading="4")
    claimed = await claim(http)
    assert claimed is not None and claimed["theory"] == "pkg:l" and claimed["pipeline"] is False

    await submit(http, ["x"])
    claimed = await claim(http)
    assert claimed is not None and claimed["theory"] == "pkg:x" and claimed["pipeline"] is False

    coordinator.settings.pipeline = False
    await submit(http, ["y", "z"], [("z", "y")], speculative_loading="4")
    claimed = await claim(http)
    assert claimed is not None and claimed["theory"] == "pkg:y" and claimed["pipeline"] is False


async def test_an_action_that_published_its_outline_frees_its_slot_of_the_cap_for_its_children(
    http: httpx.AsyncClient, coordinator: Coordinator, cache: FakeCache
) -> None:
    await submit(http, ["a", "b", "c"], [("b", "a"), ("c", "b")], speculative_loading="1")
    a = await claim_named(http, "a")
    b = await claim_ahead(http)
    assert b is not None and b["theory"] == "pkg:b"
    assert await claim_ahead(http) is None  # the cap is full

    # A stale token marks nothing.
    response = await http.post(f"/v1/work/{uuid4()}/outlined", headers=WORKER)
    assert response.status_code == 204
    assert await claim_ahead(http) is None

    # Nor does "b", once out, count as a generation: "c" is one generation ahead of it, and waits for both.
    response = await http.post(f"/v1/work/{b['attempt_token']}/outlined", headers=WORKER)
    assert response.status_code == 204
    c = await claim_ahead(http)
    assert c is not None and (c["theory"], c["ahead_parents"]) == ("pkg:c", parents("a") + parents("b"))
    assert list(coordinator.outlined_tokens) == [UUID(b["attempt_token"])]

    # Its result forgets it.
    cache.keys.add(ac_key("a"))
    assert (await complete(http, a, result("a", "built"))).status_code == 200
    cache.keys.add(ac_key("b"))
    assert (await complete(http, b["attempt_token"], result("b", "built"))).status_code == 200
    assert coordinator.outlined_tokens == {}
    # A report arriving after the result marks nothing.
    assert (await http.post(f"/v1/work/{b['attempt_token']}/outlined", headers=WORKER)).status_code == 204
    assert coordinator.outlined_tokens == {}


async def test_a_claim_ahead_past_an_outline_makes_its_children_candidates_at_once(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    coordinator.settings.ahead_depth = 2
    coordinator.settings.claim_ranking_seconds = 3600
    await submit(http, ["a", "b", "c", "d"], [("b", "a"), ("c", "b"), ("d", "c")], speculative_loading="4")
    await claim_named(http, "a")
    b = await claim_ahead(http)
    assert b is not None and b["theory"] == "pkg:b"
    assert (await http.post(f"/v1/work/{b['attempt_token']}/outlined", headers=WORKER)).status_code == 204
    c = await claim_ahead(http)
    assert c is not None and c["theory"] == "pkg:c"
    # "c" is a generation ahead of "b"'s outline, though two links from the running "a": "d", a generation further,
    # may be claimed ahead, and claiming "c" outdated the shared read that didn't have it.
    d = await claim_ahead(http)
    assert d is not None and d["theory"] == "pkg:d"


async def test_a_locked_claim_ahead_counts_a_parent_s_outline_only_while_it_is_reported(
    http: httpx.AsyncClient, remote_exec_engine: AsyncEngine
) -> None:
    """At ``ahead_depth`` 1, "d" may be claimed ahead of "c", claimed ahead of "b" on "b"'s outline, only on "c"'s own
    outline: "b"'s, though "b" still waits for the running "a", doesn't make "c" a generation 0. The claim checks it
    itself, whatever the shared read it was given found."""
    batch_id = await submit(
        http, ["a", "b", "c", "d"], [("b", "a"), ("c", "b"), ("d", "c")], speculative_loading="4"
    )
    await claim_named(http, "a")
    b = await claim_ahead(http)
    assert b is not None and b["theory"] == "pkg:b"
    assert (await http.post(f"/v1/work/{b['attempt_token']}/outlined", headers=WORKER)).status_code == 204
    c = await claim_ahead(http)
    assert c is not None and c["theory"] == "pkg:c"
    claiming = {
        "batch_id": batch_id, "keys": [input_key("d")], "tier": "standard", "depth": 1, "taken": [],
        "outlined_only": False,
    }

    async def claimed(outlined: list[str]) -> str | None:
        async with remote_exec_engine.begin() as connection:
            row = (
                await connection.execute(coordinator_module.CLAIM_AHEAD_ACTION, {**claiming, "outlined": outlined})
            ).first()
            await connection.rollback()
        return None if row is None else row.theory

    assert await claimed([]) is None
    assert await claimed([b["attempt_token"]]) is None
    assert await claimed([c["attempt_token"]]) == "pkg:d"


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


async def test_a_claim_ahead_comes_after_ready_builds_of_its_priority_and_before_those_of_lower_priorities(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    await submit(http, ["a", "b"], [("b", "a")], speculative_loading="4", priority="2")
    await claim_named(http, "a")
    await submit(http, ["x"], priority="2")
    await submit(http, ["y", "z"])

    order = []
    for _ in range(4):
        claimed = await claim_ahead(http)
        assert claimed is not None
        order.append(claimed["theory"].removeprefix("pkg:"))
    assert order[:2] == ["x", "b"] and sorted(order[2:]) == ["y", "z"]


async def test_a_claim_ahead_with_a_deeper_chain_than_its_batch_s_ready_builds_comes_before_them(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    coordinator.settings.claim_ranking_seconds = 0  # a plain claim's children are candidates at the next read
    await submit(
        http,
        ["a", "b", "c", "d", "r", "s", "t", "l"],
        [("b", "a"), ("c", "b"), ("d", "c"), ("s", "r"), ("t", "s")],
        speculative_loading="4",
    )
    await claim_named(http, "a")
    tokens: dict[str, str] = {}

    async def next_claim() -> str | None:
        action = await claim_ahead(http)
        if action is None:
            return None
        name = action["theory"].removeprefix("pkg:")
        tokens[name] = action["attempt_token"]
        return name

    # "r" ranks as deep as "b" and comes first. Then "b" and "s", whose parents run and have published no outline,
    # come before the leaf "l": they load their ancestors meanwhile.
    assert [await next_claim() for _ in range(3)] == ["r", "b", "s"]
    # "c" is a generation ahead of "b" once its outline is out, and on a longer chain than "l", comes before it.
    assert (await http.post(f"/v1/work/{tokens['b']}/outlined", headers=WORKER)).status_code == 204
    assert await next_claim() == "c"
    # Once "c"'s outline is out too, "d" may be claimed, but ranks no higher than "l", which goes first. "t", two
    # generations ahead of the running "r" until "s" publishes an outline, never may.
    assert (await http.post(f"/v1/work/{tokens['c']}/outlined", headers=WORKER)).status_code == 204
    assert [await next_claim() for _ in range(3)] == ["l", "d", None]


async def test_of_claims_ahead_as_deep_the_one_on_outlines_alone_is_taken_first(
    http: httpx.AsyncClient, remote_exec_engine: AsyncEngine
) -> None:
    await submit(http, ["a", "q", "x", "y"], [("x", "a"), ("y", "q")], speculative_loading="4")
    await claim_named(http, "a")
    q = await claim_named(http, "q")
    assert (await http.post(f"/v1/work/{q}/outlined", headers=WORKER)).status_code == 204

    # The shared read ranks it first too: a claim sees only a batch's first AHEAD_CLAIM_KEYS candidates.
    async with remote_exec_engine.connect() as connection:
        rows = await connection.execute(coordinator_module.AHEAD_CANDIDATES, {"depth": 1, "outlined": [q]})
        assert [row.input_key for row in rows] == [input_key("y"), input_key("x")]

    # "x" and "y" rank alike and "x" sorts first, but only "y" can start at once.
    claimed = await claim_ahead(http)
    assert claimed is not None and claimed["theory"] == "pkg:y"


async def test_a_claim_ahead_on_outlines_alone_counts_as_a_build_of_its_batch_in_the_ranking_claims_share(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    await submit(http, ["a", "b", "c", "l"], [("b", "a"), ("c", "b")], speculative_loading="4")
    a = await claim_named(http, "a")
    assert (await http.post(f"/v1/work/{a}/outlined", headers=WORKER)).status_code == 204
    await submit(http, ["y1", "y2"])
    coordinator.settings.claim_ranking_seconds = 3600

    # Batches take turns by their running builds: "b", claimed ahead, is the second of its batch, so the other
    # batch's "y2" comes before "l".
    claimed = []
    for _ in range(4):
        action = await claim_ahead(http)
        assert action is not None
        claimed.append(action["theory"].removeprefix("pkg:"))
    assert claimed == ["y1", "b", "y2", "l"]


def test_a_ranking_entry_counted_for_a_claim_ahead_is_put_back_after_a_cap_rewrote_its_priority() -> None:
    """A claim ahead on outlines counts in its batch's entry, and a cap reached meanwhile rewrites the priorities:
    the entry put back when the claim takes nothing is found all the same, and stays capped."""
    batch, at = uuid4(), datetime.now(UTC)
    stopped = (0, -2, 1, True, at, at, batch, "standard", None)
    counted = (0, -2, 2, True, at, at, batch, "standard", None)
    other = (0, -1, 0, False, at, at, uuid4(), "standard", None)
    ranking = _Ranking(0.0, 0, [stopped, other], set(), set(), 1, {}, {})
    Coordinator._replace_entry(ranking, stopped, counted)
    ranking.capped = True
    ranking.heap[:] = [(e[0], 0, *e[2:]) for e in ranking.heap]
    Coordinator._replace_entry(ranking, counted, stopped)
    assert sorted(ranking.heap, key=lambda e: e[2]) == [(0, 0, *other[2:]), (0, 0, *stopped[2:])]


async def test_a_ready_build_waits_only_for_a_claim_ahead_of_its_tier_or_an_earlier_one(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: AsyncEngine
) -> None:
    coordinator.settings.claim_ranking_seconds = 3600
    await submit(http, ["a", "h"], [("h", "a")], speculative_loading="4", priority="2")
    await submit(http, ["b", "s"], [("s", "b")], speculative_loading="4", priority="2")
    await claim_named(http, "a")
    await claim_named(http, "b")
    await submit(http, ["r"], priority="1")
    async with remote_exec_engine.begin() as conn:
        await conn.execute(
            sa.text("UPDATE actions SET tier = 'high' WHERE input_key = ANY(:keys)"),
            {"keys": [input_key("h"), input_key("r")]},
        )
    await coordinator._ahead_candidates()

    # "h", which outranks the high-tier "r", may no longer be claimed ahead; "s", of a later tier, doesn't.
    async with remote_exec_engine.begin() as conn:
        await conn.execute(
            sa.text("UPDATE actions SET ahead = 'abandoned' WHERE input_key = :key"), {"key": input_key("h")}
        )
    claimed = await claim_ahead(http, "high", also_claim=["standard"])
    assert claimed is not None and claimed["theory"] == "pkg:r"


async def test_a_child_another_batch_is_building_is_not_claimed_ahead_and_is_done_with_that_build(
    http: httpx.AsyncClient, cache: FakeCache
) -> None:
    leader = await submit(http, ["b"])
    token = await claim_named(http, "b")
    ahead = await submit(http, ["a", "b"], [("b", "a")], speculative_loading="4")
    await claim_named(http, "a")
    assert await claim_ahead(http) is None

    cache.keys.add(ac_key("b"))
    assert (await complete(http, token, result("b", "built"))).status_code == 200
    assert (await states(http, leader), await states(http, ahead)) == ({"b": "done"}, {"a": "running", "b": "done"})


async def test_a_child_another_batch_s_claim_is_leasing_is_passed_over_for_the_next_one_ahead(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: AsyncEngine
) -> None:
    coordinator.settings.claim_ranking_seconds = 0  # the second claim ahead reads the candidates again
    await submit(http, ["a", "b", "c"], [("b", "a"), ("c", "a")], speculative_loading="4")
    await claim_named(http, "a")

    async with remote_exec_engine.connect() as other, other.begin():
        # Another batch's claim of "b", between its lock of the key and its commit.
        await other.execute(coordinator_module.LOCK_KEY, {"key": input_key("b"), "spec": spec("b")})
        claimed = await claim_ahead(http)
        assert claimed is not None and claimed["theory"] == "pkg:c"
        assert await claim_ahead(http) is None

    claimed = await claim_ahead(http)
    assert claimed is not None and claimed["theory"] == "pkg:b"


async def test_a_child_held_by_another_batch_wakes_a_waiting_claim_ahead_once_that_build_fails(
    http: httpx.AsyncClient,
) -> None:
    await submit(http, ["b"])
    token = await claim_named(http, "b")
    await submit(http, ["a", "b"], [("b", "a")], speculative_loading="4")
    await claim_named(http, "a")

    started = time.monotonic()
    waiting = asyncio.create_task(claim_ahead(http, wait_s=CLAIM_RECHECK_SECONDS * 2))
    await asyncio.sleep(0.2)
    assert not waiting.done()
    assert (await complete(http, token, result("b", "failed", "proof"))).status_code == 200
    claimed = await waiting
    assert claimed is not None and claimed["theory"] == "pkg:b" and claimed["ahead_parents"] == parents("a")
    assert time.monotonic() - started < CLAIM_RECHECK_SECONDS


async def test_a_claim_ahead_given_up_frees_its_key_for_another_batch_s_ready_copy_at_once(
    http: httpx.AsyncClient, cache: FakeCache
) -> None:
    ahead = await submit(http, ["a", "b"], [("b", "a")], speculative_loading="4")
    a = await claim_named(http, "a")
    b = await claim_ahead(http)
    assert b is not None and b["theory"] == "pkg:b"
    # Another batch whose parent of "b" is already built: its copy is ready, and held by the claim ahead.
    ready = await submit(http, ["b"])
    assert await claim(http) is None

    started = time.monotonic()
    waiting = asyncio.create_task(claim_ahead(http, wait_s=CLAIM_RECHECK_SECONDS * 2))
    await asyncio.sleep(0.2)
    assert not waiting.done()
    assert (await complete(http, b["attempt_token"], result("b", "failed", "ahead-abandoned"))).status_code == 200
    claimed = await waiting
    assert claimed is not None and claimed["theory"] == "pkg:b" and claimed["ahead_parents"] == []
    assert time.monotonic() - started < CLAIM_RECHECK_SECONDS
    assert await states(http, ready) == {"b": "running"}
    assert await states(http, ahead) == {"a": "running", "b": "waiting"}
    assert [x["attempts"] for x in (await batch(http, ahead))["actions"] if x["theory"] == "pkg:b"] == [0]

    cache.keys.add(ac_key("b"))
    assert (await complete(http, claimed["attempt_token"], result("b", "built"))).status_code == 200
    cache.keys.add(ac_key("a"))
    assert (await complete(http, a, result("a", "built"))).status_code == 200
    assert (await states(http, ready), await states(http, ahead)) == ({"b": "done"}, {"a": "done", "b": "done"})


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


async def test_concurrent_claims_ahead_of_one_batch_wait_for_its_lock_one_connection_at_a_time(
    http: httpx.AsyncClient, cache: FakeCache, remote_exec_engine: AsyncEngine
) -> None:
    """Each claim ahead locks its batch's row; those waiting for it would each hold a pooled connection, which one big
    batch's claims filled. They take turns in memory instead, and the turns after the cap filled skip the batch."""
    children = [f"c{i}" for i in range(12)]
    await submit(http, ["p", *children], [(c, "p") for c in children], speculative_loading="2")
    await claim_named(http, "p")
    holding: set[int] = set()
    most = locks = 0

    def lock(conn: Any, cursor: Any, statement: str, *_: Any) -> None:
        nonlocal most, locks
        if statement.startswith("SELECT ahead_cap, max_heap_mb FROM batches"):
            holding.add(id(conn))
            most = max(most, len(holding))
            locks += 1

    def end(conn: Any) -> None:
        holding.discard(id(conn))

    events = [("before_cursor_execute", lock), ("commit", end), ("rollback", end)]
    for name, listener in events:
        sa.event.listen(remote_exec_engine.sync_engine, name, listener)
    try:
        claims = await asyncio.gather(*(claim_ahead(http) for _ in range(12)))
    finally:
        for name, listener in events:
            sa.event.remove(remote_exec_engine.sync_engine, name, listener)
    assert len([c for c in claims if c is not None]) == 2
    assert most == 1
    assert locks == 2  # the claims after the second skip the full batch without a connection


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


async def test_a_requeued_parent_revokes_the_child_claimed_ahead(
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
    assert await ahead_state(remote_exec_engine, "c") == ("waiting", "no", 0, 2)
    assert (await http.post(f"/v1/work/{c['attempt_token']}/heartbeat", headers=WORKER)).status_code == 409


async def test_an_action_waiting_ahead_holds_one_burst_worker_of_the_demand_until_it_waits_no_more(
    http: httpx.AsyncClient, coordinator: Coordinator, cache: FakeCache
) -> None:
    await submit(http, ["a", "b"], [("b", "a")], speculative_loading="4")
    a = await claim_named(http, "a")
    b = await claim_ahead(http)
    assert b is not None

    queue = (await http.get("/v1/queue", headers=CLIENT)).json()
    assert (queue["running_standard"], queue["waiting_ahead_standard"]) == (2, 1)
    async with coordinator.engine.connect() as conn:
        active = await coordinator._counts(conn, coordinator_module.COUNT_ACTIVE)
    assert (active.running_standard, active.waiting_ahead_standard) == (2, 1)
    # a on the warm worker, b on the burst worker that claimed it ahead
    assert coordinator_module.burst_demand(active, warm_workers=1, max_burst_workers=16) == 1

    # One that published its outline proves while its parent finishes: it waits no more.
    assert (await http.post(f"/v1/work/{b['attempt_token']}/outlined", headers=WORKER)).status_code == 204
    queue = (await http.get("/v1/queue", headers=CLIENT)).json()
    assert (queue["running_standard"], queue["waiting_ahead_standard"]) == (2, 0)
    async with coordinator.engine.connect() as conn:
        active = await coordinator._counts(conn, coordinator_module.COUNT_ACTIVE)
    assert active.waiting_ahead_standard == 0

    cache.keys.add(ac_key("a"))
    assert (await complete(http, a, result("a", "built"))).status_code == 200
    queue = (await http.get("/v1/queue", headers=CLIENT)).json()
    assert (queue["running_standard"], queue["waiting_ahead_standard"]) == (1, 0)


async def test_a_parent_claimed_makes_its_child_a_candidate_from_the_next_read_of_the_candidates(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    """A plain claim leaves the shared read of the candidates alone: its children may be claimed ahead from the
    next read, once that read is ``claim_ranking_seconds`` old."""
    coordinator.settings.claim_ranking_seconds = 3600
    await submit(http, ["a", "b"], [("b", "a")], speculative_loading="4")
    assert await claim_ahead(http, "high") is None  # a is standard: nothing for this worker
    assert await claim_named(http, "a")
    assert await claim_ahead(http, "high", also_claim=["standard"]) is None

    coordinator.settings.claim_ranking_seconds = 0
    claimed = await claim_ahead(http, "high", also_claim=["standard"])
    assert claimed is not None and claimed["theory"] == "pkg:b"


@pytest.mark.parametrize(("together", "ranking_seconds", "most_reads"), [(True, 0, 3), (False, 3600, 1)])
async def test_claims_of_workers_that_load_ahead_share_reads_of_the_candidates(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: AsyncEngine,
    together: bool, ranking_seconds: float, most_reads: int,
) -> None:
    """A worker that loads ahead looks for a candidate of a higher priority before each ready build it claims.
    Claims arriving together take one read of the candidates, even when every read is too old for a later claim;
    and plain claims don't outdate the read, so claims one after another keep it for ``claim_ranking_seconds``.
    A large batch arriving, its builds claimed by hundreds of such workers at once, reads the candidates a few
    times, not once per claim."""
    coordinator.settings.claim_ranking_seconds = ranking_seconds
    names = [f"b{i}" for i in range(200)]
    await submit(http, ["p", "c", *names], [("c", "p")], speculative_loading="4")
    await claim_named(http, "p")  # c may now be claimed ahead, after the ready builds of its priority
    reads = 0

    def count(conn: Any, cursor: Any, statement: str, *_: Any) -> None:
        nonlocal reads
        reads += "WITH RECURSIVE outlined AS" in statement  # AHEAD_CANDIDATES

    sa.event.listen(remote_exec_engine.sync_engine, "before_cursor_execute", count)
    try:
        if together:
            claimed = await asyncio.gather(*(claim_ahead(http) for _ in names))
        else:
            claimed = [await claim_ahead(http) for _ in names]
    finally:
        sa.event.remove(remote_exec_engine.sync_engine, "before_cursor_execute", count)
    assert sorted(c["theory"] for c in claimed if c is not None) == sorted(f"pkg:{n}" for n in names)
    assert 1 <= reads <= most_reads


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


async def test_a_claim_ahead_of_several_tiers_takes_the_deepest_child_of_its_first_tier_with_one(
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

    claimed = [await claim_ahead(http, "high", also_claim=["standard"]) for _ in range(3)]
    assert [c["theory"] for c in claimed if c is not None] == ["pkg:z", "pkg:y", "pkg:x"]


async def test_a_batch_at_its_cap_is_left_out_of_the_read_of_candidates(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    await submit(http, ["a", "b", "c"], [("b", "a"), ("c", "a")], speculative_loading="1")
    await claim_named(http, "a")
    assert await claim_ahead(http) is not None

    coordinator.ahead_read = None
    assert (await coordinator._ahead_candidates()).candidates == []


async def test_at_its_cap_a_batch_claims_ahead_only_a_child_whose_parents_all_published_their_outline(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    """A child whose unfinished parents all published their outline starts on them and waits for nothing: with the
    cap full, it is still claimed ahead, and takes no slot of it. One with a parent without an outline waits."""
    roots = [f"r{i}" for i in range(16)] + ["o", "u"]
    children = [f"c{i}" for i in range(16)] + ["x", "w"]
    edges = [(f"c{i}", f"r{i}") for i in range(16)] + [("x", "o"), ("w", "u")]
    batch_id = await submit(http, roots + children, edges, speculative_loading="16")
    tokens = await claim_all(http, len(roots))
    assert sorted(tokens) == sorted(roots)
    for _ in range(16):
        claimed = await claim_ahead(http)
        assert claimed is not None and claimed["theory"].startswith("pkg:c")
    assert await claim_ahead(http) is None

    assert (await http.post(f"/v1/work/{tokens['o']}/outlined", headers=WORKER)).status_code == 204
    x = await claim_ahead(http)
    assert x is not None and (x["theory"], x["ahead_parents"]) == ("pkg:x", parents("o"))
    assert await claim_ahead(http) is None  # "w" waits for "u", which published no outline

    queue = (await http.get("/v1/queue", headers=CLIENT)).json()
    assert (queue["running_standard"], queue["waiting_ahead_standard"]) == (35, 16)
    async with coordinator.engine.connect() as conn:
        active = await coordinator._counts(conn, coordinator_module.COUNT_ACTIVE)
        waiting = await conn.scalar(
            coordinator_module.COUNT_WAITING_AHEAD,
            {"batch_id": batch_id, "outlined": list(coordinator.outlined_tokens)},
        )
    assert (active.waiting_ahead_standard, waiting) == (16, 16)


async def test_at_its_cap_a_batch_claims_no_child_ahead_whose_parent_s_outlined_lease_ended_since_the_read(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: AsyncEngine
) -> None:
    coordinator.settings.claim_ranking_seconds = 3600
    await submit(http, ["a", "b", "o", "x"], [("b", "a"), ("x", "o")], speculative_loading="1")
    tokens = await claim_all(http, 2)
    b = await claim_ahead(http)
    assert b is not None and b["theory"] == "pkg:b"
    assert (await http.post(f"/v1/work/{tokens['o']}/outlined", headers=WORKER)).status_code == 204
    read = await coordinator._ahead_candidates()
    assert [(c[1], c[5]) for c in read.candidates] == [(input_key("x"), True)]

    # The shared read still has "x" whose parent's lease ended, unswept: the claim checks the outline itself.
    async with remote_exec_engine.begin() as connection:
        await connection.execute(
            sa.text("UPDATE leases SET expires_at = now() - interval '1 second' WHERE input_key = :key"),
            {"key": input_key("o")},
        )
    assert await claim_ahead(http) is None
    assert (await ahead_state(remote_exec_engine, "x"))[0] == "waiting"


async def test_a_read_from_under_the_cap_still_claims_an_outline_ready_child_once_another_coordinator_fills_it(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    """The shared read ranks more than AHEAD_CLAIM_KEYS children that would wait before the one that won't; once
    another coordinator's claim fills the cap, that one is still claimed."""
    coordinator.settings.claim_ranking_seconds = 3600
    replica = Coordinator(coordinator.engine, coordinator.cache, coordinator.settings)
    count = coordinator_module.AHEAD_CLAIM_KEYS + 2
    roots = ["o"] + [f"r{i:02}" for i in range(count)]
    children = ["x"] + [f"c{i:02}" for i in range(count)] + [f"g{i:02}" for i in range(count)]
    edges = [("x", "o")] + [(f"c{i:02}", f"r{i:02}") for i in range(count)] + [
        (f"g{i:02}", f"c{i:02}") for i in range(count)
    ]
    await submit(http, roots + children, edges, speculative_loading="1")
    tokens = await claim_all(http, len(roots))
    assert (await http.post(f"/v1/work/{tokens['o']}/outlined", headers=WORKER)).status_code == 204
    read = await coordinator._ahead_candidates()
    assert [(c[1], c[5]) for c in read.candidates] == [
        *((input_key(f"c{i:02}"), False) for i in range(count)), (input_key("x"), True)
    ]

    filled = await replica.claim(["standard"], "w-replica", ahead=True)
    assert filled is not None and filled.theory == "pkg:c00"
    x = await claim_ahead(http)
    assert x is not None and (x["theory"], x["ahead_parents"]) == ("pkg:x", parents("o"))
    assert await claim_ahead(http) is None


# An action abandoned ahead waits for its parents from then on; one retried may be claimed ahead again.
@pytest.mark.parametrize(("failure", "next_ahead"), [("ahead-abandoned", "c"), ("unavailable", "b"), ("publish", "b")])
async def test_a_claim_ahead_given_up_wakes_a_claim_waiting_for_its_slot_of_the_cap(
    http: httpx.AsyncClient, coordinator: Coordinator, failure: str, next_ahead: str
) -> None:
    coordinator.settings.claim_ranking_seconds = 3600
    await submit(http, ["a", "b", "c"], [("b", "a"), ("c", "a")], speculative_loading="1")
    await claim_named(http, "a")
    b = await claim_ahead(http)
    assert b is not None and b["theory"] == "pkg:b"

    started = time.monotonic()
    waiting = asyncio.create_task(claim_ahead(http, wait_s=CLAIM_RECHECK_SECONDS * 2))
    await asyncio.sleep(0.2)
    assert (await complete(http, b["attempt_token"], result("b", "failed", failure))).status_code == 200
    claimed = await waiting
    assert claimed is not None and claimed["theory"] == f"pkg:{next_ahead}"
    assert time.monotonic() - started < CLAIM_RECHECK_SECONDS


async def test_a_lease_lost_while_waiting_ahead_frees_its_slot_of_the_cap(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: AsyncEngine
) -> None:
    coordinator.settings.claim_ranking_seconds = 3600
    await submit(http, ["a", "b", "c"], [("b", "a"), ("c", "a")], speculative_loading="1")
    await claim_named(http, "a")
    assert await claim_ahead(http) is not None
    assert await claim_ahead(http) is None
    async with remote_exec_engine.begin() as connection:
        await connection.execute(
            sa.text("UPDATE leases SET expires_at = now() - interval '1 second' WHERE input_key = :key"),
            {"key": input_key("b")},
        )

    await coordinator.expire_leases()
    c = await claim_ahead(http)
    assert c is not None and c["theory"] == "pkg:c"


async def test_a_parent_lease_expired_wakes_a_claim_waiting_for_the_slot_its_revoked_child_frees(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: AsyncEngine
) -> None:
    coordinator.settings.claim_ranking_seconds = 3600
    await submit(http, ["a", "b", "c", "d"], [("b", "a"), ("c", "d")], speculative_loading="1")
    assert sorted(await claim_all(http, 2)) == ["a", "d"]
    b = await claim_ahead(http)
    assert b is not None and b["theory"] == "pkg:b"

    started = time.monotonic()
    waiting = asyncio.create_task(claim_ahead(http, wait_s=CLAIM_RECHECK_SECONDS * 2))
    await asyncio.sleep(0.2)
    async with remote_exec_engine.begin() as connection:
        await connection.execute(
            sa.text("UPDATE leases SET expires_at = now() - interval '1 second' WHERE input_key = :key"),
            {"key": input_key("a")},
        )
    await coordinator.expire_leases()
    claimed = await waiting
    assert claimed is not None and claimed["theory"] == "pkg:c"
    assert time.monotonic() - started < CLAIM_RECHECK_SECONDS


async def test_a_parent_back_to_waiting_revokes_what_was_claimed_ahead_of_it_and_of_that(
    http: httpx.AsyncClient, coordinator: Coordinator, cache: FakeCache, remote_exec_engine: AsyncEngine
) -> None:
    await submit(http, ["a", "b", "c"], [("b", "a"), ("c", "b")], speculative_loading="4")
    a = await claim_named(http, "a")
    b = await claim_ahead(http)
    assert b is not None
    cache.keys.add(ac_key("a"))
    assert (await complete(http, a, result("a", "built"))).status_code == 200
    c = await claim_ahead(http)
    assert c is not None and c["theory"] == "pkg:c"
    assert (await http.post(f"/v1/work/{c['attempt_token']}/outlined", headers=WORKER)).status_code == 204

    # "b" gives up loading ahead; "c" can't get its parent's outputs before "b" is claimed again.
    assert (await complete(http, b["attempt_token"], result("b", "failed", "ahead-abandoned"))).status_code == 200
    assert await ahead_state(remote_exec_engine, "c") == ("waiting", "no", 0, 1)
    assert (await http.post(f"/v1/work/{c['attempt_token']}/heartbeat", headers=WORKER)).status_code == 409
    # Nor does its outline count any more.
    assert coordinator.outlined_tokens == {}


async def test_a_chain_revoked_by_its_root_s_retry_is_claimed_ahead_again_once_the_root_runs_again(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: AsyncEngine,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(coordinator.settings, "ahead_depth", 0)
    names, edges = chain(5)
    await submit(http, names, edges, speculative_loading="16")
    root = await claim_named(http, "t0")
    for name in names[1:]:
        assert (await claim_ahead(http) or {}).get("theory") == f"pkg:{name}"

    assert (await complete(http, root, result("t0", "failed", "publish"))).status_code == 200
    assert [await ahead_state(remote_exec_engine, name) for name in names[1:]] == [("waiting", "no", 0, 1)] * 4
    await claim_named(http, "t0")
    for generation in range(1, len(names)):
        claimed = await claim_ahead(http)
        assert claimed is not None and claimed["theory"] == f"pkg:{names[generation]}"
        assert claimed["ahead_parents"] == ancestors_first(*names[:generation])


# After the revoke the root is claimed again by the batch that held the chain, whose copies were revoked, or, if the
# other batch ranks first, by that one, whose copies were never claimed.
@pytest.mark.parametrize(("first_priority", "root_batch"), [("3", 0), ("1", 1)])
async def test_a_chain_two_batches_share_is_claimed_ahead_again_after_a_revoke_until_both_are_done(
    http: httpx.AsyncClient, coordinator: Coordinator, cache: FakeCache, monkeypatch: pytest.MonkeyPatch,
    first_priority: str, root_batch: int,
) -> None:
    monkeypatch.setattr(coordinator.settings, "ahead_depth", 0)
    names, edges = chain(4)
    first = await submit(http, names, edges, speculative_loading="16", priority=first_priority)
    root = await claim_named(http, "t0")
    for name in names[1:]:
        assert (await claim_ahead(http) or {}).get("theory") == f"pkg:{name}"
    second = await submit(http, names, edges, speculative_loading="16", priority="2")
    assert await claim_ahead(http) is None  # every key is leased by the first batch

    assert (await complete(http, root, result("t0", "failed", "publish"))).status_code == 200
    tokens = {"t0": await claim_named(http, "t0")}
    assert (await states(http, (first, second)[root_batch]))["t0"] == "running"
    for name in names[1:]:
        claimed = await claim_ahead(http)
        assert claimed is not None and claimed["theory"] == f"pkg:{name}"
        tokens[name] = claimed["attempt_token"]
    for name in names:
        cache.keys.add(ac_key(name))
        assert (await complete(http, tokens[name], result(name, "built"))).status_code == 200
    assert await states(http, first) == await states(http, second) == dict.fromkeys(names, "done")


async def test_a_chain_two_batches_share_is_claimed_ahead_by_the_other_once_the_one_holding_it_is_cancelled(
    http: httpx.AsyncClient, coordinator: Coordinator, cache: FakeCache, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(coordinator.settings, "ahead_depth", 0)
    coordinator.settings.claim_ranking_seconds = 0  # the cancel wakes no claim; the next one reads the batch again
    names, edges = chain(4)
    first = await submit(http, names, edges, speculative_loading="16", priority="3")
    await claim_named(http, "t0")
    for name in names[1:]:
        assert (await claim_ahead(http) or {}).get("theory") == f"pkg:{name}"
    second = await submit(http, names, edges, speculative_loading="16", priority="2")

    assert (await http.post(f"/v1/batches/{first}/cancel", headers=CLIENT)).status_code == 200
    tokens = {"t0": await claim_named(http, "t0")}
    for name in names[1:]:
        claimed = await claim_ahead(http)
        assert claimed is not None and claimed["theory"] == f"pkg:{name}"
        tokens[name] = claimed["attempt_token"]
    for name in names:
        cache.keys.add(ac_key(name))
        assert (await complete(http, tokens[name], result(name, "built"))).status_code == 200
    assert await states(http, second) == dict.fromkeys(names, "done")


async def test_a_lease_lost_while_waiting_ahead_costs_no_attempt(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: AsyncEngine
) -> None:
    await submit(http, ["a", "b"], [("b", "a")], speculative_loading="4")
    await claim_named(http, "a")
    b = await claim_ahead(http)
    assert b is not None
    async with remote_exec_engine.begin() as connection:
        await connection.execute(
            sa.text("UPDATE leases SET expires_at = now() - interval '1 second' WHERE input_key = :key"),
            {"key": input_key("b")},
        )

    await coordinator.expire_leases()
    assert await ahead_state(remote_exec_engine, "b") == ("waiting", "abandoned", 0, 1)
    assert await ahead_state(remote_exec_engine, "a") == ("running", "no", 1, 0)
    assert await claim_ahead(http) is None  # built once "a" is done, as one whose worker gave up


async def test_input_missing_from_a_claim_ahead_counts_its_attempt_and_makes_it_plain(
    http: httpx.AsyncClient, cache: FakeCache, remote_exec_engine: AsyncEngine
) -> None:
    await submit(http, ["p", "q", "b"], [("b", "p"), ("b", "q")], speculative_loading="4")
    await build(http, cache, "p")
    await claim_named(http, "q")
    b = await claim_ahead(http)
    assert b is not None and b["ahead_parents"] == parents("q")

    cache.keys.discard(ac_key("p"))
    missing = result("b", "failed", "input-missing", missing=f"theory {input_key('p')}")
    assert (await complete(http, b["attempt_token"], missing)).status_code == 200
    assert await ahead_state(remote_exec_engine, "b") == ("waiting", "no", 1, 2)


async def test_input_missing_for_a_parent_still_building_costs_no_attempt_and_waits_for_its_build(
    http: httpx.AsyncClient, cache: FakeCache, remote_exec_engine: AsyncEngine
) -> None:
    # The claim ahead finds an entry of an earlier build of the running parent, whose blobs the cache lost. Claimed
    # ahead again at once, it used up its attempts on the same entry and failed the batch.
    batch_id = await submit(http, ["a", "b"], [("b", "a")], speculative_loading="4")
    a = await claim_named(http, "a")
    b = await claim_ahead(http)
    assert b is not None and b["ahead_parents"] == parents("a")
    missing = result("b", "failed", "input-missing", missing=f"theory {input_key('a')}")
    assert (await complete(http, b["attempt_token"], missing)).status_code == 200
    assert await ahead_state(remote_exec_engine, "b") == ("waiting", "abandoned", 0, 1)
    assert await claim_ahead(http) is None

    cache.keys.add(ac_key("a"))
    assert (await complete(http, a, result("a", "built"))).status_code == 200
    plain = await claim_ahead(http)
    assert plain is not None and (plain["theory"], plain["ahead_parents"]) == ("pkg:b", [])
    cache.keys.add(ac_key("b"))
    assert (await complete(http, plain["attempt_token"], result("b", "built"))).status_code == 200
    assert (await batch(http, batch_id))["state"] == "done"


async def test_a_claim_ahead_of_several_tiers_takes_its_first_tier_before_a_lower_tier_of_a_batch_with_one(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: AsyncEngine
) -> None:
    coordinator.settings.claim_ranking_seconds = 3600
    await submit(http, ["a", "x"], [("x", "a")], speculative_loading="4", priority="1")
    await submit(http, ["b", "h", "s"], [("h", "b"), ("s", "b")], speculative_loading="4")
    async with remote_exec_engine.begin() as conn:
        await conn.execute(sa.text("UPDATE actions SET tier = 'high' WHERE input_key = :key"), {"key": input_key("h")})
    await claim_named(http, "a")
    await claim_named(http, "b")
    await coordinator._ahead_candidates()

    # "h", the shared read's only high-tier candidate, may no longer be claimed ahead; "x" outranks "s".
    async with remote_exec_engine.begin() as conn:
        await conn.execute(
            sa.text("UPDATE actions SET ahead = 'abandoned' WHERE input_key = :key"), {"key": input_key("h")}
        )
    claimed = await claim_ahead(http, "high", also_claim=["standard"])
    assert claimed is not None and claimed["theory"] == "pkg:x"


@pytest.mark.parametrize(("cap", "first"), [(1, "n"), (2, "x")])
async def test_past_the_priority_cap_a_claim_ahead_no_longer_outranks_a_ready_build(
    http: httpx.AsyncClient, coordinator: Coordinator, cap: int, first: str
) -> None:
    coordinator.settings.priority_cap = cap
    await submit(http, ["a", "x"], [("x", "a")], speculative_loading="4", priority="1")
    await claim_named(http, "a")
    await submit(http, ["n"])
    claimed = await claim_ahead(http)
    assert claimed is not None and claimed["theory"] == f"pkg:{first}"


async def test_concurrent_claims_ahead_take_the_last_priority_cap_slot_once(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    coordinator.settings.priority_cap = 2
    coordinator.settings.claim_ranking_seconds = 3600
    await submit(http, ["a", "x1", "x2"], [("x1", "a"), ("x2", "a")], speculative_loading="4", priority="1")
    await claim_named(http, "a")
    await submit(http, ["n1", "n2"])
    claimed = await asyncio.gather(claim_ahead(http), claim_ahead(http))
    theories = sorted(c["theory"].removeprefix("pkg:") for c in claimed if c is not None)
    assert len(theories) == 2 and theories[1].startswith("x") and theories[0] == "n1"


async def test_a_parent_evicted_before_a_release_revokes_the_child_claimed_ahead(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, remote_exec_engine: AsyncEngine
) -> None:
    await submit(
        http, ["p1", "p2", "q", "c", "d"], [("c", "p1"), ("c", "p2"), ("d", "p1"), ("d", "q")], speculative_loading="1"
    )
    await build(http, cache, "p1")
    await claim_named(http, "p2")
    q = await claim_named(http, "q")
    c = await claim_ahead(http)
    assert c is not None and c["theory"] == "pkg:c"

    # "d" is released once "q" is done, and finds "p1" evicted.
    cache.keys.discard(ac_key("p1"))
    cache.keys.add(ac_key("q"))
    assert (await complete(http, q, result("q", "built"))).status_code == 200
    await coordinator.released()
    assert await ahead_state(remote_exec_engine, "p1") == ("ready", "no", 1, 0)
    assert await ahead_state(remote_exec_engine, "c") == ("waiting", "no", 0, 2)


async def test_requeueing_a_parent_of_a_batch_that_does_not_load_ahead_looks_for_no_claim_ahead(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, remote_exec_engine: AsyncEngine
) -> None:
    statements: list[str] = []

    def executed(conn: Any, cursor: Any, statement: str, *args: Any) -> None:
        statements.append(statement)

    sa.event.listen(remote_exec_engine.sync_engine, "before_cursor_execute", executed)
    batch_id = await submit(http, ["a", "b", "p", "q", "d"], [("b", "a"), ("d", "p"), ("d", "q")])
    await build(http, cache, "a")
    await build(http, cache, "p")
    tokens = await claim_all(http, 2)

    cache.keys -= {ac_key("a"), ac_key("p")}
    missing = result("b", "failed", "input-missing", missing=f"theory {input_key('a')}")
    assert (await complete(http, tokens["b"], missing)).status_code == 200
    cache.keys.add(ac_key("q"))
    assert (await complete(http, tokens["q"], result("q", "built"))).status_code == 200
    await coordinator.released()
    sa.event.remove(remote_exec_engine.sync_engine, "before_cursor_execute", executed)
    assert await states(http, batch_id) == {"a": "ready", "b": "waiting", "p": "ready", "q": "done", "d": "waiting"}
    assert not [statement for statement in statements if "revoked" in statement]


@pytest.mark.parametrize("depth", [1, 2, 8, 0])
async def test_claiming_and_revoking_ahead_read_each_actions_edges_by_key(
    coordinator: Coordinator, remote_exec_engine: AsyncEngine, depth: int
) -> None:
    """Claiming ahead, recounting a parent's children claimed ahead and revoking them read the actions near those
    claimed ahead, by key, however large the batch, even one the database's statistics don't know yet, as after
    every submit (a batch four times as large, read no more than half again as much); at depth 1, a few pages per
    action. Up to 64 actions run claimed ahead, over ``depth`` generations, 8 with no limit."""
    old, small, large = uuid4(), uuid4(), uuid4()
    width, parents = 16, 5
    limit, depth = depth or None, depth or 8

    def layer(n: int) -> list[str]:
        return [f"k{i}" for i in range(n * width, (n + 1) * width)]

    running_ahead = [key for n in range(1, depth) for key in layer(n)[: 64 // (depth - 1)]] or ["k16"]
    children = layer(depth)

    async def add(connection: Any, batch_id: UUID, layers: int) -> None:
        values = {"id": batch_id, "width": width, "parents": parents, "n": width * layers}
        await connection.execute(
            sa.text("INSERT INTO batches (id, state, profile, ahead_cap) VALUES (:id, 'running', 'default', 64)"),
            values,
        )
        await connection.execute(
            sa.text(
                "INSERT INTO actions (batch_id, input_key, ac_key, spec_sha256, theory, remaining_deps, state, tier) "
                "SELECT :id, 'k' || g, 'ac' || g, 's', 'pkg:t' || g, CASE WHEN g < :width THEN 0 ELSE :parents END, "
                "'waiting', 'standard' FROM generate_series(0, :n - 1) g"
            ),
            values,
        )
        await connection.execute(  # each action after the first layer has parents in the layer before it
            sa.text(
                "INSERT INTO edges (batch_id, input_key, parent_key) "
                "SELECT :id, 'k' || g, 'k' || ((g / :width - 1) * :width + (g + p) % :width) "
                "FROM generate_series(:width, :n - 1) g, generate_series(0, :parents - 1) p"
            ),
            values,
        )

    async def run_ahead(connection: Any, batch_id: UUID) -> None:
        """The roots run, and generations below them run claimed ahead."""
        await connection.execute(
            sa.text("UPDATE actions SET state = 'running' WHERE batch_id = :id AND input_key = ANY(:keys)"),
            {"id": batch_id, "keys": layer(0)},
        )
        await connection.execute(
            sa.text("UPDATE actions SET state = 'running', ahead = 'ahead' WHERE batch_id = :id AND input_key = ANY(:keys)"),
            {"id": batch_id, "keys": running_ahead},
        )
        await connection.execute(
            sa.text(
                "INSERT INTO leases (attempt_token, batch_id, input_key, worker, expires_at) "
                "SELECT gen_random_uuid(), :id, k, 'w', now() + interval '1 hour' FROM unnest(CAST(:keys AS text[])) k"
            ),
            {"id": batch_id, "keys": running_ahead},
        )

    async def pages(connection: Any, query: sa.TextClause, parameters: dict[str, object]) -> int:
        plan = await connection.scalar(sa.text(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {query.text}"), parameters)
        return plan[0]["Plan"]["Shared Hit Blocks"] + plan[0]["Plan"]["Shared Read Blocks"]

    async def reads(connection: Any, batch_id: UUID) -> list[int]:
        walk = {"batch_id": batch_id, "keys": children, "depth": limit, "outlined": []}
        return [  # REVOKE_AHEAD last: EXPLAIN ANALYZE runs it
            await pages(
                connection, coordinator_module.CLAIM_AHEAD_ACTION,
                {**walk, "tier": "standard", "taken": [], "outlined_only": False},
            ),
            await pages(connection, coordinator_module.AHEAD_PARENTS, {**walk, "keys": children[:1]}),
            await pages(connection, coordinator_module.REFRESH_AHEAD_CHILDREN, {"batch_id": batch_id, "key": "k0"}),
            await pages(connection, coordinator_module.REVOKE_AHEAD, {"batch_id": batch_id, "keys": ["k0"]}),
        ]

    async with remote_exec_engine.begin() as connection:  # autovacuum can't see this transaction
        await connection.execute(sa.text("SET LOCAL statement_timeout = '10s'"))
        await add(connection, old, 20)
        await connection.execute(sa.text("ANALYZE"))
        await add(connection, small, 20)
        await add(connection, large, 80)
        await run_ahead(connection, small)
        await run_ahead(connection, large)
        small_reads, large_reads = await reads(connection, small), await reads(connection, large)
        for small_read, large_read in zip(small_reads, large_reads, strict=True):
            assert large_read < small_read * 1.5 + 50, (small_reads, large_reads)
        if depth == 1:
            assert max(small_reads) < 50 * width, small_reads
        for batch_id in (small, large):
            assert await connection.scalar(
                sa.text("SELECT ahead FROM actions WHERE batch_id = :id AND input_key = 'k16'"), {"id": batch_id}
            ) == "no"
        await connection.rollback()


async def test_a_better_ranked_waiter_that_cant_claim_ahead_leaves_the_claims_ahead_to_one_that_can(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    await submit(http, ["a", "b"], [("b", "a")], speculative_loading="4")
    await claim_named(http, "a")
    loop = asyncio.get_running_loop()
    plain, capable = loop.create_future(), loop.create_future()
    coordinator.claim_waiters += [
        (["standard"], _claim_rank(["standard"], None), plain, False),  # a warm worker's, ranked first
        (["high", "standard"], _claim_rank(["high", "standard"], "host-b"), capable, True),
    ]

    # A change that may make actions claimable ahead wakes the claim that can take them.
    coordinator._ahead_changed()
    assert not plain.done() and capable.result() == ("standard", True, None, None)
    claimed = await coordinator.claim(["high", "standard"], "burst", host_id="host-c", ahead=True)
    assert claimed is not None and claimed.theory == "pkg:b"


async def test_with_no_depth_limit_revoking_reads_each_ancestor_claimed_ahead_once_however_many_paths_reach_it(
    coordinator: Coordinator, remote_exec_engine: AsyncEngine
) -> None:
    """Each action has its two predecessors as parents, so the number of distances an ancestor is at grows with
    the chain; all but the first were claimed ahead and are done but the last, which runs."""
    batch_id, n = uuid4(), 300
    async with remote_exec_engine.begin() as connection:
        await connection.execute(
            sa.text("INSERT INTO batches (id, state, profile, ahead_cap) VALUES (:id, 'running', 'default', 16)"),
            {"id": batch_id},
        )
        await connection.execute(
            sa.text(
                "INSERT INTO actions (batch_id, input_key, ac_key, spec_sha256, theory, remaining_deps, state, tier, "
                "ahead) SELECT :id, 't' || g, 'ac' || g, 's', 'pkg:t' || g, 0, CASE WHEN g = 0 THEN 'waiting' "
                "WHEN g = :n - 1 THEN 'running' ELSE 'done' END, 'standard', CASE WHEN g = 0 THEN 'no' ELSE 'ahead' "
                "END FROM generate_series(0, :n - 1) g"
            ),
            {"id": batch_id, "n": n},
        )
        await connection.execute(
            sa.text(
                "INSERT INTO edges (batch_id, input_key, parent_key) SELECT :id, 't' || g, 't' || (g - p) "
                "FROM generate_series(1, :n - 1) g, generate_series(1, 2) p WHERE g - p >= 0"
            ),
            {"id": batch_id, "n": n},
        )
        await connection.execute(sa.text("ANALYZE"))
        await connection.execute(sa.text("SET LOCAL statement_timeout = '10s'"))
        plan = await connection.scalar(
            sa.text(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {coordinator_module.REVOKE_AHEAD.text}"),
            {"batch_id": batch_id, "keys": ["t0"]},
        )
        assert plan[0]["Plan"]["Shared Hit Blocks"] + plan[0]["Plan"]["Shared Read Blocks"] < 20 * n
        assert await connection.scalar(
            sa.text("SELECT ahead FROM actions WHERE batch_id = :id AND input_key = :key"),
            {"id": batch_id, "key": f"t{n - 1}"},
        ) == "no"
        await connection.rollback()


async def test_with_no_depth_limit_a_chain_is_claimed_ahead_all_the_way_down(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(coordinator.settings, "ahead_depth", 0)
    names, edges = chain(12)
    await submit(http, names, edges, speculative_loading="16")
    await claim_named(http, "t0")
    for generation in range(1, len(names)):
        claimed = await claim_ahead(http)
        assert claimed is not None and claimed["theory"] == f"pkg:t{generation}"
        assert claimed["ahead_parents"] == ancestors_first(*names[:generation])
    assert await claim_ahead(http) is None


def chain(n: int) -> tuple[list[str], list[tuple[str, str]]]:
    """``n`` actions, each the only parent of the next."""
    names = [f"t{i}" for i in range(n)]
    return names, list(zip(names[1:], names, strict=False))


def ancestors_first(*names: str) -> list[dict[str, str]]:
    return [{"input_key": input_key(n), "spec_sha256": spec(n)} for n in names]


@pytest.mark.parametrize("depth", [2, 4])
async def test_claims_ahead_go_ahead_depth_generations_deep_naming_every_unfinished_ancestor_ancestors_first(
    http: httpx.AsyncClient, coordinator: Coordinator, cache: FakeCache, monkeypatch: pytest.MonkeyPatch, depth: int
) -> None:
    monkeypatch.setattr(coordinator.settings, "ahead_depth", depth)
    names, edges = chain(depth + 2)
    batch_id = await submit(http, names, edges, speculative_loading="16")
    tokens = {"t0": await claim_named(http, "t0")}

    # Each claim ahead below the last generation lets the next one in at once, without waiting for the shared read.
    for generation in range(1, depth + 1):
        claimed = await claim_ahead(http)
        assert claimed is not None and claimed["theory"] == f"pkg:t{generation}"
        assert claimed["ahead_parents"] == ancestors_first(*names[:generation])
        tokens[names[generation]] = claimed["attempt_token"]
    assert await claim_ahead(http) is None

    # Its first ancestor done, the generation after the last may go too.
    cache.keys.add(ac_key("t0"))
    assert (await complete(http, tokens["t0"], result("t0", "built"))).status_code == 200
    claimed = await claim_ahead(http)
    assert claimed is not None and claimed["ahead_parents"] == ancestors_first(*names[1 : depth + 1])
    tokens[names[depth + 1]] = claimed["attempt_token"]

    for name in names[1:]:
        cache.keys.add(ac_key(name))
        assert (await complete(http, tokens[name], result(name, "built"))).status_code == 200
    assert (await batch(http, batch_id))["state"] == "done"


async def test_a_child_waits_ahead_of_a_diamond_only_within_the_depth(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(coordinator.settings, "ahead_depth", 2)
    # "c" has "a" as a parent and as a grandparent through "b": it is two generations after "a".
    await submit(http, ["a", "b", "c", "d"], [("b", "a"), ("c", "a"), ("c", "b"), ("d", "c")], speculative_loading="16")
    await claim_named(http, "a")
    b = await claim_ahead(http)
    assert b is not None and b["theory"] == "pkg:b"
    c = await claim_ahead(http)
    assert c is not None and (c["theory"], c["ahead_parents"]) == ("pkg:c", ancestors_first("a", "b"))
    assert await claim_ahead(http) is None


@pytest.mark.parametrize("depth", [2, 4, 0])
async def test_an_ancestor_back_to_waiting_revokes_a_claim_ahead_across_parents_that_finished(
    http: httpx.AsyncClient, coordinator: Coordinator, cache: FakeCache, remote_exec_engine: AsyncEngine,
    monkeypatch: pytest.MonkeyPatch, depth: int,
) -> None:
    monkeypatch.setattr(coordinator.settings, "ahead_depth", depth)
    names, edges = chain((depth or 4) + 1)
    *ancestors, last = names
    batch_id = await submit(http, names, edges, speculative_loading="16")
    root = await claim_named(http, "t0")
    claims = {}
    for name in names[1:]:
        claimed = await claim_ahead(http)
        assert claimed is not None and claimed["theory"] == f"pkg:{name}"
        claims[name] = claimed["attempt_token"]
    assert claimed["ahead_parents"] == ancestors_first(*ancestors)

    # The parents between finish before the root's result comes, which then fails to publish: the last may hold
    # the root's outputs, which are no one's now, though it has no edge to the root and its parents are done.
    for name in ancestors[1:]:
        cache.keys.add(ac_key(name))
        assert (await complete(http, claims[name], result(name, "built"))).status_code == 200
    assert await ahead_state(remote_exec_engine, last) == ("running", "ahead", 1, 0)
    assert (await complete(http, root, result("t0", "failed", "publish"))).status_code == 200
    assert (await ahead_state(remote_exec_engine, last))[1:3] == ("no", 0)
    assert (await http.post(f"/v1/work/{claims[last]}/heartbeat", headers=WORKER)).status_code == 409
    assert {name: state for name, state in (await states(http, batch_id)).items() if name in ancestors[1:]} == {
        name: "done" for name in ancestors[1:]
    }


@pytest.mark.parametrize("depth", [2, 4])
async def test_an_ancestor_back_to_waiting_revokes_a_claim_ahead_made_after_parents_between_finished_beyond_the_depth(
    http: httpx.AsyncClient, coordinator: Coordinator, cache: FakeCache, remote_exec_engine: AsyncEngine,
    monkeypatch: pytest.MonkeyPatch, depth: int,
) -> None:
    monkeypatch.setattr(coordinator.settings, "ahead_depth", depth)
    names, edges = chain(depth + 2)
    first, *between, last = names[1:]
    await submit(http, names, edges, speculative_loading="16")
    root = await claim_named(http, "t0")
    claims = {}
    for name in [first, *between]:
        claimed = await claim_ahead(http)
        assert claimed is not None and claimed["theory"] == f"pkg:{name}"
        claims[name] = claimed["attempt_token"]
    assert await claim_ahead(http) is None

    # The first claim ahead finishing before the root's result comes makes the next one generation 0, so the last
    # is claimed ahead, more than the depth below the root, whose outputs it may hold through its done ancestors.
    cache.keys.add(ac_key(first))
    assert (await complete(http, claims[first], result(first, "built"))).status_code == 200
    claimed = await claim_ahead(http)
    assert claimed is not None and claimed["theory"] == f"pkg:{last}"
    for name in between:
        cache.keys.add(ac_key(name))
        assert (await complete(http, claims[name], result(name, "built"))).status_code == 200
    assert (await complete(http, root, result("t0", "failed", "publish"))).status_code == 200
    assert (await ahead_state(remote_exec_engine, last))[1:3] == ("no", 0)
    assert (await http.post(f"/v1/work/{claimed['attempt_token']}/heartbeat", headers=WORKER)).status_code == 409


@pytest.mark.parametrize("depth", [2, 4])
async def test_a_claim_ahead_finishing_before_its_parents_frees_its_slot_of_the_cap_for_a_waiting_claim(
    http: httpx.AsyncClient, coordinator: Coordinator, cache: FakeCache, remote_exec_engine: AsyncEngine,
    monkeypatch: pytest.MonkeyPatch, depth: int,
) -> None:
    monkeypatch.setattr(coordinator.settings, "ahead_depth", depth)
    names, edges = chain(depth + 1)
    last = names[-1]
    await submit(http, [*names, "x"], [*edges, ("x", "t0")], speculative_loading=str(depth))
    await claim_named(http, "t0")
    claims = {}
    for name in names[1:]:  # the chain leads; "x" then waits for the cap
        claimed = await claim_ahead(http)
        assert claimed is not None and claimed["theory"] == f"pkg:{name}"
        claims[name] = claimed
    assert await claim_ahead(http) is None

    started = time.monotonic()
    waiting = asyncio.create_task(claim_ahead(http, wait_s=CLAIM_RECHECK_SECONDS * 2))
    await asyncio.sleep(0.2)
    assert not waiting.done()
    cache.keys.add(ac_key(last))
    assert (await complete(http, claims[last]["attempt_token"], result(last, "built"))).status_code == 200
    assert await ahead_state(remote_exec_engine, last) == ("done", "ahead", 1, 1)
    x = await waiting
    assert x is not None and (x["theory"], x["ahead_parents"]) == ("pkg:x", ancestors_first("t0"))
    assert time.monotonic() - started < CLAIM_RECHECK_SECONDS


async def test_a_child_nearer_its_running_ancestors_wakes_a_waiting_claim_ahead_for_its_own_child(
    http: httpx.AsyncClient, coordinator: Coordinator, cache: FakeCache, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(coordinator.settings, "ahead_depth", 2)
    # "c" waits ahead of "a" and "b"; "d" is a generation too far until "a" finishes.
    await submit(
        http, ["a", "b", "c", "d"], [("b", "a"), ("c", "a"), ("c", "b"), ("d", "c")], speculative_loading="16"
    )
    a = await claim_named(http, "a")
    assert await claim_ahead(http) is not None
    assert await claim_ahead(http) is not None
    started = time.monotonic()
    waiting = asyncio.create_task(claim_ahead(http, wait_s=CLAIM_RECHECK_SECONDS * 2))
    await asyncio.sleep(0.2)
    assert not waiting.done()

    cache.keys.add(ac_key("a"))
    assert (await complete(http, a, result("a", "built"))).status_code == 200
    d = await waiting
    assert d is not None and (d["theory"], d["ahead_parents"]) == ("pkg:d", ancestors_first("b", "c"))
    assert time.monotonic() - started < CLAIM_RECHECK_SECONDS


async def test_claiming_ahead_reads_each_ancestors_action_by_key(
    coordinator: Coordinator, remote_exec_engine: AsyncEngine
) -> None:
    """Claiming ahead and naming the parents of what was claimed read each action, the candidates and their
    ancestors, by key, whatever join the database would pick for a batch of 5,000 actions its statistics don't know
    yet: not a scan of every unfinished action of every batch, as when the ancestors were joined with the actions,
    nor of every action of the batch, as when the candidates were read by their batch with their keys as a filter."""
    old, new = uuid4(), uuid4()
    width, parents = 32, 5

    async def add(connection: Any, batch_id: UUID, layers: int) -> None:
        values = {"id": batch_id, "width": width, "parents": parents, "n": width * layers}
        await connection.execute(
            sa.text("INSERT INTO batches (id, state, profile, ahead_cap) VALUES (:id, 'running', 'default', 64)"),
            values,
        )
        await connection.execute(
            sa.text(
                "INSERT INTO actions (batch_id, input_key, ac_key, spec_sha256, theory, remaining_deps, state, tier) "
                "SELECT :id, 'k' || g, 'ac' || g, 's', 'pkg:t' || g, CASE WHEN g < :width THEN 0 ELSE :parents END, "
                "CASE WHEN g < :width THEN 'running' ELSE 'waiting' END, 'standard' FROM generate_series(0, :n - 1) g"
            ),
            values,
        )
        await connection.execute(  # each action after the first layer has parents in the layer before it
            sa.text(
                "INSERT INTO edges (batch_id, input_key, parent_key) "
                "SELECT :id, 'k' || g, 'k' || ((g / :width - 1) * :width + (g + p) % :width) "
                "FROM generate_series(:width, :n - 1) g, generate_series(0, :parents - 1) p"
            ),
            values,
        )

    def actions_read(plan: dict[str, Any]) -> list[str]:
        """How each node of ``plan`` reads actions."""
        here = [f"{plan['Node Type']} {plan.get('Index Cond', '')}"] if plan.get("Relation Name") == "actions" else []
        return here + [read for p in plan.get("Plans", []) for read in actions_read(p)]

    async with remote_exec_engine.begin() as connection:  # autovacuum can't see this transaction
        await connection.execute(sa.text("SET LOCAL statement_timeout = '10s'"))
        await add(connection, old, 40)  # analyzed while it runs, then built
        await connection.execute(sa.text("ANALYZE"))
        await connection.execute(sa.text("UPDATE batches SET state = 'done' WHERE id = :id"), {"id": old})
        await connection.execute(sa.text("UPDATE actions SET state = 'done' WHERE batch_id = :id"), {"id": old})
        await add(connection, new, 157)  # 5,024 actions
        await connection.execute(  # the second layer runs claimed ahead of the first
            sa.text(
                "UPDATE actions SET state = 'running', ahead = 'ahead' "
                "WHERE batch_id = :id AND input_key = ANY(CAST(:keys AS text[]))"
            ),
            {"id": new, "keys": [f"k{i}" for i in range(width, 2 * width)]},
        )
        walk = {"batch_id": new, "keys": [f"k{i}" for i in range(2 * width, 3 * width)], "depth": 2, "outlined": []}
        claiming = (
            coordinator_module.CLAIM_AHEAD_ACTION, {**walk, "tier": "standard", "taken": [], "outlined_only": False}
        )
        naming = (coordinator_module.AHEAD_PARENTS, {**walk, "keys": walk["keys"][:1]})
        # The planner's own choice; nested loops alone; and the join a large history's statistics led to: all the
        # unfinished actions hashed, for a few ancestors. Claiming locks its candidate's row through a join, which
        # only a nested loop reads by key, but which no statistics make cheaper than a probe per candidate.
        for settings, statements in (
            ([], (claiming, naming)),
            (["enable_hashjoin = off", "enable_mergejoin = off"], (claiming, naming)),
            (["enable_hashjoin = on", "enable_mergejoin = on", "enable_nestloop = off"], (naming,)),
        ):
            for setting in settings:
                await connection.execute(sa.text(f"SET LOCAL {setting}"))
            for query, values in statements:
                plan = await connection.scalar(sa.text(f"EXPLAIN (ANALYZE, FORMAT JSON) {query.text}"), values)
                reads = actions_read(plan[0]["Plan"])
                assert reads and all("input_key" in read for read in reads), (settings, reads)
        rows = await connection.execute(coordinator_module.AHEAD_PARENTS, {**walk, "keys": ["k64"]})
        assert [(row.input_key, row.distance) for row in rows] == [
            *((f"k{i}", 2) for i in range(2 * parents - 1)), *((f"k{width + i}", 1) for i in range(parents))
        ]
        await connection.rollback()


async def test_claiming_ahead_passes_over_a_locked_candidate_and_locks_the_one_it_takes(
    coordinator: Coordinator, remote_exec_engine: AsyncEngine
) -> None:
    """Claiming ahead takes the best candidate no other transaction holds, without waiting for one that does, and
    holds the one it takes."""
    batch_id = uuid4()
    async with remote_exec_engine.begin() as connection:  # a running parent with two children, c0 the deeper
        await connection.execute(
            sa.text("INSERT INTO batches (id, state, profile, ahead_cap) VALUES (:id, 'running', 'default', 64)"),
            {"id": batch_id},
        )
        await connection.execute(
            sa.text(
                "INSERT INTO actions (batch_id, input_key, ac_key, spec_sha256, theory, remaining_deps, state, tier, "
                "critical_depth) VALUES (:id, 'p', 'ap', 's', 'pkg:p', 0, 'running', 'standard', 2), "
                "(:id, 'c0', 'a0', 's', 'pkg:c0', 1, 'waiting', 'standard', 1), "
                "(:id, 'c1', 'a1', 's', 'pkg:c1', 1, 'waiting', 'standard', 0)"
            ),
            {"id": batch_id},
        )
        await connection.execute(
            sa.text("INSERT INTO edges (batch_id, input_key, parent_key) VALUES (:id, 'c0', 'p'), (:id, 'c1', 'p')"),
            {"id": batch_id},
        )
    claiming = {
        "batch_id": batch_id, "keys": ["c0", "c1"], "tier": "standard", "depth": 2, "taken": [], "outlined": [],
        "outlined_only": False,
    }
    locking = sa.text("SELECT input_key FROM actions WHERE batch_id = :id AND input_key = :key FOR UPDATE NOWAIT")

    async def claimed() -> str | None:
        async with remote_exec_engine.begin() as connection:
            row = (await connection.execute(coordinator_module.CLAIM_AHEAD_ACTION, claiming)).first()
            await connection.rollback()
        return None if row is None else row.input_key

    assert await claimed() == "c0"
    async with remote_exec_engine.connect() as holder, remote_exec_engine.connect() as claimer:
        await holder.begin()
        await holder.execute(locking, {"id": batch_id, "key": "c0"})
        await claimer.begin()
        await claimer.execute(sa.text("SET LOCAL lock_timeout = '5s'"))
        assert (await claimer.execute(coordinator_module.CLAIM_AHEAD_ACTION, claiming)).scalar() == "c1"
        await holder.rollback()
        await holder.begin()
        with pytest.raises(sa.exc.DBAPIError, match="could not obtain lock"):
            await holder.execute(locking, {"id": batch_id, "key": "c1"})
        await holder.rollback()
        await claimer.rollback()


async def test_reading_the_candidates_reads_each_childs_action_by_key(
    coordinator: Coordinator, remote_exec_engine: AsyncEngine
) -> None:
    """Reading the candidates handles about as many rows as the running parents have edges, even in a batch the
    database's statistics don't know yet, as after every submit: not as many as the waiting actions times the
    children, as when each waiting action was joined with every child."""
    old, new = uuid4(), uuid4()
    width, layers, parents = 32, 40, 5

    async def add(connection: Any, batch_id: UUID) -> None:
        values = {"id": batch_id, "width": width, "parents": parents, "n": width * layers}
        await connection.execute(
            sa.text("INSERT INTO batches (id, state, profile, ahead_cap) VALUES (:id, 'running', 'default', 64)"),
            values,
        )
        await connection.execute(
            sa.text(
                "INSERT INTO actions (batch_id, input_key, ac_key, spec_sha256, theory, remaining_deps, state, tier) "
                "SELECT :id, 'k' || g, 'ac' || g, 's', 'pkg:t' || g, CASE WHEN g < :width THEN 0 ELSE :parents END, "
                "CASE WHEN g < :width THEN 'running' ELSE 'waiting' END, 'standard' FROM generate_series(0, :n - 1) g"
            ),
            values,
        )
        await connection.execute(  # each action after the first layer has parents in the layer before it
            sa.text(
                "INSERT INTO edges (batch_id, input_key, parent_key) "
                "SELECT :id, 'k' || g, 'k' || ((g / :width - 1) * :width + (g + p) % :width) "
                "FROM generate_series(:width, :n - 1) g, generate_series(0, :parents - 1) p"
            ),
            values,
        )

    def handled(plan: dict[str, Any]) -> int:
        return plan["Actual Rows"] * plan["Actual Loops"] + sum(handled(p) for p in plan.get("Plans", []))

    async with remote_exec_engine.begin() as connection:  # autovacuum can't see this transaction
        await connection.execute(sa.text("SET LOCAL statement_timeout = '10s'"))
        await add(connection, old)  # analyzed while it runs, then built
        await connection.execute(sa.text("UPDATE actions SET state = 'running' WHERE batch_id = :id"), {"id": old})
        await connection.execute(sa.text("ANALYZE"))
        await connection.execute(sa.text("UPDATE batches SET state = 'done' WHERE id = :id"), {"id": old})
        await connection.execute(sa.text("UPDATE actions SET state = 'done' WHERE batch_id = :id"), {"id": old})
        await add(connection, new)
        for depth in (1, None):
            query = coordinator_module.AHEAD_CANDIDATES
            plan = await connection.scalar(
                sa.text(f"EXPLAIN (ANALYZE, FORMAT JSON) {query.text}"), {"depth": depth, "outlined": []}
            )
            rows = await connection.execute(query, {"depth": depth, "outlined": []})
            assert {row.input_key for row in rows} == {f"k{i}" for i in range(width, 2 * width)}
            assert handled(plan[0]["Plan"]) < 10 * width * parents
        await connection.rollback()
