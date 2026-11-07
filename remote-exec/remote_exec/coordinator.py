"""Scheduling state of remote holbuild builds: batches, their DAG, leases and retries, over Postgres.

Done means the action's key is in the remote cache's ``/ac/``; Postgres holds no result pointers. Lock order
is a batch row first, then its actions and leases, so a completion, an expiry and a cancel never deadlock.
"""

import asyncio
import contextlib
import graphlib
import json
import logging
import os
import shlex
import time
from collections import defaultdict, deque
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, fields, replace
from datetime import UTC, datetime
from typing import Annotated
from uuid import UUID, uuid4

import asyncpg
import httpx
import sqlalchemy as sa
from pydantic import Field, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine, create_async_engine

from remote_exec.cache import cache_nodes, node_identity, ranked_nodes
from remote_exec.cache_pool import HELD_TARGET, CachePool, CacheSlot, CommandAdapter
from remote_exec.formats import Batch, Result
from remote_exec.membership import REFRESH_SECONDS, Membership

logger = logging.getLogger(__name__)

CLAIM_RECHECK_SECONDS = 5  # how often a waiting claim looks for actions another coordinator process made ready
# How long a cache entry found is taken to still be there without asking the cache again.
IN_CACHE_TRUST_SECONDS = 60
# How many requests a release has in flight to the cache at once. At most two releases run at once (a pass over every
# batch and one of single batches), so together they stay within the cache client's 100 connections.
RELEASE_CACHE_CHECKS = 48
RELEASE_SLOW_SECONDS = 5.0  # a release pass that takes this long is logged

# A statement, or a transaction left idle, that runs longer than this is ended by the database, so one stuck
# query can't hold a connection, or the locks it took, for good.
DATABASE_STATEMENT_TIMEOUT = "60s"

# A scale command that runs longer than this is killed, so it can't stall the sweep.
SCALE_CMD_TIMEOUT_S = 60

# A host none of whose workers reported for this long is left out of the queue's hosts, and forgotten.
HOST_REPORT_SECONDS = 120
# Hosts the coordinator remembers at most; a report from another host beyond them is dropped.
MAX_HOSTS = 1000
# The queue sums the phase reports of workers' last this many seconds; at most MAX_PHASE_REPORTS are kept.
PHASE_WINDOW_SECONDS = 600
MAX_PHASE_REPORTS = 100_000


class Settings(BaseSettings):
    """The coordinator's configuration, from ``REMOTE_EXEC_*`` environment variables."""

    # hide_input_in_errors: a validation error would otherwise print every setting, credentials included.
    model_config = SettingsConfigDict(env_prefix="REMOTE_EXEC_", hide_input_in_errors=True)

    database_url: str  # postgresql+asyncpg://...
    client_token: SecretStr
    worker_token: SecretStr
    cache_url: str = Field(default_factory=lambda: os.environ.get("HOLBUILD_REMOTE_CACHE_URL", ""))

    lease_seconds: int = 120
    max_attempts: int = 3
    # A theory whose peak hint reaches this goes to the high-memory tier; set it to what a standard worker holds.
    standard_tier_mb: int = 16000
    retention_hours: int = 168
    # A batch still running this long after its submission fails, so nothing keeps it, or workers for it, alive.
    batch_deadline_hours: float = 12.0
    hint_ttl_days: int = 30
    sweep_seconds: float = 5.0
    events_poll_seconds: float = 1.0
    # An event stream with nothing to send this long sends a blank line, shorter than proxies' idle timeouts.
    events_keepalive_seconds: float = 15.0
    # Database connections the coordinator holds at most, and how long a request waits for one before it fails.
    database_pool_size: int = 20
    database_pool_timeout_s: float = 10.0
    # Burst workers: workers that a scaler starts and stops on top of `warm_workers` always-on ones.
    run_slots: int = Field(default=30, ge=0)
    warm_workers: int = 0
    max_burst_workers: int = 0
    scale_down_hold_s: float = 900.0
    cache_pool_cmd: str | None = None
    cache_slots: list[CacheSlot] = Field(default_factory=list)
    cache_workers_per_node: int = Field(default=15, ge=0)
    cache_drain_seconds: int = Field(default=60, ge=60)
    cache_launch_timeout_seconds: int = Field(default=900, gt=0)
    scale_cmd: str | None = None  # run as `<scale_cmd> <desired burst workers>` when that number changes

    @field_validator("cache_url")
    @classmethod
    def normalize_cache_url(cls, value: str) -> str:
        return ",".join(cache_nodes(value))

class ScaleCommandError(RuntimeError):
    """The scale command failed or timed out."""


class ResultMismatch(ValueError):
    """A result record for another action than the one its attempt token leases."""


@dataclass(frozen=True)
class Claim:
    attempt_token: UUID
    spec_sha256: str
    input_key: str
    theory: str
    lease_s: int
    max_heap_mb: int | None


@dataclass(frozen=True)
class ActionStatus:
    input_key: str
    theory: str
    state: str
    tier: str
    attempts: int
    last_failure: str | None
    log_sha256: str | None
    timings: dict[str, int] | None  # the last result's, in milliseconds; see formats.Result


@dataclass(frozen=True)
class BatchStatus:
    batch_id: UUID
    state: str
    failure: str | None
    actions: list[ActionStatus]


@dataclass(frozen=True)
class QueueCounts:
    """Unfinished actions of running batches, by state and tier."""

    waiting: int
    ready_standard: int
    ready_high: int
    running_standard: int
    running_high: int
    ready_run: int = 0
    running_run: int = 0
    high_run: int = 0  # internal: ready or running high-tier runs, for capped burst demand


# What a host report's counts and sizes may be: JSON's exact integers.
Amount = Annotated[int, Field(ge=0, le=2**53)]


@dataclass(frozen=True)
class HostReport:
    """What a worker reports of its host with a claim or heartbeat (``HostReport`` in worker.py): the share of CPU
    time idle lately, memory in bytes as holbuild's ``--cooperate-dir`` admission sees it, and whether that
    admission would hold a child back now or held the worker back since its last report."""

    id: Annotated[str, Field(max_length=64)]  # the host's boot_id
    cpu_idle_pct: Annotated[float, Field(ge=0, le=100)] | None
    mem_total: Amount | None
    mem_available: Amount | None
    budget: Amount | None
    reserved: Amount
    leases: Amount
    memory_short: bool


# Seconds of a worker's time in one phase since its last report. No upper bound: a worker that couldn't report
# for long sends it all at once, and a refused report would refuse the claim it comes with.
PhaseSeconds = Annotated[float, Field(ge=0, allow_inf_nan=False)]


@dataclass(frozen=True)
class PhaseReport:
    """Where a worker's time went since its last report (``Phases`` in worker.py), in seconds: waiting for memory
    before a claim, in claim requests, sleeping after a claim got nothing, taking and giving up an action's lease
    (scale-in protection, the heartbeat thread), finding the action's holbuild release,
    in exec-action before its first HOL child, from then to its last HOL child's end, after it, all of exec-action
    when the worker can't see HOL children, and reporting the result."""

    memory_wait: PhaseSeconds = 0
    claim: PhaseSeconds = 0
    idle: PhaseSeconds = 0
    lease: PhaseSeconds = 0
    release: PhaseSeconds = 0
    before_hol: PhaseSeconds = 0
    hol: PhaseSeconds = 0
    after_hol: PhaseSeconds = 0
    exec: PhaseSeconds = 0
    complete: PhaseSeconds = 0


