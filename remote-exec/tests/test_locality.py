"""Claim-time locality: claims and wakes on hosts below the scale-in line prefer actions whose dependency context
(deps-key) the host holds; see Coordinator._local_entry."""

import asyncio
from collections.abc import Callable
from datetime import timedelta
from types import SimpleNamespace
from typing import Any
from uuid import UUID, uuid4

import httpx
import pytest
from conftest import FakeCache
from test_coordinator import CLIENT, WORKER, ac_key, complete, input_key, result, spec, submit

from remote_exec import coordinator as coordinator_module
from remote_exec.coordinator import Coordinator, HostReport, _claim_rank
from remote_exec.formats import FormatError, parse_result

D1 = "d" * 64
D2 = "e" * 64
WINDOW = coordinator_module.LOCALITY_WINDOW


@pytest.fixture(autouse=True)
def fresh_rankings(coordinator: Coordinator) -> None:
    coordinator.settings.claim_ranking_seconds = 0


async def submit_as(http: httpx.AsyncClient, name: str, theory: str, priority: int = 0) -> UUID:
    """A batch of one action, ``name``, building ``pkg:<theory>``."""
    text = f"holbuild-action-batch-v1\naction {input_key(name)} {ac_key(name)} {spec(name)} pkg:{theory}\n"
    response = await http.post("/v1/batches", content=text, headers=CLIENT, params={"priority": priority})
    assert response.status_code == 201, response.text
    return UUID(response.json()["batch_id"])


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


