import logging
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import httpx
import pytest
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from conftest import CLIENT_TOKEN, WORKER_TOKEN
from remote_exec import app as app_module
from remote_exec.coordinator import Coordinator, QueueCounts, burst_demand, is_auth_failure
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
        "desired_burst_workers": 1,  # what the other coordinator's sweep recorded
    }
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
