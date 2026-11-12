"""Claims ahead of running parents, for batches submitted with ``speculative_loading``."""

import asyncio
import time
from typing import Any
from uuid import UUID, uuid4

import httpx
import pytest
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncEngine

from conftest import FakeCache
from remote_exec import coordinator as coordinator_module
from remote_exec.coordinator import CLAIM_RECHECK_SECONDS, Coordinator, _claim_rank
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
    for value in ["0", "17", "x"]:
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
    assert (queue["running_standard"], queue["waiting_ahead_standard"]) == (2, 1)
    async with coordinator.engine.connect() as conn:
        active = await coordinator._counts(conn, coordinator_module.COUNT_ACTIVE)
    assert (active.running_standard, active.waiting_ahead_standard) == (2, 1)
    assert coordinator_module.burst_demand(active, warm_workers=1, max_burst_workers=16) == 0

    cache.keys.add(ac_key("a"))
    assert (await complete(http, a, result("a", "built"))).status_code == 200
    queue = (await http.get("/v1/queue", headers=CLIENT)).json()
    assert (queue["running_standard"], queue["waiting_ahead_standard"]) == (1, 0)


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
    http: httpx.AsyncClient, cache: FakeCache, remote_exec_engine: AsyncEngine
) -> None:
    await submit(http, ["a", "b", "c"], [("b", "a"), ("c", "b")], speculative_loading="4")
    a = await claim_named(http, "a")
    b = await claim_ahead(http)
    assert b is not None
    cache.keys.add(ac_key("a"))
    assert (await complete(http, a, result("a", "built"))).status_code == 200
    c = await claim_ahead(http)
    assert c is not None and c["theory"] == "pkg:c"

    # "b" gives up loading ahead; "c" can't get its parent's outputs before "b" is claimed again.
    assert (await complete(http, b["attempt_token"], result("b", "failed", "ahead-abandoned"))).status_code == 200
    assert await ahead_state(remote_exec_engine, "c") == ("waiting", "abandoned", 0, 1)
    assert (await http.post(f"/v1/work/{c['attempt_token']}/heartbeat", headers=WORKER)).status_code == 409


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


async def test_a_parent_evicted_before_a_release_revokes_the_child_claimed_ahead_as_abandoned(
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
    assert await ahead_state(remote_exec_engine, "c") == ("waiting", "abandoned", 0, 2)


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


async def test_claiming_and_revoking_ahead_read_each_actions_edges_by_key(
    coordinator: Coordinator, remote_exec_engine: AsyncEngine
) -> None:
    """Claiming ahead, recounting a parent's children claimed ahead and revoking them read a few pages per action,
    even in a batch the database's statistics don't know yet, as after every submit."""
    old, new = uuid4(), uuid4()
    width, layers, parents = 10, 20, 5

    async def add(connection: Any, batch_id: UUID) -> None:
        values = {"id": batch_id, "width": width, "parents": parents, "n": width * layers}
        await connection.execute(
            sa.text("INSERT INTO batches (id, state, profile, ahead_cap) VALUES (:id, 'running', 'default', 4)"), values
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

    async def pages(connection: Any, query: sa.TextClause, parameters: dict[str, object]) -> int:
        plan = await connection.scalar(sa.text(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {query.text}"), parameters)
        return plan[0]["Plan"]["Shared Hit Blocks"] + plan[0]["Plan"]["Shared Read Blocks"]

    roots = [f"k{i}" for i in range(width)]
    children = [f"k{i}" for i in range(width, 2 * width)]
    async with remote_exec_engine.begin() as connection:  # autovacuum can't see this transaction
        await connection.execute(sa.text("SET LOCAL statement_timeout = '10s'"))
        await add(connection, old)
        await connection.execute(sa.text("ANALYZE"))
        await add(connection, new)
        # The roots run, and a child of theirs runs claimed ahead of them.
        await connection.execute(
            sa.text("UPDATE actions SET state = 'running' WHERE batch_id = :id AND input_key = ANY(:keys)"),
            {"id": new, "keys": roots},
        )
        await connection.execute(
            sa.text("UPDATE actions SET state = 'running', ahead = 'ahead' WHERE batch_id = :id AND input_key = 'k10'"),
            {"id": new},
        )
        await connection.execute(
            sa.text(
                "INSERT INTO leases (attempt_token, batch_id, input_key, worker, expires_at) "
                "VALUES (:token, :id, 'k10', 'w', now() + interval '1 hour')"
            ),
            {"token": uuid4(), "id": new},
        )
        for query, parameters in [
            (coordinator_module.CLAIM_AHEAD_ACTION, {"batch_id": new, "keys": children, "tier": "standard"}),
            (coordinator_module.REFRESH_AHEAD_CHILDREN, {"batch_id": new, "key": "k0"}),
            (coordinator_module.REVOKE_AHEAD, {"batch_id": new, "keys": ["k0"]}),
        ]:
            assert await pages(connection, query, parameters) < 50 * width, query.text
        assert await connection.scalar(
            sa.text("SELECT ahead FROM actions WHERE batch_id = :id AND input_key = 'k10'"), {"id": new}
        ) == "abandoned"
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
    assert not plain.done() and capable.result() == ("standard", True)
    claimed = await coordinator.claim(["high", "standard"], "burst", host_id="host-c", ahead=True)
    assert claimed is not None and claimed.theory == "pkg:b"
