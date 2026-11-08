import asyncio
import logging
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from unittest.mock import AsyncMock

import httpx
import pytest
from pydantic import ValidationError
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from conftest import CLIENT_TOKEN, WORKER_TOKEN
from remote_exec import app as app_module
from remote_exec import coordinator as coordinator_module
from remote_exec.coordinator import (
    Coordinator,
    HostReport,
    QueueCounts,
    ScaleRun,
    Settings,
    burst_demand,
    is_auth_failure,
)
from test_coordinator import claim, input_key, submit

CLIENT = {"Authorization": f"Bearer {CLIENT_TOKEN}"}
WORKER = {"Authorization": f"Bearer {WORKER_TOKEN}"}


def counts(
    ready: int = 0,
    running: int = 0,
    ready_high: int = 0,
    running_high: int = 0,
    ready_run: int = 0,
    running_run: int = 0,
    high_run: int = 0,
) -> QueueCounts:
    return QueueCounts(
        waiting=0,
        ready_standard=ready,
        ready_high=ready_high,
        running_standard=running,
        running_high=running_high,
        ready_run=ready_run,
        running_run=running_run,
        high_run=high_run,
    )


@pytest.mark.parametrize(
    ("queue", "expected"),
    [
        (counts(), 0),
        (counts(ready=1, running=1), 0),  # the two warm workers take them
        (counts(ready=3, running=2), 3),
        (counts(ready_high=1), 1),  # warm workers are standard-tier, so a high action needs a burst worker
        (counts(running=2, ready_high=1, running_high=1), 2),
        (counts(ready=30, running=10), 16),  # capped
    ],
)
def test_burst_demand(queue: QueueCounts, expected: int) -> None:
    assert burst_demand(queue, warm_workers=2, max_burst_workers=16) == expected


def scaled_coordinator(coordinator: Coordinator, tmp_path: Path, script: str) -> tuple[Coordinator, Path]:
    """A coordinator with 1 warm worker, at most 4 burst ones, a 100 s hold, and a scale command running
    ``script`` with the count appended to ``tmp_path/scaled``."""
    calls = tmp_path / "scaled"
    command = tmp_path / "scale"
    command.write_text(f'#!/bin/sh\necho "$1" >> {calls}\n{script}\n')
    command.chmod(0o755)
    settings = coordinator.settings.model_copy(
        update={"warm_workers": 1, "max_burst_workers": 4, "scale_down_hold_s": 100.0, "scale_cmd": str(command)}
    )
    scaled = Coordinator(coordinator.engine, coordinator.cache, settings)
    return scaled, calls


async def test_sweep_runs_the_scale_command_when_the_held_target_changes_and_keeps_it_across_restarts(
    http: httpx.AsyncClient, coordinator: Coordinator, tmp_path: Path
) -> None:
    start = datetime(2026, 1, 1, tzinfo=UTC)
    now = start

    def at(seconds: float) -> None:
        nonlocal now
        now = start + timedelta(seconds=seconds)

    scaled, calls = scaled_coordinator(coordinator, tmp_path, "")
    scaled.clock = lambda: now

    await scaled.sweep()  # once at start, so a restarted coordinator corrects the fleet
    await submit(http, ["a", "b", "c"])
    await scaled.sweep()
    assert await claim(http) is not None
    at(50)
    await scaled.sweep()  # same demand: running counts as much as ready
    for _ in range(2):
        assert await claim(http) is not None
    async with scaled.engine.begin() as connection:
        await connection.execute(sa.text("UPDATE actions SET state = 'cancelled'"))
    at(60)
    await scaled.sweep()  # the queue is empty but the hold keeps the workers
    assert calls.read_text().split() == ["0", "2"]

    restarted, _ = scaled_coordinator(coordinator, tmp_path, "")
    restarted.clock = lambda: now
    at(70)
    await restarted.sweep()  # still inside the hold of the demand the first process recorded
    at(151)
    await restarted.sweep()

    assert calls.read_text().split() == ["0", "2", "2", "0"]


