import asyncio
import contextlib
import hashlib
import json
import time
from collections.abc import Callable
from typing import Any
from uuid import UUID, uuid4

import httpx
import pytest
import sqlalchemy as sa

from remote_exec import coordinator as coordinator_module
from remote_exec.app import create_app
from remote_exec.coordinator import Coordinator, _claim_rank
from remote_exec.formats import parse_result
from conftest import CLIENT_TOKEN, WORKER_TOKEN, FakeCache, Settled

CLIENT = {"Authorization": f"Bearer {CLIENT_TOKEN}"}
WORKER = {"Authorization": f"Bearer {WORKER_TOKEN}"}


def input_key(name: str) -> str:
    return hashlib.sha256(name.encode()).hexdigest()


def ac_key(name: str) -> str:
    return hashlib.sha256(f"holbuild-remote-ac-v1\n{input_key(name)}\n".encode()).hexdigest()


def spec(name: str) -> str:
    return hashlib.sha256(f"spec {name}".encode()).hexdigest()


def batch_text(names: list[str], edges: list[tuple[str, str]] | None = None) -> str:
    lines = ["holbuild-action-batch-v1"]
    lines += [f"action {input_key(n)} {ac_key(n)} {spec(n)} pkg:{n}" for n in names]
    lines += [f"edge {input_key(child)} {input_key(parent)}" for child, parent in edges or []]
    return "\n".join(lines) + "\n"


def result(name: str, status: str, failure: str | None = None, **extra: str) -> str:
    lines = ["holbuild-action-result-v1", f"spec={spec(name)}", f"input-key={input_key(name)}", f"status={status}"]
    if failure:
        lines.append(f"failure={failure}")
    lines += [f"{k.replace('_', '-')}={v}" for k, v in extra.items()]
    lines += ["wall-ms=10"] + ([] if "detail" in extra else [f"log={'a' * 64} 12"])
    return "\n".join(lines) + "\n"


async def submit(
    http: httpx.AsyncClient, names: list[str], edges: list[tuple[str, str]] | None = None, **params: str
) -> str:
    response = await http.post("/v1/batches", content=batch_text(names, edges), headers=CLIENT, params=params)
    assert response.status_code == 201, response.text
    return response.json()["batch_id"]


async def states(http: httpx.AsyncClient, batch_id: str) -> dict[str, str]:
    response = await http.get(f"/v1/batches/{batch_id}", headers=CLIENT)
    assert response.status_code == 200
    return {a["theory"].removeprefix("pkg:"): a["state"] for a in response.json()["actions"]}


async def batch(http: httpx.AsyncClient, batch_id: str) -> dict[str, Any]:
    return (await http.get(f"/v1/batches/{batch_id}", headers=CLIENT)).json()


async def claim(http: httpx.AsyncClient, tier: str = "standard") -> dict[str, Any] | None:
    response = await http.post("/v1/work/claim", json={"tier": tier, "worker": "w1"}, headers=WORKER)
    if response.status_code == 204:
        return None
    assert response.status_code == 200, response.text
    return response.json()


async def claim_named(http: httpx.AsyncClient, name: str, tier: str = "standard") -> str:
    claimed = await claim(http, tier)
    assert claimed is not None and claimed["theory"] == f"pkg:{name}", claimed
    return claimed["attempt_token"]


async def claim_all(http: httpx.AsyncClient, count: int) -> dict[str, str]:
    """Claim ``count`` actions, in whatever order the coordinator hands them out; their tokens by name."""
    tokens: dict[str, str] = {}
    for _ in range(count):
        claimed = await claim(http)
        assert claimed is not None
        tokens[claimed["theory"].removeprefix("pkg:")] = claimed["attempt_token"]
    return tokens


async def complete(http: httpx.AsyncClient, token: str, record: str) -> httpx.Response:
    return await http.post(f"/v1/work/{token}/complete", content=record, headers=WORKER)


async def build(http: httpx.AsyncClient, cache: FakeCache, name: str) -> None:
    """Claim ``name``, publish it to the fake cache and complete it as built."""
    token = await claim_named(http, name)
    cache.keys.add(ac_key(name))
    assert (await complete(http, token, result(name, "built", peak_rss_mb="100"))).status_code == 200


async def test_submit_makes_roots_ready_and_children_wait(http: httpx.AsyncClient) -> None:
    batch_id = await submit(http, ["a", "b", "c"], [("b", "a"), ("c", "b")])

    assert await states(http, batch_id) == {"a": "ready", "b": "waiting", "c": "waiting"}


async def test_submit_rejects_bad_batches_and_tokens(http: httpx.AsyncClient) -> None:
    bad_edge = batch_text(["a"]) + f"edge {input_key('a')} {input_key('z')}\n"
    cycle = batch_text(["a", "b", "c"], [("b", "a"), ("c", "b"), ("a", "c")])
    for body in ["nonsense\n", bad_edge, batch_text(["a", "a"]), cycle]:
        response = await http.post("/v1/batches", content=body, headers=CLIENT)
        assert response.status_code == 400, body

    assert (await http.post("/v1/batches", content=batch_text(["a"]))).status_code == 401
    assert (await http.post("/v1/batches", content=batch_text(["a"]), headers=WORKER)).status_code == 401
    claim_body = {"tier": "standard", "worker": "w"}
    assert (await http.post("/v1/work/claim", json=claim_body, headers=CLIENT)).status_code == 401


async def test_empty_batch_is_done(http: httpx.AsyncClient) -> None:
    batch_id = await submit(http, [])

    assert (await batch(http, batch_id))["state"] == "done"


async def test_claim_leases_once_and_skips_locked_rows(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: Any
) -> None:
    await submit(http, ["a", "b"])

    async with remote_exec_engine.connect() as blocker, blocker.begin():
        await blocker.execute(
            sa.text("SELECT 1 FROM actions WHERE input_key = :key FOR UPDATE"), {"key": input_key("a")}
        )
        # A claim racing an open transaction on "a" takes "b" instead of waiting.
        assert (await claim(http))["theory"] == "pkg:b"  # pyright: ignore[reportOptionalSubscript]
        assert await claim(http) is None

    assert (await claim(http))["theory"] == "pkg:a"  # pyright: ignore[reportOptionalSubscript]
    assert await claim(http) is None


async def test_one_worker_takes_turns_between_batches(http: httpx.AsyncClient, cache: FakeCache) -> None:
    for prefix in "abc":
        await submit(http, [f"{prefix}1", f"{prefix}2"])

    # With nothing running, the batch that least recently had a claim goes next, not the oldest again.
    for name in ["a1", "b1", "c1", "a2", "b2", "c2"]:
        await build(http, cache, name)


async def test_a_new_batch_goes_ahead_of_a_wide_one_holding_workers(http: httpx.AsyncClient) -> None:
    await submit(http, ["w1", "w2", "w3", "w4"])
    for name in ["w1", "w2", "w3"]:
        await claim_named(http, name)

    await submit(http, ["n1", "n2"])
    await claim_named(http, "n1")
    # The new batch was claimed from last, but it still runs fewer actions.
    await claim_named(http, "n2")
    await claim_named(http, "w4")


