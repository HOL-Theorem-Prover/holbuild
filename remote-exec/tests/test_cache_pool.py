"""Cache lifecycle invariants through the real registry and a deployment-adapter fixture."""

import asyncio
from datetime import UTC, datetime, timedelta

import pytest
import pytest_asyncio
import sqlalchemy as sa
from sqlalchemy.ext.asyncio import AsyncEngine

from remote_exec.cache_pool import (
    AdapterError,
    AdapterRequest,
    AdapterResponse,
    CachePool,
    CacheSlot,
    CommandAdapter,
    Instance,
    cache_target,
)


class Provider(CommandAdapter):
    def __init__(self) -> None:
        self.instances: list[Instance] = []
        self.calls: list[AdapterRequest] = []
        self.durable = False
        self.ready = True
        self.now = datetime(2026, 1, 1, tzinfo=UTC)
        self.block: asyncio.Event | None = None
        self.entered = asyncio.Event()
        self.cpu_target = 0
        self.fail_owner: str | None = None

    async def call(self, request: AdapterRequest) -> AdapterResponse:
        self.calls.append(request)
        if request.op == "inventory":
            self.entered.set()
            if self.block is not None:
                await self.block.wait()
            return AdapterResponse(instances=self.instances, cpu_target=self.cpu_target)
        if request.instance == self.fail_owner and self.fail_owner is not None:
            raise AdapterError("fixture provider error")
        if request.op == "drain":
            return AdapterResponse(done=True, ingress_stopped_at=self.now)
        if request.op == "flush":
            return AdapterResponse(done=True, durable=self.durable)
        if request.op == "ready":
            return AdapterResponse(done=self.ready)
        return AdapterResponse(done=True)


@pytest_asyncio.fixture
async def pool(remote_exec_engine: AsyncEngine) -> CachePool:
    async with remote_exec_engine.begin() as conn:
        await conn.execute(sa.text("DELETE FROM cache_slots"))
        await conn.execute(sa.text("DELETE FROM cache_cpu_demand"))
        await conn.execute(sa.text("DELETE FROM burst_demand"))
    return CachePool(remote_exec_engine, [CacheSlot(name=str(n), url=f"https://cache-{n}.example") for n in range(3, 7)],
                     Provider(), drain_seconds=60)


def provider(pool: CachePool) -> Provider:
    assert isinstance(pool.adapter, Provider)
    return pool.adapter


async def phase(pool: CachePool, owner: str) -> str | None:
    async with pool.engine.connect() as conn:
        return await conn.scalar(sa.text("SELECT phase FROM cache_slots WHERE owner=:owner"), {"owner": owner})


async def launch(pool: CachePool) -> None:
    p = provider(pool)
    for _ in range(6):
        await pool.reconcile(p.now)


async def test_concurrent_controllers_claim_four_distinct_slots_and_refuse_fifth(pool: CachePool) -> None:
    p = provider(pool)
    p.instances = [Instance(id=f"instance-{n}", state="launching") for n in range(5)]
    other = CachePool(pool.engine, pool.slots, p, drain_seconds=60)
    await asyncio.gather(pool.reconcile(p.now), other.reconcile(p.now))
    async with pool.engine.connect() as conn:
        rows = (await conn.execute(sa.text("SELECT slot,owner FROM cache_slots"))).all()
    assert len(rows) == len({r.slot for r in rows}) == len({r.owner for r in rows}) == 4
    assert "instance-4" not in {r.owner for r in rows}


async def test_no_discovery_until_readiness_and_launch_hook_not_completed_before_probe(pool: CachePool) -> None:
    p = provider(pool)
    p.instances = [Instance(id="a", state="launching")]
    p.ready = False
    for _ in range(6):
        await pool.reconcile(p.now)
        assert await pool.ready_urls() == []
    p.ready = True
    await pool.reconcile(p.now)
    assert await pool.ready_urls() == []
    await pool.reconcile(p.now)
    assert await pool.ready_urls() == ["https://cache-3.example"]
    operations = [r.op for r in p.calls if r.instance == "a"]
    assert operations.index("boot") < operations.index("dns") < operations.index("ready") < operations.index("admit")