async def test_queue_reports_counts_and_the_desired_burst_workers(
    http: httpx.AsyncClient, coordinator: Coordinator, tmp_path: Path
) -> None:
    scaled, _ = scaled_coordinator(coordinator, tmp_path, "")
    await submit(http, ["a", "b", "c"], [("c", "a")])
    assert await claim(http) is not None
    await submit(http, ["r1", "r2", "r3"], **{"class": "run"})
    async with coordinator.engine.begin() as connection:
        await connection.execute(sa.text("UPDATE actions SET tier = 'high' WHERE theory = 'pkg:r1'"))
    assert await claim(http, "high") is not None
    await scaled.sweep()

    response = await http.get("/v1/queue", headers=CLIENT)
    assert response.status_code == 200
    assert response.json() | {"phases": None} == {
        "waiting": 1,
        "ready_standard": 3,
        "ready_high": 0,
        "running_standard": 1,
        "running_high": 1,
        "ready_run": 2,
        "running_run": 1,
        "run_slots": 30,
        "run_floor": 0,
        "desired_burst_workers": 0,  # the route's coordinator has no burst workers to ask for
        "hosts": [],
        "phases": None,  # see test_queue_sums_the_phases_workers_reported_in_the_last_ten_minutes
        "scaler": None,  # nor a scale command
    }
    assert (await scaled.queue()).desired_burst_workers == 4

    coordinator.scaler = ScaleRun(4, datetime(2026, 1, 1, 12, tzinfo=UTC), "scale 4 exited 1")
    response = await http.get("/v1/queue", headers=CLIENT)
    assert response.json()["scaler"] == {"workers": 4, "at": "2026-01-01T12:00:00+00:00", "error": "scale 4 exited 1"}
    assert (await http.get("/v1/queue", headers=WORKER)).status_code == 401


@pytest.mark.parametrize(("slots", "floor", "effective"), [(30, 4, 4), (2, 8, 2), (0, 4, 0)])
async def test_queue_reports_effective_run_capacity(
    http: httpx.AsyncClient, coordinator: Coordinator, slots: int, floor: int, effective: int
) -> None:
    coordinator.settings.run_slots = slots
    coordinator.settings.run_floor = floor

    response = await http.get("/v1/queue", headers=CLIENT)

    assert response.status_code == 200
    assert response.json()["run_slots"] == slots
    assert response.json()["run_floor"] == effective


async def test_failing_scale_command_neither_stops_the_sweep_nor_counts_as_applied(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: AsyncEngine, tmp_path: Path
) -> None:
    scaled, calls = scaled_coordinator(coordinator, tmp_path, "exit 1")
    now = datetime(2026, 1, 1, tzinfo=UTC)
    scaled.clock = lambda: now
    await submit(http, ["a"])
    assert await claim(http) is not None
    async with remote_exec_engine.begin() as connection:
        await connection.execute(sa.text("UPDATE leases SET expires_at = now() - interval '1 second'"))

    await scaled.sweep()
    await scaled.sweep()

    assert await claim(http) is not None  # the sweep expired the lease despite the failing command
    assert calls.read_text().split() == ["0", "0"]  # retried, since it never succeeded
    assert (await scaled.queue()).scaler == ScaleRun(0, now, f"{tmp_path / 'scale'} 0 exited 1")

    scaled_coordinator(coordinator, tmp_path, "")  # the command works again
    now += timedelta(seconds=10)
    await scaled.sweep()
    await scaled.sweep()

    assert calls.read_text().split() == ["0", "0", "0"]  # once it succeeded, not again for the same target
    assert (await scaled.queue()).scaler == ScaleRun(0, now, None)


async def test_also_claim_takes_the_other_tier_only_when_its_own_has_nothing(
    http: httpx.AsyncClient, remote_exec_engine: AsyncEngine
) -> None:
    await submit(http, ["a", "b"])
    async with remote_exec_engine.begin() as connection:
        await connection.execute(
            sa.text("UPDATE actions SET tier = 'high' WHERE input_key = :key"), {"key": input_key("b")}
        )

    def body(tier: str, also: list[str]) -> dict[str, Any]:
        return {"tier": tier, "also_claim": also, "worker": "w"}

    first = await http.post("/v1/work/claim", json=body("high", ["standard"]), headers=WORKER)
    second = await http.post("/v1/work/claim", json=body("high", ["standard"]), headers=WORKER)
    assert (first.json()["theory"], second.json()["theory"]) == ("pkg:b", "pkg:a")

    await submit(http, ["c"])
    async with remote_exec_engine.begin() as connection:
        await connection.execute(
            sa.text("UPDATE actions SET tier = 'high' WHERE input_key = :key"), {"key": input_key("c")}
        )
    assert (await http.post("/v1/work/claim", json=body("standard", []), headers=WORKER)).status_code == 204