@dataclass(frozen=True)
class PhaseTotals:
    """The phase reports workers sent this process in the last ``window_s`` seconds, and their sums."""

    window_s: int
    reports: int
    seconds: PhaseReport


@dataclass(frozen=True)
class HostStatus:
    """A host's latest report, ``age_s`` seconds old, with the latest ``cpu_idle_pct`` measured."""

    report: HostReport
    age_s: float


@dataclass(frozen=True)
class ScaleRun:
    """A run of the scale command: the burst worker target it got, when, and why it failed (None if it didn't)."""

    workers: int
    at: datetime
    error: str | None


@dataclass(frozen=True)
class QueueStatus:
    counts: QueueCounts
    desired_burst_workers: int
    hosts: list[HostStatus]
    phases: PhaseTotals
    scaler: ScaleRun | None  # the scale command's last run in this process


def burst_demand(counts: QueueCounts, warm_workers: int, max_burst_workers: int, run_slots: int = 30) -> int:
    """Burst workers the queue needs now: every ready or running action beyond the warm workers, and at least
    one per high-tier action, since warm workers are standard-tier. Runs contribute at most ``run_slots``
    in each term; the total is at most ``max_burst_workers``."""
    ready = counts.ready_standard + counts.ready_high
    running = counts.running_standard + counts.running_high
    runs = counts.ready_run + counts.running_run
    active = ready + running - runs + min(run_slots, runs)
    high = counts.ready_high + counts.running_high - counts.high_run + min(run_slots, counts.high_run)
    demand = max(0, active - warm_workers, high)
    return min(demand, max_burst_workers)


@dataclass(frozen=True)
class Priority:
    """Where an action stands in its batch's DAG; claims take the deepest, then the widest, first."""

    critical_depth: int  # edges on the longest path from the action to one nothing in the batch depends on
    descendant_count: int  # actions of the batch that depend on it, directly or transitively


def dag_priorities(keys: list[str], edges: list[tuple[str, str]]) -> dict[str, Priority]:
    """The priority of each of ``keys`` in the DAG of ``edges``, ``(input_key, parent input_key)`` pairs.

    Raises graphlib.CycleError when the edges form a cycle, a self-edge included.
    """
    children: dict[str, set[str]] = {key: set() for key in keys}
    for child, parent in edges:
        children[parent].add(child)
    bit = {key: 1 << index for index, key in enumerate(keys)}
    depth: dict[str, int] = {}
    descendants: dict[str, int] = {}  # a bitset of ``bit``s
    # With each action's children as its predecessors, the order visits children before their parents.
    for key in graphlib.TopologicalSorter(children).static_order():
        depth[key] = max((depth[c] + 1 for c in children[key]), default=0)
        descendants[key] = 0
        for c in children[key]:
            descendants[key] |= bit[c] | descendants[c]
    return {key: Priority(depth[key], descendants[key].bit_count()) for key in keys}


def is_auth_failure(error: BaseException) -> bool:
    """Whether ``error``, or an error it wraps, is the database refusing the coordinator's credentials."""
    seen: BaseException | None = error
    while seen is not None:
        if isinstance(seen, asyncpg.InvalidAuthorizationSpecificationError):
            return True
        seen = seen.__cause__ or getattr(seen, "orig", None)
    return False


# A batch's actions are found by key and their edges by subqueries per action and per edge, never by joins. The
# database can't estimate how many rows a batch it hasn't analyzed yet holds, so a join could read every edge and
# action of a large new batch once per action.

# Recompute remaining_deps of the selected waiting or ready actions from their parents' states; an action with
# a parent that isn't done goes back to waiting.
REFRESH = """
UPDATE actions c SET (remaining_deps, state) = (
    SELECT n.remaining, CASE WHEN n.remaining > 0 THEN 'waiting' ELSE c.state END
    FROM (
        SELECT count(*) AS remaining FROM edges e
        WHERE e.batch_id = c.batch_id AND e.input_key = c.input_key AND (
            SELECT p.state FROM actions p WHERE p.batch_id = e.batch_id AND p.input_key = e.parent_key
        ) <> 'done'
    ) n
)
WHERE c.batch_id = :batch_id AND c.input_key = ANY({selected}) AND c.state IN ('waiting', 'ready')
"""
REFRESH_KEYS = sa.text(REFRESH.format(selected="CAST(:keys AS text[])"))
REFRESH_CHILDREN = sa.text(
    REFRESH.format(
        selected="ARRAY(SELECT input_key FROM edges WHERE batch_id = :batch_id AND parent_key = ANY(:keys))"
    )
)

# The waiting actions whose parents are all done, with each parent's input and action-cache keys; see
# Coordinator.release.
RELEASABLE = sa.text("""
SELECT a.batch_id, a.input_key, ARRAY(
    SELECT ROW(e.parent_key, (
        SELECT p.ac_key FROM actions p WHERE p.batch_id = e.batch_id AND p.input_key = e.parent_key
    ))
    FROM edges e WHERE e.batch_id = a.batch_id AND e.input_key = a.input_key
) AS parents
FROM actions a JOIN batches b ON b.id = a.batch_id
WHERE a.state = 'waiting' AND a.remaining_deps = 0 AND b.state = 'running'
AND (CAST(:batch_id AS uuid) IS NULL OR a.batch_id = :batch_id)
""")


# The actions of a batch written by transactions numbered :since or later; see Coordinator.changes.
CHANGED_ACTIONS = sa.text("""
SELECT input_key, theory, state, tier, attempts, last_failure, log_sha256, CAST(timings AS text) FROM actions
WHERE batch_id = :batch_id AND changed_xid >= CAST(CAST(:since AS text) AS xid8)
ORDER BY theory, input_key
""")


# The ready action to claim next; see Coordinator.claim. Only the batches with a ready action of the tiers are
# ranked, each from its own index entries, so a claim reads neither finished batches nor finished actions.
CLAIM = sa.text("""
WITH run_capacity AS MATERIALIZED (
    SELECT :allow_run AND (
        SELECT count(*) FROM actions WHERE state = 'running' AND class = 'run'
    ) < :run_slots AS available
), ready_batches AS MATERIALIZED (
    SELECT b.id, b.created_at, b.max_heap_mb,
        (SELECT count(*) FROM actions r WHERE r.batch_id = b.id AND r.state = 'running') AS running_count,
        (SELECT max(c.last_claimed_at) FROM actions c WHERE c.batch_id = b.id) AS last_claimed_at
    FROM batches b
    WHERE b.state = 'running' AND b.id IN (
        SELECT batch_id FROM actions WHERE state = 'ready' AND tier = ANY(CAST(:tiers AS text[]))
        AND (class = 'build' OR (SELECT available FROM run_capacity))
    )
)
SELECT a.batch_id, a.input_key, a.spec_sha256, a.theory, b.max_heap_mb
FROM actions a
JOIN ready_batches b ON b.id = a.batch_id
WHERE a.state = 'ready' AND a.tier = ANY(CAST(:tiers AS text[]))
AND (a.class = 'build' OR (SELECT available FROM run_capacity))
ORDER BY
    a.class,
    array_position(CAST(:tiers AS text[]), a.tier),
    b.running_count,
    b.last_claimed_at NULLS FIRST,
    b.created_at,
    a.critical_depth DESC,
    a.descendant_count DESC,
    a.theory,
    a.input_key
LIMIT 1 FOR UPDATE OF a SKIP LOCKED
""")


