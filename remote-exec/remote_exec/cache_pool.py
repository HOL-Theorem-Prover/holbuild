"""Persisted cache membership and lifecycle ordering, independent of the capacity provider."""

import asyncio
import logging
import shlex
from dataclasses import dataclass
from datetime import datetime
from typing import Literal

import sqlalchemy as sa
from pydantic import BaseModel, ConfigDict, Field, field_validator
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine

logger = logging.getLogger(__name__)

# One controller across replicas. Its dedicated session lock survives the short state transactions.
POOL_LOCK = 719483206
ADAPTER_TIMEOUT_SECONDS = 20

Phase = Literal["boot", "dns", "ready", "admit", "serving", "drain", "flush", "stop", "withdraw", "terminate"]


class CacheSlot(BaseModel):
    """A stable cache identity reserved for one temporary instance at a time."""

    model_config = ConfigDict(extra="forbid")
    name: str
    url: str

    @field_validator("url")
    @classmethod
    def public_identity(cls, value: str) -> str:
        from urllib.parse import urlsplit

        parsed = urlsplit(value)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError("cache slot URL must be an HTTPS URL without credentials")
        if parsed.query or parsed.fragment:
            raise ValueError("cache slot URL must not have a query or fragment")
        return value.rstrip("/")


class Instance(BaseModel):
    """Provider inventory; gone means confirmed terminated, not merely absent from its group."""

    model_config = ConfigDict(extra="forbid")
    id: str
    state: Literal["launching", "running", "terminating", "gone"]


class AdapterRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    op: Literal["inventory", "capacity", "heartbeat", "boot", "dns", "ready", "admit", "drain", "flush",
                "stop", "withdraw", "terminate"]
    instance: str | None = None
    slot: str | None = None
    url: str | None = None
    token: str | None = None
    context: str | None = None
    owners: list[str] = Field(default_factory=list)
    target: int | None = None


class AdapterResponse(BaseModel):
    """A short adapter operation; pending operations return a token persisted for the next poll."""

    model_config = ConfigDict(extra="forbid")
    instances: list[Instance] = Field(default_factory=list)
    # Optional CPU scale-out recommendation, never allowed to lower the worker-derived target.
    cpu_target: int = Field(default=0, ge=0)
    done: bool = False
    token: str | None = None
    context: str | None = None
    ingress_stopped_at: datetime | None = None
    durable: bool = False
    error: str | None = None


class AdapterError(RuntimeError):
    """The deployment adapter failed; leave ownership and the lifecycle hook intact."""