async def test_database_refusing_the_credentials_is_recognized(remote_exec_engine: AsyncEngine) -> None:
    refused = create_async_engine(remote_exec_engine.url.set(username="no_such_role", password="x"))
    try:
        with pytest.raises(Exception) as error:
            async with refused.connect():
                pass
    finally:
        await refused.dispose()
    assert is_auth_failure(error.value)

    with pytest.raises(Exception) as other:
        async with remote_exec_engine.connect() as connection:
            await connection.execute(sa.text("SELECT * FROM no_such_table"))
    assert not is_auth_failure(other.value)


async def test_the_coordinators_connections_are_bounded(
    coordinator: Coordinator, remote_exec_engine: AsyncEngine
) -> None:
    url = remote_exec_engine.url.render_as_string(hide_password=False)
    settings = coordinator.settings.model_copy(update={"database_url": url, "database_pool_size": 3})
    bounded = Coordinator.from_settings(settings)
    try:
        async with bounded.engine.connect() as connection:
            timeouts = await connection.execute(
                sa.text(
                    "SELECT current_setting('statement_timeout'), current_setting('idle_in_transaction_session_timeout')"
                )
            )
            assert timeouts.one() == ("1min", "1min")
        assert bounded.engine.pool.size() == 3  # pyright: ignore[reportAttributeAccessIssue]
    finally:
        await bounded.aclose()


async def test_request_meeting_a_refused_login_exits_the_process(
    coordinator: Coordinator, remote_exec_engine: AsyncEngine, monkeypatch: pytest.MonkeyPatch
) -> None:
    exits: list[int] = []
    monkeypatch.setattr(app_module.os, "_exit", exits.append)
    refused = create_async_engine(remote_exec_engine.url.set(username="no_such_role", password="x"))
    app = app_module.create_app(Coordinator(refused, coordinator.cache, coordinator.settings), coordinator.settings)
    transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
    try:
        async with httpx.AsyncClient(transport=transport, base_url="http://coordinator.test") as client:
            response = await client.get("/v1/queue", headers=CLIENT)
    finally:
        await refused.dispose()

    assert (response.status_code, exits) == (500, [1])


def test_auth_failure_exits_the_process(monkeypatch: pytest.MonkeyPatch) -> None:
    exits: list[int] = []
    monkeypatch.setattr(app_module, "is_auth_failure", lambda error: isinstance(error, PermissionError))
    monkeypatch.setattr(app_module.os, "_exit", exits.append)

    app_module.exit_on_auth_failure(ValueError())
    app_module.exit_on_auth_failure(PermissionError())

    assert exits == [1]


def test_httpx_requests_are_not_logged(monkeypatch: pytest.MonkeyPatch) -> None:
    for name, value in {
        "DATABASE_URL": "postgresql+asyncpg://u:p@127.0.0.1:1/db",
        "CLIENT_TOKEN": "c",
        "WORKER_TOKEN": "w",
        "CACHE_URL": "http://user:secret@cache.test",
    }.items():
        monkeypatch.setenv(f"REMOTE_EXEC_{name}", value)
    app_module.app()

    assert not logging.getLogger("httpx").isEnabledFor(logging.INFO)


async def test_zero_hold_follows_demand_and_the_cap_applies_to_held_demand(
    http: httpx.AsyncClient, coordinator: Coordinator, tmp_path: Path
) -> None:
    scaled, calls = scaled_coordinator(coordinator, tmp_path, "")
    unheld = Coordinator(scaled.engine, scaled.cache, scaled.settings.model_copy(update={"scale_down_hold_s": 0.0}))
    await submit(http, ["a", "b", "c", "d"])

    await unheld.sweep()
    capped = Coordinator(scaled.engine, scaled.cache, scaled.settings.model_copy(update={"max_burst_workers": 1}))
    await capped.sweep()

    assert calls.read_text().split() == ["3", "1"]
    assert (await unheld.queue()).desired_burst_workers == 3