async def test_drain_waits_after_ingress_stop_and_requires_durability_even_after_restart(pool: CachePool) -> None:
    p = provider(pool)
    p.instances = [Instance(id="a", state="launching")]
    await launch(pool)
    p.instances = [Instance(id="a", state="terminating")]
    await pool.reconcile(p.now)
    assert await pool.ready_urls() == []
    await pool.reconcile(p.now)
    assert await phase(pool, "a") == "flush"
    restarted = CachePool(pool.engine, pool.slots, p, drain_seconds=60)
    await restarted.reconcile(p.now + timedelta(seconds=59))
    assert not any(r.op == "flush" for r in p.calls)
    await restarted.reconcile(p.now + timedelta(seconds=60))
    assert await phase(pool, "a") == "flush"
    assert not any(r.op in {"stop", "withdraw", "terminate"} for r in p.calls)
    p.durable = True
    for _ in range(4):
        await restarted.reconcile(p.now + timedelta(seconds=61))
    operations = [r.op for r in p.calls if r.instance == "a"]
    assert operations.index("drain") < operations.index("flush") < operations.index("stop")
    assert operations.index("stop") < operations.index("withdraw") < operations.index("terminate")
    assert await phase(pool, "a") == "terminate"  # hook completion alone cannot free the slot
    p.instances = [Instance(id="a", state="gone")]
    await restarted.reconcile(p.now + timedelta(seconds=62))
    assert await phase(pool, "a") is None


async def test_absent_inventory_is_not_confirmation_of_termination(pool: CachePool) -> None:
    p = provider(pool)
    p.instances = [Instance(id="a", state="launching")]
    await launch(pool)
    p.instances = []
    await pool.reconcile(p.now)
    assert await phase(pool, "a") == "serving"
    assert not any(r.op == "withdraw" for r in p.calls)


async def test_leader_does_not_hold_database_transaction_during_adapter_io(pool: CachePool) -> None:
    p = provider(pool)
    p.block = asyncio.Event()
    running = asyncio.create_task(pool.reconcile(p.now))
    await p.entered.wait()
    try:
        async with pool.engine.connect() as conn:
            held = await conn.scalar(sa.text(
                "SELECT count(*) FROM pg_stat_activity WHERE state='idle in transaction' "
                "AND query LIKE '%cache_slots%'"
            ))
        assert held == 0
        other = CachePool(pool.engine, pool.slots, p, drain_seconds=60)
        await asyncio.wait_for(other.reconcile(p.now), 1)
        assert len([r for r in p.calls if r.op == "inventory"]) == 1  # one elected controller
    finally:
        p.block.set()
        await running
    await pool.reconcile(p.now)
    assert len([r for r in p.calls if r.op == "inventory"]) == 2


async def test_cpu_backup_cannot_lower_worker_floor_and_survives_restart_hold(pool: CachePool) -> None:
    p = provider(pool)
    pool.workers_per_node = 15
    async with pool.engine.begin() as conn:
        await conn.execute(sa.text("INSERT INTO burst_demand(at,workers) VALUES (:at,45)"), {"at": p.now})
    await pool.reconcile(p.now)
    assert [r.target for r in p.calls if r.op == "capacity"][-1] == 3
    p.cpu_target = 4
    await pool.reconcile(p.now)
    assert [r.target for r in p.calls if r.op == "capacity"][-1] == 4
    p.cpu_target = 0
    restarted = CachePool(pool.engine, pool.slots, p, drain_seconds=60, hold_seconds=900)
    restarted.workers_per_node = 15
    await restarted.reconcile(p.now + timedelta(seconds=899))
    assert [r.target for r in p.calls if r.op == "capacity"][-1] == 4
    await restarted.reconcile(p.now + timedelta(seconds=901))
    assert [r.target for r in p.calls if r.op == "capacity"][-1] == 0
    restarted.workers_per_node = 0
    p.cpu_target = 4
    await restarted.reconcile(p.now + timedelta(seconds=902))
    assert [r.target for r in p.calls if r.op == "capacity"][-1] == 0