class Coordinator:
    """Owns the database engine and the cache client; every rule of the coordinator lives here."""

    def __init__(self, engine: AsyncEngine, cache: httpx.AsyncClient, settings: Settings) -> None:
        self.engine = engine
        self.cache = cache
        self.settings = settings
        self.cache_nodes = cache_nodes(settings.cache_url)
        self.membership = Membership(self.cache_nodes, [slot.url for slot in settings.cache_slots])
        self.membership_lock = asyncio.Lock()
        self.clock: Callable[[], datetime] = lambda: datetime.now(UTC)
        self.cache_pool = (CachePool(engine, settings.cache_slots, CommandAdapter(settings.cache_pool_cmd),
                                     drain_seconds=settings.cache_drain_seconds, hold_seconds=settings.scale_down_hold_s,
                                     workers_per_node=settings.cache_workers_per_node,
                                     max_workers=settings.max_burst_workers,
                                     launch_timeout_seconds=settings.cache_launch_timeout_seconds)
                           if settings.cache_pool_cmd else None)
        self.scaler: ScaleRun | None = None  # the scale command's last run
        # How many actions this process's release has made ready, and the claims waiting, by the tiers they take
        # and the future that wakes them, oldest first; see claim.
        self.made_ready = 0
        self.claim_waiters: list[tuple[list[str], asyncio.Future[None]]] = []
        # When each cache entry was last found, the checks of the cache under way, and how many times
        # input-missing results forgot both; see _in_cache.
        self.found_in_cache: dict[str, float] = {}
        self.cache_checks: dict[str, asyncio.Task[bool | None]] = {}
        self.cache_forgotten = 0
        # The batches whose releases were asked for and not yet started, None for every batch, and the tasks that
        # run them, one for every batch's and one for single batches'; see request_release.
        self.release_pending: set[UUID | None] = set()
        self.releasers: dict[bool, asyncio.Task[None]] = {}
        # What workers reported of their hosts, by host id, and when. Kept in memory: each coordinator process
        # knows the hosts whose workers' requests reached it.
        self.hosts: dict[str, tuple[datetime, HostReport]] = {}
        # The phase reports of the last PHASE_WINDOW_SECONDS, oldest first, and when each came; also in memory.
        self.phase_reports: deque[tuple[datetime, PhaseReport]] = deque(maxlen=MAX_PHASE_REPORTS)

    @classmethod
    def from_settings(cls, settings: Settings) -> "Coordinator":
        return cls(
            create_async_engine(
                settings.database_url,
                pool_pre_ping=True,
                pool_size=settings.database_pool_size,
                max_overflow=0,
                pool_timeout=settings.database_pool_timeout_s,
                connect_args={
                    "server_settings": {
                        "statement_timeout": DATABASE_STATEMENT_TIMEOUT,
                        "idle_in_transaction_session_timeout": DATABASE_STATEMENT_TIMEOUT,
                    }
                },
            ),
            # Every connection stays open between requests, so bursts of them don't each open a new TLS connection.
            httpx.AsyncClient(
                timeout=30,
                follow_redirects=True,
                limits=httpx.Limits(max_connections=100, max_keepalive_connections=100),
            ),
            settings,
        )

    async def aclose(self) -> None:
        for releaser in self.releasers.values():
            releaser.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await releaser
        await self.cache.aclose()
        await self.engine.dispose()

    async def submit(
        self, batch: Batch, profile: str, action_class: str = "build", max_heap_mb: int | None = None
    ) -> UUID:
        """Store a batch; its actions without uncached parents become ready."""
        batch_id = uuid4()
        parents: defaultdict[str, int] = defaultdict(int)
        for child, _ in batch.edges:
            parents[child] += 1
        priority = dag_priorities([a.input_key for a in batch.actions], batch.edges)
        packages = [a.theory.split(":", 1)[0] for a in batch.actions]
        names = [a.theory.split(":", 1)[1] for a in batch.actions]
        async with self.engine.begin() as conn:
            hints = await conn.execute(
                sa.text(
                    "UPDATE peak_hints SET updated_at = now() WHERE profile = :profile "
                    "AND (package, theory) IN "
                    "(SELECT * FROM unnest(CAST(:packages AS text[]), CAST(:names AS text[]))) "
                    "RETURNING package || ':' || theory, peak_rss_mb"
                ),
                {"profile": profile, "packages": packages, "names": names},
            )
            high = {theory for theory, peak in hints if peak >= self.settings.standard_tier_mb}
            await conn.execute(
                sa.text(
                    "INSERT INTO batches (id, state, profile, max_heap_mb) "
                    "VALUES (:id, :state, :profile, :max_heap_mb)"
                ),
                {
                    "id": batch_id,
                    "state": "running" if batch.actions else "done",
                    "profile": profile,
                    "max_heap_mb": max_heap_mb,
                },
            )
            if batch.actions:
                await conn.execute(
                    sa.text(
                        "INSERT INTO actions "
                        "(batch_id, input_key, ac_key, spec_sha256, theory, remaining_deps, state, tier, "
                        "critical_depth, descendant_count, class) "
                        "VALUES (:batch_id, :input_key, :ac_key, :spec, :theory, :remaining, 'waiting', :tier, "
                        ":depth, :descendants, :class)"
                    ),
                    [
                        {
                            "batch_id": batch_id,
                            "input_key": a.input_key,
                            "ac_key": a.ac_key,
                            "spec": a.spec_sha256,
                            "theory": a.theory,
                            "remaining": parents[a.input_key],
                            "tier": "high" if a.theory in high else "standard",
                            "depth": priority[a.input_key].critical_depth,
                            "descendants": priority[a.input_key].descendant_count,
                            "class": action_class,
                        }
                        for a in batch.actions
                    ],
                )
            if batch.edges:
                await conn.execute(
                    sa.text("INSERT INTO edges (batch_id, input_key, parent_key) VALUES (:batch_id, :child, :parent)"),
                    [{"batch_id": batch_id, "child": child, "parent": parent} for child, parent in batch.edges],
                )
        await self.release(batch_id)
        return batch_id

    async def get(self, batch_id: UUID) -> BatchStatus | None:
        changed = await self.changes(batch_id, 0)
        return None if changed is None else changed[0]

    async def changes(self, batch_id: UUID, since: int) -> tuple[BatchStatus, int] | None:
        """The batch with only the actions written by transactions numbered ``since`` or later, and the ``since``
        to pass next time; ``since`` 0 gives every action.

        The next ``since`` is the oldest transaction still running on the server when this one read, so an action
        written by a transaction that commits later is read next time, maybe again. A long transaction anywhere on
        the server holds ``since`` back, so polls reread what changed since it began until it ends.
        """
        async with self.engine.connect() as conn:
            await conn.execution_options(isolation_level="REPEATABLE READ")  # both reads see one snapshot
            batch = (
                await conn.execute(
                    sa.text(
                        "SELECT state, failure, CAST(pg_snapshot_xmin(pg_current_snapshot()) AS text) AS xmin "
                        "FROM batches WHERE id = :id"
                    ),
                    {"id": batch_id},
                )
            ).first()
            if batch is None:
                return None
            actions = await conn.execute(CHANGED_ACTIONS, {"batch_id": batch_id, "since": str(since)})
            status = BatchStatus(batch_id, batch.state, batch.failure, [ActionStatus(*row[:-1], json.loads(row[-1]) if row[-1] is not None else None) for row in actions])
            return status, int(batch.xmin)

    async def cancel(self, batch_id: UUID) -> str | None:
        """Cancel a running batch; its leases go, so its workers' heartbeats and completions are refused."""
        async with self.engine.begin() as conn:
            state = await self._lock_batch(conn, batch_id)
            if state != "running":
                return state
            await self._end_batch(conn, batch_id, "cancelled", None)
            return "cancelled"

    async def claim(
        self,
        tiers: list[str],
        worker: str,
        wait_s: float = 0,
        disconnected: Callable[[], Awaitable[bool]] | None = None,
    ) -> Claim | None:
        """Lease a ready action to ``worker``, waiting up to ``wait_s`` seconds for one, or None if none became
        ready: of the first of ``tiers`` that has one, the batch with the fewest running actions, then the one
        that least recently had one claimed, then the oldest; within it, the action with the deepest chain of
        dependents, then the most dependents.

        A wait ends early once ``disconnected`` says the worker has gone, so no action is leased to nobody. Each
        action this process's ``release`` makes ready wakes the longest waiting claim that takes its tier, not
        every waiting claim, so hundreds of waiting workers don't all query for it. Waits recheck every
        ``CLAIM_RECHECK_SECONDS``, for actions another coordinator process made ready and for an action whose
        woken claim took another one or lost it to another claim; a claim woken that leaves without trying wakes
        the next.
        """
        loop = asyncio.get_running_loop()
        deadline = loop.time() + wait_s
        woken: asyncio.Future[str] = loop.create_future()  # done once a wake was handed to this claim
        try:
            while True:
                # Taken before the attempt, so an action made ready during it is tried at once, not waited for.
                made_ready = self.made_ready
                claimed = await self._claim(tiers, worker)
                remaining = deadline - loop.time()
                if claimed is not None or remaining <= 0:
                    return claimed
                woken = loop.create_future()
                if self.made_ready == made_ready:
                    waiter = (tiers, woken)
                    self.claim_waiters.append(waiter)
                    try:
                        with contextlib.suppress(TimeoutError):
                            await asyncio.wait_for(asyncio.shield(woken), min(remaining, CLAIM_RECHECK_SECONDS))
                    finally:
                        with contextlib.suppress(ValueError):
                            self.claim_waiters.remove(waiter)
                if disconnected is not None and await disconnected():
                    self._pass_wake(woken)
                    return None
        except asyncio.CancelledError:
            self._pass_wake(woken)
            raise

    async def _claim(self, tiers: list[str], worker: str) -> Claim | None:
        async with self.engine.begin() as conn:
            # A batch's running count and last claim are read without locking its row, so concurrent claims see
            # only each other's committed leases, which at worst lets workers waking together pick the same
            # batch. Locking or updating the batch row here, after the action row, would invert the lock order.
            params = {"tiers": tiers, "allow_run": False, "run_slots": self.settings.run_slots}
            row = (await conn.execute(CLAIM, params)).first()
            if row is None:
                if self.settings.run_slots == 0 or not await conn.scalar(
                    sa.text(
                        "SELECT EXISTS (SELECT 1 FROM actions WHERE state = 'ready' AND class = 'run' "
                        "AND tier = ANY(CAST(:tiers AS text[])))"
                    ),
                    {"tiers": tiers},
                ):
                    return None
                # Serialize only run admission, across replicas. The next statement gets a fresh snapshot
                # after the preceding claimant commits, so its running run counts against the cap.
                # This advisory key is reserved for run admission; no batch writer takes it.
                await conn.execute(sa.text("SELECT pg_advisory_xact_lock(1752132706, 1)"))
                row = (await conn.execute(CLAIM, {**params, "allow_run": True})).first()
                if row is None:
                    return None
            token = uuid4()
            await conn.execute(
                sa.text(
                    "UPDATE actions SET state = 'running', attempts = attempts + 1, last_claimed_at = now() "
                    "WHERE batch_id = :batch_id AND input_key = :input_key"
                ),
                {"batch_id": row.batch_id, "input_key": row.input_key},
            )
            await conn.execute(
                sa.text(
                    "INSERT INTO leases (attempt_token, batch_id, input_key, worker, expires_at) "
                    "VALUES (:token, :batch_id, :input_key, :worker, now() + make_interval(secs => :lease))"
                ),
                {
                    "token": token,
                    "batch_id": row.batch_id,
                    "input_key": row.input_key,
                    "worker": worker,
                    "lease": self.settings.lease_seconds,
                },
            )
        return Claim(token, row.spec_sha256, row.input_key, row.theory, self.settings.lease_seconds, row.max_heap_mb)

    def _wake_claim(self, tier: str) -> None:
        """Count an action of ``tier`` made ready, and wake the longest waiting claim that takes it."""
        self.made_ready += 1
        for waiter in self.claim_waiters:
            tiers, woken = waiter
            if tier in tiers and not woken.done():
                woken.set_result(tier)
                self.claim_waiters.remove(waiter)
                return

    def _pass_wake(self, woken: asyncio.Future[str]) -> None:
        """Hand the wake of a claim leaving without trying, if it got one, to the next claim that takes its tier."""
        if woken.done() and not woken.cancelled():
            self.made_ready -= 1
            self._wake_claim(woken.result())

    def report_host(self, report: HostReport) -> None:
        """Take a worker's report of its host. A report without ``cpu_idle_pct`` keeps the host's last one."""
        previous = self.hosts.get(report.id)
        if previous is None and len(self.hosts) >= MAX_HOSTS:
            return
        if previous is not None and report.cpu_idle_pct is None:
            report = replace(report, cpu_idle_pct=previous[1].cpu_idle_pct)
        self.hosts[report.id] = (self.clock(), report)

    def report_phases(self, report: PhaseReport) -> None:
        """Take a worker's report of where its time went."""
        self.phase_reports.append((self.clock(), report))

    def _phase_totals(self, now: datetime) -> PhaseTotals:
        while self.phase_reports and (now - self.phase_reports[0][0]).total_seconds() >= PHASE_WINDOW_SECONDS:
            self.phase_reports.popleft()
        sums = {
            field.name: round(sum(getattr(report, field.name) for _, report in self.phase_reports), 1)
            for field in fields(PhaseReport)
        }
        return PhaseTotals(PHASE_WINDOW_SECONDS, len(self.phase_reports), PhaseReport(**sums))

    async def heartbeat(self, token: UUID) -> bool:
        """Extend a live lease; False when it expired or was revoked, so the worker should stop."""
        async with self.engine.begin() as conn:
            result = await conn.execute(
                sa.text(
                    "UPDATE leases SET expires_at = now() + make_interval(secs => :lease) "
                    "WHERE attempt_token = :token AND expires_at > now()"
                ),
                {"token": token, "lease": self.settings.lease_seconds},
            )
            return result.rowcount == 1

    async def complete(self, token: UUID, result: Result) -> bool:
        """Apply a worker's result record; False when its lease is stale, and the record is dropped.

        Raises ResultMismatch when the record is for another action than the lease's.
        """
        async with self.engine.begin() as conn:
            batch_id = await conn.scalar(
                sa.text("SELECT batch_id FROM leases WHERE attempt_token = :token"), {"token": token}
            )
            if batch_id is None:
                return False
            await self._lock_batch(conn, batch_id)
            lease = (
                await conn.execute(
                    sa.text(
                        "DELETE FROM leases WHERE attempt_token = :token AND expires_at > now() RETURNING input_key"
                    ),
                    {"token": token},
                )
            ).first()
            if lease is None:
                return False
            action = (
                await conn.execute(
                    sa.text(
                        "SELECT a.input_key, a.spec_sha256, a.theory, a.tier, a.attempts, a.last_failure, a.class AS action_class, b.profile "
                        "FROM actions a JOIN batches b ON b.id = a.batch_id "
                        "WHERE a.batch_id = :batch_id AND a.input_key = :input_key"
                    ),
                    {"batch_id": batch_id, "input_key": lease.input_key},
                )
            ).one()
            if result.spec_sha256 != action.spec_sha256 or result.input_key not in (None, action.input_key):
                raise ResultMismatch(
                    f"result for {result.input_key} (spec {result.spec_sha256}) does not match the lease's action "
                    f"{action.input_key} (spec {action.spec_sha256})"
                )
            await conn.execute(
                sa.text(
                    "UPDATE actions SET log_sha256 = :log, last_failure = :failure, "
                    "timings = CAST(CAST(:timings AS text) AS jsonb) "
                    "WHERE batch_id = :batch_id AND input_key = :input_key"
                ),
                {
                    "log": result.log_sha256,
                    "failure": result.failure,
                    "timings": json.dumps(result.timings) if result.timings is not None else None,
                    "batch_id": batch_id,
                    "input_key": lease.input_key,
                },
            )
            package, theory = action.theory.split(":", 1)
            if result.status != "failed":
                await self._set_state(conn, batch_id, action.input_key, "done")
                if result.peak_rss_mb is not None:
                    await self._record_peak(conn, package, theory, action.profile, result.peak_rss_mb)
                await conn.execute(REFRESH_CHILDREN, {"batch_id": batch_id, "keys": [action.input_key]})
                await self._finish_if_done(conn, batch_id)
            elif result.failure == "memory" and action.tier == "standard":
                # The tier it failed on is the hint: future batches place this theory on the high tier.
                await self._record_peak(conn, package, theory, action.profile, self.settings.standard_tier_mb)
                await conn.execute(
                    sa.text("UPDATE actions SET tier = 'high' WHERE batch_id = :batch_id AND input_key = :input_key"),
                    {"batch_id": batch_id, "input_key": action.input_key},
                )
                await self._retry(conn, batch_id, action.input_key)
            elif result.failure == "unavailable":
                # The worker couldn't start it, so it doesn't count as an attempt.
                await conn.execute(
                    sa.text(
                        "UPDATE actions SET attempts = attempts - 1 WHERE batch_id = :batch_id AND input_key = :input_key"
                    ),
                    {"batch_id": batch_id, "input_key": action.input_key},
                )
                await self._retry(conn, batch_id, action.input_key)
            elif action.attempts < self.settings.max_attempts and (
                result.failure in ("publish", "toolchain", "internal", "memory")
                or (result.failure == "disk" and action.last_failure != "disk")
            ):
                await self._retry(conn, batch_id, action.input_key)
            elif result.failure == "input-missing":
                self._forget_cache_findings()
                await self._input_missing(conn, batch_id, action.input_key, action.theory, action.attempts, result)
            else:
                await self._fail(
                    conn, batch_id, action.input_key, action.action_class, f"{action.theory}: {result.failure}"
                )
        self.request_release(batch_id)
        return True

    def request_release(self, batch_id: UUID | None = None) -> None:
        """Have ``release`` run for ``batch_id``, or every batch, in the background, so neither a worker's
        completion nor the sweep waits on the cache requests it makes.

        Two tasks run the releases asked for, a pass at a time: one the passes over every batch, which the sweep
        asks for, and one those of single batches, so that a completion's or a submission's release doesn't wait
        behind a pass over the whole queue. The requests that arrive during a pass are run together in the next,
        so a burst of completions in one batch costs one more pass, not one each. What is releasable is read from
        the database on each pass, so requests lost with the process are made again by the next sweep.
        """
        self.release_pending.add(batch_id)
        every = batch_id is None
        if every not in self.releasers or self.releasers[every].done():
            self.releasers[every] = asyncio.get_running_loop().create_task(self._run_releases(every))

    async def _run_releases(self, every: bool) -> None:
        while pending := {batch_id for batch_id in self.release_pending if (batch_id is None) == every}:
            self.release_pending -= pending
            for batch_id in pending:
                try:
                    await self.release(batch_id)
                except Exception:
                    logger.exception("releasing %s failed", "every batch" if batch_id is None else batch_id)

    async def released(self) -> None:
        """Wait until no release asked for is pending or running."""
        while running := [releaser for releaser in self.releasers.values() if not releaser.done()]:
            await asyncio.shield(asyncio.gather(*running))

    async def release(self, batch_id: UUID | None = None) -> None:
        """Make waiting actions whose parents are all done ready, once the cache holds each parent's entry.

        A parent the cache doesn't hold is re-queued; a parent the cache can't be asked about leaves its children
        waiting for the next sweep. Each batch's actions are made ready as soon as the cache has answered for that
        batch's parents, so a slow answer holds up only its own batch. No transaction is open during the cache
        requests. A pass that takes RELEASE_SLOW_SECONDS or more is logged.
        """
        while True:
            started = time.monotonic()
            async with self.engine.connect() as conn:
                rows = await conn.execute(RELEASABLE, {"batch_id": batch_id})
                candidates: defaultdict[UUID, dict[str, list[tuple[str, str]]]] = defaultdict(dict)
                for row in rows:
                    candidates[row.batch_id][row.input_key] = list(row.parents)
            limit = asyncio.Semaphore(RELEASE_CACHE_CHECKS)
            results = await asyncio.gather(
                *(self._release_batch(batch, actions, limit) for batch, actions in candidates.items()),
                return_exceptions=True,  # one batch's failure doesn't cut the others' releases short
            )
            for batch, result in zip(candidates, results, strict=True):
                if isinstance(result, BaseException):
                    if not isinstance(result, Exception):
                        raise result
                    logger.error("releasing %s failed", batch, exc_info=result)
            if (seconds := time.monotonic() - started) >= RELEASE_SLOW_SECONDS:
                logger.warning(
                    "releasing %s took %.1f s: %d candidates in %d batches",
                    "every batch" if batch_id is None else batch_id,
                    seconds,
                    sum(map(len, candidates.values())),
                    len(candidates),
                )
            if True not in results:
                return

    async def _release_batch(
        self, batch_id: UUID, candidates: dict[str, list[tuple[str, str]]], limit: asyncio.Semaphore
    ) -> bool:
        """``release`` of the ``candidates`` of one batch, their parents' cache checks ``limit`` at a time with the
        other batches' of the pass. Whether it re-queued a parent."""
        present = await self._in_cache_all({ac_key for parents in candidates.values() for _, ac_key in parents}, limit)
        ready = [key for key, parents in candidates.items() if all(present[ac_key] for _, ac_key in parents)]
        if ready:
            # Taking the batch's lock before its actions', as every other writer does.
            async with self.engine.begin() as conn:
                if await self._lock_batch(conn, batch_id) != "running":
                    return False
                tiers = await conn.scalars(
                    sa.text(
                        "UPDATE actions SET state = 'ready' WHERE batch_id = :batch_id "
                        "AND input_key = ANY(:keys) AND state = 'waiting' AND remaining_deps = 0 RETURNING tier"
                    ),
                    {"batch_id": batch_id, "keys": ready},
                )
                made_ready = list(tiers)
            for tier in made_ready:
                self._wake_claim(tier)
        requeued = False
        for parents in candidates.values():
            for parent, ac_key in parents:
                if present[ac_key] is False:
                    requeued |= await self._requeue_evicted(batch_id, parent)
        return requeued

    async def expire_leases(self) -> None:
        """Send the actions of expired leases back to waiting, or fail them once they used up their attempts.

        ``sweep`` asks for their release afterwards.
        """
        async with self.engine.connect() as conn:
            expired = list(
                await conn.execute(sa.text("SELECT attempt_token, batch_id FROM leases WHERE expires_at <= now()"))
            )
        for token, batch_id in expired:
            async with self.engine.begin() as conn:
                await self._lock_batch(conn, batch_id)
                lease = (
                    await conn.execute(
                        sa.text(
                            "DELETE FROM leases WHERE attempt_token = :token AND expires_at <= now() "
                            "RETURNING input_key"
                        ),
                        {"token": token},
                    )
                ).first()
                if lease is None:
                    continue
                action = (
                    await conn.execute(
                        sa.text(
                            "SELECT theory, state, attempts, class AS action_class FROM actions "
                            "WHERE batch_id = :batch_id AND input_key = :input_key FOR UPDATE"
                        ),
                        {"batch_id": batch_id, "input_key": lease.input_key},
                    )
                ).one()
                if action.state != "running":
                    continue
                if action.attempts >= self.settings.max_attempts:
                    await conn.execute(
                        sa.text(
                            "UPDATE actions SET last_failure = 'internal' "
                            "WHERE batch_id = :batch_id AND input_key = :input_key AND class = 'run'"
                        ),
                        {"batch_id": batch_id, "input_key": lease.input_key},
                    )
                    await self._fail(
                        conn,
                        batch_id,
                        lease.input_key,
                        action.action_class,
                        f"{action.theory}: lease expired {action.attempts} times",
                    )
                else:
                    await self._retry(conn, batch_id, lease.input_key)

    async def fail_overdue(self) -> None:
        """Fail the batches still running ``batch_deadline_hours`` after their submission: one that can't finish,
        such as a high-tier action with no high-tier worker or a parent check the cache keeps refusing, would
        otherwise run, and be kept from retention, forever."""
        hours = self.settings.batch_deadline_hours
        async with self.engine.connect() as conn:
            overdue = list(
                await conn.scalars(
                    sa.text(
                        "SELECT id FROM batches WHERE state = 'running' "
                        "AND created_at < now() - make_interval(secs => :secs)"
                    ),
                    {"secs": hours * 3600},
                )
            )
        for batch_id in overdue:
            async with self.engine.begin() as conn:
                if await self._lock_batch(conn, batch_id) == "running":
                    await self._end_batch(conn, batch_id, "failed", f"deadline: still running after {hours:g} h")

    async def delete_expired(self) -> None:
        """Delete terminal batches past the retention period, a bounded number at a time, and stale peak hints."""
        while True:
            async with self.engine.begin() as conn:
                deleted = await conn.execute(
                    sa.text(
                        "DELETE FROM batches WHERE id IN (SELECT id FROM batches WHERE state <> 'running' "
                        "AND created_at < now() - make_interval(hours => :hours) LIMIT 100)"
                    ),
                    {"hours": self.settings.retention_hours},
                )
            if deleted.rowcount < 100:
                break
        async with self.engine.begin() as conn:
            await conn.execute(
                sa.text("DELETE FROM peak_hints WHERE updated_at < now() - make_interval(days => :days)"),
                {"days": self.settings.hint_ttl_days},
            )

    async def queue(self) -> QueueStatus:
        """The unfinished actions, the burst worker target: the highest demand of the last ``scale_down_hold_s``
        seconds, which the sweeps of every replica record, and of now, the hosts whose workers reported to this
        process in the last ``HOST_REPORT_SECONDS``, by id, and this process's last run of the scale command."""
        async with self.engine.connect() as conn:
            desired = await conn.scalar(HELD_TARGET, self._held_target_params(self.clock()))
            rows = await conn.execute(
                sa.text(
                    "SELECT state, tier, class, count(*) FROM actions "
                    "WHERE state IN ('waiting', 'ready', 'running') GROUP BY state, tier, class"
                )
            )
            count: defaultdict[tuple[str, str], int] = defaultdict(int)
            runs: defaultdict[str, int] = defaultdict(int)
            high_run = 0
            for state, tier, action_class, n in rows:
                count[state, tier] += n
                if action_class == "run":
                    runs[state] += n
                    if tier == "high" and state in ("ready", "running"):
                        high_run += n
        counts = QueueCounts(
            waiting=count["waiting", "standard"] + count["waiting", "high"],
            ready_standard=count["ready", "standard"],
            ready_high=count["ready", "high"],
            running_standard=count["running", "standard"],
            running_high=count["running", "high"],
            ready_run=runs["ready"],
            running_run=runs["running"],
            high_run=high_run,
        )
        demand = burst_demand(
            counts, self.settings.warm_workers, self.settings.max_burst_workers, self.settings.run_slots
        )
        now = self.clock()
        self.hosts = {
            host: (at, report)
            for host, (at, report) in self.hosts.items()
            if (now - at).total_seconds() < HOST_REPORT_SECONDS
        }
        hosts = [HostStatus(report, round((now - at).total_seconds(), 1)) for at, report in self.hosts.values()]
        return QueueStatus(
            counts,
            max(desired, demand),
            sorted(hosts, key=lambda h: h.report.id),
            self._phase_totals(now),
            self.scaler,
        )

    async def sweep(self) -> None:
        """The periodic pass: expired leases, a release of every batch in the background (for actions those
        leases or a failed HEAD left waiting), retention, then the burst worker target, which the scale command gets
        whenever it changes.

        The demand samples behind the target are in the database, so a restarted coordinator keeps holding it. A
        failing scale command is logged and retried on the next sweep; it never stops the sweep.
        """
        trusted_since = asyncio.get_running_loop().time() - IN_CACHE_TRUST_SECONDS
        self.found_in_cache = {key: at for key, at in self.found_in_cache.items() if at > trusted_since}
        await self.expire_leases()
        await self.fail_overdue()
        self.request_release()
        await self.delete_expired()
        counts = (await self.queue()).counts
        demand = burst_demand(
            counts, self.settings.warm_workers, self.settings.max_burst_workers, self.settings.run_slots
        )
        now = self.clock()
        async with self.engine.begin() as conn:
            await conn.execute(
                sa.text("DELETE FROM burst_demand WHERE at < CAST(:now AS timestamptz) - make_interval(secs => :hold)"),
                {"now": now, "hold": self.settings.scale_down_hold_s},
            )
            await conn.execute(
                sa.text("INSERT INTO burst_demand (at, workers) VALUES (:now, :workers)"),
                {"now": now, "workers": demand},
            )
            desired = await conn.scalar(HELD_TARGET, self._held_target_params(now))
        last = self.scaler
        if self.settings.scale_cmd is None or (last is not None and last.error is None and last.workers == desired):
            return
        try:
            await self._scale(self.settings.scale_cmd, desired)
        except (OSError, ScaleCommandError) as error:
            logger.warning("scaling to %d burst workers failed: %s", desired, error)
            self.scaler = ScaleRun(desired, now, str(error))
            return
        self.scaler = ScaleRun(desired, now, None)

    def _held_target_params(self, now: datetime) -> dict[str, object]:
        return {"now": now, "hold": self.settings.scale_down_hold_s, "cap": self.settings.max_burst_workers}

    async def _scale(self, scale_cmd: str, workers: int) -> None:
        process = await asyncio.create_subprocess_exec(*shlex.split(scale_cmd), str(workers))
        try:
            code = await asyncio.wait_for(process.wait(), SCALE_CMD_TIMEOUT_S)
        except TimeoutError:
            process.kill()
            await process.wait()
            raise ScaleCommandError(f"{scale_cmd} {workers} ran longer than {SCALE_CMD_TIMEOUT_S} s") from None
        if code != 0:
            raise ScaleCommandError(f"{scale_cmd} {workers} exited {code}")

    async def _in_cache_all(self, ac_keys: set[str], limit: asyncio.Semaphore) -> dict[str, bool | None]:
        """``_in_cache`` of each of ``ac_keys``, all at once."""
        keys = list(ac_keys)
        return dict(zip(keys, await asyncio.gather(*(self._in_cache(key, limit) for key in keys)), strict=True))

    async def _in_cache(self, ac_key: str, limit: asyncio.Semaphore) -> bool | None:
        """Whether the cache holds entry ``ac_key``; None when the cache can't tell. A request it sends waits for
        ``limit``.

        The entry's blobs aren't asked about: holbuild uploads them before it, and one that expires before it makes
        the children that restore it report ``input-missing`` for the parent, which re-queues the parent. Asking
        would cost a request per blob, and bazel-remote can't answer ``HEAD`` for a blob only its proxy backend
        holds without copying it from there first.

        An entry found is taken to be there for ``IN_CACHE_TRUST_SECONDS`` without asking again, and
        concurrent calls share one check, since each completion releases its batch and every concurrent release
        would otherwise ask about the same parents. One evicted meanwhile makes its children report
        ``input-missing``, which forgets every entry found and every check under way.
        """
        now = asyncio.get_running_loop().time()
        if now - self.found_in_cache.get(ac_key, -IN_CACHE_TRUST_SECONDS) < IN_CACHE_TRUST_SECONDS:
            return True
        check = self.cache_checks.get(ac_key)
        if check is None:
            check = asyncio.create_task(self._check_cache(ac_key, limit))
            self.cache_checks[ac_key] = check

            def done(_: object) -> None:
                if self.cache_checks.get(ac_key) is check:
                    del self.cache_checks[ac_key]

            check.add_done_callback(done)
        # Shielded, so a caller cancelled leaves the check to the others.
        return await asyncio.shield(check)

    def _forget_cache_findings(self) -> None:
        self.found_in_cache.clear()
        self.cache_checks.clear()
        self.cache_forgotten += 1

    async def cache_read_nodes(self, digest: str) -> list[str]:
        """Refresh ready slots at most once per thirty seconds, retaining the permanent fallback."""
        if self.cache_pool is None:
            return ranked_nodes(self.cache_nodes, digest)[:2]
        now = asyncio.get_running_loop().time()
        if now - self.membership.attempted >= REFRESH_SECONDS:
            async with self.membership_lock:
                if now - self.membership.attempted >= REFRESH_SECONDS:
                    self.membership.attempted = now
                    try:
                        members = self.cache_nodes + await self.cache_pool.ready_urls()
                        text = "holbuild-cache-members-v1\n" + "\n".join(node_identity(url) for url in members)
                        self.membership.update(text, now)
                    except sa.exc.SQLAlchemyError:
                        logger.warning("cache membership query failed; retaining the permanent fallback")
        return ranked_nodes(self.membership.current(now), digest)

    async def _check_cache(self, ac_key: str, limit: asyncio.Semaphore) -> bool | None:
        forgotten = self.cache_forgotten
        missing = False
        failure: httpx.Response | None = None
        nodes = await self.cache_read_nodes(ac_key)
        joining = self.membership.joining(asyncio.get_running_loop().time())
        for attempt, node in enumerate(nodes, 1):
            if attempt == 3 and not joining and missing:
                break
            try:
                async with limit:
                    response = await self.cache.get(f"{node}/ac/{ac_key}")
            except httpx.HTTPError:
                continue
            if response.status_code == 200:
                if self.cache_forgotten == forgotten:  # else an input went missing since this check began
                    self.found_in_cache[ac_key] = asyncio.get_running_loop().time()
                return True
            if response.status_code == 404:
                missing = True
                continue
            failure = response
            if response.status_code != 429 and not 500 <= response.status_code < 600:
                missing = False
                break
        if missing:
            return False
        if failure is not None:
            request = failure.request
            logger.warning(
                "%s %s answered %d; its children wait for the next sweep",
                request.method,
                request.url.path,
                failure.status_code,
            )
        return None

    async def _requeue_evicted(self, batch_id: UUID, parent: str) -> bool:
        """Re-queue a done parent whose key the cache no longer holds; True when it was."""
        async with self.engine.begin() as conn:
            if await self._lock_batch(conn, batch_id) != "running":
                return False
            action = (
                await conn.execute(
                    sa.text(
                        "SELECT theory, state, attempts FROM actions "
                        "WHERE batch_id = :batch_id AND input_key = :input_key FOR UPDATE"
                    ),
                    {"batch_id": batch_id, "input_key": parent},
                )
            ).one()
            if action.state != "done":
                return False
            if action.attempts >= self.settings.max_attempts:
                await self._fail_batch(
                    conn, batch_id, parent, f"resubmit: {action.theory} (theory {parent}) is not in the cache after it built"
                )
                return False
            await self._requeue(conn, batch_id, parent)
            return True

    async def _input_missing(
        self, conn: AsyncConnection, batch_id: UUID, input_key: str, theory: str, attempts: int, result: Result
    ) -> None:
        """Handle ``input-missing``: re-queue a missing theory the batch builds, and retry on anything else, since a
        restore that fails on a network error reports its input missing too; once the action used up its
        attempts, fail the batch for resubmission.

        The missing theory may be a transitive dependency, which the batch has no edge for; the edge added here
        holds the action back until that theory is rebuilt and the cache holds it again.
        """
        missing = result.missing
        rebuilt = None
        if missing is not None and missing.kind == "theory":
            rebuilt = await conn.scalar(
                sa.text("SELECT theory FROM actions WHERE batch_id = :batch_id AND input_key = :input_key"),
                {"batch_id": batch_id, "input_key": missing.key},
            )
        if attempts >= self.settings.max_attempts:
            what = f"{missing.kind} {missing.key}" if missing else "an input"
            if rebuilt is not None:
                what = f"{rebuilt} ({what})"
            await self._fail_batch(
                conn, batch_id, input_key, f"resubmit: {theory} is still missing {what} after {attempts} attempts"
            )
        elif (
            rebuilt is not None and missing is not None and await self._add_edge(conn, batch_id, input_key, missing.key)
        ):
            await self._set_state(conn, batch_id, input_key, "waiting")
            await self._requeue(conn, batch_id, missing.key)
        else:
            await self._retry(conn, batch_id, input_key)

    async def _add_edge(self, conn: AsyncConnection, batch_id: UUID, child: str, parent: str) -> bool:
        """Make ``child`` depend on ``parent``, updating the priorities it changes; False, adding nothing, when the
        edge would close a cycle: a theory can't be missing itself or a theory that depends on it, so the result is
        wrong and the action is retried as for an input that isn't the batch's."""
        edges = [
            (row.input_key, row.parent_key)
            for row in await conn.execute(
                sa.text("SELECT input_key, parent_key FROM edges WHERE batch_id = :batch_id"), {"batch_id": batch_id}
            )
        ]
        current = {
            row.input_key: Priority(row.critical_depth, row.descendant_count)
            for row in await conn.execute(
                sa.text("SELECT input_key, critical_depth, descendant_count FROM actions WHERE batch_id = :batch_id"),
                {"batch_id": batch_id},
            )
        }
        try:
            priority = dag_priorities(list(current), [*edges, (child, parent)])
        except graphlib.CycleError:
            return False
        await conn.execute(
            sa.text(
                "INSERT INTO edges (batch_id, input_key, parent_key) VALUES (:batch_id, :child, :parent) "
                "ON CONFLICT DO NOTHING"
            ),
            {"batch_id": batch_id, "child": child, "parent": parent},
        )
        # Only ``parent`` and what it depends on can change, and nothing does when the edge was there already;
        # leaving the other rows alone keeps concurrent claims from skipping them.
        changed = [key for key, p in priority.items() if p != current[key]]
        if changed:
            await conn.execute(
                sa.text(
                    "UPDATE actions SET critical_depth = :depth, descendant_count = :descendants "
                    "WHERE batch_id = :batch_id AND input_key = :input_key"
                ),
                [
                    {
                        "batch_id": batch_id,
                        "input_key": key,
                        "depth": priority[key].critical_depth,
                        "descendants": priority[key].descendant_count,
                    }
                    for key in changed
                ],
            )
        return True

    async def _requeue(self, conn: AsyncConnection, batch_id: UUID, input_key: str) -> None:
        await conn.execute(
            sa.text(
                "UPDATE actions SET state = 'waiting' WHERE batch_id = :batch_id AND input_key = :input_key "
                "AND state = 'done'"
            ),
            {"batch_id": batch_id, "input_key": input_key},
        )
        await conn.execute(REFRESH_KEYS, {"batch_id": batch_id, "keys": [input_key]})
        await conn.execute(REFRESH_CHILDREN, {"batch_id": batch_id, "keys": [input_key]})

    async def _retry(self, conn: AsyncConnection, batch_id: UUID, input_key: str) -> None:
        """Send a failed or expired action back to waiting, so ``release`` checks its parents' keys again, or
        trusts what it found within ``IN_CACHE_TRUST_SECONDS``.

        A parent may have been re-queued while the action ran; going straight to ready would skip that check.
        """
        await self._set_state(conn, batch_id, input_key, "waiting")
        await conn.execute(REFRESH_KEYS, {"batch_id": batch_id, "keys": [input_key]})

    async def _lock_batch(self, conn: AsyncConnection, batch_id: UUID) -> str | None:
        return await conn.scalar(sa.text("SELECT state FROM batches WHERE id = :id FOR UPDATE"), {"id": batch_id})

    async def _set_state(self, conn: AsyncConnection, batch_id: UUID, input_key: str, state: str) -> None:
        await conn.execute(
            sa.text("UPDATE actions SET state = :state WHERE batch_id = :batch_id AND input_key = :input_key"),
            {"state": state, "batch_id": batch_id, "input_key": input_key},
        )

    async def _finish_if_done(self, conn: AsyncConnection, batch_id: UUID) -> None:
        await conn.execute(
            sa.text(
                "UPDATE batches SET state = 'done' WHERE id = :id AND NOT EXISTS "
                "(SELECT 1 FROM actions WHERE batch_id = :id AND state NOT IN ('done', 'failed'))"
            ),
            {"id": batch_id},
        )

    async def _fail(
        self, conn: AsyncConnection, batch_id: UUID, input_key: str, action_class: str, failure: str
    ) -> None:
        """Keep final failures independent in a run batch; build failures still end the whole batch."""
        if action_class == "build":
            await self._fail_batch(conn, batch_id, input_key, failure)
            return
        await self._set_state(conn, batch_id, input_key, "failed")
        await self._finish_if_done(conn, batch_id)

    async def _fail_batch(self, conn: AsyncConnection, batch_id: UUID, input_key: str, failure: str) -> None:
        """Fail ``input_key`` finally and with it the batch; its other unfinished actions are cancelled."""
        await self._set_state(conn, batch_id, input_key, "failed")
        await self._end_batch(conn, batch_id, "failed", failure)

    async def _end_batch(self, conn: AsyncConnection, batch_id: UUID, state: str, failure: str | None) -> None:
        """Give a running batch its final state; its unfinished actions are cancelled and their leases revoked."""
        await conn.execute(
            sa.text("UPDATE batches SET state = :state, failure = :failure WHERE id = :id"),
            {"id": batch_id, "state": state, "failure": failure},
        )
        await conn.execute(
            sa.text(
                "UPDATE actions SET state = 'cancelled' "
                "WHERE batch_id = :id AND state IN ('waiting', 'ready', 'running')"
            ),
            {"id": batch_id},
        )
        await conn.execute(sa.text("DELETE FROM leases WHERE batch_id = :id"), {"id": batch_id})

    async def _record_peak(self, conn: AsyncConnection, package: str, theory: str, profile: str, peak: int) -> None:
        """Raise the theory's peak hint to ``peak``; a run that took less, perhaps with a quieter neighbour, keeps it."""
        await conn.execute(
            sa.text(
                "INSERT INTO peak_hints (package, theory, profile, peak_rss_mb) "
                "VALUES (:package, :theory, :profile, :peak) "
                "ON CONFLICT (package, theory, profile) DO UPDATE "
                "SET peak_rss_mb = GREATEST(peak_hints.peak_rss_mb, :peak), updated_at = now()"
            ),
            {"package": package, "theory": theory, "profile": profile, "peak": peak},
        )
