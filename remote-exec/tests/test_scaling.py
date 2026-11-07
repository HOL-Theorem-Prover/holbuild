import logging
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import httpx
import pytest
from pydantic import ValidationError
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from conftest import CLIENT_TOKEN, WORKER_TOKEN
from remote_exec import app as app_module
from remote_exec import coordinator as coordinator_module
from remote_exec.coordinator import Coordinator, HostReport, QueueCounts, Settings, burst_demand, is_auth_failure
from test_coordinator import claim, input_key, submit

CLIENT = {"Authorization": f"Bearer {CLIENT_TOKEN}"}
WORKER = {"Authorization": f"Bearer {WORKER_TOKEN}"}


def counts(ready: int = 0, running: int = 0, ready_high: int = 0, running_high: int = 0) -> QueueCounts:
    return QueueCounts(
        waiting=0, ready_standard=ready, ready_high=ready_high, running_standard=running, running_high=running_high
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
    await scaled.sweep()

    response = await http.get("/v1/queue", headers=CLIENT)
    assert response.status_code == 200
    assert response.json() == {
        "waiting": 1,
        "ready_standard": 1,
        "ready_high": 0,
        "running_standard": 1,
        "running_high": 0,
        "desired_burst_workers": 0,  # the route's coordinator has no burst workers to ask for
        "hosts": [],
    }
    assert (await scaled.queue()).desired_burst_workers == 1
    assert (await http.get("/v1/queue", headers=WORKER)).status_code == 401


async def test_failing_scale_command_neither_stops_the_sweep_nor_counts_as_applied(
    http: httpx.AsyncClient, coordinator: Coordinator, remote_exec_engine: AsyncEngine, tmp_path: Path
) -> None:
    scaled, calls = scaled_coordinator(coordinator, tmp_path, "exit 1")
    await submit(http, ["a"])
    assert await claim(http) is not None
    async with remote_exec_engine.begin() as connection:
        await connection.execute(sa.text("UPDATE leases SET expires_at = now() - interval '1 second'"))

    await scaled.sweep()
    await scaled.sweep()

    assert await claim(http) is not None  # the sweep expired the lease despite the failing command
    assert calls.read_text().split() == ["0", "0"]  # retried, since it never succeeded


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


def host_report(host_id: str, cpu_idle_pct: float | None) -> dict[str, Any]:
    return {
        "id": host_id,
        "cpu_idle_pct": cpu_idle_pct,
        "mem_total": 64 << 30,
        "mem_available": 40 << 30,
        "budget": 52 << 30,
        "reserved": 6 << 30,
        "leases": 2,
        "memory_short": False,
    }


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