async def test_replicas_read_shared_worker_demand_before_each_capacity_write(pool: CachePool) -> None:
    p = provider(pool)
    pool.workers_per_node = 15
    other = CachePool(pool.engine, pool.slots, p, drain_seconds=60, workers_per_node=15)
    await other.reconcile(p.now)
    async with pool.engine.begin() as conn:
        await conn.execute(sa.text("INSERT INTO burst_demand(at,workers) VALUES (:at,60)"), {"at": p.now})
    await pool.reconcile(p.now)
    await other.reconcile(p.now)
    assert [r.target for r in p.calls if r.op == "capacity"] == [0, 4, 4]


async def test_one_broken_instance_does_not_starve_other_launches_or_heartbeats(pool: CachePool) -> None:
    p = provider(pool)
    p.instances = [Instance(id="a", state="launching"), Instance(id="b", state="launching")]
    await pool.reconcile(p.now)
    p.fail_owner = "a"
    for _ in range(5):
        await pool.reconcile(p.now)
    assert await phase(pool, "a") == "boot"
    assert await phase(pool, "b") == "serving"
    errors = {s.owner: s.error for s in await pool.status()}
    assert errors == {"a": "fixture provider error", "b": None}


async def test_cancelled_controller_releases_leadership_before_returning_connection(pool: CachePool) -> None:
    p = provider(pool)
    p.block = asyncio.Event()
    running = asyncio.create_task(pool.reconcile(p.now))
    await p.entered.wait()
    running.cancel()
    with pytest.raises(asyncio.CancelledError):
        await running
    p.block.set()
    other = CachePool(pool.engine, pool.slots, p, drain_seconds=60)
    await asyncio.wait_for(other.reconcile(p.now), 1)
    assert len([r for r in p.calls if r.op == "inventory"]) == 2


@pytest.mark.parametrize(("workers", "ratio", "expected"), [(0, 15, 0), (1, 15, 1), (15, 15, 1), (16, 15, 2),
                                                          (60, 15, 4), (240, 15, 4), (240, 0, 0)])
def test_worker_mapping_is_bounded_and_zero_ratio_disables_capacity(workers: int, ratio: int, expected: int) -> None:
    assert cache_target(workers, ratio, 4) == expected


@pytest.mark.parametrize("url", ["http://cache.example", "https://u:p@cache.example", "https://cache.example#fragment"])
def test_slot_identity_requires_credential_free_https(url: str) -> None:
    with pytest.raises(ValueError):
        CacheSlot(name="slot", url=url)


async def test_failed_readiness_deadline_drains_before_releasing_failed_launch(pool: CachePool) -> None:
    p = provider(pool)
    p.instances = [Instance(id="failed", state="launching")]
    p.ready = False
    await launch(pool)
    assert await phase(pool, "failed") == "ready"
    p.now += timedelta(seconds=901)
    restarted = CachePool(pool.engine, pool.slots, p, drain_seconds=60)
    await restarted.reconcile(p.now)
    assert await phase(pool, "failed") == "drain"
    await restarted.reconcile(p.now)
    await restarted.reconcile(p.now + timedelta(seconds=59))
    assert not any(r.op in {"flush", "stop", "withdraw", "terminate"} for r in p.calls)
    p.durable = True
    for _ in range(4):
        await restarted.reconcile(p.now + timedelta(seconds=60))
    operations = [r.op for r in p.calls if r.instance == "failed"]
    assert operations.index("drain") < operations.index("flush") < operations.index("stop")
    assert operations.index("stop") < operations.index("withdraw") < operations.index("terminate")
    p.instances = [Instance(id="failed", state="gone"), Instance(id="replacement", state="launching")]
    await restarted.reconcile(p.now + timedelta(seconds=61))
    assert await phase(pool, "failed") is None
    assert await phase(pool, "replacement") == "boot"


async def test_explicit_launch_failure_enters_verified_cleanup(pool: CachePool, monkeypatch) -> None:
    p = provider(pool)
    p.instances = [Instance(id="failed", state="launching")]
    await pool.reconcile(p.now)
    original = p.call

    async def fail_configure(request: AdapterRequest) -> AdapterResponse:
        if request.op == "boot":
            return AdapterResponse(done=False, error="configuration failed")
        return await original(request)

    monkeypatch.setattr(p, "call", fail_configure)
    await pool.reconcile(p.now)
    assert await phase(pool, "failed") == "drain"
    assert not any(r.op == "terminate" for r in p.calls)