async def test_a_claim_doesn_t_swap_to_a_warm_batch_whose_deeper_claim_ahead_on_outlines_goes_first(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    """host-1 ran ``b``, but ``b``'s batch has a claim ahead on outlines deeper than its ready build, which goes
    first: host-1 takes ``a``, the head of the ranking, instead."""
    await run_on(http, cache, "host-1", "b0", "b", D1)
    await submit_as(http, "a1", "a")
    deep = await submit_as(http, "b1", "b")
    outranked = SimpleNamespace(above=lambda *_: [], deepest={}, deeper=lambda batch, *_: batch == deep)

    claimed, _ = await coordinator._claim(["standard"], "w", outranked, "host-1", None, frozenset(), frozenset())

    assert claimed is not None and claimed.theory == "pkg:a"


async def test_a_woken_claim_doesn_t_take_the_build_it_was_woken_for_before_its_batch_s_deeper_claim_ahead(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    """Woken for ``b``, which no host holds, a claim still takes the head ``a``: ``b``'s batch has a claim ahead
    deeper than its ready build, which goes first."""
    await submit_as(http, "a1", "a")
    woken_for = await submit_as(http, "b1", "b")
    outranked = SimpleNamespace(above=lambda *_: [], deepest={}, deeper=lambda batch, *_: batch == woken_for)

    claimed, _ = await coordinator._claim(
        ["standard"], "w", outranked, "host-5", (woken_for, "standard", "pkg:b"), frozenset(), frozenset()
    )

    assert claimed is not None and claimed.theory == "pkg:a"


async def test_a_batch_is_passed_over_for_locality_at_most_the_window(
    http: httpx.AsyncClient, cache: FakeCache
) -> None:
    await run_on(http, cache, "host-1", "b0", "b", D1)
    await submit_as(http, "a1", "a")
    for i in range(WINDOW + 2):
        await submit_as(http, f"b{i + 1}", "b")

    theories = [(await claim_on(http, "host-1") or {}).get("theory") for _ in range(WINDOW + 1)]

    assert theories == ["pkg:b"] * WINDOW + ["pkg:a"]


async def test_concurrent_claims_pass_a_batch_over_at_most_the_window(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    await run_on(http, cache, "host-1", "b0", "b", D1)
    await submit_as(http, "a1", "a")
    for i in range(2 * WINDOW):
        await submit_as(http, f"b{i + 1}", "b")

    claims = await asyncio.gather(
        *(coordinator.claim(["standard"], f"host-1-{i}", host_id="host-1") for i in range(WINDOW + 1))
    )

    assert sorted(c.theory for c in claims if c is not None) == ["pkg:a"] + ["pkg:b"] * WINDOW


async def test_a_batch_of_a_higher_priority_is_never_passed_over(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
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

    assert waiters["host-1"].result() == ("standard", False, None, "pkg:b")
    assert waiters["host-0"].result() == ("standard", False, None, "pkg:c")
    assert not waiters["host-9"].done()
    assert coordinator.locality.wakes == 1


async def test_a_wake_passed_on_keeps_its_theory(coordinator: Coordinator) -> None:
    coordinator.settings.warm_workers = 2
    loop = asyncio.get_running_loop()
    left, cold, warm = loop.create_future(), loop.create_future(), loop.create_future()
    left.set_result(("standard", False, None, "pkg:b"))
    coordinator.made_ready = 1
    coordinator.claim_waiters = [
        (["standard"], _claim_rank(["standard"], "host-0"), cold, False),
        (["standard"], _claim_rank(["standard"], "host-1"), warm, False),
    ]
    for host in ["host-0", "host-1"]:
        coordinator.report_worker(host, f"{host}-w", ["standard"])
    coordinator.host_keys = {"host-1": {"pkg:b": None}}

    coordinator._pass_wake(left)

    assert warm.result() == ("standard", False, None, "pkg:b") and not cold.done()


async def test_hosts_learn_contexts_and_forget_those_of_their_infrastructure_failures(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    await run_on(http, cache, "host-1", "x", "x", D1)
    await run_on(http, cache, "host-1", "y", "y", D2, failure="internal")
    await run_on(http, cache, "host-1", "z", "z", None, failure="proof")

    assert coordinator.theory_deps == {"pkg:x": D1, "pkg:y": D2}
    assert list(coordinator.host_keys["host-1"]) == [D1, "pkg:x", "pkg:z"]

    await run_on(http, cache, "host-1", "x2", "x", None, failure="internal")  # a worker that reports no deps-key

    assert list(coordinator.host_keys["host-1"]) == ["pkg:z"]


async def test_hosts_keep_their_contexts_through_a_quiet_spell_and_count_those_no_kept_host_holds_once_gone(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    """host-9's workers went quiet: it is no longer kept, but its contexts stay, as when its workers are replaced,
    until HOST_KEYS_SECONDS after its last worker was seen."""
    coordinator.settings.warm_workers = 1  # host-0 is kept
    for host in ["host-0", "host-9"]:
        coordinator.report_worker(host, f"{host}-w", ["standard"])
    coordinator.host_keys = {"host-0": {D1: None}, "host-9": {D1: None, D2: None}}
    gone = coordinator.clock() - timedelta(seconds=coordinator_module.HOST_REPORT_SECONDS + 1)
    coordinator.host_workers["host-9"] = {"host-9-w": (gone, True)}

    queue = (await http.get("/v1/queue", headers=CLIENT)).json()

    assert queue["locality"]["hosts_left"] == 0 and "host-9" in coordinator.host_keys
    coordinator.keys_seen["host-9"] = coordinator.clock() - timedelta(seconds=coordinator_module.HOST_KEYS_SECONDS)

    queue = (await http.get("/v1/queue", headers=CLIENT)).json()

    assert {k: queue["locality"][k] for k in ["hosts_left", "keys_left", "keys_lost"]} == {
        "hosts_left": 1, "keys_left": 2, "keys_lost": 1
    }
    assert "host-9" not in coordinator.host_keys


def test_result_records_carry_an_optional_deps_key() -> None:
    assert parse_result(result("a", "built", deps_key=D1)).deps_key == D1
    assert parse_result(result("a", "built")).deps_key is None
    with pytest.raises(FormatError, match="deps-key"):
        parse_result(result("a", "built", deps_key="nope"))


def counts(coordinator: Coordinator, *names: str) -> dict[str, int]:
    return {name: getattr(coordinator.locality, name) for name in names}


async def test_claims_count_what_their_host_held_of_the_theory(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(coordinator_module, "LOCALITY_HOLD_SECONDS", 0)  # no build is left for its holder here
    coordinator.theory_deps.update({"pkg:t": D1, "pkg:u": D1})
    coordinator.host_keys = {"host-1": {"pkg:t": None}, "host-2": {D1: None}}
    for host in ["host-1", "host-2", "host-3"]:
        coordinator.report_worker(host, f"{host}-w", ["standard"])

    for name, theory, host in [("t1", "t", "host-1"), ("u1", "u", "host-2"), ("t2", "t", "host-3"), ("v1", "v", "host-3")]:
        await submit_as(http, name, theory)
        claimed = await claim_on(http, host)
        assert claimed is not None and claimed["theory"] == f"pkg:{theory}"

    queue = (await http.get("/v1/queue", headers=CLIENT)).json()
    assert {k: queue["locality"][k] for k in ["hit_theory", "hit_deps", "missed_held", "unheld"]} == {
        "hit_theory": 1, "hit_deps": 1, "missed_held": 1, "unheld": 1
    }


@pytest.mark.parametrize("locality", [True, False])
async def test_a_cold_host_leaves_a_build_its_kept_holder_holds_and_takes_the_next(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, locality: bool
) -> None:
    """``b`` ran on host-1, so a claim from cold host-3 leaves ``b1``, the head, to host-1 and takes ``a1``, which no
    host holds."""
    coordinator.settings.locality = locality
    await run_on(http, cache, "host-1", "b0", "b", D1)
    await submit_as(http, "b1", "b")
    await submit_as(http, "a1", "a")

    cold = await claim_on(http, "host-3")
    warm = await claim_on(http, "host-1")

    assert cold is not None and warm is not None
    assert (cold["theory"], warm["theory"]) == (("pkg:a", "pkg:b") if locality else ("pkg:b", "pkg:a"))
    assert counts(coordinator, "hit_theory", "missed_held", "unheld", "held_waits") == (
        {"hit_theory": 1, "missed_held": 0, "unheld": 2, "held_waits": 1} if locality
        else {"hit_theory": 0, "missed_held": 1, "unheld": 2, "held_waits": 0}
    )


async def test_a_claim_finding_only_held_builds_takes_one_once_its_hold_ends(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(coordinator_module, "CLAIM_RECHECK_SECONDS", 60)  # only the hold's end ends the wait in time
    await run_on(http, cache, "host-1", "b0", "b", D1)
    await submit_as(http, "b1", "b")
    loop = asyncio.get_running_loop()
    started = loop.time()

    claimed = await coordinator.claim(["standard"], "cold", 10, host_id="host-3")

    waited = loop.time() - started
    assert claimed is not None and claimed.theory == "pkg:b"
    assert coordinator_module.LOCALITY_HOLD_SECONDS <= waited < 5
    assert counts(coordinator, "missed_held", "held_waits") == {"missed_held": 1, "held_waits": 1}
    assert coordinator.locality.held_ms_total >= 1000 * coordinator_module.LOCALITY_HOLD_SECONDS


async def test_a_hold_wakes_a_claim_waiting_on_the_holder(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    """A claim from cold host ``a`` leaves ``b1`` to host ``c``, which ran ``b``, and wakes the claim waiting there
    for it, not the better-ranked one on cold host ``b``; nothing new was made ready."""
    coordinator.settings.warm_workers = 3
    await run_on(http, cache, "c", "b0", "b", D1)
    batch_id = await submit_as(http, "b1", "b")
    loop = asyncio.get_running_loop()
    waiters = {host: loop.create_future() for host in ["b", "c"]}
    coordinator.claim_waiters = [
        (["standard"], _claim_rank(["standard"], host), wake, False) for host, wake in waiters.items()
    ]
    coordinator.report_worker("b", "b-w", ["standard"])
    made_ready = coordinator.made_ready

    assert await claim_on(http, "a") is None

    assert waiters["c"].result() == ("standard", False, batch_id, "pkg:b")
    assert not waiters["b"].done() and coordinator.made_ready == made_ready


@pytest.mark.parametrize(
    ("locality", "theory", "expected"), [(True, "pkg:b", "pkg:b"), (False, "pkg:b", "pkg:a"), (True, "pkg:c", "pkg:a")]
)
async def test_a_woken_claim_takes_the_build_it_was_woken_for_unless_another_claim_took_it(
    http: httpx.AsyncClient, coordinator: Coordinator, locality: bool, theory: str, expected: str
) -> None:
    """Woken for ``pkg:c``, a build of ``b1``'s batch another claim took, a claim takes the head."""
    coordinator.settings.locality = locality
    await submit_as(http, "a1", "a")
    woken_for = await submit_as(http, "b1", "b")

    claimed, _ = await coordinator._claim(["standard"], "w", host_id="host-5", hint=(woken_for, "standard", theory))

    assert claimed is not None and claimed.theory == expected


async def test_a_woken_claim_leaves_the_build_it_was_woken_for_to_a_kept_host_holding_more_of_it(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    await run_on(http, cache, "host-1", "b0", "b", D1)
    await submit_as(http, "a1", "a")
    woken_for = await submit_as(http, "b1", "b")

    claimed, _ = await coordinator._claim(["standard"], "w", host_id="host-5", hint=(woken_for, "standard", "pkg:b"))

    assert claimed is not None and claimed.theory == "pkg:a"


@pytest.mark.parametrize("head", ["b", "a"])
async def test_a_host_holding_only_the_context_leaves_the_build_to_a_host_that_ran_its_theory(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, head: str
) -> None:
    """Whether ``b1`` heads the ranking (held) or follows ``a1`` in its band (not swapped in)."""
    coordinator.settings.warm_workers = 3
    await run_on(http, cache, "host-2", "b0", "b", D1)
    coordinator.host_keys["host-1"] = {D1: None}
    for name in ["b", "a"] if head == "b" else ["a", "b"]:
        await submit_as(http, f"{name}1", name)

    first = await claim_on(http, "host-1")
    second = await claim_on(http, "host-2")

    assert first is not None and second is not None
    assert (first["theory"], second["theory"]) == ("pkg:a", "pkg:b")


async def test_a_wake_prefers_a_waiter_that_ran_the_theory_to_one_holding_only_its_context(
    coordinator: Coordinator,
) -> None:
    coordinator.settings.warm_workers = 3
    loop = asyncio.get_running_loop()
    waiters = {host: loop.create_future() for host in ["host-0", "host-1", "host-2"]}
    coordinator.claim_waiters = [
        (["standard"], _claim_rank(["standard"], host), wake, False) for host, wake in waiters.items()
    ]
    for host in waiters:
        coordinator.report_worker(host, f"{host}-w", ["standard"])
    coordinator.theory_deps["pkg:b"] = D1
    coordinator.host_keys = {"host-1": {D1: None}, "host-2": {"pkg:b": None, D1: None}}

    coordinator._wake_claim("standard", theory="pkg:b")

    assert waiters["host-2"].done() and not waiters["host-0"].done() and not waiters["host-1"].done()


@pytest.mark.parametrize(("short", "ready", "kept"), [(False, 1, False), (True, 1, True), (False, 5, True)])
def test_the_scale_in_line_counts_ready_builds_and_not_workers_waiting_for_memory(
    coordinator: Coordinator, short: bool, ready: int, kept: bool
) -> None:
    """host-0 runs one lease and has 5 workers: with one more build ready, they cover the line unless host-0 is
    short of memory, so its idle workers wait for memory rather than claim; with 5 ready, host-1 is needed too."""
    for i in range(5):
        coordinator.report_worker("host-0", f"host-0-w{i}", ["standard"])
    coordinator.report_worker("host-1", "host-1-w", ["standard"])
    coordinator.report_host(HostReport(id="host-0", memory_short=short, leases=1))
    coordinator.lease_hosts[uuid4()] = ("host-0", "host-0-w0", ["standard"])
    coordinator.ready_builds = ready

    assert ("host-1" in coordinator._kept_hosts()) == kept


@pytest.mark.parametrize("priorities", [False, True])
async def test_a_build_held_for_another_host_still_comes_before_claims_ahead(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch,
    priorities: bool,
) -> None:
    """Cold host-3 leaves ``b1`` to host-1 and waits out its hold rather than claim ``c`` ahead of its running
    parent; with priorities, ``c``'s batch (3) outranks ``x1`` (0) but not ``b1`` (5)."""
    monkeypatch.setattr(coordinator_module, "CLAIM_RECHECK_SECONDS", 60)
    await run_on(http, cache, "host-1", "b0", "b", D1)
    await submit(http, ["a", "c"], [("c", "a")], speculative_loading="4", priority="3" if priorities else "0")
    leased = await claim_on(http, "host-0")
    assert leased is not None and leased["theory"] == "pkg:a"
    await submit_as(http, "b1", "b", priority=5 if priorities else 0)
    if priorities:
        await submit_as(http, "x1", "x")

    claimed = await coordinator.claim(["standard"], "cold", 10, host_id="host-3", ahead=True)

    assert claimed is not None and claimed.theory == "pkg:b"


async def test_a_hold_wakes_no_waiter_holding_less_of_the_theory_than_the_host_it_is_left_for(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    """``b1`` is left for host ``c``, which ran ``b``; the claim waiting on ``b``, which holds only its context,
    would only find it held again."""
    coordinator.settings.warm_workers = 3
    await run_on(http, cache, "c", "b0", "b", D1)
    await submit_as(http, "b1", "b")
    coordinator.host_keys["b"] = {D1: None}
    wake = asyncio.get_running_loop().create_future()
    coordinator.claim_waiters = [(["standard"], _claim_rank(["standard"], "b"), wake, False)]
    coordinator.report_worker("b", "b-w", ["standard"])

    assert await claim_on(http, "a") is None

    assert not wake.done()


async def test_a_release_wake_counts_the_build_it_made_ready_in_the_scale_in_line(coordinator: Coordinator) -> None:
    """host-1 runs the only lease and holds ``b``: with the build just made ready, the line keeps it after cold
    host-0, though no sweep has counted that build yet."""
    loop = asyncio.get_running_loop()
    waiters = {host: loop.create_future() for host in ["host-0", "host-1"]}
    coordinator.claim_waiters = [
        (["standard"], _claim_rank(["standard"], host), wake, False) for host, wake in waiters.items()
    ]
    for host in waiters:
        coordinator.report_worker(host, f"{host}-w", ["standard"])
    coordinator.lease_hosts[uuid4()] = ("host-1", "host-1-w9", ["standard"])
    coordinator.host_keys = {"host-1": {"pkg:b": None}}

    coordinator._wake_claim("standard", theory="pkg:b")

    assert waiters["host-1"].done() and not waiters["host-0"].done()


async def test_a_release_hands_the_claim_it_wakes_the_batch_it_made_ready(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    hints: list[tuple[UUID, str, str] | None] = []
    claim = coordinator._claim

    async def recording(
        tiers: list[str], worker: str, outranked: Any = None, host_id: str | None = None,
        hint: tuple[UUID, str, str] | None = None, *rest: Any,
    ) -> Any:
        hints.append(hint)
        return await claim(tiers, worker, outranked, host_id, hint, *rest)

    monkeypatch.setattr(coordinator, "_claim", recording)
    waiting = asyncio.create_task(coordinator.claim(["standard"], "w", 10, host_id="host-5"))
    while not coordinator.claim_waiters:
        await asyncio.sleep(0.01)
    batch_id = await submit_as(http, "a1", "a")

    claimed = await waiting

    assert claimed is not None and claimed.theory == "pkg:a"
    assert hints[-1] == (batch_id, "standard", "pkg:a")


def test_high_work_draws_its_scale_in_line_over_the_hosts_with_burst_workers(coordinator: Coordinator) -> None:
    """Warm host-0's standard workers cover the warm workers, but can't take high work."""
    coordinator.settings.warm_workers = 2
    for i in range(2):
        coordinator.report_worker("host-0", f"host-0-w{i}", ["standard"])
    coordinator.report_worker("host-9", "host-9-w", ["high", "standard"])

    assert (coordinator._kept_hosts(1), coordinator._kept_hosts(1, "high")) == ({"host-0"}, {"host-9"})


def test_the_high_line_counts_high_work_and_burst_workers_only(coordinator: Coordinator) -> None:
    """One ready high build needs one burst host, whatever the warm workers wanted; with host-8's burst worker
    leased, host-9 too, though host-8's standard workers are free."""
    coordinator.settings.warm_workers = 5
    for host in ["host-8", "host-9"]:
        coordinator.report_worker(host, f"{host}-w", ["high", "standard"])
    for i in range(3):
        coordinator.report_worker("host-8", f"host-8-s{i}", ["standard"])

    assert coordinator._kept_hosts(1, "high") == {"host-8"}
    coordinator.lease_hosts[uuid4()] = ("host-8", "host-8-w", ["high", "standard"])
    assert coordinator._kept_hosts(1, "high") == {"host-8", "host-9"}


async def test_a_holder_claiming_unwoken_during_a_hold_takes_its_build_before_better_ranked_waiters(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    """``b1`` is held for host-1, which ran ``b``; a claim from host-1 that wasn't woken for it isn't deferred to the
    claim waiting on better-ranked cold host-0, which would take it cold once the hold ends."""
    coordinator.settings.warm_workers = 3
    await run_on(http, cache, "host-1", "b0", "b", D1, rank=1)
    await submit_as(http, "b1", "b")
    assert await claim_on(http, "host-3", rank=1) is None
    wake = asyncio.get_running_loop().create_future()
    coordinator.claim_waiters = [(["standard"], _claim_rank(["standard"], "host-0"), wake, False)]
    coordinator.report_worker("host-0", "host-0-w", ["standard"])

    claimed = await claim_on(http, "host-1", rank=1)

    assert claimed is not None and claimed["theory"] == "pkg:b"
    assert counts(coordinator, "hit_theory", "held_waits") == {"hit_theory": 1, "held_waits": 1}


async def test_a_claim_passing_over_a_held_build_wakes_a_holder_that_began_waiting_after_the_hold(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    coordinator.settings.warm_workers = 3
    await run_on(http, cache, "c", "b0", "b", D1)
    batch_id = await submit_as(http, "b1", "b")
    assert await claim_on(http, "a") is None  # the hold begins; nobody waits on c yet
    wake = asyncio.get_running_loop().create_future()
    coordinator.claim_waiters = [(["standard"], _claim_rank(["standard"], "c"), wake, False)]

    assert await claim_on(http, "a") is None

    assert wake.result() == ("standard", False, batch_id, "pkg:b")


async def test_the_end_of_a_hold_wakes_a_waiting_claim_for_the_build_left(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Cold host-3 leaves ``b1`` to host-1 and takes ``a1``; when the hold ends, the claim waiting on cold host-9 is
    woken for ``b1``, though host-1 never came for it, and nothing new was made ready."""
    monkeypatch.setattr(coordinator_module, "LOCALITY_HOLD_SECONDS", 0.05)
    coordinator.settings.warm_workers = 3
    await run_on(http, cache, "host-1", "b0", "b", D1)
    batch_id = await submit_as(http, "b1", "b")
    await submit_as(http, "a1", "a")
    wake = asyncio.get_running_loop().create_future()
    coordinator.claim_waiters = [(["standard"], _claim_rank(["standard"], "host-9"), wake, False)]
    made_ready = coordinator.made_ready
    claimed = await claim_on(http, "host-3")
    assert claimed is not None and claimed["theory"] == "pkg:a"

    await asyncio.wait_for(asyncio.shield(wake), 5)

    assert wake.result() == ("standard", False, batch_id, "pkg:b") and coordinator.made_ready == made_ready


@pytest.mark.parametrize("hinted", [False, True])
async def test_a_build_that_waited_out_its_hold_is_not_passed_over_again(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch, hinted: bool
) -> None:
    """``b1`` waited out its hold for host-1; host-2, which ran ``a``, takes it rather than swap in ``a1``, also when
    woken for ``a1``."""
    monkeypatch.setattr(coordinator_module, "LOCALITY_HOLD_SECONDS", 0.05)
    coordinator.settings.warm_workers = 3
    await run_on(http, cache, "host-1", "b0", "b", D1)
    await run_on(http, cache, "host-2", "a0", "a", D2)
    await submit_as(http, "b1", "b")
    assert await claim_on(http, "host-3") is None
    await asyncio.sleep(0.1)
    a_batch = await submit_as(http, "a1", "a")

    if hinted:
        claimed, _ = await coordinator._claim(["standard"], "w", host_id="host-2", hint=(a_batch, "standard", "pkg:a"))
        theory = claimed.theory if claimed is not None else None
    else:
        theory = (await claim_on(http, "host-2") or {}).get("theory")

    assert theory == "pkg:b"


async def held_in_a_busier_batch(
    http: httpx.AsyncClient, coordinator: Coordinator, *, context_only: bool = False
) -> tuple[str, str]:
    """A batch of ``x`` and ``y`` with one of them leased, whose other build, returned with the batch, is held for
    host-1, which alone ran its theory (or holds its context), after a cold claim from host-3 found it."""
    coordinator.settings.warm_workers = 3
    batch_id = await submit(http, ["x", "y"])
    leased = await claim_on(http, "host-2")
    assert leased is not None
    theory = "pkg:y" if leased["theory"] == "pkg:x" else "pkg:x"
    if context_only:
        coordinator.theory_deps[theory] = D1
    coordinator.host_keys["host-1"] = {D1 if context_only else theory: None}
    coordinator.report_worker("host-1", "host-1-w", ["standard"])
    assert await claim_on(http, "host-3") is None
    return batch_id, theory


def wait_on_host_0(coordinator: Coordinator) -> None:
    """A claim waits on host-0, which ranks before host-1: an unwoken claim from host-1 defers to it."""
    coordinator.claim_waiters = [
        (["standard"], _claim_rank(["standard"], "host-0"), asyncio.get_running_loop().create_future(), False)
    ]
    coordinator.report_worker("host-0", "host-0-w", ["standard"])


async def test_a_holder_claiming_unwoken_finds_its_held_build_behind_a_batch_running_less(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    """``a1``'s batch runs nothing, so it heads the ranking, in another band than the held build's."""
    _, theory = await held_in_a_busier_batch(http, coordinator)
    await submit_as(http, "a1", "a")
    wait_on_host_0(coordinator)

    claimed = await claim_on(http, "host-1")

    assert claimed is not None and claimed["theory"] == theory


async def test_a_holder_claiming_unwoken_takes_nothing_but_its_held_build_ahead_of_better_ranked_waiters(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    """``a1`` ranks first by its priority, so the held build is no candidate for the hint; host-1 leaves ``a1`` to
    host-0's claim, which ranks better."""
    await held_in_a_busier_batch(http, coordinator)
    await submit_as(http, "a1", "a", priority=1)
    wait_on_host_0(coordinator)

    assert await claim_on(http, "host-1") is None


async def learn_high(http: httpx.AsyncClient, cache: FakeCache) -> None:
    """Build ``h`` once with a peak above the standard tier, so its next batches place it high."""
    await submit(http, ["h"])
    first = await claim_on(http, "host-9")
    assert first is not None
    cache.keys.add(ac_key("h"))
    assert (await complete(http, first["attempt_token"], result("h", "built", peak_rss_mb="5000"))).status_code == 200


async def test_a_holder_claiming_unwoken_takes_a_ready_build_of_an_earlier_tier_before_its_held_build(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    """``h`` peaked above the standard tier, so it is ready as high work; host-1's worker takes high work first."""
    await learn_high(http, cache)
    await held_in_a_busier_batch(http, coordinator)
    await submit(http, ["h"])
    wait_on_host_0(coordinator)

    claimed = await coordinator.claim(["high", "standard"], "host-1-h", host_id="host-1")

    assert claimed is not None and claimed.theory == "pkg:h"


async def test_a_claim_passing_over_a_held_build_holds_it_for_the_kept_hosts_holding_the_most_of_it_now(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    """host-0, kept, and host-9, above the scale-in line, came to hold the theory after the hold began: the next claim
    passing the build over wakes host-0, which ranks first, and not host-9."""
    batch_id, theory = await held_in_a_busier_batch(http, coordinator)
    coordinator.host_keys["host-0"] = {theory: None}
    coordinator.host_keys["host-9"] = {theory: None}
    loop = asyncio.get_running_loop()
    waiters = {host: loop.create_future() for host in ["host-0", "host-1", "host-9"]}
    coordinator.claim_waiters = [
        (["standard"], _claim_rank(["standard"], host), wake, False) for host, wake in waiters.items()
    ]
    coordinator.report_worker("host-0", "host-0-w", ["standard"])

    assert await claim_on(http, "a") is None

    assert waiters["host-0"].result() == ("standard", False, UUID(batch_id), theory)
    assert not waiters["host-1"].done() and not waiters["host-9"].done()


async def test_a_claim_passing_over_a_held_build_leaves_it_to_a_host_that_has_come_to_hold_more_of_it(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    """host-1 held only the context when the hold began; host-2 has run the theory since, so the build is no longer
    held for host-1, and the next claim passing it over wakes host-2."""
    batch_id, theory = await held_in_a_busier_batch(http, coordinator, context_only=True)
    coordinator.host_keys["host-2"] = {theory: None}
    loop = asyncio.get_running_loop()
    waiters = {host: loop.create_future() for host in ["host-1", "host-2"]}
    coordinator.claim_waiters = [
        (["standard"], _claim_rank(["standard"], host), wake, False) for host, wake in waiters.items()
    ]

    assert await claim_on(http, "a") is None

    assert waiters["host-2"].result() == ("standard", False, UUID(batch_id), theory)
    assert not waiters["host-1"].done()


async def test_a_holder_claiming_unwoken_takes_its_held_build_only_while_it_holds_the_most_of_it(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    """host-1 held only the context when the hold began; host-2, kept, has run the theory since, with no claim passing
    the build over in between. ``a1``, in another band, heads the ranking. An unwoken claim from host-1 defers to the
    claim waiting on host-0; one from host-2 takes the build."""
    _, theory = await held_in_a_busier_batch(http, coordinator, context_only=True)
    coordinator.host_keys["host-2"] = {theory: None}
    coordinator.settings.warm_workers = 4  # host-2 below the scale-in line too
    await submit_as(http, "a1", "a")
    wait_on_host_0(coordinator)

    assert await claim_on(http, "host-1") is None
    claimed = await claim_on(http, "host-2")

    assert claimed is not None and claimed["theory"] == theory


async def test_a_hold_of_a_theory_the_batch_no_longer_builds_next_is_replaced(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    """Another coordinator process leased the held build, so this one still has its hold when the ranking shows the
    batch's next build: a claim passing that over holds it anew, for its own theory."""
    batch_id, theory = await held_in_a_busier_batch(http, coordinator)
    key = (UUID(batch_id), "standard")
    now = asyncio.get_running_loop().time()
    coordinator.holds[key] = (now, now + 60, "pkg:gone")

    assert await claim_on(http, "a") is None

    assert coordinator.holds[key][2] == theory
    assert coordinator.holds[key][1] < now + 60


def outranking(above: Callable[[str, int], list[str]]) -> Any:
    """Claims ahead that rank before ready builds of other batches by ``above``, and none of a build's own."""
    return SimpleNamespace(above=above, deepest={}, deeper=lambda *_: False)


async def test_a_claim_with_a_hint_only_tier_claims_ahead_for_the_build_that_stopped_it(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The ready high build ``h`` isn't the hint's, so the claim, deferring high, passes it; the standard build
    ``s`` ranks after an action claimed ahead, so the claim ahead is for ``s``'s tier and priority."""
    await learn_high(http, cache)
    await submit(http, ["h"])
    await submit(http, ["s"])
    asked: list[list[str]] = []

    async def claim_ahead(tiers: list[str], worker: str, **_: object) -> None:
        asked.append(tiers)

    monkeypatch.setattr(coordinator, "_claim_ahead", claim_ahead)

    claimed, _ = await coordinator._claim(
        ["high", "standard"], "w", outranking(lambda tier, priority: [tier] if tier == "standard" else []), "host-1",
        None, frozenset({"high"}), frozenset({"high"}),
    )

    assert asked == [["standard"]]
    assert claimed is not None and claimed.theory == "pkg:s"


async def test_a_held_build_of_a_hint_only_tier_that_a_claim_ahead_outranks_is_claimed_ahead_of(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``h``, high and held for host-1, ranks after a high action claimed ahead; ``s``, standard, after none."""
    await learn_high(http, cache)
    held = UUID(await submit(http, ["h"]))
    await submit(http, ["s"], priority="2")
    now = asyncio.get_running_loop().time()
    coordinator.holds[(held, "high")] = (now, now + 60, "pkg:h")
    coordinator.host_keys["host-1"] = {"pkg:h": None}
    coordinator.report_worker("host-1", "host-1-w", ["high", "standard"])
    asked: list[list[str]] = []

    async def claim_ahead(tiers: list[str], worker: str, **_: object) -> None:
        asked.append(tiers)

    monkeypatch.setattr(coordinator, "_claim_ahead", claim_ahead)

    await coordinator._claim(
        ["high", "standard"], "w", outranking(lambda tier, priority: ["high"] if tier == "high" and priority < 1 else []),
        "host-1", None, frozenset({"high"}), frozenset({"high"}),
    )

    assert asked == [["high"]]


@pytest.mark.parametrize("failing", ["_lock_unleased", "_lease"])
async def test_a_hold_taken_by_a_claim_that_fails_to_lease_its_build_is_put_back(
    http: httpx.AsyncClient,
    cache: FakeCache,
    coordinator: Coordinator,
    monkeypatch: pytest.MonkeyPatch,
    failing: str,
) -> None:
    """``b1`` is held for host-1; host-1's claim fails while locking or leasing it, so ``b1`` stays ready and held,
    in the ranking the claims share too."""
    await run_on(http, cache, "host-1", "b0", "b", D1)
    held = await submit_as(http, "b1", "b")
    coordinator.settings.claim_ranking_seconds = 3600
    assert await claim_on(http, "host-3") is None
    hold = coordinator.holds[(held, "standard")]

    async def fail(*_: object, **__: object) -> None:
        raise RuntimeError("database gone")

    with monkeypatch.context() as patch:
        patch.setattr(coordinator, failing, fail)
        with pytest.raises(RuntimeError):
            await coordinator.claim(["standard"], "w", 0, host_id="host-1")

    assert coordinator.holds[(held, "standard")] == hold
    claimed = await claim_on(http, "host-3")
    assert claimed is None
    claimed = await claim_on(http, "host-1")
    assert claimed is not None and claimed["theory"] == "pkg:b"


async def test_a_hold_ends_only_for_the_build_it_held(http: httpx.AsyncClient, coordinator: Coordinator) -> None:
    """An ended hold of another theory, left after another process's claim took the held build, doesn't keep claims
    from passing over the batch's next build."""
    key = (await submit_as(http, "b1", "b"), "standard")
    ranking = await coordinator._current_ranking(("standard",))
    now = asyncio.get_running_loop().time()

    coordinator.holds[key] = (now - 1, now - 0.5, "pkg:gone")
    assert not coordinator._hold_ended(ranking, key)
    coordinator.holds[key] = (now - 1, now - 0.5, "pkg:b")
    assert coordinator._hold_ended(ranking, key)


async def test_a_holder_claiming_unwoken_finds_the_build_held_for_it_among_several_held(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    """host-1 holds the context of ``x`` and ``y``, and kept host-2 ran ``x``: both builds are held, ``x`` for host-2
    and ``y`` for host-1, which takes ``y`` though the hold of ``x`` began first."""
    coordinator.settings.warm_workers = 4
    coordinator.theory_deps["pkg:x"] = coordinator.theory_deps["pkg:y"] = D1
    coordinator.host_keys["host-1"] = {D1: None}
    coordinator.host_keys["host-2"] = {"pkg:x": None}
    coordinator.report_worker("host-1", "host-1-w", ["standard"])
    coordinator.report_worker("host-2", "host-2-w", ["standard"])
    await submit_as(http, "x1", "x")
    await submit_as(http, "y1", "y")
    assert await claim_on(http, "host-3") is None
    assert len(coordinator.holds) == 2
    wait_on_host_0(coordinator)

    claimed = await claim_on(http, "host-1")

    assert claimed is not None and claimed["theory"] == "pkg:y"


async def test_a_claim_swapping_past_a_held_build_wakes_a_holder_that_began_waiting_after_the_hold(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    """``b1``, the head, is held for host-1 and ``a1`` for host-4, which takes ``a1`` from behind ``b1``, waking the
    claim host-1 started waiting after the hold began."""
    await run_on(http, cache, "host-1", "b0", "b", D1)
    await run_on(http, cache, "host-4", "a0", "a", D2)
    held = await submit_as(http, "b1", "b")
    await submit_as(http, "a1", "a")
    coordinator.settings.warm_workers = 5
    assert await claim_on(http, "host-3") is None
    assert (held, "standard") in coordinator.holds
    wake = asyncio.get_running_loop().create_future()
    coordinator.claim_waiters = [(["standard"], _claim_rank(["standard"], "host-1"), wake, False)]

    claimed = await claim_on(http, "host-4")

    assert claimed is not None and claimed["theory"] == "pkg:a"
    assert wake.result() == ("standard", False, held, "pkg:b")


async def test_a_claim_swapping_within_its_band_to_a_build_held_for_its_host_takes_no_other_build_of_its_batch(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``a1`` is held for host-4, whose claim, woken for another tier, swaps to it past ``b1``, the head; another
    process's claim took ``a1`` since the ranking was read, so the lock finds a build of another theory: host-4's claim
    leaves it and takes ``b1``."""
    await run_on(http, cache, "host-4", "a0", "a", D2)
    await submit_as(http, "b1", "b")
    held = await submit_as(http, "a1", "a")
    coordinator.settings.warm_workers = 5
    now = asyncio.get_running_loop().time()
    coordinator.holds[(held, "standard")] = (now, now + 60, "pkg:a")
    lock = coordinator._lock_unleased

    async def next_build(*args: Any) -> Any:
        row = await lock(*args)
        return row if row is None or row.theory == "pkg:b" else SimpleNamespace(**{**row._mapping, "theory": "pkg:z"})

    monkeypatch.setattr(coordinator, "_lock_unleased", next_build)

    claimed, _ = await coordinator._claim(["standard"], "host-4-w", host_id="host-4", hint=(uuid4(), "high", "pkg:h"))

    assert claimed is not None and claimed.theory == "pkg:b"


async def test_a_hold_of_another_theory_counts_no_held_wait(http: httpx.AsyncClient, coordinator: Coordinator) -> None:
    """The hold left after another process's claim took the held build isn't the claimed build's."""
    key = (await submit_as(http, "b1", "b"), "standard")
    now = asyncio.get_running_loop().time()
    coordinator.holds[key] = (now, now + 60, "pkg:gone")

    claimed = await claim_on(http, "host-3")

    assert claimed is not None and claimed["theory"] == "pkg:b"
    assert counts(coordinator, "held_waits") == {"held_waits": 0}


async def test_a_holder_claiming_unwoken_tries_each_tier_with_a_held_build(
    http: httpx.AsyncClient, cache: FakeCache, coordinator: Coordinator
) -> None:
    """host-1 ran ``h``, held as high work, but takes no high work, so ``h`` isn't held for it; the standard build
    held for it, whose hold began later, it takes ahead of the claim waiting on host-0, to which it defers both
    tiers."""
    await learn_high(http, cache)
    held_high = UUID(await submit(http, ["h"]))
    now = asyncio.get_running_loop().time()
    coordinator.holds[(held_high, "high")] = (now, now + 60, "pkg:h")
    _, theory = await held_in_a_busier_batch(http, coordinator)
    coordinator.host_keys["host-1"]["pkg:h"] = None
    coordinator.claim_waiters = [
        (
            ["high", "standard"], _claim_rank(["high", "standard"], "host-0"),
            asyncio.get_running_loop().create_future(), False,
        )
    ]
    coordinator.report_worker("host-0", "host-0-w", ["high", "standard"])

    claimed = await coordinator.claim(["high", "standard"], "host-1-w", 0, host_id="host-1")

    assert claimed is not None and claimed.theory == theory


@pytest.mark.parametrize("woken", [False, True])
async def test_a_holder_swapping_to_its_held_build_takes_no_other_build_of_its_batch(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch, woken: bool
) -> None:
    """Another process's claim took the held build since the ranking was read, so the lock finds the batch's next
    build, of another theory: host-1's claim, unwoken or woken for the held build, leaves it and takes ``a1``, the
    head."""
    batch_id, theory = await held_in_a_busier_batch(http, coordinator)
    await submit_as(http, "a1", "a")
    lock = coordinator._lock_unleased

    async def next_build(*args: Any) -> Any:
        row = await lock(*args)
        return row if row is None or row.theory == "pkg:a" else SimpleNamespace(**{**row._mapping, "theory": "pkg:z"})

    monkeypatch.setattr(coordinator, "_lock_unleased", next_build)

    if woken:
        hint = (UUID(batch_id), "standard", theory)
        claimed, _ = await coordinator._claim(["standard"], "host-1-w", host_id="host-1", hint=hint)
    else:
        claimed = await coordinator.claim(["standard"], "host-1-w", 0, host_id="host-1")

    assert claimed is not None and claimed.theory == "pkg:a"