async def test_build_claims_share_one_ranking_and_still_spread_over_batches(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Claims within claim_ranking_seconds of a ranking take turns over its batches, as fresh rankings would
    have them, without ranking again; once every batch it ranked is out of ready actions, a claim ranks again, and
    finds the actions made ready since."""
    coordinator.settings.claim_ranking_seconds = 3600
    rankings = 0
    rank = coordinator._rank

    async def counted(conn: Any, key: tuple[str, ...]) -> Any:
        nonlocal rankings
        rankings += 1
        return await rank(conn, key)

    monkeypatch.setattr(coordinator, "_rank", counted)
    await submit(http, ["a1", "a2", "a3"])
    await submit(http, ["b1", "b2"])
    claimed = [(await claim(http))["theory"] for _ in range(5)]
    assert claimed == ["pkg:a1", "pkg:b1", "pkg:a2", "pkg:b2", "pkg:a3"]
    assert rankings == 1
    assert await claim(http) is None
    assert rankings == 2

    # A batch that wasn't ranked drops the ranking as soon as it has a ready action.
    await submit(http, ["c1"])
    assert (await claim(http))["theory"] == "pkg:c1"
    assert rankings == 3


async def test_a_priority_batch_submitted_while_a_ranking_is_shared_is_claimed_next(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Making a batch the shared ranking lacks ready drops the ranking at once, so a priority batch submitted while
    claims share one goes first on the next claim, not once the ranking expires."""
    coordinator.settings.claim_ranking_seconds = 3600
    rankings = 0
    rank = coordinator._rank

    async def counted(conn: Any, key: tuple[str, ...]) -> Any:
        nonlocal rankings
        rankings += 1
        return await rank(conn, key)

    monkeypatch.setattr(coordinator, "_rank", counted)
    await submit(http, ["n1", "n2", "n3"])
    await claim_named(http, "n1")
    await submit(http, ["p1", "p2"], priority="1")
    await claim_named(http, "p1")
    await claim_named(http, "p2")
    await claim_named(http, "n2")
    assert rankings == 2


async def test_a_ranking_read_while_a_release_drops_rankings_is_not_shared(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A ranking whose read overlapped a release that made an unranked batch ready may predate that batch's
    actions, so the claims waiting for it use it once and later claims read again."""
    coordinator.settings.claim_ranking_seconds = 3600
    entered, go = asyncio.Event(), asyncio.Event()
    rank = coordinator._rank

    async def held(conn: Any, key: tuple[str, ...]) -> Any:
        ranking = await rank(conn, key)
        entered.set()
        await go.wait()
        return ranking

    await submit(http, ["a1", "a2"])
    monkeypatch.setattr(coordinator, "_rank", held)
    claiming = asyncio.create_task(claim(http))
    await entered.wait()
    await submit(http, ["b1"])
    go.set()
    assert (await claiming) is not None
    assert coordinator.rankings == {}


async def test_a_claim_after_a_release_does_not_join_a_ranking_read_begun_before_it(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A claim that starts after a release made a priority batch ready reads a ranking of its own rather than
    joining one whose snapshot predates the batch, and so claims the priority batch."""
    coordinator.settings.claim_ranking_seconds = 3600
    entered, go = asyncio.Event(), asyncio.Event()
    calls = 0
    rank = coordinator._rank

    async def first_held(conn: Any, key: tuple[str, ...]) -> Any:
        nonlocal calls
        calls += 1
        ranking = await rank(conn, key)
        if calls == 1:
            entered.set()
            await go.wait()
        return ranking

    await submit(http, ["n1", "n2"])
    monkeypatch.setattr(coordinator, "_rank", first_held)
    early = asyncio.create_task(claim(http))
    await entered.wait()
    await submit(http, ["p1"], priority="1")
    try:
        # Joining the held read would wait for it.
        async with asyncio.timeout(5):
            await claim_named(http, "p1")
    finally:
        go.set()
    assert (await early)["theory"] == "pkg:n1"
    assert calls == 2


async def test_a_claims_own_ranking_read_while_a_release_makes_a_priority_batch_ready_is_not_shared(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A ranking a claim reads for itself, here after the shared read failed, may predate the actions a release
    made ready meanwhile even with no ranking kept to drop, so later claims don't share it and claim the priority
    batch."""
    coordinator.settings.claim_ranking_seconds = 3600
    entered, go = asyncio.Event(), asyncio.Event()
    calls = 0
    rank = coordinator._rank

    async def failing_then_held(conn: Any, key: tuple[str, ...]) -> Any:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise TimeoutError("pool")
        if calls > 2:
            return await rank(conn, key)

        class Slow:
            """The connection, but a statement's result arrives only once go is set, after its snapshot."""

            async def execute(self, *args: Any) -> Any:
                result = await conn.execute(*args)
                entered.set()
                await go.wait()
                return result

        return await rank(Slow(), key)

    await submit(http, ["n1", "n2"])
    monkeypatch.setattr(coordinator, "_rank", failing_then_held)
    early = asyncio.create_task(claim(http))
    await entered.wait()
    await submit(http, ["p1"], priority="1")
    go.set()
    assert (await early)["theory"] == "pkg:n1"
    await claim_named(http, "p1")


async def test_a_claim_ranks_for_itself_when_the_shared_ranking_read_fails(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls = 0
    rank = coordinator._rank

    async def failing_once(conn: Any, key: tuple[str, ...]) -> Any:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise TimeoutError("pool")
        return await rank(conn, key)

    monkeypatch.setattr(coordinator, "_rank", failing_once)
    await submit(http, ["a"])
    await claim_named(http, "a")
    assert calls == 2


async def test_claims_take_the_deepest_then_the_widest_action_of_a_batch_first(
    http: httpx.AsyncClient, remote_exec_engine: Any
) -> None:
    # A diamond d <- l, r <- j, a spine b1 <- b2 <- b3, a fan f <- f1..f4 and a lone a. d and b1 both head two
    # levels of dependents, d three of them (j counted once) and b1 two; f heads one level of four.
    diamond = [("l", "d"), ("r", "d"), ("j", "l"), ("j", "r")]
    spine = [("b2", "b1"), ("b3", "b2")]
    fan = [(f"f{i}", "f") for i in range(1, 5)]
    names = ["a", "d", "j", "l", "r", "b1", "b2", "b3", "f", "f1", "f2", "f3", "f4"]
    await submit(http, names, diamond + spine + fan)

    async with remote_exec_engine.connect() as connection:
        rows = await connection.execute(sa.text("SELECT theory, critical_depth, descendant_count FROM actions"))
        priority = {theory.removeprefix("pkg:"): (depth, count) for theory, depth, count in rows}
    assert priority == {
        "a": (0, 0),
        "d": (2, 3),
        "l": (1, 1),
        "r": (1, 1),
        "j": (0, 0),
        "b1": (2, 2),
        "b2": (1, 1),
        "b3": (0, 0),
        "f": (1, 4),
        **{f"f{i}": (0, 0) for i in range(1, 5)},
    }
    for name in ["d", "b1", "f", "a"]:
        await claim_named(http, name)


async def test_built_parent_releases_child_only_once_its_key_is_in_the_cache(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    batch_id = await submit(http, ["a", "b"], [("b", "a")])

    # "a" reports built but its key isn't in /ac/: it is re-queued, "b" keeps waiting.
    token = await claim_named(http, "a")
    assert (await complete(http, token, result("a", "built"))).status_code == 200
    assert await states(http, batch_id) == {"a": "ready", "b": "waiting"}

    # The cache can't answer: "b" waits for the next sweep.
    token = await claim_named(http, "a")
    cache.keys.add(ac_key("a"))
    cache.broken.add(ac_key("a"))
    assert (await complete(http, token, result("a", "cached"))).status_code == 200
    assert await states(http, batch_id) == {"a": "done", "b": "waiting"}

    cache.broken.clear()
    await coordinator.sweep()
    assert await states(http, batch_id) == {"a": "done", "b": "ready"}

    await build(http, cache, "b")
    assert (await batch(http, batch_id))["state"] == "done"


async def test_child_is_released_only_once_every_parent_key_is_in_the_cache(
    http: httpx.AsyncClient, cache: FakeCache
) -> None:
    batch_id = await submit(http, ["a", "b", "c"], [("c", "a"), ("c", "b")])
    tokens = await claim_all(http, 2)
    cache.keys.add(ac_key("a"))
    assert (await complete(http, tokens["a"], result("a", "built"))).status_code == 200
    # "b" reports built, but only "a" answers HEAD: "c" keeps waiting and "b" is built again.
    assert (await complete(http, tokens["b"], result("b", "built"))).status_code == 200
    assert await states(http, batch_id) == {"a": "done", "b": "ready", "c": "waiting"}

    await build(http, cache, "b")
    assert await states(http, batch_id) == {"a": "done", "b": "done", "c": "ready"}


async def test_a_parent_whose_blob_expired_is_built_again_once_its_child_cant_restore_it(
    http: httpx.AsyncClient, cache: FakeCache
) -> None:
    # The cache holds the entry of "a" (a release asks for nothing more), but one of its blobs has expired, so the
    # worker that runs "b" can't restore "a" and reports it missing.
    batch_id = await submit(http, ["a", "b"], [("b", "a")])
    await build(http, cache, "a")
    assert await states(http, batch_id) == {"a": "done", "b": "ready"}
    token = await claim_named(http, "b")
    record = result("b", "failed", "input-missing", missing=f"theory {input_key('a')}")
    assert (await complete(http, token, record)).status_code == 200
    assert await states(http, batch_id) == {"a": "ready", "b": "waiting"}

    # Building "a" again uploads its blobs again.
    await build(http, cache, "a")
    assert await states(http, batch_id) == {"a": "done", "b": "ready"}
    await build(http, cache, "b")
    assert (await batch(http, batch_id))["state"] == "done"


async def test_a_parent_found_in_the_cache_is_not_asked_about_again_until_an_input_goes_missing(
    http: httpx.AsyncClient, cache: FakeCache
) -> None:
    batch_id = await submit(http, ["a", "b", "c", "d"], [("b", "a"), ("c", "a"), ("c", "b"), ("d", "a"), ("d", "c")])
    await build(http, cache, "a")
    await build(http, cache, "b")
    # Releasing "c" needs "a" again, which was found whole when "b" was released.
    assert cache.asked == [ac_key("a"), ac_key("b")]
    assert await states(http, batch_id) == {"a": "done", "b": "done", "c": "ready", "d": "waiting"}

    # A blob "c" needs expired: it goes back to waiting, and releasing it asks about both its parents again.
    token = await claim_named(http, "c")
    record = result("c", "failed", "input-missing", missing=f"blob {'b' * 64}")
    assert (await complete(http, token, record)).status_code == 200
    assert sorted(cache.asked[2:]) == sorted([ac_key("a"), ac_key("b")])
    await build(http, cache, "c")
    assert cache.asked[4:] == [ac_key("c")]
    assert await states(http, batch_id) == {"a": "done", "b": "done", "c": "done", "d": "ready"}


async def test_concurrent_releases_share_one_check_of_a_parent(cache: FakeCache, coordinator: Coordinator) -> None:
    cache.keys.add(ac_key("a"))
    cache.hold = asyncio.Event()
    checks = [asyncio.create_task(coordinator._in_cache(ac_key("a"), asyncio.Semaphore(1))) for _ in range(5)]
    await asyncio.sleep(0.1)  # every check is waiting on the first one's GET
    cache.hold.set()
    assert await asyncio.gather(*checks) == [True] * 5
    assert cache.asked == [ac_key("a")]


async def test_releases_sharing_a_check_spend_one_request_of_their_limit_on_it(
    cache: FakeCache, coordinator: Coordinator
) -> None:
    cache.keys |= {ac_key("a"), ac_key("b")}
    cache.hold = asyncio.Event()
    limit = asyncio.Semaphore(2)
    # Three releases ask about "a" and one about "b": one request each is in flight, the two the limit allows.
    checks = [asyncio.create_task(coordinator._in_cache_all({ac_key(name)}, limit)) for name in ["a", "a", "a", "b"]]
    await asyncio.wait_for(wait_until(lambda: cache.held == 2), 5)
    cache.hold.set()
    assert [present for check in checks for present in (await check).values()] == [True] * 4
    assert sorted(cache.asked) == sorted([ac_key("a"), ac_key("b")])


async def test_a_check_begun_before_an_input_went_missing_is_not_remembered(
    cache: FakeCache, coordinator: Coordinator
) -> None:
    cache.keys.add(ac_key("a"))
    cache.hold = asyncio.Event()
    check = asyncio.create_task(coordinator._in_cache(ac_key("a"), asyncio.Semaphore(1)))
    await asyncio.sleep(0.1)
    coordinator._forget_cache_findings()  # what an input-missing result does
    cache.hold.set()
    assert await check is True
    assert await coordinator._in_cache(ac_key("a"), asyncio.Semaphore(1)) is True
    assert cache.asked == [ac_key("a"), ac_key("a")]


async def wait_until(condition: Callable[[], bool]) -> None:
    while not condition():
        await asyncio.sleep(0.01)


async def test_a_release_asks_the_cache_about_its_parents_at_once(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    batch_id = await submit(http, ["a", "b", "c"], [("c", "a"), ("c", "b")])
    tokens = await claim_all(http, 2)
    cache.keys |= {ac_key("a"), ac_key("b")}
    cache.hold = asyncio.Event()
    for name in ("a", "b"):
        assert await coordinator.complete(UUID(tokens[name]), parse_result(result(name, "built")))
    try:
        await asyncio.wait_for(wait_until(lambda: cache.held == 2), 5)
    finally:
        cache.hold.set()
    await coordinator.released()
    assert await states(http, batch_id) == {"a": "done", "b": "done", "c": "ready"}


async def stored_state(coordinator: Coordinator, batch_id: str, name: str) -> str | None:
    """The state of action ``name``, read without ``http``, whose requests wait for every release to finish."""
    async with coordinator.engine.connect() as conn:
        return await conn.scalar(
            sa.text("SELECT state FROM actions WHERE batch_id = :batch_id AND input_key = :input_key"),
            {"batch_id": UUID(batch_id), "input_key": input_key(name)},
        )


async def test_a_pass_over_every_batch_releases_each_batch_without_waiting_for_the_others(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    slow = await submit(http, ["a", "ca"], [("ca", "a")])
    quick = await submit(http, ["b", "cb"], [("cb", "b")])
    tokens = await claim_all(http, 2)
    # Both children's parents are done, but the cache can't answer for them yet, so both stay waiting.
    cache.keys |= {ac_key("a"), ac_key("b")}
    cache.broken |= {ac_key("a"), ac_key("b")}
    for name in ("a", "b"):
        assert await coordinator.complete(UUID(tokens[name]), parse_result(result(name, "built")))
    await coordinator.released()

    # The next pass over every batch releases "cb" while the cache is still answering for "ca"'s parent.
    cache.broken.clear()
    cache.hold, cache.hold_only = asyncio.Event(), {ac_key("a")}
    coordinator.request_release()
    try:
        await asyncio.wait_for(wait_until(lambda: cache.held == 1), 5)
        for _ in range(500):
            if await stored_state(coordinator, quick, "cb") == "ready":
                break
            await asyncio.sleep(0.01)
        assert await stored_state(coordinator, quick, "cb") == "ready"
    finally:
        cache.hold.set()
    await coordinator.released()
    assert await states(http, slow) == {"a": "done", "ca": "ready"}


async def test_a_pass_over_every_batch_finishes_the_others_when_one_batch_fails(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    failing = await submit(http, ["x", "cx"], [("cx", "x")])
    held = await submit(http, ["y", "cy"], [("cy", "y")])
    tokens = await claim_all(http, 2)
    cache.keys |= {ac_key("x"), ac_key("y")}
    cache.broken |= {ac_key("x"), ac_key("y")}
    for name in ("x", "y"):
        assert await coordinator.complete(UUID(tokens[name]), parse_result(result(name, "built")))
    await coordinator.released()

    # Writing "cx" ready fails while the cache is still answering for "cy"'s parent.
    lock_batch = coordinator._lock_batch
    failed = asyncio.Event()

    async def fail_one(conn: Any, batch_id: UUID) -> str | None:
        if batch_id == UUID(failing):
            failed.set()
            raise RuntimeError("lost the database")
        return await lock_batch(conn, batch_id)

    monkeypatch.setattr(coordinator, "_lock_batch", fail_one)
    cache.broken.clear()
    cache.hold, cache.hold_only = asyncio.Event(), {ac_key("y")}
    coordinator.request_release()
    released = asyncio.ensure_future(coordinator.released())
    try:
        await asyncio.wait_for(failed.wait(), 5)
        await asyncio.sleep(0.1)
        assert not released.done()
    finally:
        cache.hold.set()
    await asyncio.wait_for(released, 5)
    assert await stored_state(coordinator, held, "cy") == "ready"
    assert await stored_state(coordinator, failing, "cx") == "waiting"


async def test_a_batch_asked_for_is_released_during_a_pass_over_every_batch(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(coordinator_module, "RELEASE_CACHE_CHECKS", 1)
    passed = await submit(http, ["a1", "a2", "ca"], [("ca", "a1"), ("ca", "a2")])
    asked = await submit(http, ["b", "cb"], [("cb", "b")])
    tokens = await claim_all(http, 3)
    # "ca"'s parents are done, but the cache can't answer for them yet, so "ca" stays waiting.
    cache.keys |= {ac_key("a1"), ac_key("a2"), ac_key("b")}
    cache.broken |= {ac_key("a1"), ac_key("a2")}
    for name in ("a1", "a2"):
        assert await coordinator.complete(UUID(tokens[name]), parse_result(result(name, "built")))
    await coordinator.released()
    assert (await states(http, passed))["ca"] == "waiting"

    # A pass over every batch waits on the cache for "ca"'s parents, one at a time, while "b" completes: "cb" is
    # released by the release "b"'s completion asks for, and wouldn't be by the held pass either.
    cache.broken.clear()
    cache.hold, cache.hold_only = asyncio.Event(), {ac_key("a1"), ac_key("a2")}
    coordinator.request_release()
    try:
        await asyncio.wait_for(wait_until(lambda: cache.held == 1), 5)
        assert await coordinator.complete(UUID(tokens["b"]), parse_result(result("b", "built")))
        await asyncio.wait_for(wait_until(lambda: coordinator.releasers[False].done()), 5)
        assert await stored_state(coordinator, asked, "cb") == "ready"
    finally:
        cache.hold.set()
    await coordinator.released()
    assert (await states(http, passed))["ca"] == "ready"


async def test_completions_and_sweeps_answer_while_releases_wait_on_the_cache(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    batch_id = await submit(http, ["a", "b", "c"], [("c", "a"), ("c", "b")])
    tokens = await claim_all(http, 2)
    cache.keys |= {ac_key("a"), ac_key("b")}
    cache.hold = asyncio.Event()

    # Neither the completions nor the sweep wait for the release that asks the held cache about "c"'s parents.
    for name in ("a", "b"):
        completed = coordinator.complete(UUID(tokens[name]), parse_result(result(name, "built")))
        assert await asyncio.wait_for(completed, 5)
    await asyncio.wait_for(coordinator.sweep(), 5)
    assert not all(releaser.done() for releaser in coordinator.releasers.values())

    cache.hold.set()
    await coordinator.released()
    assert await states(http, batch_id) == {"a": "done", "b": "done", "c": "ready"}
    assert sorted(cache.asked) == sorted([ac_key("a"), ac_key("b")])  # the sweep's pass found both remembered


async def test_retried_action_waits_for_a_parent_requeued_while_it_ran(
    http: httpx.AsyncClient, cache: FakeCache
) -> None:
    batch_id = await submit(http, ["a", "b", "c"], [("b", "a"), ("c", "a")])
    await build(http, cache, "a")
    tokens = await claim_all(http, 2)
    token_b, token_c = tokens["b"], tokens["c"]

    # "c" finds "a" evicted, so "a" is built again; "b", still running, then fails to publish.
    cache.keys.discard(ac_key("a"))
    record = result("c", "failed", "input-missing", missing=f"theory {input_key('a')}")
    assert (await complete(http, token_c, record)).status_code == 200
    assert (await complete(http, token_b, result("b", "failed", "publish"))).status_code == 200
    assert await states(http, batch_id) == {"a": "ready", "b": "waiting", "c": "waiting"}

    await build(http, cache, "a")
    assert await states(http, batch_id) == {"a": "done", "b": "ready", "c": "ready"}


async def test_expired_lease_returns_the_action_and_drops_the_old_token(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, remote_exec_engine: Any
) -> None:
    batch_id = await submit(http, ["a"])
    old = await claim_named(http, "a")
    async with remote_exec_engine.begin() as connection:
        await connection.execute(sa.text("UPDATE leases SET expires_at = now() - interval '1 second'"))

    assert (await http.post(f"/v1/work/{old}/heartbeat", headers=WORKER)).status_code == 409
    assert await claim(http) is None  # the sweep, not a claim, returns the action
    await coordinator.sweep()
    new = await claim_named(http, "a")
    assert new != old
    assert (await complete(http, old, result("a", "built"))).status_code == 409
    assert (await http.post(f"/v1/work/{new}/heartbeat", headers=WORKER)).status_code == 200

    cache.keys.add(ac_key("a"))
    assert (await complete(http, new, result("a", "built"))).status_code == 200
    assert (await batch(http, batch_id))["state"] == "done"


async def test_lease_expiring_on_every_attempt_fails_the_batch(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: Any
) -> None:
    batch_id = await submit(http, ["a"])
    for _ in range(3):
        await claim_named(http, "a")
        async with remote_exec_engine.begin() as connection:
            await connection.execute(sa.text("UPDATE leases SET expires_at = now() - interval '1 second'"))
        await coordinator.sweep()

    assert await claim(http) is None
    status = await batch(http, batch_id)
    assert (status["state"], status["failure"]) == ("failed", "pkg:a: lease expired 3 times")


async def test_unknown_token_and_mismatched_result_are_refused(http: httpx.AsyncClient) -> None:
    await submit(http, ["a", "b"])
    token = await claim_named(http, "a")

    assert (await complete(http, str(uuid4()), result("a", "built"))).status_code == 409
    assert (await complete(http, token, result("b", "built"))).status_code == 400
    assert (await complete(http, token, "holbuild-action-result-v1\nstatus=weird\n")).status_code == 400
    assert (await http.post(f"/v1/work/{uuid4()}/heartbeat", headers=WORKER)).status_code == 409


async def test_a_waiting_claim_takes_an_action_that_becomes_ready_meanwhile(
    http: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(coordinator_module, "CLAIM_RECHECK_SECONDS", 60)  # only the wake can end the wait in time
    body = {"tier": "standard", "worker": "w1", "wait_s": 30}
    waiting = asyncio.create_task(http.post("/v1/work/claim", json=body, headers=WORKER))
    await asyncio.sleep(0.5)
    assert not waiting.done()

    await submit(http, ["a"])
    response = await asyncio.wait_for(waiting, 10)
    assert response.status_code == 200, response.text
    assert response.json()["theory"] == "pkg:a"


async def test_an_action_made_ready_wakes_one_of_the_waiting_claims(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(coordinator_module, "CLAIM_RECHECK_SECONDS", 60)  # only wakes end the waits in time
    attempts = 0
    claim_once = coordinator._claim

    async def counted(tiers: list[str], worker: str) -> Any:
        nonlocal attempts
        attempts += 1
        return await claim_once(tiers, worker)

    monkeypatch.setattr(coordinator, "_claim", counted)
    waiting = [asyncio.create_task(coordinator.claim(["standard"], f"w{i}", 30)) for i in range(10)]
    await asyncio.sleep(0.5)
    assert attempts == 10

    await submit(http, ["a"])
    done, pending = await asyncio.wait(waiting, timeout=10, return_when=asyncio.FIRST_COMPLETED)
    assert [task.result().theory for task in done] == ["pkg:a"]
    await asyncio.sleep(0.5)
    assert attempts == 11  # the other nine slept on
    for task in pending:
        task.cancel()
    await asyncio.gather(*pending, return_exceptions=True)


async def test_an_action_made_ready_wakes_a_waiting_claim_that_takes_its_tier(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(coordinator_module, "CLAIM_RECHECK_SECONDS", 60)  # only wakes end the waits in time
    # "a" peaked above the standard tier, so the next batch places it high.
    await submit(http, ["a"])
    token = await claim_named(http, "a")
    cache.keys.add(ac_key("a"))
    assert (await complete(http, token, result("a", "built", peak_rss_mb="5000"))).status_code == 200

    standard = [asyncio.create_task(coordinator.claim(["standard"], f"s{i}", 30)) for i in range(3)]
    await asyncio.sleep(0.2)
    high = asyncio.create_task(coordinator.claim(["high", "standard"], "h", 30))
    await asyncio.sleep(0.2)
    await submit(http, ["a"])
    claimed = await asyncio.wait_for(high, 10)
    assert claimed is not None and claimed.theory == "pkg:a"
    assert not any(task.done() for task in standard)
    for task in standard:
        task.cancel()
    await asyncio.gather(*standard, return_exceptions=True)


async def test_a_woken_claim_cancelled_hands_its_wake_to_the_next(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(coordinator_module, "CLAIM_RECHECK_SECONDS", 60)  # only wakes end the waits in time
    first = asyncio.create_task(coordinator.claim(["standard"], "w1", 30))
    await asyncio.sleep(0.2)
    second = asyncio.create_task(coordinator.claim(["standard"], "w2", 30))
    await asyncio.sleep(0.2)
    claim_once = coordinator._claim
    hold = asyncio.Event()

    async def held(tiers: list[str], worker: str) -> Any:
        if worker == "w1":
            await hold.wait()  # cancelled while trying, after its wake
        return await claim_once(tiers, worker)

    monkeypatch.setattr(coordinator, "_claim", held)
    await submit(http, ["a"])
    await asyncio.sleep(0.2)
    assert not second.done()
    first.cancel()
    claimed = await asyncio.wait_for(second, 10)
    assert claimed is not None and claimed.theory == "pkg:a"
    with contextlib.suppress(asyncio.CancelledError):
        await first


@pytest.mark.parametrize(
    ("tier", "workers", "order"),
    [
        ("standard", [(["high", "standard"], "host-a", 0), (["standard"], "warm", 0)], [1, 0]),
        ("standard", [(["high", "standard"], "host-b", 0), (["high", "standard"], "host-a", 0)], [1, 0]),
        ("high", [(["standard"], "warm", 0), (["high", "standard"], "host-b", 0)], [1]),
        ("high", [(["high"], None, 0), (["high"], "host-a", 0), (["high"], "host-a", 0)], [1, 2, 0]),
        # Lower-rank hosts (an on-demand base) fill before higher-rank ones (spot), whatever their ids.
        ("high", [(["high"], "host-a", 1), (["high"], "host-b", 0), (["high"], None, 0)], [1, 0, 2]),
        (
            "standard",
            [(["high", "standard"], "host-a", 1), (["standard"], "warm", 0), (["high", "standard"], "host-b", 0)],
            [1, 2, 0],
        ),
    ],
)
async def test_wakes_pack_compatible_hosts_with_fifo_ties(
    coordinator: Coordinator, tier: str, workers: list[tuple[list[str], str | None, int]], order: list[int]
) -> None:
    loop = asyncio.get_running_loop()
    wakes = [loop.create_future() for _ in workers]
    coordinator.claim_waiters = [
        (tiers, _claim_rank(tiers, host, rank), wake) for (tiers, host, rank), wake in zip(workers, wakes)
    ]
    cancelled = loop.create_future()
    cancelled.cancel()
    coordinator.claim_waiters.insert(0, ([tier], _claim_rank([tier], "host-0"), cancelled))
    for index in order:
        coordinator._wake_claim(tier)
        assert wakes[index].result() == tier
        assert all(wake.done() == (i in order[:order.index(index) + 1]) for i, wake in enumerate(wakes))
    coordinator._wake_claim(tier)
    assert coordinator.made_ready == len(order) + 1


@pytest.mark.parametrize("waiting_tiers", [["high", "standard"], ["standard"]])
async def test_new_tail_host_claim_defers_ready_work_to_a_better_waiter(
    http: httpx.AsyncClient, coordinator: Coordinator, waiting_tiers: list[str]
) -> None:
    batch_id = await submit(http, ["a"])
    wake = asyncio.get_running_loop().create_future()
    waiter = (waiting_tiers, _claim_rank(waiting_tiers, "host-a"), wake)
    coordinator.claim_waiters.append(waiter)
    assert await coordinator.claim(["high", "standard"], "tail", host_id="host-b") is None
    assert await states(http, batch_id) == {"a": "ready"}
    coordinator.claim_waiters.remove(waiter)
    claimed = await coordinator.claim(waiting_tiers, "preferred", host_id="host-a")
    assert claimed is not None and claimed.theory == "pkg:a"


async def test_rechecking_tail_host_defers_ready_work_to_a_better_waiter(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(coordinator_module, "CLAIM_RECHECK_SECONDS", 0.01)
    attempts = 0
    checks = 0
    batch_id = ""
    claim_once = coordinator._claim
    wake = asyncio.get_running_loop().create_future()
    waiter = (["high", "standard"], _claim_rank(["high", "standard"], "host-a"), wake)

    async def counted(tiers: list[str], worker: str) -> Any:
        nonlocal attempts
        attempts += 1
        return await claim_once(tiers, worker)

    async def disconnected() -> bool:
        nonlocal checks, batch_id
        checks += 1
        if checks == 1:
            # The polling claim has left claim_waiters, so this ready action doesn't wake it.
            batch_id = await submit(http, ["a"])
            coordinator.claim_waiters.append(waiter)
        return checks == 2

    monkeypatch.setattr(coordinator, "_claim", counted)
    assert await coordinator.claim(["high", "standard"], "tail", 10, disconnected, "host-b") is None
    assert checks == 2 and attempts == 1
    assert await states(http, batch_id) == {"a": "ready"}
    coordinator.claim_waiters.remove(waiter)
    claimed = await coordinator.claim(["high", "standard"], "preferred", host_id="host-a")
    assert claimed is not None and claimed.theory == "pkg:a"


async def test_burst_can_claim_high_while_warm_waits_for_standard(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    await submit(http, ["a", "b"])
    async with coordinator.engine.begin() as conn:
        await conn.execute(sa.text("UPDATE actions SET tier = 'high' WHERE theory = 'pkg:b'"))
    wake = asyncio.get_running_loop().create_future()
    coordinator.claim_waiters.append((["standard"], _claim_rank(["standard"], "warm"), wake))
    claimed = await coordinator.claim(["high", "standard"], "burst", host_id="host-a")
    assert claimed is not None and claimed.theory == "pkg:b"
    assert not wake.done()


async def test_explicitly_woken_claim_is_not_blocked_by_a_new_better_waiter(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    await submit(http, ["a"])
    claim_once = coordinator._claim
    attempts = 0

    async def missed(tiers: list[str], worker: str) -> Any:
        nonlocal attempts
        attempts += 1
        return None if attempts == 1 else await claim_once(tiers, worker)

    monkeypatch.setattr(coordinator, "_claim", missed)
    waiting = asyncio.create_task(coordinator.claim(["standard"], "tail", 10, host_id="host-b"))
    try:
        async with asyncio.timeout(5):
            while not coordinator.claim_waiters:
                await asyncio.sleep(0)
        coordinator._wake_claim("standard")
        # A new better waiter must not block the explicit wake before the tail host resumes.
        wake = asyncio.get_running_loop().create_future()
        coordinator.claim_waiters.append((["standard"], _claim_rank(["standard"], "host-a"), wake))
        claimed = await asyncio.wait_for(waiting, 5)
        assert claimed is not None and claimed.theory == "pkg:a"
    finally:
        waiting.cancel()
        await asyncio.gather(waiting, return_exceptions=True)


async def test_a_waiting_claim_whose_worker_left_leases_nothing(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    async def gone() -> bool:
        return True

    waiting = asyncio.create_task(coordinator.claim(["standard"], "w1", 30, gone))
    await asyncio.sleep(0.5)
    batch_id = await submit(http, ["a"])
    assert await asyncio.wait_for(waiting, 10) is None
    assert await states(http, batch_id) == {"a": "ready"}


async def test_a_waiting_claim_finds_an_action_another_coordinator_process_made_ready(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(coordinator_module, "CLAIM_RECHECK_SECONDS", 0.2)
    other = Coordinator(coordinator.engine, coordinator.cache, coordinator.settings)
    waiting = asyncio.create_task(other.claim(["standard"], "w1", 30))
    await asyncio.sleep(0.5)
    await submit(http, ["a"])
    claimed = await asyncio.wait_for(waiting, 10)
    assert claimed is not None and claimed.theory == "pkg:a"


async def test_a_waiting_claim_ends_empty_after_its_wait(http: httpx.AsyncClient) -> None:
    body = {"tier": "standard", "worker": "w1", "wait_s": 0.3}
    response = await http.post("/v1/work/claim", json=body, headers=WORKER)
    assert response.status_code == 204
    body["wait_s"] = 51
    assert (await http.post("/v1/work/claim", json=body, headers=WORKER)).status_code == 422


@pytest.mark.parametrize("classes", [["build"], ["build", "run"], ["run"]])
async def test_a_claim_reads_no_finished_actions(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: Any, classes: list[str]
) -> None:
    """A claim reads the same few pages however many finished actions running and retained batches hold, and
    however many ready actions a batch holds, so claims stay cheap on a busy fleet."""
    await submit(http, ["a"])

    async def pages_read() -> int:
        """Pages read ranking the candidates and locking the first one's first ready action."""
        params = {"tiers": ["standard"], "classes": classes, "run_slots": 30}

        async def explained(statement: sa.TextClause, values: dict[str, object]) -> int:
            plan = await connection.scalar(sa.text(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {statement.text}"), values)
            return plan[0]["Plan"]["Shared Hit Blocks"] + plan[0]["Plan"]["Shared Read Blocks"]

        async with remote_exec_engine.begin() as connection:
            await connection.execute(sa.text("ANALYZE"))
            pages = await explained(coordinator_module.CLAIM_CANDIDATES, params)
            first = (await connection.execute(coordinator_module.CLAIM_CANDIDATES, params)).first()
            if first is not None:
                pages += await explained(
                    coordinator_module.CLAIM_ACTION,
                    {"batch_id": first.batch_id, "class": first.action_class, "tier": first.tier},
                )
            await connection.rollback()
        return pages

    before = await pages_read()
    async with remote_exec_engine.begin() as connection:
        # A running batch's finished actions, and a retained batch's.
        await connection.execute(
            sa.text("INSERT INTO batches (id, state, profile) VALUES (:id, 'done', 'default')"), {"id": uuid4()}
        )
        await connection.execute(
            sa.text(
                "INSERT INTO actions (batch_id, input_key, ac_key, spec_sha256, theory, remaining_deps, state, tier, "
                "last_claimed_at) "
                "SELECT b.id, b.state || g, 'ac', 's', 'pkg:t' || g, 0, 'done', 'standard', now() "
                "FROM batches b, generate_series(1, 20000) g"
            )
        )
        # Many more ready actions of the running batch, of every class.
        await connection.execute(
            sa.text(
                "INSERT INTO actions (batch_id, input_key, ac_key, spec_sha256, theory, remaining_deps, state, tier, "
                "class) "
                "SELECT b.id, 'ready' || g, 'ac', 's', 'pkg:r' || g, 0, 'ready', 'standard', "
                "CASE WHEN g % 2 = 0 THEN 'build' ELSE 'run' END "
                "FROM batches b, generate_series(1, 20000) g WHERE b.state = 'running'"
            )
        )
    assert await pages_read() < before + 20
    assert (await claim(http))["theory"] == "pkg:a"


async def test_the_finished_check_reads_no_finished_actions(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: Any
) -> None:
    """The check after each completion that its batch has nothing unfinished left reads the same few pages however
    many actions the batch finished, wherever its last unfinished action lies, and however many unfinished actions
    other batches hold."""
    batch_id = await submit(http, ["a"])
    other = await submit(http, ["b"])

    async def pages_read() -> int:
        async with remote_exec_engine.begin() as connection:
            await connection.execute(sa.text("ANALYZE"))
            plan = await connection.scalar(
                sa.text(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {coordinator_module.FINISH_IF_DONE.text}"),
                {"id": batch_id},
            )
            await connection.rollback()
        return plan[0]["Plan"]["Shared Hit Blocks"] + plan[0]["Plan"]["Shared Read Blocks"]

    before = await pages_read()
    async with remote_exec_engine.begin() as connection:
        await connection.execute(
            sa.text(
                "INSERT INTO actions (batch_id, input_key, ac_key, spec_sha256, theory, remaining_deps, state, tier) "
                "SELECT :id, '00000000' || g, 'ac', 's', 'pkg:d' || g, 0, 'done', 'standard' "
                "FROM generate_series(1, 20000) g"
            ),
            {"id": batch_id},
        )
        await connection.execute(
            sa.text(
                "INSERT INTO actions (batch_id, input_key, ac_key, spec_sha256, theory, remaining_deps, state, tier) "
                "SELECT :id, 'waiting' || g, 'ac', 's', 'pkg:w' || g, 1, 'waiting', 'standard' "
                "FROM generate_series(1, 20000) g"
            ),
            {"id": other},
        )
    async with remote_exec_engine.begin() as connection:
        # Its one unfinished action now last in every order: the newest row, written last, with the greatest key.
        await connection.execute(
            sa.text("UPDATE actions SET state = 'done' WHERE batch_id = :id AND theory = 'pkg:a'"), {"id": batch_id}
        )
        await connection.execute(
            sa.text(
                "INSERT INTO actions (batch_id, input_key, ac_key, spec_sha256, theory, remaining_deps, state, tier) "
                "VALUES (:id, 'zzzzzzzz', 'ac', 's', 'pkg:z', 0, 'ready', 'standard')"
            ),
            {"id": batch_id},
        )
    assert await pages_read() < before + 20


async def test_releasing_reads_each_selected_actions_edges_by_key(
    coordinator: Coordinator, remote_exec_engine: Any
) -> None:
    """Finding the releasable actions and recounting a completed action's children read a few pages per action,
    even in a batch the database's statistics don't know yet, as after every submit."""
    old, new = uuid4(), uuid4()
    width, layers, parents = 10, 20, 5

    async def add(connection: Any, batch_id: UUID) -> None:
        values = {"id": batch_id, "width": width, "parents": parents, "n": width * layers}
        await connection.execute(
            sa.text("INSERT INTO batches (id, state, profile) VALUES (:id, 'running', 'default')"), values
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

    async with remote_exec_engine.begin() as connection:  # autovacuum can't see this transaction
        await connection.execute(sa.text("SET LOCAL statement_timeout = '10s'"))  # the old plans run for minutes
        await add(connection, old)
        await connection.execute(sa.text("ANALYZE"))
        await add(connection, new)
        roots = [f"k{i}" for i in range(width)]
        await connection.execute(
            sa.text("UPDATE actions SET state = 'done' WHERE batch_id = :id AND input_key = ANY(:keys)"),
            {"id": new, "keys": roots},
        )
        for query, parameters in [
            # Leaves the roots' children releasable, so RELEASABLE looks up their parents.
            (coordinator_module.REFRESH_CHILDREN, {"batch_id": new, "keys": roots}),
            (coordinator_module.RELEASABLE_BATCH, {"batch_id": new}),
        ]:
            plan = await connection.scalar(sa.text(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {query.text}"), parameters)
            pages = plan[0]["Plan"]["Shared Hit Blocks"] + plan[0]["Plan"]["Shared Read Blocks"]
            assert pages < 50 * width, query.text
        releasable = await connection.execute(coordinator_module.RELEASABLE_BATCH, {"batch_id": new})
        children = {f"k{i}": parents for i in range(width, 2 * width)}
        assert {row.input_key: len(row.parents) for row in releasable} == children
        await connection.rollback()


async def test_a_release_pass_over_many_batches_holds_few_transactions_at_once(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, remote_exec_engine: Any,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A pass over every batch writes each batch's releases in its own transaction, but holds at most
    RELEASE_TRANSACTIONS of them at once, so the pass doesn't take every pooled connection."""
    monkeypatch.setattr(coordinator_module, "RELEASE_TRANSACTIONS", 2)
    batch_ids = [await submit(http, ["a", "b"], [("b", "a")]) for _ in range(12)]
    cache.keys.add(ac_key("a"))
    async with remote_exec_engine.begin() as connection:  # every a built, so every b is releasable
        await connection.execute(sa.text("UPDATE actions SET state = 'done' WHERE theory = 'pkg:a'"))
        await connection.execute(sa.text("UPDATE actions SET remaining_deps = 0 WHERE theory = 'pkg:b'"))
    open_now = peak = 0
    lock_batch = coordinator._lock_batch

    async def counted(conn: Any, batch_id: UUID) -> str | None:
        nonlocal open_now, peak
        open_now += 1
        peak = max(peak, open_now)
        try:
            await asyncio.sleep(0.01)
            return await lock_batch(conn, batch_id)
        finally:
            open_now -= 1

    monkeypatch.setattr(coordinator, "_lock_batch", counted)
    await coordinator.release()

    assert peak == 2
    for batch_id in batch_ids:
        assert (await states(http, batch_id))["b"] == "ready"


async def test_memory_failure_moves_to_the_high_tier_and_retries_up_to_max_attempts(
    http: httpx.AsyncClient, cache: FakeCache
) -> None:
    batch_id = await submit(http, ["a"])
    token = await claim_named(http, "a")
    assert (await complete(http, token, result("a", "failed", "memory"))).status_code == 200

    assert await claim(http, "standard") is None
    token = await claim_named(http, "a", "high")
    assert (await complete(http, token, result("a", "failed", "memory"))).status_code == 200
    assert await states(http, batch_id) == {"a": "ready"}
    token = await claim_named(http, "a", "high")
    assert (await complete(http, token, result("a", "failed", "memory"))).status_code == 200
    status = await batch(http, batch_id)
    assert (status["state"], status["failure"]) == ("failed", "pkg:a: memory")

    # The next batch places the theory on the high tier from the start, and a
    # run that takes less memory doesn't lower the hint.
    await submit(http, ["a"])
    assert await claim(http, "standard") is None
    token = await claim_named(http, "a", "high")
    cache.keys.add(ac_key("a"))
    assert (await complete(http, token, result("a", "built", peak_rss_mb="100"))).status_code == 200
    await submit(http, ["a"])
    assert await claim(http, "standard") is None
    await claim_named(http, "a", "high")


async def test_memory_failure_on_the_last_standard_attempt_fails_the_batch(
    http: httpx.AsyncClient, cache: FakeCache
) -> None:
    batch_id = await submit(http, ["a"])
    for _ in range(2):
        token = await claim_named(http, "a")
        assert (await complete(http, token, result("a", "failed", "internal"))).status_code == 200
    token = await claim_named(http, "a")
    assert (await complete(http, token, result("a", "failed", "memory"))).status_code == 200

    status = await batch(http, batch_id)
    assert (status["state"], status["failure"]) == ("failed", "pkg:a: memory")
    assert await claim(http, "high") is None

    # The failure still places the theory on the high tier for the next batch.
    await submit(http, ["a"])
    assert await claim(http, "standard") is None
    await claim_named(http, "a", "high")


async def test_peak_above_the_standard_tier_places_the_next_batch_high(
    http: httpx.AsyncClient, cache: FakeCache
) -> None:
    await submit(http, ["a"], profile="proofs")
    token = await claim_named(http, "a")
    cache.keys.add(ac_key("a"))
    assert (await complete(http, token, result("a", "built", peak_rss_mb="5000"))).status_code == 200

    await submit(http, ["a"], profile="other")
    await claim_named(http, "a", "standard")
    await submit(http, ["a"], profile="proofs")
    assert await claim(http, "standard") is None
    await claim_named(http, "a", "high")


@pytest.mark.parametrize("failure", ["publish", "toolchain", "internal"])
async def test_infrastructure_failures_retry_up_to_max_attempts(http: httpx.AsyncClient, failure: str) -> None:
    batch_id = await submit(http, ["a"])
    for _ in range(2):
        token = await claim_named(http, "a")
        assert (await complete(http, token, result("a", "failed", failure))).status_code == 200
        assert await states(http, batch_id) == {"a": "ready"}

    token = await claim_named(http, "a")
    assert (await complete(http, token, result("a", "failed", failure))).status_code == 200
    status = await batch(http, batch_id)
    assert (status["state"], status["failure"]) == ("failed", f"pkg:a: {failure}")


async def test_an_action_its_worker_could_not_start_is_retried_without_using_an_attempt(
    http: httpx.AsyncClient,
) -> None:
    batch_id = await submit(http, ["a"])
    for _ in range(4):
        token = await claim_named(http, "a")
        assert (await complete(http, token, result("a", "failed", "unavailable"))).status_code == 200
        assert await states(http, batch_id) == {"a": "ready"}

    # Still all three attempts left: the third infrastructure failure is the one that fails the batch.
    for _ in range(2):
        token = await claim_named(http, "a")
        assert (await complete(http, token, result("a", "failed", "internal"))).status_code == 200
        assert await states(http, batch_id) == {"a": "ready"}
    token = await claim_named(http, "a")
    assert (await complete(http, token, result("a", "failed", "internal"))).status_code == 200
    assert (await batch(http, batch_id))["state"] == "failed"


async def test_unavailable_results_past_the_interruption_cap_use_attempts(http: httpx.AsyncClient) -> None:
    batch_id = await submit(http, ["a"])
    # Five refunded interruptions, then two counted ones: the third counted one fails the batch.
    for _ in range(5 + 2):
        token = await claim_named(http, "a")
        assert (await complete(http, token, result("a", "failed", "unavailable"))).status_code == 200
        assert await states(http, batch_id) == {"a": "ready"}
    token = await claim_named(http, "a")
    assert (await complete(http, token, result("a", "failed", "unavailable"))).status_code == 200
    status = await batch(http, batch_id)
    assert (status["state"], status["failure"]) == ("failed", "pkg:a: unavailable")


async def test_disk_failure_retries_once(http: httpx.AsyncClient) -> None:
    batch_id = await submit(http, ["a"])
    token = await claim_named(http, "a")
    assert (await complete(http, token, result("a", "failed", "disk"))).status_code == 200
    assert await states(http, batch_id) == {"a": "ready"}

    token = await claim_named(http, "a")
    assert (await complete(http, token, result("a", "failed", "disk"))).status_code == 200
    assert (await batch(http, batch_id))["state"] == "failed"


def test_a_result_detail_is_read_as_one_line_of_printable_ascii() -> None:
    record = result("a", "failed", "spec-rejected", detail="bad\tspec\u00e9" + "x" * 600)
    assert parse_result(record).detail == "bad spec " + "x" * 491
    assert parse_result(result("a", "failed", "proof")).detail is None


async def test_result_without_an_input_key_is_matched_by_its_spec(http: httpx.AsyncClient) -> None:
    # exec-action leaves input-key empty when it couldn't read the spec.
    batch_id = await submit(http, ["a", "b"], fail_fast="true")
    token = await claim_named(http, "a")
    unread = result("a", "failed", "spec-rejected").replace(f"input-key={input_key('a')}", "input-key=")
    wrong_spec = unread.replace(f"spec={spec('a')}", f"spec={spec('b')}")

    assert (await complete(http, token, wrong_spec)).status_code == 400
    assert (await complete(http, token, unread)).status_code == 200
    assert (await batch(http, batch_id))["failure"] == "pkg:a: spec-rejected"


@pytest.mark.parametrize("failure", ["proof", "tactic-timeout", "spec-rejected"])
async def test_fail_fast_cancels_the_rest(http: httpx.AsyncClient, failure: str) -> None:
    batch_id = await submit(http, ["a", "b", "c"], [("c", "a")], fail_fast="true")
    token_a = await claim_named(http, "a")
    token_b = await claim_named(http, "b")
    assert (await complete(http, token_a, result("a", "failed", failure))).status_code == 200

    status = await batch(http, batch_id)
    assert (status["state"], status["failure"]) == ("failed", f"pkg:a: {failure}")
    assert await states(http, batch_id) == {"a": "failed", "b": "cancelled", "c": "cancelled"}
    assert (await http.post(f"/v1/work/{token_b}/heartbeat", headers=WORKER)).status_code == 409


async def test_independent_failures_and_success_finish_before_the_batch_fails(
    http: httpx.AsyncClient, cache: FakeCache,
) -> None:
    batch_id = await submit(http, ["a", "b", "c", "d", "e", "f"], [("c", "a"), ("d", "c"), ("f", "e")])
    tokens = await claim_all(http, 3)
    assert set(tokens) == {"a", "b", "e"}
    assert (await complete(http, tokens["a"], result("a", "failed", "proof"))).status_code == 200
    assert (await batch(http, batch_id))["state"] == "running"
    assert await states(http, batch_id) == {
        "a": "failed", "b": "running", "c": "cancelled", "d": "cancelled", "e": "running", "f": "waiting",
    }
    assert (await http.post(f"/v1/work/{tokens['b']}/heartbeat", headers=WORKER)).status_code == 200
    assert (await complete(http, tokens["b"], result("b", "failed", "tactic-timeout"))).status_code == 200
    assert (await batch(http, batch_id))["state"] == "running"
    cache.keys.add(ac_key("e"))
    assert (await complete(http, tokens["e"], result("e", "built"))).status_code == 200
    assert (await batch(http, batch_id))["state"] == "running"
    await build(http, cache, "f")
    status = await batch(http, batch_id)
    assert (status["state"], status["failure"]) == ("failed", "pkg:a: proof; pkg:b: tactic-timeout")
    assert await claim(http) is None
    events = [json.loads(line) for line in
              (await http.get(f"/v1/batches/{batch_id}/events", headers=CLIENT)).text.splitlines() if line]
    actions = {e["theory"]: e for e in events if e["type"] == "action"}
    for name in ("a", "b"):
        assert actions[f"pkg:{name}"]["state"] == "failed"
        assert actions[f"pkg:{name}"]["log_sha256"] == "a" * 64
    for name in ("c", "d"):
        assert actions[f"pkg:{name}"]["attempts"] == 0
        assert actions[f"pkg:{name}"]["last_failure"].startswith("skipped because of pkg:a:")
    assert actions["pkg:e"]["state"] == "done"
    assert actions["pkg:f"]["state"] == "done"
    assert cache.keys == {ac_key("e"), ac_key("f")}
    assert events[-1]["state"] == "failed"


async def test_failed_requeued_parent_revokes_running_descendants(
    http: httpx.AsyncClient, cache: FakeCache,
) -> None:
    batch_id = await submit(http, ["a", "b", "c"], [("b", "a"), ("c", "a")])
    await build(http, cache, "a")
    tokens = await claim_all(http, 2)
    cache.keys.discard(ac_key("a"))
    assert (await complete(http, tokens["c"], result("c", "failed", "input-missing",
                           missing=f"theory {input_key('a')}"))).status_code == 200
    retry = await claim_named(http, "a")
    assert (await complete(http, retry, result("a", "failed", "proof"))).status_code == 200
    assert await states(http, batch_id) == {"a": "failed", "b": "cancelled", "c": "cancelled"}
    assert (await http.post(f"/v1/work/{tokens['b']}/heartbeat", headers=WORKER)).status_code == 409
    assert (await complete(http, tokens["b"], result("b", "built"))).status_code == 409
    assert (await batch(http, batch_id))["state"] == "failed"


async def test_missing_failed_parent_skips_the_action_instead_of_waiting_forever(
    http: httpx.AsyncClient,
) -> None:
    batch_id = await submit(http, ["a", "b", "c"], [("c", "b")])
    tokens = await claim_all(http, 2)
    assert (await complete(http, tokens["a"], result("a", "failed", "proof"))).status_code == 200
    assert (await complete(http, tokens["b"], result("b", "failed", "input-missing",
                           missing=f"theory {input_key('a')}"))).status_code == 200
    assert await states(http, batch_id) == {"a": "failed", "b": "cancelled", "c": "cancelled"}
    assert (await batch(http, batch_id))["state"] == "failed"
    assert await claim(http) is None


async def test_a_final_failure_without_a_log_gives_its_detail_in_the_batch_failure(http: httpx.AsyncClient) -> None:
    batch_id = await submit(http, ["a"])
    token = await claim_named(http, "a")
    assert (await complete(http, token, result("a", "failed", "toolchain", detail="clone failed"))).status_code == 200
    assert (await batch(http, batch_id))["actions"][0]["failure_detail"] == "clone failed"

    token = await claim_named(http, "a")
    untrusted = "exec-action HOL repository is not trusted by this worker: https://example.invalid/HOL.git"
    assert (await complete(http, token, result("a", "failed", "spec-rejected", detail=untrusted))).status_code == 200
    status = await batch(http, batch_id)
    assert (status["state"], status["failure"]) == ("failed", f"pkg:a: spec-rejected: {untrusted}")
    [action] = status["actions"]
    assert (action["last_failure"], action["log_sha256"], action["failure_detail"]) == ("spec-rejected", None, untrusted)


async def test_missing_parent_in_the_batch_is_requeued(http: httpx.AsyncClient, cache: FakeCache) -> None:
    batch_id = await submit(http, ["a", "b"], [("b", "a")])
    await build(http, cache, "a")
    token = await claim_named(http, "b")

    cache.keys.discard(ac_key("a"))  # evicted after the readiness check
    record = result("b", "failed", "input-missing", missing=f"theory {input_key('a')}")
    assert (await complete(http, token, record)).status_code == 200
    assert await states(http, batch_id) == {"a": "ready", "b": "waiting"}

    await build(http, cache, "a")
    await build(http, cache, "b")
    assert (await batch(http, batch_id))["state"] == "done"


async def test_missing_transitive_dependency_holds_the_child_until_rebuilt(
    http: httpx.AsyncClient, cache: FakeCache
) -> None:
    batch_id = await submit(http, ["a", "b", "c"], [("b", "a"), ("c", "b")])
    await build(http, cache, "a")
    await build(http, cache, "b")
    token = await claim_named(http, "c")

    cache.keys.discard(ac_key("a"))
    record = result("c", "failed", "input-missing", missing=f"theory {input_key('a')}")
    assert (await complete(http, token, record)).status_code == 200
    assert await states(http, batch_id) == {"a": "ready", "b": "done", "c": "waiting"}

    await build(http, cache, "a")
    await build(http, cache, "c")
    assert (await batch(http, batch_id))["state"] == "done"


async def test_an_edge_added_for_a_missing_theory_raises_its_priority(
    http: httpx.AsyncClient, cache: FakeCache, remote_exec_engine: Any
) -> None:
    batch_id = await submit(http, ["a", "b"])
    await build(http, cache, "a")
    token = await claim_named(http, "b")

    cache.keys.discard(ac_key("a"))
    record = result("b", "failed", "input-missing", missing=f"theory {input_key('a')}")
    assert (await complete(http, token, record)).status_code == 200
    assert await states(http, batch_id) == {"a": "ready", "b": "waiting"}
    async with remote_exec_engine.connect() as connection:
        rows = await connection.execute(sa.text("SELECT theory, critical_depth, descendant_count FROM actions"))
        assert {theory: (depth, count) for theory, depth, count in rows} == {"pkg:a": (1, 1), "pkg:b": (0, 0)}


@pytest.mark.parametrize(
    ("names", "edges", "missing"),
    [(["a"], [], "a"), (["a", "b"], [("b", "a")], "b")],
    ids=["itself", "its dependent"],
)
async def test_an_action_missing_itself_or_its_dependent_is_retried_without_an_edge(
    http: httpx.AsyncClient,
    cache: FakeCache,
    remote_exec_engine: Any,
    names: list[str],
    edges: list[tuple[str, str]],
    missing: str,
) -> None:
    batch_id = await submit(http, names, edges)
    token = await claim_named(http, "a")

    record = result("a", "failed", "input-missing", missing=f"theory {input_key(missing)}")
    assert (await complete(http, token, record)).status_code == 200
    assert (await states(http, batch_id))["a"] == "ready"
    async with remote_exec_engine.connect() as connection:
        stored = set(await connection.execute(sa.text("SELECT input_key, parent_key FROM edges")))
    assert stored == {(input_key(child), input_key(parent)) for child, parent in edges}

    for name in names:
        await build(http, cache, name)
    assert (await batch(http, batch_id))["state"] == "done"


@pytest.mark.parametrize("missing", [f"blob {'b' * 64}", f"theory {input_key('outside')}"])
async def test_other_missing_inputs_retry_then_fail_the_batch_for_resubmission(
    http: httpx.AsyncClient, missing: str
) -> None:
    batch_id = await submit(http, ["a"])
    record = result("a", "failed", "input-missing", missing=missing)
    for _ in range(2):
        token = await claim_named(http, "a")
        assert (await complete(http, token, record)).status_code == 200
        assert await states(http, batch_id) == {"a": "ready"}

    token = await claim_named(http, "a")
    assert (await complete(http, token, record)).status_code == 200
    status = await batch(http, batch_id)
    assert status["state"] == "failed"
    assert status["failure"] == f"resubmit: pkg:a is still missing {missing} after 3 attempts"


async def test_a_rebuilt_theory_still_missing_fails_the_batch_naming_its_key(
    http: httpx.AsyncClient, cache: FakeCache
) -> None:
    batch_id = await submit(http, ["a", "b"], [("b", "a")])
    await build(http, cache, "a")
    record = result("b", "failed", "input-missing", missing=f"theory {input_key('a')}")
    for _ in range(2):
        token = await claim_named(http, "b")
        assert (await complete(http, token, record)).status_code == 200
        await build(http, cache, "a")

    token = await claim_named(http, "b")
    assert (await complete(http, token, record)).status_code == 200
    status = await batch(http, batch_id)
    assert status["state"] == "failed"
    assert status["failure"] == f"resubmit: pkg:b is still missing pkg:a (theory {input_key('a')}) after 3 attempts"


async def test_a_theory_never_in_the_cache_after_it_built_fails_the_batch_naming_its_key(
    http: httpx.AsyncClient,
) -> None:
    batch_id = await submit(http, ["a", "b"], [("b", "a")])
    for _ in range(3):
        token = await claim_named(http, "a")
        assert (await complete(http, token, result("a", "built"))).status_code == 200

    status = await batch(http, batch_id)
    assert status["state"] == "failed"
    assert status["failure"] == f"resubmit: pkg:a (theory {input_key('a')}) is not in the cache after it built"


async def test_cancel_revokes_leases_and_stops_claims(http: httpx.AsyncClient) -> None:
    batch_id = await submit(http, ["a", "b"])
    token = await claim_named(http, "a")

    response = await http.post(f"/v1/batches/{batch_id}/cancel", headers=CLIENT)
    assert response.json() == {"state": "cancelled"}
    assert await states(http, batch_id) == {"a": "cancelled", "b": "cancelled"}
    assert (await http.post(f"/v1/work/{token}/heartbeat", headers=WORKER)).status_code == 409
    assert (await complete(http, token, result("a", "built"))).status_code == 409
    assert await claim(http) is None
    assert (await http.post(f"/v1/batches/{uuid4()}/cancel", headers=CLIENT)).status_code == 404


async def test_events_stream_action_states_then_the_batch(http: httpx.AsyncClient, cache: FakeCache) -> None:
    batch_id = await submit(http, ["a"])
    await build(http, cache, "a")

    async with http.stream("GET", f"/v1/batches/{batch_id}/events", headers=CLIENT) as response:
        events = [json.loads(line) async for line in response.aiter_lines() if line]

    assert [(e["type"], e["state"]) for e in events] == [("action", "done"), ("batch", "done")]
    assert events[0]["log_sha256"] == "a" * 64


async def test_batch_status_shows_each_actions_phase_timings(http: httpx.AsyncClient) -> None:
    batch_id = await submit(http, ["a", "b"])
    token = await claim_named(http, "a")
    assert (await complete(http, token, result("a", "built", phase_ms="hydrate:812,hol:1500"))).status_code == 200

    response = await http.get(f"/v1/batches/{batch_id}", headers=CLIENT)
    timings = {a["theory"].removeprefix("pkg:"): a["timings"] for a in response.json()["actions"]}
    assert timings == {"a": {"hydrate": 812, "hol": 1500, "wall": 10}, "b": None}


async def test_a_malformed_phase_timing_is_refused(http: httpx.AsyncClient) -> None:
    await submit(http, ["a"])
    token = await claim_named(http, "a")
    assert (await complete(http, token, result("a", "built", phase_ms="hydrate"))).status_code == 400


async def test_events_keep_a_quiet_stream_alive_with_blank_lines(
    coordinator: Coordinator, cache: FakeCache, monkeypatch: pytest.MonkeyPatch
) -> None:
    """While nothing changes, a stream sends blank lines, so a proxy doesn't close it as idle."""
    settings = coordinator.settings.model_copy(update={"events_keepalive_seconds": 0.0})
    polls: list[int] = []
    changes = coordinator.changes

    async def counted(batch: UUID, since: int) -> Any:
        polls.append(since)
        return await changes(batch, since)

    monkeypatch.setattr(coordinator, "changes", counted)
    transport = httpx.ASGITransport(app=create_app(coordinator, settings))
    async with httpx.AsyncClient(transport=transport, base_url="http://coordinator.test") as http:
        batch_id = await submit(http, ["a"])

        async def follow() -> list[str]:
            async with http.stream("GET", f"/v1/batches/{batch_id}/events", headers=CLIENT) as response:
                return [line async for line in response.aiter_lines()]

        stream = asyncio.create_task(follow())
        while len(polls) < 3:
            await asyncio.sleep(0.01)
        await build(http, cache, "a")
        lines = await stream

    assert "" in lines
    events = [json.loads(line) for line in lines if line]
    assert events[-1] == {"type": "batch", "state": "done", "failure": None}


async def test_changes_reads_only_the_actions_written_since_the_last_read(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, remote_exec_engine: Any
) -> None:
    """An event stream's polls read what changed since the previous one, including a write that committed after
    a poll began, and not every action of the batch again."""
    batch_id = UUID(await submit(http, ["a", "b"]))

    def names(changed: tuple[Any, int] | None) -> set[str]:
        assert changed is not None
        return {action.theory for action in changed[0].actions}

    first = await coordinator.changes(batch_id, 0)
    assert first is not None and names(first) == {"pkg:a", "pkg:b"}
    assert names(await coordinator.changes(batch_id, first[1])) == set()

    await build(http, cache, "a")
    async with remote_exec_engine.connect() as late:
        await late.execute(
            sa.text("UPDATE actions SET attempts = 1 WHERE batch_id = :id AND theory = 'pkg:b'"), {"id": batch_id}
        )
        during = await coordinator.changes(batch_id, first[1])  # b's write is uncommitted
        assert during is not None and names(during) == {"pkg:a"}
        await late.commit()
    assert names(await coordinator.changes(batch_id, during[1])) == {"pkg:b"}

    async with remote_exec_engine.begin() as connection:  # many settled actions don't make a poll read more
        await connection.execute(
            sa.text(
                "INSERT INTO actions (batch_id, input_key, ac_key, spec_sha256, theory, remaining_deps, state, tier) "
                "SELECT :id, 'k' || g, 'ac', 's', 'pkg:t' || g, 0, 'done', 'standard' FROM generate_series(1, 20000) g"
            ),
            {"id": batch_id},
        )
        await connection.execute(sa.text("ANALYZE actions"))
    settled = await coordinator.changes(batch_id, 0)
    assert settled is not None
    async with remote_exec_engine.begin() as connection:
        plan = await connection.scalar(
            sa.text(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {coordinator_module.CHANGED_ACTIONS.text}"),
            {"batch_id": batch_id, "since": str(settled[1])},
        )
    assert plan[0]["Plan"]["Actual Rows"] == 0
    assert plan[0]["Plan"]["Shared Hit Blocks"] + plan[0]["Plan"]["Shared Read Blocks"] < 20


async def test_event_streams_of_a_large_batch_poll_only_its_changes(
    http: httpx.AsyncClient,
    cache: FakeCache,
    coordinator: Coordinator,
    remote_exec_engine: Any,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Several streams following a batch of 10,000 actions each read the whole batch once, then only the actions
    that change, and still deliver every change."""
    batch_id = await submit(http, ["a", "b"], [("b", "a")])
    async with remote_exec_engine.begin() as connection:
        await connection.execute(
            sa.text(
                "INSERT INTO actions (batch_id, input_key, ac_key, spec_sha256, theory, remaining_deps, state, tier) "
                "SELECT :id, 'k' || g, 'ac', 's', 'pkg:t' || g, 0, 'done', 'standard' FROM generate_series(1, 10000) g"
            ),
            {"id": batch_id},
        )
    reads: list[int] = []
    changes = coordinator.changes

    async def counted(batch: UUID, since: int) -> Any:
        changed = await changes(batch, since)
        reads.append(0 if changed is None else len(changed[0].actions))
        return changed

    monkeypatch.setattr(coordinator, "changes", counted)

    async def follow() -> list[dict[str, Any]]:
        async with http.stream("GET", f"/v1/batches/{batch_id}/events", headers=CLIENT) as response:
            return [json.loads(line) async for line in response.aiter_lines() if line]

    streams = [asyncio.create_task(follow()) for _ in range(3)]
    while len(reads) < 6:  # each stream's full read and its first poll after it
        await asyncio.sleep(0.01)
    await build(http, cache, "a")
    await build(http, cache, "b")
    for events in await asyncio.gather(*streams):
        last = {e["theory"]: e["state"] for e in events if e["type"] == "action"}
        assert (last["pkg:a"], last["pkg:b"], len(last)) == ("done", "done", 10002)
        assert events[-1] == {"type": "batch", "state": "done", "failure": None}
    assert sorted(reads)[-3:] == [10002] * 3  # one full read per stream
    assert sorted(reads)[-4] <= 2  # the rest read a and b at most


async def test_an_event_stream_outlives_a_failed_read_and_resumes_where_it_was(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A read that finds no free database connection doesn't end the stream, which would make its client follow
    the batch again from the start; the next read starts where the failed one would have and gets what changed."""
    sinces: list[int] = []
    changes = coordinator.changes

    async def flaky(batch: UUID, since: int) -> Any:
        sinces.append(since)
        if len(sinces) == 2:  # the stream's first read after the response started
            raise sa.exc.TimeoutError("QueuePool limit of size 50 overflow 0 reached")
        return await changes(batch, since)

    monkeypatch.setattr(coordinator, "changes", flaky)
    batch_id = await submit(http, ["a"])

    async def follow() -> list[dict[str, Any]]:
        async with http.stream("GET", f"/v1/batches/{batch_id}/events", headers=CLIENT) as response:
            assert response.status_code == 200
            return [json.loads(line) async for line in response.aiter_lines() if line]

    stream = asyncio.create_task(follow())
    async with asyncio.timeout(5):
        while len(sinces) < 3:
            assert not stream.done(), stream.exception()
            await asyncio.sleep(0.01)
    await build(http, cache, "a")
    events = await asyncio.wait_for(stream, 5)

    assert sinces[0] == 0 and sinces[1] == sinces[2] != 0
    assert [(e["type"], e["state"]) for e in events if e["type"] == "batch" or e["state"] == "done"] == [
        ("action", "done"),
        ("batch", "done"),
    ]


async def test_an_event_stream_keeps_alive_while_its_reads_keep_failing(
    coordinator: Coordinator, cache: FakeCache, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Reads that each fail after longer than the fallback interval, as pool timeouts do while the database is
    overloaded, still leave room for the keepalive lines, so a proxy doesn't close the stream as idle."""
    settings = coordinator.settings.model_copy(
        update={"events_fallback_seconds": 0.05, "events_keepalive_seconds": 0.1}
    )
    failing = True
    changes = coordinator.changes
    calls = 0

    async def slow_failure(batch: UUID, since: int) -> Any:
        nonlocal calls
        calls += 1
        if calls > 1 and failing:
            await asyncio.sleep(0.06)
            raise sa.exc.TimeoutError("QueuePool limit of size 50 overflow 0 reached")
        return await changes(batch, since)

    monkeypatch.setattr(coordinator, "changes", slow_failure)
    async with httpx.AsyncClient(
        transport=Settled(create_app(coordinator, settings), coordinator), base_url="http://coordinator.test"
    ) as http:
        batch_id = await submit(http, ["a"])
        received: list[str] = []

        async def follow() -> None:
            async with http.stream("GET", f"/v1/batches/{batch_id}/events", headers=CLIENT) as response:
                async for line in response.aiter_lines():
                    received.append(line)

        stream = asyncio.create_task(follow())
        await asyncio.sleep(0.6)
        failing = False
        await build(http, cache, "a")
        await asyncio.wait_for(stream, 5)

    assert received.count("") >= 3
    assert json.loads(received[-1]) == {"type": "batch", "state": "done", "failure": None}


async def test_a_write_wakes_its_batchs_event_streams_and_idle_streams_wait_for_the_fallback(
    coordinator: Coordinator, cache: FakeCache, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A stream reads its batch again as soon as this process writes to it; while nothing is written it waits for
    the fallback read, for other processes' writes, instead of reading every events_poll_seconds."""
    settings = coordinator.settings.model_copy(update={"events_fallback_seconds": 60.0})
    reads = 0
    changes = coordinator.changes

    async def counted(batch: UUID, since: int) -> Any:
        nonlocal reads
        reads += 1
        return await changes(batch, since)

    monkeypatch.setattr(coordinator, "changes", counted)
    async with httpx.AsyncClient(
        transport=Settled(create_app(coordinator, settings), coordinator), base_url="http://coordinator.test"
    ) as http:
        batch_id = await submit(http, ["a"])

        async def follow() -> list[dict[str, Any]]:
            async with http.stream("GET", f"/v1/batches/{batch_id}/events", headers=CLIENT) as response:
                return [json.loads(line) async for line in response.aiter_lines() if line]

        stream = asyncio.create_task(follow())
        async with asyncio.timeout(5):
            while reads < 2:  # the full read, then the one that covers a write before the stream began watching
                await asyncio.sleep(0.01)
        await asyncio.sleep(0.5)
        assert reads == 2
        await build(http, cache, "a")
        events = await asyncio.wait_for(stream, 5)

    assert events[-1] == {"type": "batch", "state": "done", "failure": None}
    assert coordinator.batch_watchers == {}


async def test_a_stream_reads_a_burst_of_writes_at_once_but_steady_writes_at_the_poll_rate(
    coordinator: Coordinator, cache: FakeCache, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The first few writes to a batch reach its stream at once; a batch written to without pause, as a wide build
    is, is read about once every events_poll_seconds, not once per write."""
    settings = coordinator.settings.model_copy(update={
        "events_poll_seconds": 0.5, "events_burst": 3, "events_burst_spacing_seconds": 0.02,
        "events_fallback_seconds": 60.0,
    })
    reads: list[float] = []
    changes = coordinator.changes

    async def counted(batch: UUID, since: int) -> Any:
        reads.append(time.monotonic())
        return await changes(batch, since)

    monkeypatch.setattr(coordinator, "changes", counted)
    async with httpx.AsyncClient(
        transport=Settled(create_app(coordinator, settings), coordinator), base_url="http://coordinator.test"
    ) as http:
        batch_id = await submit(http, ["a"])

        async def follow() -> None:
            async with http.stream("GET", f"/v1/batches/{batch_id}/events", headers=CLIENT) as response:
                async for _ in response.aiter_lines():
                    pass

        stream = asyncio.create_task(follow())
        async with asyncio.timeout(5):
            while len(reads) < 2:  # the full read, then the one for a write before the stream began watching
                await asyncio.sleep(0.005)
        started = time.monotonic()
        while time.monotonic() - started < 2.0:
            coordinator._batch_changed(UUID(batch_id))
            await asyncio.sleep(0.005)
        during = [t for t in reads[2:] if t >= started]
        # The bucket held one read after the first two: then one every 0.5 s.
        assert during and during[0] - started < 0.2
        assert len(during) <= 1 + 2.0 / 0.5 + 1
        stream.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await stream


async def test_a_request_that_finds_no_free_database_connection_answers_503(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def busy(batch: UUID, since: int) -> Any:
        raise sa.exc.TimeoutError("QueuePool limit of size 50 overflow 0 reached")

    monkeypatch.setattr(coordinator, "changes", busy)
    response = await http.get(f"/v1/batches/{uuid4()}/events", headers=CLIENT)

    assert (response.status_code, response.json()) == (503, {"detail": "database busy"})
    assert response.headers["Retry-After"] == "5"


@pytest.mark.parametrize("operation", ["submit", "retention"])
async def test_peak_hint_writers_lock_in_key_order(
    http: httpx.AsyncClient, coordinator: Coordinator, operation: str,
) -> None:
    # A heap scan meets b before a; another transaction holds a and then needs b.
    async with coordinator.engine.begin() as connection:
        await connection.execute(sa.text(
            "INSERT INTO peak_hints (package, theory, profile, peak_rss_mb, updated_at) VALUES "
            "('pkg', 'b', 'p', 100, now() - interval '90 days'), "
            "('pkg', 'a', 'p', 100, now() - interval '90 days'), "
            "('pkg', 'a', 'other', 9000, now() - interval '2 days')"
        ))

    def heap_scan(connection: Any) -> None:
        connection.exec_driver_sql("SET LOCAL enable_indexscan = off")
        connection.exec_driver_sql("SET LOCAL enable_bitmapscan = off")

    sa.event.listen(coordinator.engine.sync_engine, "begin", heap_scan)
    writer: asyncio.Task[Any] | None = None
    try:
        async with coordinator.engine.begin() as blocker:
            pid = await blocker.scalar(sa.text("SELECT pg_backend_pid()"))
            await blocker.execute(sa.text(
                "SELECT 1 FROM peak_hints WHERE package = 'pkg' AND theory = 'a' AND profile = 'p' FOR UPDATE"
            ))
            writer = asyncio.create_task(
                submit(http, ["b", "a"], profile="p") if operation == "submit" else coordinator.delete_expired()
            )
            async with asyncio.timeout(5):
                async with coordinator.engine.connect() as observer:
                    while not await observer.scalar(sa.text(
                        "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE :pid = ANY(pg_blocking_pids(pid)))"
                    ), {"pid": pid}):
                        await asyncio.sleep(0.01)
            # This forms a deadlock if the writer locked b before waiting for a.
            await blocker.execute(sa.text(
                "UPDATE peak_hints SET peak_rss_mb = 6000, updated_at = now() "
                "WHERE package = 'pkg' AND theory = 'b' AND profile = 'p'"
            ))
            if operation == "retention":
                await blocker.execute(sa.text(
                    "UPDATE peak_hints SET updated_at = now() "
                    "WHERE package = 'pkg' AND theory = 'a' AND profile = 'p'"
                ))
        await asyncio.wait_for(writer, 5)
    finally:
        sa.event.remove(coordinator.engine.sync_engine, "begin", heap_scan)
        if writer is not None:
            writer.cancel()
            await asyncio.gather(writer, return_exceptions=True)

    async with coordinator.engine.connect() as connection:
        hints = await connection.execute(sa.text(
            "SELECT theory, profile, peak_rss_mb, updated_at > now() - interval '1 day' "
            "FROM peak_hints ORDER BY theory, profile"
        ))
        assert list(hints) == [("a", "other", 9000, False), ("a", "p", 100, True), ("b", "p", 6000, True)]
        if operation == "submit":
            tiers = await connection.execute(sa.text("SELECT theory, tier FROM actions ORDER BY theory"))
            assert list(tiers) == [("pkg:a", "standard"), ("pkg:b", "high")]


async def test_retention_deletes_old_terminal_batches_and_stale_hints(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, remote_exec_engine: Any
) -> None:
    old_done = await submit(http, ["a"])
    await build(http, cache, "a")
    recent_done = await submit(http, [])
    async with remote_exec_engine.begin() as connection:
        await connection.execute(
            sa.text("UPDATE batches SET created_at = now() - interval '30 days' WHERE id <> :recent"),
            {"recent": UUID(recent_done)},
        )
        await connection.execute(sa.text("UPDATE peak_hints SET updated_at = now() - interval '90 days'"))

    await coordinator.sweep()

    assert (await http.get(f"/v1/batches/{old_done}", headers=CLIENT)).status_code == 404
    assert (await batch(http, recent_done))["state"] == "done"
    async with remote_exec_engine.connect() as connection:
        assert await connection.scalar(sa.text("SELECT count(*) FROM peak_hints")) == 0
        assert await connection.scalar(sa.text("SELECT count(*) FROM actions")) == 0


async def test_batches_past_the_deadline_fail_and_then_expire(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: Any
) -> None:
    # A high-tier action no worker takes would keep its batch running forever.
    overdue = await submit(http, ["a", "b"])
    token = await claim_named(http, "a")
    current = await submit(http, ["c"])
    async with remote_exec_engine.begin() as connection:
        await connection.execute(
            sa.text("UPDATE batches SET created_at = now() - interval '13 hours' WHERE id = :id"), {"id": UUID(overdue)}
        )

    await coordinator.sweep()

    status = await batch(http, overdue)
    assert (status["state"], status["failure"]) == ("failed", "deadline: still running after 12 h")
    assert await states(http, overdue) == {"a": "cancelled", "b": "cancelled"}
    assert (await http.post(f"/v1/work/{token}/heartbeat", headers=WORKER)).status_code == 409
    assert (await batch(http, current))["state"] == "running"

    async with remote_exec_engine.begin() as connection:
        await connection.execute(
            sa.text("UPDATE batches SET created_at = now() - interval '30 days' WHERE id = :id"), {"id": UUID(overdue)}
        )
    await coordinator.sweep()
    assert (await http.get(f"/v1/batches/{overdue}", headers=CLIENT)).status_code == 404


async def test_batch_class_defaults_to_build_and_rejects_unknown_classes(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    await submit(http, ["a"])
    await submit(http, ["b"], **{"class": "run"})
    async with coordinator.engine.connect() as connection:
        rows = await connection.execute(sa.text("SELECT theory, class FROM actions ORDER BY theory"))
        assert list(rows) == [("pkg:a", "build"), ("pkg:b", "run")]
    response = await http.post("/v1/batches?class=other", content=batch_text(["c"]), headers=CLIENT)
    assert response.status_code == 422


async def test_run_batches_reject_dependency_edges_before_storing_actions(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    response = await http.post(
        "/v1/batches?class=run", content=batch_text(["a", "b"], [("b", "a")]), headers=CLIENT
    )
    assert response.status_code == 400
    assert "dependency edges are not allowed" in response.json()["detail"]
    async with coordinator.engine.connect() as connection:
        assert await connection.scalar(sa.text("SELECT count(*) FROM batches")) == 0
    await submit(http, ["a", "b"], [("b", "a")])


async def test_builds_beat_older_runs_across_all_accepted_tiers(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    await submit(http, ["run"], **{"class": "run"})
    async with coordinator.engine.begin() as connection:
        await connection.execute(sa.text("UPDATE actions SET tier = 'high'"))
    await submit(http, ["build"])
    body = {"tier": "high", "also_claim": ["standard"], "worker": "w"}
    assert (await http.post("/v1/work/claim", json=body, headers=WORKER)).json()["theory"] == "pkg:build"
    assert (await http.post("/v1/work/claim", json=body, headers=WORKER)).json()["theory"] == "pkg:run"


async def test_run_slots_span_batches_and_free_on_completion(http: httpx.AsyncClient, coordinator: Coordinator) -> None:
    coordinator.settings.run_slots = 2
    for name in ("a", "b", "c"):
        await submit(http, [name], **{"class": "run"})
    token = await claim_named(http, "a")
    await claim_named(http, "b")
    assert await claim(http) is None
    assert (await complete(http, token, result("a", "built"))).status_code == 200
    await claim_named(http, "c")


async def test_run_floor_precedes_builds_then_keeps_the_idle_run_fallback(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    coordinator.settings.run_floor = 1
    coordinator.settings.run_slots = 2
    await submit(http, ["build"])
    await submit(http, ["run-a", "run-b", "run-c"], **{"class": "run"})
    token = await claim_named(http, "run-a")
    await claim_named(http, "build")
    await claim_named(http, "run-b")
    assert await claim(http) is None
    await complete(http, token, result("run-a", "built"))
    await claim_named(http, "run-c")


@pytest.mark.parametrize("run_slots", [0, 2])
async def test_run_floor_is_clamped_to_run_slots(
    http: httpx.AsyncClient, coordinator: Coordinator, run_slots: int
) -> None:
    coordinator.settings.run_floor = 5
    coordinator.settings.run_slots = run_slots
    await submit(http, ["build"])
    await submit(http, ["run-a", "run-b", "run-c"], **{"class": "run"})
    for name in ["run-a", "run-b"][:run_slots]:
        await claim_named(http, name)
    await claim_named(http, "build")
    assert await claim(http) is None


@pytest.mark.parametrize("floor", [1, 5])
async def test_concurrent_coordinators_recheck_the_run_floor_under_the_admission_lock(
    http: httpx.AsyncClient, coordinator: Coordinator, floor: int
) -> None:
    coordinator.settings.run_floor = floor
    coordinator.settings.run_slots = 2
    replica = Coordinator(coordinator.engine, coordinator.cache, coordinator.settings)
    await submit(http, [f"build{i}" for i in range(24)])
    for i in range(4):
        await submit(http, [f"run{i}"], **{"class": "run"})
    claims = await asyncio.gather(*((coordinator, replica)[i % 2].claim(["standard"], f"w{i}") for i in range(12)))
    assert all(c is not None for c in claims)
    assert sum(c.theory.startswith("pkg:run") for c in claims if c is not None) == min(floor, 2)


@pytest.mark.parametrize("runs", ["absent", "other-tier", "floor-full"])
async def test_run_floor_precheck_keeps_build_claims_off_the_admission_lock(
    http: httpx.AsyncClient, coordinator: Coordinator, runs: str
) -> None:
    coordinator.settings.run_floor = 4
    if runs != "absent":
        await submit(http, [f"run{i:03}" for i in range(200)], **{"class": "run"})
        if runs == "other-tier":
            async with coordinator.engine.begin() as connection:
                await connection.execute(sa.text("UPDATE actions SET tier = 'high'"))
        else:
            for i in range(4):
                await claim_named(http, f"run{i:03}")
    await submit(http, ["build"])

    def before_execute(_: object, __: object, statement: str, *args: object) -> None:
        assert "pg_advisory_xact_lock" not in statement

    async with coordinator.engine.begin() as blocker:
        await blocker.execute(sa.text("SELECT pg_advisory_xact_lock(1752132706, 1)"))
        sa.event.listen(coordinator.engine.sync_engine, "before_cursor_execute", before_execute)
        try:
            await asyncio.wait_for(claim_named(http, "build"), 2)
        finally:
            sa.event.remove(coordinator.engine.sync_engine, "before_cursor_execute", before_execute)


async def test_zero_run_slots_pauses_runs_and_keeps_builds_claimable(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    coordinator.settings.run_slots = 0
    await submit(http, ["run"], **{"class": "run"})
    assert await claim(http) is None
    await submit(http, ["build"])
    await claim_named(http, "build")
    assert await claim(http) is None


async def test_concurrent_claims_on_separate_coordinators_cannot_exceed_run_slots(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    coordinator.settings.run_slots = 2
    replica = Coordinator(coordinator.engine, coordinator.cache, coordinator.settings)
    for i in range(4):
        await submit(http, [f"r{i}a", f"r{i}b", f"r{i}c"], **{"class": "run"})
    claims = await asyncio.gather(*((coordinator, replica)[i % 2].claim(["standard"], f"worker{i}") for i in range(12)))
    assert sum(c is not None for c in claims) == 2
    async with coordinator.engine.connect() as connection:
        assert await connection.scalar(sa.text("SELECT count(*) FROM actions WHERE state = 'running'")) == 2


async def test_a_build_claim_does_not_wait_for_run_admission(http: httpx.AsyncClient, coordinator: Coordinator) -> None:
    await submit(http, ["run"], **{"class": "run"})
    acquiring = asyncio.Event()

    def before_execute(_: object, __: object, statement: str, *args: object) -> None:
        if "pg_advisory_xact_lock" in statement:
            acquiring.set()

    async with coordinator.engine.begin() as blocker:
        await blocker.execute(sa.text("SELECT pg_advisory_xact_lock(1752132706, 1)"))
        sa.event.listen(coordinator.engine.sync_engine, "before_cursor_execute", before_execute)
        waiting = asyncio.create_task(coordinator.claim(["standard"], "run-worker"))
        try:
            await asyncio.wait_for(acquiring.wait(), 2)
            await submit(http, ["build"])
            await asyncio.wait_for(claim_named(http, "build"), 2)
        finally:
            sa.event.remove(coordinator.engine.sync_engine, "before_cursor_execute", before_execute)
            waiting.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await waiting


@pytest.mark.parametrize("failure", ["script", "timeout", "spec-rejected", "internal", "disk", "memory"])
@pytest.mark.parametrize("failed_first", [True, False])
async def test_final_run_failure_is_independent_and_visible_in_events(
    http: httpx.AsyncClient, coordinator: Coordinator, failure: str, failed_first: bool
) -> None:
    coordinator.settings.max_attempts = 1
    batch_id = await submit(http, ["a", "b"], **{"class": "run"})
    if failure == "memory":
        async with coordinator.engine.begin() as connection:
            await connection.execute(sa.text("UPDATE actions SET tier = 'high' WHERE theory = 'pkg:a'"))
    a = await claim_named(http, "a", "high" if failure == "memory" else "standard")
    b = await claim_named(http, "b")
    completions = [(a, result("a", "failed", failure)), (b, result("b", "built"))]
    if not failed_first:
        completions.reverse()
    assert (await complete(http, *completions[0])).status_code == 200
    assert (await batch(http, batch_id))["state"] == "running"
    assert (await complete(http, *completions[1])).status_code == 200
    status = await batch(http, batch_id)
    assert (status["state"], status["failure"]) == ("done", None)
    assert await states(http, batch_id) == {"a": "failed", "b": "done"}
    events = [
        json.loads(line)
        for line in (await http.get(f"/v1/batches/{batch_id}/events", headers=CLIENT)).text.splitlines()
        if line
    ]
    assert next(e for e in events if e.get("theory") == "pkg:a")["last_failure"] == failure
    assert events[-1] == {"type": "batch", "state": "done", "failure": None}


async def test_a_failed_run_without_a_log_gives_its_detail_in_events(http: httpx.AsyncClient) -> None:
    batch_id = await submit(http, ["a"], **{"class": "run"})
    token = await claim_named(http, "a")
    rejected = "the run-loads do not match the run text"
    assert (await complete(http, token, result("a", "failed", "spec-rejected", detail=rejected))).status_code == 200
    events = [
        json.loads(line)
        for line in (await http.get(f"/v1/batches/{batch_id}/events", headers=CLIENT)).text.splitlines()
        if line
    ]
    action = next(e for e in events if e.get("theory") == "pkg:a")
    assert (action["state"], action["last_failure"], action["failure_detail"]) == ("failed", "spec-rejected", rejected)
    assert events[-1] == {"type": "batch", "state": "done", "failure": None}


async def test_expired_run_attempt_fails_only_its_action(http: httpx.AsyncClient, coordinator: Coordinator) -> None:
    coordinator.settings.max_attempts = 2
    batch_id = await submit(http, ["a", "b"], **{"class": "run"})
    token = await claim_named(http, "a")
    assert (await complete(http, token, result("a", "failed", "toolchain", detail="clone failed"))).status_code == 200
    await claim_named(http, "a")
    async with coordinator.engine.begin() as connection:
        await connection.execute(sa.text("UPDATE leases SET expires_at = now() - interval '1 second'"))
    await coordinator.expire_leases()
    status = await batch(http, batch_id)
    assert status["state"] == "running"
    assert await states(http, batch_id) == {"a": "failed", "b": "ready"}
    assert (status["actions"][0]["last_failure"], status["actions"][0]["failure_detail"]) == ("internal", None)
    b = await claim_named(http, "b")
    assert (await complete(http, b, result("b", "built"))).status_code == 200
    assert (await batch(http, batch_id))["state"] == "done"


async def test_run_resubmit_and_deadline_still_end_the_batch(http: httpx.AsyncClient, coordinator: Coordinator) -> None:
    coordinator.settings.max_attempts = 1
    batch_id = await submit(http, ["a", "b"], **{"class": "run"})
    a = await claim_named(http, "a")
    assert (await complete(http, a, result("a", "failed", "input-missing"))).status_code == 200
    status = await batch(http, batch_id)
    assert status["state"] == "failed" and status["failure"].startswith("resubmit:")
    assert await states(http, batch_id) == {"a": "failed", "b": "cancelled"}
    overdue = await submit(http, ["c", "d"], **{"class": "run"})
    async with coordinator.engine.begin() as connection:
        await connection.execute(sa.text("UPDATE batches SET created_at = now() - interval '1 day'"))
    await coordinator.fail_overdue()
    status = await batch(http, overdue)
    assert status["state"] == "failed" and status["failure"].startswith("deadline:")
    assert await states(http, overdue) == {"c": "cancelled", "d": "cancelled"}


async def test_run_memory_failure_uses_the_existing_profile_hint_and_high_tier(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    batch_id = await submit(http, ["a"], profile="scripts", **{"class": "run"})
    a = await claim_named(http, "a")
    assert (await complete(http, a, result("a", "failed", "memory"))).status_code == 200
    assert await claim(http) is None
    a = await claim_named(http, "a", "high")
    assert (await complete(http, a, result("a", "built"))).status_code == 200
    assert (await batch(http, batch_id))["state"] == "done"
    await submit(http, ["a"], profile="scripts", **{"class": "run"})
    await submit(http, ["b"], profile="other", **{"class": "run"})
    await claim_named(http, "b")
    assert await claim(http) is None
    await claim_named(http, "a", "high")


async def test_cached_targets_submitted_for_execution_still_run_and_return_the_new_log(
    http: httpx.AsyncClient, cache: FakeCache,
) -> None:
    # Force/trace clients deliberately submit actions whose entries exist.
    # The coordinator must wait for the worker, including a forced parent.
    cache.keys.update([ac_key("a"), ac_key("b")])
    batch_id = await submit(http, ["a", "b"], [("b", "a")])
    token = await claim_named(http, "a")
    assert await claim(http) is None
    assert await states(http, batch_id) == {"a": "running", "b": "waiting"}
    assert (await complete(http, token, result("a", "built"))).status_code == 200
    token = await claim_named(http, "b")
    record = result("b", "built").replace("log=" + "a" * 64, "log=" + "b" * 64)
    assert (await complete(http, token, record)).status_code == 200
    async with http.stream("GET", f"/v1/batches/{batch_id}/events", headers=CLIENT) as response:
        events = [json.loads(line) async for line in response.aiter_lines() if line]
    actions = {e["theory"]: e for e in events if e["type"] == "action"}
    assert events[-1]["state"] == "done"
    assert actions["pkg:a"]["log_sha256"] == "a" * 64
    assert actions["pkg:b"]["log_sha256"] == "b" * 64
    assert all(a["state"] == "done" and a["attempts"] == 1 for a in actions.values())


async def test_cache_ring_routes_digests_independently_of_configuration_order(coordinator: Coordinator) -> None:
    from remote_exec.cache import cache_nodes, ranked_nodes

    nodes = ["http://one.test/cache", "http://two.test/cache"]
    assert cache_nodes(f" {nodes[0]}///, {nodes[1]}/ {nodes[0]} ") == nodes
    asked: list[str] = []

    def answer(request: httpx.Request) -> httpx.Response:
        asked.append(str(request.url))
        return httpx.Response(200)

    owners = set()
    async with httpx.AsyncClient(transport=httpx.MockTransport(answer)) as client:
        ring = Coordinator(coordinator.engine, client, coordinator.settings)
        for i in range(32):
            digest = input_key(str(i))
            expected = max(nodes, key=lambda node: hashlib.sha256(f"{node}:{digest}".encode()).hexdigest())
            owners.add(expected)
            assert ranked_nodes(nodes, digest) == ranked_nodes(list(reversed(nodes)), digest)
            for order in (nodes, list(reversed(nodes))):
                ring.cache_nodes = order
                assert await ring._check_cache(digest, asyncio.Semaphore(1)) is True
                assert asked[-1] == f"{expected}/ac/{digest}"
    assert owners == set(nodes)
    assert len(asked) == 64  # successful primary reads never contact a backup


@pytest.mark.parametrize("primary", [404, 503, 429, "connection", "timeout"])
@pytest.mark.parametrize("secondary", [200, 404, 503, 403, "connection"])
async def test_cache_ring_read_fallback(
    coordinator: Coordinator, primary: int | str, secondary: int | str, caplog: pytest.LogCaptureFixture
) -> None:
    from remote_exec.cache import ranked_nodes

    digest = input_key("handoff")
    nodes = ["http://one.test", "http://two.test", "http://three.test"]
    ranked = ranked_nodes(nodes, digest)
    asked: list[str] = []

    def answer(request: httpx.Request) -> httpx.Response:
        node = str(request.url).removesuffix(f"/ac/{digest}")
        asked.append(node)
        if node == ranked[0]:
            if primary == "connection":
                raise httpx.ConnectError("unreachable", request=request)
            if primary == "timeout":
                raise httpx.ReadTimeout("timeout", request=request)
            return httpx.Response(primary)
        if secondary == "connection":
            raise httpx.ConnectError("unreachable", request=request)
        return httpx.Response(secondary)

    async with httpx.AsyncClient(transport=httpx.MockTransport(answer)) as client:
        ring = Coordinator(coordinator.engine, client, coordinator.settings)
        ring.cache_nodes = nodes
        result = await ring._check_cache(digest, asyncio.Semaphore(1))
    expected = (True if secondary == 200 else None if secondary == 403
                else False if 404 in (primary, secondary) else None)
    assert result is expected
    assert asked == ranked[:2]
    if expected is not None:
        assert not caplog.records
    else:
        status = secondary if isinstance(secondary, int) else primary
        if isinstance(status, int):
            assert f"answered {status}" in caplog.text
    assert (digest in ring.found_in_cache) == (expected is True)


async def test_cache_ring_does_not_retry_authorization_errors(coordinator: Coordinator) -> None:
    asked = []

    def answer(request: httpx.Request) -> httpx.Response:
        asked.append(request)
        return httpx.Response(401)

    async with httpx.AsyncClient(transport=httpx.MockTransport(answer)) as client:
        ring = Coordinator(coordinator.engine, client, coordinator.settings)
        ring.cache_nodes = ["http://one.test", "http://two.test"]
        assert await ring._check_cache(input_key("secret"), asyncio.Semaphore(1)) is None
    assert len(asked) == 1


def test_cache_ring_settings_accept_both_environment_names(monkeypatch: pytest.MonkeyPatch) -> None:
    from remote_exec.coordinator import Settings

    monkeypatch.setenv("CACHE_URL", "http://stray.test")
    monkeypatch.delenv("REMOTE_EXEC_CACHE_URL", raising=False)
    monkeypatch.setenv("HOLBUILD_REMOTE_CACHE_URL", "http://one.test/,http://two.test/,http://one.test")
    args = dict(database_url="unused", client_token="client", worker_token="worker")
    assert Settings(**args).cache_url == "http://one.test,http://two.test"
    monkeypatch.setenv("REMOTE_EXEC_CACHE_URL", "http://explicit.test/")
    assert Settings(**args).cache_url == "http://explicit.test"
    assert Settings(**args, cache_url="http://argument.test/").cache_url == "http://argument.test"
    monkeypatch.delenv("REMOTE_EXEC_CACHE_URL")
    monkeypatch.delenv("HOLBUILD_REMOTE_CACHE_URL")
    with pytest.raises(ValueError, match="remote cache URL must not be empty"):
        Settings(**args)


@pytest.mark.parametrize(("cache_url", "slot", "error"), [
    ("http://ci:secret@one.test", "http://two.test", "without credentials"),
    ("https://one.test", "http://two.test", "mix"),
    ("http://one.test", "https://two.test", "mix"),
])
def test_plain_http_slots_refuse_credentials_and_mixed_schemes(cache_url: str, slot: str, error: str) -> None:
    from remote_exec.coordinator import Settings

    args = dict(database_url="unused", client_token="client", worker_token="worker", cache_url=cache_url)
    with pytest.raises(ValueError, match=error):
        Settings(**args, cache_slots=[{"name": "two", "url": slot}])


def test_plain_http_slots_accept_a_credential_free_http_pool() -> None:
    from remote_exec.coordinator import Settings

    args = dict(database_url="unused", client_token="client", worker_token="worker")
    assert Settings(**args, cache_url="http://one.test", cache_slots=[{"name": "two", "url": "http://two.test"}])
    assert Settings(**args, cache_url="https://ci:secret@one.test",
                    cache_slots=[{"name": "two", "url": "https://two.test"}])
    assert Settings(**args, cache_url="http://ci:secret@one.test")


def test_cache_ring_identity_ignores_credentials_but_preserves_request_urls() -> None:
    from remote_exec.cache import cache_nodes, node_identity, ranked_nodes

    bare = ["https://one.test/path", "https://two.test/path"]
    authenticated = [url.replace("://", "://user:pass@") for url in bare]
    assert cache_nodes(",".join([*authenticated, *bare])) == authenticated
    assert node_identity("http://u:p@ss@[::1]:8080/path@name") == "http://[::1]:8080/path@name"
    assert node_identity("http://host?name@value") == "http://host?name@value"
    assert node_identity("http://host#name@value") == "http://host#name@value"
    for i in range(32):
        digest = input_key(str(i))
        assert ranked_nodes(authenticated, digest) == [
            url.replace("://", "://user:pass@") for url in ranked_nodes(bare, digest)
        ]


@pytest.mark.parametrize("action_class", ["build", "run"])
@pytest.mark.parametrize("max_heap_mb", [None, 4096, 16000])
async def test_claim_carries_its_batch_heap_limit(
    http: httpx.AsyncClient, action_class: str, max_heap_mb: int | None
) -> None:
    params = {"class": action_class}
    if max_heap_mb is not None:
        params["max_heap_mb"] = str(max_heap_mb)
    await submit(http, ["A", "B"], **params)
    first, second = await claim(http), await claim(http)
    assert first is not None and second is not None
    assert first["max_heap_mb"] == second["max_heap_mb"] == max_heap_mb


@pytest.mark.parametrize("value", ["0", "-1", "bad", "2147483648"])
async def test_submit_rejects_invalid_heap_limit(http: httpx.AsyncClient, value: str) -> None:
    response = await http.post(
        "/v1/batches", params={"max_heap_mb": value}, content=batch_text(["A"]), headers=CLIENT
    )
    assert response.status_code == 422
    assert await claim(http) is None


async def test_priority_precedes_batch_fair_share_and_preserves_equal_priority_turns(http: httpx.AsyncClient) -> None:
    await submit(http, ["normal"])
    await submit(http, ["p11", "p12", "p13"], priority="1")
    await submit(http, ["p21", "p22"], priority="1")
    await claim_named(http, "p11")
    await claim_named(http, "p21")
    await claim_named(http, "p12")
    await claim_named(http, "p22")
    # Priority still wins with three running actions, ahead of a normal batch with none.
    await claim_named(http, "p13")
    await claim_named(http, "normal")


async def test_normal_build_progresses_while_priority_chain_waits_for_its_parent(http: httpx.AsyncClient) -> None:
    await submit(http, ["normal1", "normal2"])
    await submit(http, ["parent", "child"], [("child", "parent")], priority="1")
    await claim_named(http, "parent")
    await claim_named(http, "normal1")
    await claim_named(http, "normal2")
    assert await claim(http) is None


async def test_priority_does_not_override_memory_tier_or_action_class(
    http: httpx.AsyncClient, remote_exec_engine: Any
) -> None:
    await submit(http, ["high"])
    await submit(http, ["priority"], priority="1")
    await submit(http, ["run"], **{"class": "run", "priority": "100"})
    async with remote_exec_engine.begin() as conn:
        await conn.execute(sa.text("UPDATE actions SET tier = 'high' WHERE theory = 'pkg:high'"))
    response = await http.post(
        "/v1/work/claim", headers=WORKER,
        json={"tier": "high", "also_claim": ["standard"], "worker": "w1"},
    )
    assert response.status_code == 200, response.text
    assert response.json()["theory"] == "pkg:high"
    await claim_named(http, "priority")
    await claim_named(http, "run")


@pytest.mark.parametrize("value", [None, "0", "2147483647"])
async def test_missing_priority_defaults_to_zero_and_valid_values_are_stored(
    http: httpx.AsyncClient, remote_exec_engine: Any, value: str | None
) -> None:
    batch_id = await submit(http, ["a"], **({} if value is None else {"priority": value}))
    async with remote_exec_engine.connect() as conn:
        actual = await conn.scalar(sa.text("SELECT priority FROM batches WHERE id = :id"), {"id": UUID(batch_id)})
    assert actual == (0 if value is None else int(value))


@pytest.mark.parametrize("value", ["-1", "2147483648", "1.5", "urgent", ""])
async def test_invalid_priority_is_rejected(http: httpx.AsyncClient, value: str) -> None:
    response = await http.post("/v1/batches", headers=CLIENT, content=batch_text(["a"]), params={"priority": value})
    assert response.status_code == 422


async def test_queue_reports_priority_subsets_without_double_counting(http: httpx.AsyncClient) -> None:
    await submit(http, ["normal"])
    await submit(http, ["p1", "p2", "child"], [("child", "p1")], priority="1")
    await claim_named(http, "p1")
    queue = (await http.get("/v1/queue", headers=CLIENT)).json()
    assert (queue["ready_priority"], queue["running_priority"]) == (1, 1)
    assert (queue["ready_standard"], queue["running_standard"], queue["waiting"]) == (2, 1, 1)