class CommandAdapter:
    """Run a deployment-owned command with one JSON request on stdin and one response on stdout."""

    def __init__(self, command: str) -> None:
        self.argv = shlex.split(command)
        if not self.argv:
            raise ValueError("cache pool adapter command must not be empty")

    async def call(self, request: AdapterRequest) -> AdapterResponse:
        process = await asyncio.create_subprocess_exec(
            *self.argv, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, _ = await asyncio.wait_for(
                process.communicate(request.model_dump_json().encode()), ADAPTER_TIMEOUT_SECONDS
            )
        except (TimeoutError, asyncio.CancelledError):
            if process.returncode is None:
                process.kill()
            await process.wait()
            raise
        if process.returncode != 0:
            # Commands may use credentials internally: never copy their output into diagnostics.
            raise AdapterError(f"cache pool adapter {request.op} exited {process.returncode}")
        try:
            return AdapterResponse.model_validate_json(stdout)
        except ValueError:
            raise AdapterError(f"cache pool adapter {request.op} returned an invalid response") from None


@dataclass(frozen=True)
class Member:
    slot: str
    url: str
    owner: str
    phase: Phase
    token: str | None
    context: str | None
    ingress_stopped_at: datetime | None


@dataclass(frozen=True)
class SlotStatus:
    slot: str
    url: str
    owner: str
    phase: str
    error: str | None


HELD_TARGET = sa.text(
    "SELECT least(coalesce(max(workers), 0), :cap) FROM burst_demand "
    "WHERE at >= CAST(:now AS timestamptz) - make_interval(secs => :hold)"
)


class CachePool:
    """Own the slot registry; only the elected controller may advance lifecycle state."""

    def __init__(self, engine: AsyncEngine, slots: list[CacheSlot], adapter: CommandAdapter, *, drain_seconds: int,
                 hold_seconds: float = 900, workers_per_node: int = 0, max_workers: int = 240) -> None:
        if drain_seconds < 60:
            raise ValueError("cache drain must be at least 60 seconds")
        if not 1 <= len(slots) <= 4 or len({s.name for s in slots}) != len(slots):
            raise ValueError("cache pool must have one to four distinct slots")
        if len({s.url for s in slots}) != len(slots):
            raise ValueError("cache slot URLs must be distinct")
        self.engine = engine
        self.slots = slots
        self.adapter = adapter
        self.drain_seconds = drain_seconds
        self.hold_seconds = hold_seconds
        self.workers_per_node = workers_per_node
        self.max_workers = max_workers

    async def ready_urls(self) -> list[str]:
        async with self.engine.connect() as conn:
            return list((await conn.scalars(sa.text(
                "SELECT url FROM cache_slots WHERE phase = 'serving' ORDER BY slot"
            ))).all())

    async def status(self) -> list[SlotStatus]:
        async with self.engine.connect() as conn:
            rows = (await conn.execute(sa.text(
                "SELECT slot,url,owner,phase,error FROM cache_slots ORDER BY slot"
            ))).mappings()
            return [SlotStatus(**row) for row in rows]

    async def _members(self, conn: AsyncConnection) -> list[Member]:
        rows = (await conn.execute(sa.text(
            "SELECT slot, url, owner, phase, token, context, ingress_stopped_at FROM cache_slots ORDER BY slot"
        ))).mappings()
        return [Member(**row) for row in rows]

    async def reconcile(self, now: datetime) -> None:
        """Heartbeat hooks, reconcile capacity and advance at most one operation per owned member."""
        async with self.engine.connect() as connection:
            conn = await connection.execution_options(isolation_level="AUTOCOMMIT")
            if not await conn.scalar(sa.text("SELECT pg_try_advisory_lock(:key)"), {"key": POOL_LOCK}):
                return
            try:
                await self._reconcile(conn, now)
            finally:
                # A pooled connection must never retain this lock after its controller stops.
                try:
                    await asyncio.shield(conn.execute(sa.text("SELECT pg_advisory_unlock(:key)"), {"key": POOL_LOCK}))
                except BaseException:
                    await conn.invalidate()
                    raise

    async def _reconcile(self, conn: AsyncConnection, now: datetime) -> None:
        members = await self._members(conn)
        inventory = await self.adapter.call(AdapterRequest(op="inventory", owners=[m.owner for m in members]))
        instances = {instance.id: instance for instance in inventory.instances}
        # Inventory also supplies the provider's CPU-only scale-out recommendation. One writer owns capacity.
        workers = await conn.scalar(HELD_TARGET, {"now": now, "hold": self.hold_seconds, "cap": self.max_workers})
        await conn.execute(sa.text(
            "DELETE FROM cache_cpu_demand WHERE at < CAST(:now AS timestamptz) - make_interval(secs => :hold)"
        ), {"now": now, "hold": self.hold_seconds})
        if inventory.cpu_target and self.workers_per_node > 0:
            await conn.execute(sa.text("INSERT INTO cache_cpu_demand(at,target) VALUES (:now,:target)"),
                               {"now": now, "target": min(len(self.slots), inventory.cpu_target)})
        cpu = await conn.scalar(sa.text("SELECT coalesce(max(target),0) FROM cache_cpu_demand"))
        floor = cache_target(workers, self.workers_per_node, len(self.slots))
        target = min(len(self.slots), max(floor, cpu)) if self.workers_per_node > 0 else 0
        try:
            await self.adapter.call(AdapterRequest(op="capacity", target=target))
        except (AdapterError, OSError, TimeoutError) as error:
            logger.warning("cache capacity request failed; continuing lifecycle hooks: %s", error)
        for member in members:
            try:
                await self._reconcile_member(conn, member, instances.get(member.owner), now)
            except (AdapterError, OSError, TimeoutError) as error:
                logger.warning("cache slot %s: %s", member.slot, error)
                await conn.execute(sa.text("UPDATE cache_slots SET error=:error WHERE slot=:slot AND owner=:owner"),
                                   {"error": str(error), "slot": member.slot, "owner": member.owner})
        owners = {member.owner for member in members}
        occupied = {member.slot for member in await self._members(conn)}
        vacant = iter(slot for slot in self.slots if slot.name not in occupied)
        for instance in inventory.instances:
            if instance.state != "launching" or instance.id in owners:
                continue
            slot = next(vacant, None)
            if slot is None:
                break
            await conn.execute(sa.text(
                "INSERT INTO cache_slots (slot,url,owner,phase) VALUES (:slot,:url,:owner,'boot')"
            ), {"slot": slot.name, "url": slot.url, "owner": instance.id})

    async def _reconcile_member(self, conn: AsyncConnection, member: Member, instance: Instance | None,
                                now: datetime) -> None:
        if instance is None:
            logger.error("cache owner %s missing from authoritative inventory; keeping slot %s", member.owner,
                         member.slot)
            return
        if instance.state == "gone":
            await self._save(conn, member, "withdraw", token=member.token)
            # Withdrawal is idempotent and compares the owner's DNS values before deleting.
            result = await self.adapter.call(AdapterRequest(
                    op="withdraw", instance=member.owner, slot=member.slot, url=member.url, token=member.token,
                    context=member.context
            ))
            if result.done:
                await conn.execute(sa.text("DELETE FROM cache_slots WHERE slot=:slot AND owner=:owner"),
                                   {"slot": member.slot, "owner": member.owner})
            else:
                await self._save(conn, member, "withdraw", token=result.token, error=result.error)
            return
        await self.adapter.call(AdapterRequest(op="heartbeat", instance=member.owner))
        if instance.state == "terminating" and member.phase not in {
            "drain", "flush", "stop", "withdraw", "terminate"
        }:
            await self._save(conn, member, "drain")
            return
        await self._advance(conn, member, now)

    async def _save(self, conn: AsyncConnection, member: Member, phase: Phase, *,
                    token: str | None = None, context: str | None = None, stopped_at: datetime | None = None,
                    error: str | None = None) -> None:
        await conn.execute(sa.text(
            "UPDATE cache_slots SET phase=:phase, token=:token, context=coalesce(:context,context), error=:error, "
            "ingress_stopped_at=coalesce(:stopped_at,ingress_stopped_at) WHERE slot=:slot AND owner=:owner"
        ), {"phase": phase, "token": token, "context": context, "stopped_at": stopped_at, "error": error,
            "slot": member.slot, "owner": member.owner})

    async def _advance(self, conn: AsyncConnection, member: Member, now: datetime) -> None:
        if member.phase == "serving":
            return
        if member.phase == "flush" and (member.ingress_stopped_at is None or
                (now - member.ingress_stopped_at).total_seconds() < self.drain_seconds):
            return
        result = await self.adapter.call(AdapterRequest(
            op=member.phase, instance=member.owner, slot=member.slot, url=member.url, token=member.token,
            context=member.context
        ))
        if not result.done or (member.phase == "flush" and not result.durable):
            if result.error:
                logger.warning("cache %s %s: %s", member.slot, member.phase, result.error)
            await self._save(conn, member, member.phase, token=result.token, context=result.context, error=result.error)
            return
        if member.phase == "drain":
            if result.ingress_stopped_at is None or result.ingress_stopped_at.tzinfo is None:
                raise AdapterError("ingress drain completed without its stop timestamp")
            await self._save(conn, member, "flush", stopped_at=result.ingress_stopped_at)
            return
        following: dict[Phase, Phase] = {
            "boot": "dns", "dns": "ready", "ready": "admit", "admit": "serving",
            "flush": "stop", "stop": "withdraw", "withdraw": "terminate", "terminate": "terminate",
        }
        await self._save(conn, member, following[member.phase], context=result.context)


def cache_target(workers: int, workers_per_cache: int, slots: int) -> int:
    """Map the held worker burst demand to bounded cache capacity; zero disables new capacity."""
    if workers_per_cache <= 0:
        return 0
    return min(slots, max(0, (workers + workers_per_cache - 1) // workers_per_cache))
