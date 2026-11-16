"""Claim-time locality: claims and wakes on hosts below the scale-in line prefer actions whose dependency context
(deps-key) the host holds; see Coordinator._local_entry."""

import asyncio
from datetime import timedelta
from typing import Any
from uuid import uuid4

import httpx
import pytest

from conftest import FakeCache
from remote_exec import coordinator as coordinator_module
from remote_exec.coordinator import Coordinator, _claim_rank
from remote_exec.formats import FormatError, parse_result
from test_coordinator import CLIENT, WORKER, ac_key, complete, input_key, result, spec

D1 = "d" * 64
D2 = "e" * 64
WINDOW = coordinator_module.LOCALITY_WINDOW


@pytest.fixture(autouse=True)
def fresh_rankings(coordinator: Coordinator) -> None:
    coordinator.settings.claim_ranking_seconds = 0


async def submit_as(http: httpx.AsyncClient, name: str, theory: str, priority: int = 0) -> None:
    """A batch of one action, ``name``, building ``pkg:<theory>``."""
    text = f"holbuild-action-batch-v1\naction {input_key(name)} {ac_key(name)} {spec(name)} pkg:{theory}\n"
    response = await http.post("/v1/batches", content=text, headers=CLIENT, params={"priority": priority})
    assert response.status_code == 201, response.text


async def claim_on(http: httpx.AsyncClient, host: str, rank: int = 0) -> dict[str, Any] | None:
    """A claim by a new worker on ``host``, as workers send it."""
    body = {"tier": "standard", "worker": f"{host}-{uuid4().hex[:6]}", "host": {"id": host, "rank": rank}}
    response = await http.post("/v1/work/claim", json=body, headers=WORKER)
    if response.status_code == 204:
        return None
    assert response.status_code == 200, response.text
    return response.json()


async def run_on(
    http: httpx.AsyncClient,
    cache: FakeCache,
    host: str,
    name: str,
    theory: str,
    deps_key: str | None,
    failure: str | None = None,
    rank: int = 0,
) -> None:
    """Build ``name`` of ``pkg:<theory>`` on ``host``, its worker reporting ``deps_key``."""
    await submit_as(http, name, theory)
    claimed = await claim_on(http, host, rank)
    assert claimed is not None and claimed["theory"] == f"pkg:{theory}", claimed
    cache.keys.add(ac_key(name))
    extra = {} if deps_key is None else {"deps_key": deps_key}
    record = result(name, "failed" if failure else "built", failure, **extra)
    assert (await complete(http, claimed["attempt_token"], record)).status_code == 200


@pytest.mark.parametrize("locality", [True, False])
async def test_a_claim_takes_the_batch_whose_dependency_context_its_host_holds(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, locality: bool
) -> None:
    """``b`` shares ``x``'s dependency context, which host-1 ran: host-1 takes ``b``'s batch over the older ``a``
    of the same band, and a cold host takes ``a``."""
    coordinator.settings.locality = locality
    await run_on(http, cache, "host-1", "x", "x", D1)
    await run_on(http, cache, "host-2", "b0", "b", D1)
    await submit_as(http, "a1", "a")
    await submit_as(http, "b1", "b")

    first = await claim_on(http, "host-1")
    second = await claim_on(http, "host-3")

    assert first is not None and second is not None
    assert (first["theory"], second["theory"]) == (("pkg:b", "pkg:a") if locality else ("pkg:a", "pkg:b"))
    queue = (await http.get("/v1/queue", headers=CLIENT)).json()
    assert queue["locality"]["claims"] == (1 if locality else 0)


async def test_a_batch_is_passed_over_for_locality_at_most_the_window(
    http: httpx.AsyncClient, cache: FakeCache
) -> None:
    await run_on(http, cache, "host-1", "b0", "b", D1)
    await submit_as(http, "a1", "a")
    for i in range(WINDOW + 2):
        await submit_as(http, f"b{i + 1}", "b")

    theories = [(await claim_on(http, "host-1") or {}).get("theory") for _ in range(WINDOW + 1)]

    assert theories == ["pkg:b"] * WINDOW + ["pkg:a"]