def test_settings_errors_do_not_print_credentials(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("REMOTE_EXEC_CACHE_URL", "https://user:cachesecret@cache.test")
    monkeypatch.setenv("REMOTE_EXEC_WORKER_TOKEN", "workersecret")

    with pytest.raises(ValidationError) as error:
        Settings()  # pyright: ignore[reportCallIssue]

    assert "secret" not in str(error.value)


def host_report(host_id: str, cpu_idle_pct: float | None, rank: int = 0) -> dict[str, Any]:
    return {
        "id": host_id,
        "cpu_idle_pct": cpu_idle_pct,
        "mem_total": 64 << 30,
        "mem_available": 40 << 30,
        "budget": 52 << 30,
        "reserved": 6 << 30,
        "leases": 2,
        "memory_short": False,
        "rank": rank,
    }


@pytest.mark.parametrize(("host_id", "host_rank"), [(None, 0), ("host-a", 0), ("host-a", 1)])
async def test_claim_forwards_optional_host_id_and_rank(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch, host_id: str | None,
    host_rank: int,
) -> None:
    claim = AsyncMock(return_value=None)
    monkeypatch.setattr(coordinator, "claim", claim)
    body: dict[str, Any] = {"tier": "high", "also_claim": ["standard"], "worker": "w1"}
    if host_id is not None:
        body["host"] = host_report(host_id, 30.0, host_rank)
    response = await http.post("/v1/work/claim", json=body, headers=WORKER)
    assert response.status_code == 204
    assert claim.await_args is not None
    assert claim.await_args.args[:3] == (["high", "standard"], "w1", 0)
    assert claim.await_args.kwargs == {"host_id": host_id, "host_rank": host_rank}


async def test_queue_lists_the_hosts_workers_reported(http: httpx.AsyncClient, coordinator: Coordinator) -> None:
    now = datetime(2026, 1, 1, tzinfo=UTC)
    coordinator.clock = lambda: now
    await submit(http, ["a"])
    response = await http.post(
        "/v1/work/claim",
        json={"tier": "standard", "worker": "w1", "host": host_report("h1", 30.0)},
        headers=WORKER,
    )
    token = response.json()["attempt_token"]
    now += timedelta(seconds=10)
    heartbeat = {"host": host_report("h1", None)}
    assert (await http.post(f"/v1/work/{token}/heartbeat", json=heartbeat, headers=WORKER)).status_code == 200
    await http.post(
        "/v1/work/claim",
        json={"tier": "high", "worker": "w2", "host": host_report("h2", 80.0)},
        headers=WORKER,
    )
    now += timedelta(seconds=5)

    hosts = (await http.get("/v1/queue", headers=CLIENT)).json()["hosts"]
    assert hosts == [
        {**host_report("h1", 30.0), "age_s": 5.0},  # the last idle share measured
        {**host_report("h2", 80.0), "age_s": 5.0},
    ]

    now += timedelta(seconds=120)
    assert (await http.get("/v1/queue", headers=CLIENT)).json()["hosts"] == []
    assert coordinator.hosts == {}


async def test_queue_sums_the_phases_workers_reported_in_the_last_ten_minutes(
    http: httpx.AsyncClient, coordinator: Coordinator
) -> None:
    now = datetime(2026, 1, 1, tzinfo=UTC)
    coordinator.clock = lambda: now
    for phases in ({"claim": 0.5, "hol": 30.0}, {"after_hol": 12.0, "hol": 10.0}):
        response = await http.post(
            "/v1/work/claim", json={"tier": "standard", "worker": "w1", "phases": phases}, headers=WORKER
        )
        assert response.status_code == 204
        now += timedelta(seconds=300)

    seconds = dict.fromkeys(["memory_wait", "claim", "idle", "lease", "release", "before_hol", "exec", "complete"], 0.0)
    totals = (await http.get("/v1/queue", headers=CLIENT)).json()["phases"]
    assert totals == {"window_s": 600, "reports": 1, "seconds": {**seconds, "hol": 10.0, "after_hol": 12.0}}

    now += timedelta(seconds=300)
    assert (await http.get("/v1/queue", headers=CLIENT)).json()["phases"]["reports"] == 0


async def test_a_negative_phase_report_is_refused(http: httpx.AsyncClient) -> None:
    response = await http.post(
        "/v1/work/claim", json={"tier": "standard", "worker": "w1", "phases": {"hol": -1}}, headers=WORKER
    )
    assert response.status_code == 422


async def test_a_heartbeat_with_no_body_still_extends_the_lease(http: httpx.AsyncClient) -> None:
    await submit(http, ["a"])
    claimed = await claim(http)
    assert claimed is not None
    response = await http.post(f"/v1/work/{claimed['attempt_token']}/heartbeat", headers=WORKER)
    assert response.status_code == 200
    assert (await http.get("/v1/queue", headers=CLIENT)).json()["hosts"] == []


async def test_a_malformed_host_report_is_refused(http: httpx.AsyncClient) -> None:
    for report in (
        {**host_report("h1", 30.0), "leases": "many"},
        host_report("h" * 65, 30.0),
        {**host_report("h1", 30.0), "reserved": 2**53 + 1},
        {**host_report("h1", 30.0), "leases": -1},
        host_report("h1", 101.0),
    ):
        response = await http.post(
            "/v1/work/claim", json={"tier": "standard", "worker": "w1", "host": report}, headers=WORKER
        )
        assert response.status_code == 422


async def test_reports_from_more_hosts_than_it_remembers_are_dropped(
    coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(coordinator_module, "MAX_HOSTS", 2)
    for host_id in ("h1", "h2", "h3"):
        coordinator.report_host(HostReport(**host_report(host_id, 50.0)))
    coordinator.report_host(HostReport(**host_report("h1", 10.0)))

    assert [host.report.cpu_idle_pct for host in (await coordinator.queue()).hosts] == [10.0, 50.0]
    assert sorted(coordinator.hosts) == ["h1", "h2"]


@pytest.mark.parametrize(
    ("queue", "slots", "expected"),
    [
        (counts(ready=50, ready_run=50), 2, 0),
        (counts(ready=50, ready_run=50), 0, 0),
        (counts(ready=53, running=1, ready_run=50), 2, 4),
        (counts(ready=10, running=10, ready_run=10, running_run=10), 3, 1),
        (counts(ready_high=50, ready_run=50, high_run=50), 2, 2),
        (counts(ready_high=50, ready_run=50, high_run=50), 0, 0),
        (counts(ready_high=53, ready_run=50, high_run=50), 2, 5),
        (counts(ready_high=20, ready_run=10, high_run=10), 1, 11),
        (counts(ready_high=50, ready_run=20, high_run=20), 2, 16),
    ],
)
def test_burst_demand_caps_both_standard_and_high_run_contributions(
    queue: QueueCounts, slots: int, expected: int
) -> None:
    assert burst_demand(queue, warm_workers=2, max_burst_workers=16, run_slots=slots) == expected


def test_run_slots_defaults_to_thirty_and_rejects_negative_values(coordinator: Coordinator) -> None:
    settings = coordinator.settings.model_dump()
    settings.pop("run_slots")
    assert Settings(**settings).run_slots == 30
    with pytest.raises(ValidationError):
        Settings(**settings, run_slots=-1)


async def test_batch_intake_scales_without_waiting_for_sweep_or_scale_command(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    coordinator.settings.scale_cmd = "unused"
    coordinator.settings.max_burst_workers = 10
    started = asyncio.Event()
    finish = asyncio.Event()
    calls: list[int] = []
    active = 0

    async def scale(command: str, workers: int) -> None:
        nonlocal active
        active += 1
        assert active == 1
        calls.append(workers)
        started.set()
        try:
            await finish.wait()
        finally:
            active -= 1

    monkeypatch.setattr(coordinator, "_scale", scale)
    sweep = None
    try:
        await asyncio.wait_for(submit(http, ["a"]), 5)
        await asyncio.wait_for(started.wait(), 5)
        assert calls == [1]
        assert coordinator.scale_task is not None and not coordinator.scale_task.done()
        await submit(http, ["b", "c"])
        sweep = asyncio.create_task(coordinator.sweep())
        await asyncio.sleep(0)
        assert calls == [1]  # intake and sweep both wait for the first command
    finally:
        finish.set()
        if sweep is not None:
            await sweep
        if coordinator.scale_task is not None:
            await coordinator.scale_task
    assert calls == [1, 3]  # fresh demand is read after acquiring the lock


async def test_intake_scale_requests_are_coalesced(coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch) -> None:
    coordinator.settings.scale_cmd = "unused"
    started = asyncio.Event()
    finish = asyncio.Event()

    async def scale() -> None:
        started.set()
        await finish.wait()

    check = AsyncMock(side_effect=scale)
    monkeypatch.setattr(coordinator, "scale", check)
    for _ in range(20):
        coordinator.request_scale()
    await asyncio.wait_for(started.wait(), 5)
    task = coordinator.scale_task
    try:
        for _ in range(20):
            coordinator.request_scale()
        assert coordinator.scale_task is task
        assert check.await_count == 1
    finally:
        finish.set()
        assert task is not None
        await task
    assert check.await_count == 2


async def test_empty_batch_does_not_request_scaling(
    http: httpx.AsyncClient, coordinator: Coordinator, monkeypatch: pytest.MonkeyPatch
) -> None:
    check = AsyncMock()
    monkeypatch.setattr(coordinator, "scale", check)
    coordinator.settings.scale_cmd = "unused"
    await submit(http, [])
    assert coordinator.scale_task is None
    check.assert_not_awaited()
