import asyncio
import contextlib
import hashlib
import json
from typing import Any
from uuid import UUID, uuid4

import httpx
import pytest
import sqlalchemy as sa

from remote_exec import coordinator as coordinator_module
from remote_exec.app import create_app
from remote_exec.coordinator import Coordinator
from remote_exec.formats import parse_result
from conftest import CLIENT_TOKEN, WORKER_TOKEN, FakeCache, entry_blob

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
    lines += ["wall-ms=10", f"log={'a' * 64} 12"]
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


async def test_a_parent_whose_blob_expired_is_built_again_before_its_child_is_released(
    http: httpx.AsyncClient, cache: FakeCache
) -> None:
    batch_id = await submit(http, ["a", "b"], [("b", "a")])
    token = await claim_named(http, "a")
    cache.keys.add(ac_key("a"))
    cache.lost.add(ac_key("a"))
    assert (await complete(http, token, result("a", "built"))).status_code == 200
    assert await states(http, batch_id) == {"a": "ready", "b": "waiting"}

    cache.lost.clear()
    await build(http, cache, "a")
    assert await states(http, batch_id) == {"a": "done", "b": "ready"}


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


async def test_a_remembered_parent_whose_blob_expired_is_built_again_once_a_child_misses_it(
    http: httpx.AsyncClient, cache: FakeCache
) -> None:
    batch_id = await submit(http, ["a", "b", "c"], [("b", "a"), ("c", "a")])
    await build(http, cache, "a")
    assert await states(http, batch_id) == {"a": "done", "b": "ready", "c": "ready"}

    # A blob of "a" expires after it was found whole; "b" can't restore it.
    cache.lost.add(ac_key("a"))
    token = await claim_named(http, "b")
    record = result("b", "failed", "input-missing", missing=f"blob {entry_blob(ac_key('a'))}")
    assert (await complete(http, token, record)).status_code == 200
    assert (await states(http, batch_id))["a"] == "ready"
    assert (await states(http, batch_id))["b"] == "waiting"

    cache.lost.clear()
    await build(http, cache, "a")
    assert (await states(http, batch_id))["b"] == "ready"


async def test_concurrent_releases_share_one_check_of_a_parent(cache: FakeCache, coordinator: Coordinator) -> None:
    cache.keys.add(ac_key("a"))
    cache.hold = asyncio.Event()
    checks = [asyncio.create_task(coordinator._in_cache(ac_key("a"))) for _ in range(5)]
    await asyncio.sleep(0.1)  # every check is waiting on the first one's GET
    cache.hold.set()
    assert await asyncio.gather(*checks) == [True] * 5
    assert cache.asked == [ac_key("a")]


async def test_a_check_begun_before_an_input_went_missing_is_not_remembered(
    cache: FakeCache, coordinator: Coordinator
) -> None:
    cache.keys.add(ac_key("a"))
    cache.hold = asyncio.Event()
    check = asyncio.create_task(coordinator._in_cache(ac_key("a")))
    await asyncio.sleep(0.1)
    coordinator._forget_cache_findings()  # what an input-missing result does
    cache.hold.set()
    assert await check is True
    assert await coordinator._in_cache(ac_key("a")) is True
    assert cache.asked == [ac_key("a"), ac_key("a")]


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
    assert coordinator.releaser is not None and not coordinator.releaser.done()

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


async def test_a_claim_reads_no_finished_actions(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: Any
) -> None:
    """A claim reads the same few pages however many finished actions running and retained batches hold, so
    claims stay cheap on a busy fleet."""
    await submit(http, ["a"])

    async def pages_read() -> int:
        async with remote_exec_engine.begin() as connection:
            await connection.execute(sa.text("ANALYZE"))
            plan = await connection.scalar(
                sa.text(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {coordinator_module.CLAIM.text}"),
                {"tiers": ["standard"]},
            )
            await connection.rollback()
        return plan[0]["Plan"]["Shared Hit Blocks"] + plan[0]["Plan"]["Shared Read Blocks"]

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
    assert await pages_read() < before + 20
    assert (await claim(http))["theory"] == "pkg:a"


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
            (coordinator_module.RELEASABLE, {"batch_id": new}),
        ]:
            plan = await connection.scalar(sa.text(f"EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {query.text}"), parameters)
            pages = plan[0]["Plan"]["Shared Hit Blocks"] + plan[0]["Plan"]["Shared Read Blocks"]
            assert pages < 50 * width, query.text
        releasable = await connection.execute(coordinator_module.RELEASABLE, {"batch_id": new})
        children = {f"k{i}": parents for i in range(width, 2 * width)}
        assert {row.input_key: len(row.parents) for row in releasable} == children
        await connection.rollback()


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


async def test_disk_failure_retries_once(http: httpx.AsyncClient) -> None:
    batch_id = await submit(http, ["a"])
    token = await claim_named(http, "a")
    assert (await complete(http, token, result("a", "failed", "disk"))).status_code == 200
    assert await states(http, batch_id) == {"a": "ready"}

    token = await claim_named(http, "a")
    assert (await complete(http, token, result("a", "failed", "disk"))).status_code == 200
    assert (await batch(http, batch_id))["state"] == "failed"


async def test_result_without_an_input_key_is_matched_by_its_spec(http: httpx.AsyncClient) -> None:
    # exec-action leaves input-key empty when it couldn't read the spec.
    batch_id = await submit(http, ["a", "b"])
    token = await claim_named(http, "a")
    unread = result("a", "failed", "spec-rejected").replace(f"input-key={input_key('a')}", "input-key=")
    wrong_spec = unread.replace(f"spec={spec('a')}", f"spec={spec('b')}")

    assert (await complete(http, token, wrong_spec)).status_code == 400
    assert (await complete(http, token, unread)).status_code == 200
    assert (await batch(http, batch_id))["failure"] == "pkg:a: spec-rejected"


@pytest.mark.parametrize("failure", ["proof", "tactic-timeout", "spec-rejected"])
async def test_final_failures_fail_the_batch_and_cancel_the_rest(http: httpx.AsyncClient, failure: str) -> None:
    batch_id = await submit(http, ["a", "b", "c"], [("c", "a")])
    token_a = await claim_named(http, "a")
    token_b = await claim_named(http, "b")
    assert (await complete(http, token_a, result("a", "failed", failure))).status_code == 200

    status = await batch(http, batch_id)
    assert (status["state"], status["failure"]) == ("failed", f"pkg:a: {failure}")
    assert await states(http, batch_id) == {"a": "failed", "b": "cancelled", "c": "cancelled"}
    assert (await http.post(f"/v1/work/{token_b}/heartbeat", headers=WORKER)).status_code == 409


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