async def test_a_batch_of_a_higher_priority_is_never_passed_over(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    coordinator.settings.default_priority_floor = 0  # else the floor's swap, not locality, takes ``b``
    await run_on(http, cache, "host-1", "b0", "b", D1)
    await submit_as(http, "a1", "a", priority=1)
    await submit_as(http, "b1", "b")

    claimed = await claim_on(http, "host-1")

    assert claimed is not None and claimed["theory"] == "pkg:a"


@pytest.mark.parametrize(("warm_workers_seen", "expected"), [(2, "pkg:a"), (1, "pkg:b")])
async def test_a_host_above_the_scale_in_line_takes_the_head(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, warm_workers_seen: int, expected: str
) -> None:
    """A spot host (rank 1) that holds ``b``'s context is above the line while the rank-0 host's workers can run the
    two ready actions, so it takes the head, ``a``, and is left to empty; with room for one only, it is kept."""
    await run_on(http, cache, "host-9", "b0", "b", D1, rank=1)
    for worker in range(warm_workers_seen):
        coordinator.report_worker("host-0", f"w{worker}", ["standard"])
    await submit_as(http, "a1", "a")
    await submit_as(http, "b1", "b")

    claimed = await claim_on(http, "host-9", rank=1)

    assert claimed is not None and claimed["theory"] == expected


async def test_a_wake_goes_to_a_waiter_below_the_scale_in_line_that_holds_the_context(
    coordinator: Coordinator,
) -> None:
    coordinator.settings.warm_workers = 2  # host-0 and host-1 are kept, host-9 (rank 1) is above the line
    loop = asyncio.get_running_loop()
    waiters = {host: loop.create_future() for host in ["host-0", "host-1", "host-9"]}
    coordinator.claim_waiters = [
        (["standard"], _claim_rank(["standard"], host, 1 if host == "host-9" else 0), wake, False)
        for host, wake in waiters.items()
    ]
    for host in waiters:
        coordinator.report_worker(host, f"{host}-w", ["standard"])
    coordinator.theory_deps.update({"pkg:b": D1, "pkg:c": D2})
    coordinator.host_keys = {"host-1": {D1: None}, "host-9": {D1: None, D2: None}}

    coordinator._wake_claim("standard", theory="pkg:b")
    coordinator._wake_claim("standard", theory="pkg:c")  # held only above the line: the canonical waiter

    assert waiters["host-1"].result() == ("standard", False, "pkg:b")
    assert waiters["host-0"].result() == ("standard", False, "pkg:c")
    assert not waiters["host-9"].done()
    assert coordinator.locality.wakes == 1


async def test_a_wake_passed_on_keeps_its_theory(coordinator: Coordinator) -> None:
    coordinator.settings.warm_workers = 2
    loop = asyncio.get_running_loop()
    left, cold, warm = loop.create_future(), loop.create_future(), loop.create_future()
    left.set_result(("standard", False, "pkg:b"))
    coordinator.made_ready = 1
    coordinator.claim_waiters = [
        (["standard"], _claim_rank(["standard"], "host-0"), cold, False),
        (["standard"], _claim_rank(["standard"], "host-1"), warm, False),
    ]
    for host in ["host-0", "host-1"]:
        coordinator.report_worker(host, f"{host}-w", ["standard"])
    coordinator.host_keys = {"host-1": {"pkg:b": None}}

    coordinator._pass_wake(left)

    assert warm.result() == ("standard", False, "pkg:b") and not cold.done()


async def test_hosts_learn_contexts_and_forget_those_of_their_infrastructure_failures(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    await run_on(http, cache, "host-1", "x", "x", D1)
    await run_on(http, cache, "host-1", "y", "y", D2, failure="internal")
    await run_on(http, cache, "host-1", "z", "z", None, failure="proof")

    assert coordinator.theory_deps == {"pkg:x": D1, "pkg:y": D2}
    assert list(coordinator.host_keys["host-1"]) == [D1, "pkg:z"]


async def test_hosts_that_leave_count_the_contexts_no_kept_host_holds(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    coordinator.settings.warm_workers = 1  # host-0 is kept
    for host in ["host-0", "host-9"]:
        coordinator.report_worker(host, f"{host}-w", ["standard"])
    coordinator.host_keys = {"host-0": {D1: None}, "host-9": {D1: None, D2: None}}
    gone = coordinator.clock() - timedelta(seconds=coordinator_module.HOST_REPORT_SECONDS + 1)
    coordinator.host_workers["host-9"] = {"host-9-w": (gone, True)}

    queue = (await http.get("/v1/queue", headers=CLIENT)).json()

    assert queue["locality"] == {"claims": 0, "wakes": 0, "hosts_left": 1, "keys_left": 2, "keys_lost": 1}
    assert "host-9" not in coordinator.host_keys


def test_result_records_carry_an_optional_deps_key() -> None:
    assert parse_result(result("a", "built", deps_key=D1)).deps_key == D1
    assert parse_result(result("a", "built")).deps_key is None
    with pytest.raises(FormatError, match="deps-key"):
        parse_result(result("a", "built", deps_key="nope"))
