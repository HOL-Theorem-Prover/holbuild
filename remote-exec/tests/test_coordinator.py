import hashlib
import json
from typing import Any
from uuid import UUID, uuid4

import httpx
import pytest
import sqlalchemy as sa

from remote_exec.coordinator import Coordinator
from conftest import CLIENT_TOKEN, WORKER_TOKEN, FakeCache

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


async def test_memory_failure_retries_once_on_the_high_tier_and_records_the_hint(http: httpx.AsyncClient) -> None:
    batch_id = await submit(http, ["a"])
    token = await claim_named(http, "a")
    assert (await complete(http, token, result("a", "failed", "memory"))).status_code == 200

    assert await claim(http, "standard") is None
    token = await claim_named(http, "a", "high")
    assert (await complete(http, token, result("a", "failed", "memory"))).status_code == 200
    status = await batch(http, batch_id)
    assert (status["state"], status["failure"]) == ("failed", "pkg:a: memory")

    # The next batch places the theory on the high tier from the start.
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


@pytest.mark.parametrize("failure", ["publish", "toolchain"])
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


@pytest.mark.parametrize("failure", ["proof", "tactic-timeout", "spec-rejected", "internal"])
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


@pytest.mark.parametrize("missing", [f"blob {'b' * 64}", f"theory {input_key('outside')}"])
async def test_other_missing_inputs_fail_the_batch_for_resubmission(http: httpx.AsyncClient, missing: str) -> None:
    batch_id = await submit(http, ["a"])
    token = await claim_named(http, "a")
    record = result("a", "failed", "input-missing", missing=missing)
    assert (await complete(http, token, record)).status_code == 200

    status = await batch(http, batch_id)
    assert status["state"] == "failed"
    assert status["failure"].startswith("resubmit: ")


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


async def test_retention_deletes_old_terminal_batches_and_stale_hints(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, remote_exec_engine: Any
) -> None:
    old_done = await submit(http, ["a"])
    await build(http, cache, "a")
    old_running = await submit(http, ["b"])
    recent_done = await submit(http, [])
    async with remote_exec_engine.begin() as connection:
        await connection.execute(
            sa.text("UPDATE batches SET created_at = now() - interval '30 days' WHERE id <> :recent"),
            {"recent": UUID(recent_done)},
        )
        await connection.execute(sa.text("UPDATE peak_hints SET updated_at = now() - interval '90 days'"))

    await coordinator.sweep()

    assert (await http.get(f"/v1/batches/{old_done}", headers=CLIENT)).status_code == 404
    assert (await batch(http, old_running))["state"] == "running"
    assert (await batch(http, recent_done))["state"] == "done"
    async with remote_exec_engine.connect() as connection:
        assert await connection.scalar(sa.text("SELECT count(*) FROM peak_hints")) == 0
        assert await connection.scalar(sa.text("SELECT count(*) FROM actions")) == 1
