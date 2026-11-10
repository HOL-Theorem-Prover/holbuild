"""Scheduling state of remote holbuild builds: batches, their DAG, leases and retries, over Postgres.

Done means the action's key is in the remote cache's ``/ac/``; Postgres holds no result pointers. Lock order
is a batch row first, then its actions and leases, so a completion, an expiry and a cancel never deadlock.
"""

import asyncio
import contextlib
import graphlib
import heapq
import json
import logging
import math
import os
import shlex
import time
from collections import defaultdict, deque
from collections.abc import Awaitable, Callable, Iterator
from dataclasses import dataclass, fields, replace
from datetime import UTC, datetime
from typing import Annotated, Self
from urllib.parse import urlsplit
from uuid import UUID, uuid4

import asyncpg
import httpx
import sqlalchemy as sa
from pydantic import Field, SecretStr, field_validator, model_validator
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
# Transactions a release pass holds at once, so a pass over many batches leaves pooled connections to the rest.
RELEASE_TRANSACTIONS = 8
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
# The highest --host-rank a worker may report (worker.py checks the same bound at start).
MAX_HOST_RANK = 1000
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
    # Refunded "unavailable" results per action (a worker drained or its cache was out); past this they count as
    # attempts, so an action that never fits a drain window can't loop forever.
    max_interruptions: int = 5
    # A theory whose peak hint reaches this goes to the high-memory tier; set it to what a standard worker holds.
    standard_tier_mb: int = 16000
    retention_hours: int = 168
    # A batch still running this long after its submission fails, so nothing keeps it, or workers for it, alive.
    batch_deadline_hours: float = 12.0
    hint_ttl_days: int = 30
    sweep_seconds: float = 5.0
    # An event stream reads its batch at most this often, when a write of this process to the batch wakes it, and
    # at least every events_fallback_seconds, for the writes of other coordinator processes.
    events_poll_seconds: float = 1.0
    events_fallback_seconds: float = 10.0
    # An event stream with nothing to send this long sends a blank line, shorter than proxies' idle timeouts.
    events_keepalive_seconds: float = 15.0
    # Database connections the coordinator holds at most, and how long a request waits for one before it fails.
    # Kept well under the workers' request timeouts, so an overloaded coordinator answers 503 rather than doing the
    # work of a heartbeat or completion its worker has already given up on and is retrying.
    database_pool_size: int = 50
    database_pool_timeout_s: float = 3.0
    # /v1/cache/members reuses the serving slots it read for this long: workers ask about as often as they claim.
    # Clients keep the list REFRESH_SECONDS more, which together stay under cache_drain_seconds.
    cache_members_ttl_seconds: float = Field(default=2.0, ge=0, allow_inf_nan=False)
    # Build claims share one ranking of the batches for this long; see Coordinator._claim_build. With 0, only claims
    # that arrive while a ranking is being read share it.
    claim_ranking_seconds: float = Field(default=0.5, ge=0, allow_inf_nan=False)
    # Burst workers: workers that a scaler starts and stops on top of `warm_workers` always-on ones.
    run_slots: int = Field(default=30, ge=0)
    run_floor: int = Field(default=0, ge=0)
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

    @model_validator(mode="after")
    def plain_http_slots(self) -> Self:
        """Discovery hands the permanent nodes' credentials to slots, so plain-HTTP slots need a credential-free HTTP pool."""
        urls = [*(self.cache_url.split(",") if self.cache_url else []), *(slot.url for slot in self.cache_slots)]
        parts = [urlsplit(url) for url in urls]
        if any(part.scheme == "http" for part in parts) and self.cache_slots:
            if any(part.username or part.password for part in parts):
                raise ValueError("http:// cache slots need a cache URL without credentials")
            if len({part.scheme for part in parts}) > 1:
                raise ValueError("cache slots and the cache URL must not mix http:// and https://")
        return self

    @model_validator(mode="after")
    def members_kept_under_drain(self) -> Self:
        """A slot's drain must outlast every list that still names it: the coordinator's and then a client's."""
        if self.cache_members_ttl_seconds + REFRESH_SECONDS >= self.cache_drain_seconds:
            raise ValueError(
                f"cache_members_ttl_seconds plus the clients' {REFRESH_SECONDS} s refresh must stay under "
                "cache_drain_seconds"
            )
        return self

class ScaleCommandError(RuntimeError):
    """The scale command failed or timed out."""


# What a read raises while the database is out of reach or overloaded: no pooled connection came free, a statement
# timed out or lost its connection (wrapped by SQLAlchemy), or a new connection failed to open (not wrapped).
DATABASE_UNAVAILABLE = (sa.exc.TimeoutError, sa.exc.DBAPIError, asyncpg.PostgresError, asyncpg.InterfaceError, OSError)


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
    failure_detail: str | None  # the last result's detail: why it failed when it has no log
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
    ready_priority: int = 0
    running_priority: int = 0
    high_run: int = 0  # internal: ready or running high-tier runs, for capped burst demand


# What a host report's counts and sizes may be: JSON's exact integers.
Amount = Annotated[int, Field(ge=0, le=2**53)]


@dataclass(frozen=True)
class HostReport:
    """What a worker reports of its host with a claim or heartbeat (``HostReport`` in worker.py): the share of CPU
    time idle lately, memory in bytes as holbuild's ``--cooperate-dir`` admission sees it, and whether that
    admission would hold a child back now or held the worker back since its last report. Claims pack onto hosts of
    lower ``rank`` first (the worker's ``--host-rank``)."""

    id: Annotated[str, Field(max_length=64)]  # the host's boot_id
    cpu_idle_pct: Annotated[float, Field(ge=0, le=100)] | None
    mem_total: Amount | None
    mem_available: Amount | None
    budget: Amount | None
    reserved: Amount
    leases: Amount
    memory_short: bool
    rank: Annotated[int, Field(ge=0, le=MAX_HOST_RANK)] = 0


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

# The waiting actions whose parents are all done, with each parent's input and action-cache keys, of every batch
# or of one; see Coordinator.release. Two statements, so the database plans the one-batch read by its batch.
RELEASABLE = """
SELECT a.batch_id, a.input_key, ARRAY(
    SELECT ROW(e.parent_key, (
        SELECT p.ac_key FROM actions p WHERE p.batch_id = e.batch_id AND p.input_key = e.parent_key
    ))
    FROM edges e WHERE e.batch_id = a.batch_id AND e.input_key = a.input_key
) AS parents
FROM actions a JOIN batches b ON b.id = a.batch_id
WHERE a.state = 'waiting' AND a.remaining_deps = 0 AND b.state = 'running'{batch}
"""
RELEASABLE_ALL = sa.text(RELEASABLE.format(batch=""))
RELEASABLE_BATCH = sa.text(RELEASABLE.format(batch=" AND a.batch_id = :batch_id"))


# The actions of a batch written by transactions numbered :since or later; see Coordinator.changes.
CHANGED_ACTIONS = sa.text("""
SELECT input_key, theory, state, tier, attempts, last_failure, log_sha256, failure_detail, CAST(timings AS text)
FROM actions
WHERE batch_id = :batch_id AND changed_xid >= CAST(CAST(:since AS text) AS xid8)
ORDER BY theory, input_key
""")


# The ready action to claim next is found in two steps; see Coordinator.claim. CLAIM_CANDIDATES ranks the running
# batches with a ready action of an accepted class and tier, one row per batch, class and tier, best first; each
# batch's running count and last claim come from its own index entries, so a claim reads neither finished batches
# nor finished actions, nor every ready action: a LIMIT 1 probe per batch, class and tier looks for a ready one. CLAIM_ACTION then locks a candidate's first ready action in the
# order of actions_ready_order, skipping those other claims hold; the first candidate with one wins. Together they
# take the first unlocked action in the order (class, tier, batch rank, critical depth, descendants, theory, key).
CLAIM_CANDIDATES = sa.text("""
WITH run_capacity AS MATERIALIZED (
    SELECT 'run' = ANY(CAST(:classes AS text[])) AND (
        SELECT count(*) FROM actions WHERE state = 'running' AND class = 'run'
    ) < :run_slots AS available
)
SELECT b.id AS batch_id, c.class AS action_class, t.tier, b.max_heap_mb, b.priority,
    (SELECT count(*) FROM actions r WHERE r.batch_id = b.id AND r.state = 'running') AS running,
    (SELECT max(l.last_claimed_at) FROM actions l WHERE l.batch_id = b.id) AS last_claimed_at,
    b.created_at
FROM batches b
CROSS JOIN (SELECT DISTINCT unnest(CAST(:classes AS text[]))) c (class)
CROSS JOIN (SELECT DISTINCT unnest(CAST(:tiers AS text[]))) t (tier)
CROSS JOIN LATERAL (
    SELECT FROM actions a WHERE a.batch_id = b.id AND a.state = 'ready' AND a.class = c.class AND a.tier = t.tier
    ORDER BY a.critical_depth DESC, a.descendant_count DESC, a.theory, a.input_key
    LIMIT 1
) ready
WHERE b.state = 'running'
AND (c.class = 'build' OR (SELECT available FROM run_capacity))
ORDER BY
    c.class,
    array_position(CAST(:tiers AS text[]), t.tier),
    b.priority DESC,
    running,
    last_claimed_at NULLS FIRST,
    b.created_at,
    b.id
""")
CLAIM_ACTION = sa.text("""
SELECT input_key, spec_sha256, theory FROM actions
WHERE batch_id = :batch_id AND state = 'ready' AND class = :class AND tier = :tier
ORDER BY critical_depth DESC, descendant_count DESC, theory, input_key
LIMIT 1 FOR UPDATE SKIP LOCKED
""")


@dataclass
class _Ranking:
    """The running batches with ready build actions, as CLAIM_CANDIDATES ranks them, read at ``at``: a heap of
    (tier position, negated priority, running actions, ever claimed, last claim, created, batch, tier, heap limit),
    the batches and tiers it ranked, and those found without an unlocked ready action since."""

    at: float
    forgotten: int  # Coordinator.rankings_forgotten when it was read
    heap: list[tuple[int, int, int, bool, datetime, datetime, UUID, str, int | None]]
    ranked: set[tuple[UUID, str]]  # the batches and tiers it ranked
    exhausted: set[tuple[UUID, str]]


_NEVER = datetime.min.replace(tzinfo=UTC)  # the last claim of a batch never claimed from, for ordering


@dataclass(frozen=True)
class _Claimed:
    """The action a claim locked, and its batch's heap limit."""

    batch_id: UUID
    input_key: str
    spec_sha256: str
    theory: str
    max_heap_mb: int | None


# End a running batch that has no unfinished action left: done, or failed with its failed builds. Run after every
# completion, so the check is one entry of actions_batch_unfinished however many actions the batch finished. It looks
# for the batch's first unfinished action in the index's order rather than for any: with no order asked for, the
# database scans the table for one whenever unfinished actions look common, and reads every row a batch near its end
# finished.
FINISH_IF_DONE = sa.text(
    "UPDATE batches SET (state, failure) = (SELECT "
    "CASE WHEN count(*) = 0 THEN 'done' ELSE 'failed' END, "
    "string_agg(theory || ': ' || COALESCE(last_failure, 'internal') || "
    "COALESCE(': ' || failure_detail, ''), '; ' ORDER BY theory, input_key) "
    "FROM actions WHERE batch_id = :id AND class = 'build' AND state = 'failed') "
    "WHERE id = :id AND state = 'running' AND (SELECT input_key FROM actions "
    "WHERE batch_id = :id AND state IN ('waiting', 'ready', 'running') ORDER BY input_key LIMIT 1) IS NULL"
)

# The unfinished actions by state, tier and class, for the queue counts, and only the ready and running ones, which
# are all burst demand needs: the scale check runs every sweep, and waiting actions can outnumber the others many
# times over. Literal states, so the partial index actions_unfinished serves both.
COUNT_UNFINISHED = sa.text(
    "SELECT a.state, a.tier, a.class, b.priority > 0, count(*) FROM actions a "
    "JOIN batches b ON b.id = a.batch_id "
    "WHERE a.state IN ('waiting', 'ready', 'running') "
    "GROUP BY a.state, a.tier, a.class, b.priority > 0"
)
COUNT_ACTIVE = sa.text(
    "SELECT state, tier, class, false, count(*) FROM actions "
    "WHERE state IN ('ready', 'running') GROUP BY state, tier, class"
)


ClaimRank = tuple[bool, bool, int, str]


def _claim_rank(tiers: list[str], host_id: str | None, host_rank: int = 0) -> ClaimRank:
    """Pack standard work onto warm workers first, then hosts of lower rank, then hosts in a stable order."""
    return tiers[0] != "standard", host_id is None, host_rank, host_id or ""


class Coordinator:
    """Owns the database engine and the cache client; every rule of the coordinator lives here."""

    def __init__(self, engine: AsyncEngine, cache: httpx.AsyncClient, settings: Settings) -> None:
        self.engine = engine
        self.cache = cache
        self.settings = settings
        self.cache_nodes = cache_nodes(settings.cache_url)
        self.membership = Membership(self.cache_nodes, [slot.url for slot in settings.cache_slots])
        self.membership_lock = asyncio.Lock()
        self.serving_lock = asyncio.Lock()
        self.serving: tuple[float, list[str]] | None = None  # when the serving slots were last read, and them
        self.clock: Callable[[], datetime] = lambda: datetime.now(UTC)
        self.cache_pool = (CachePool(engine, settings.cache_slots, CommandAdapter(settings.cache_pool_cmd),
                                     drain_seconds=settings.cache_drain_seconds, hold_seconds=settings.scale_down_hold_s,
                                     workers_per_node=settings.cache_workers_per_node,
                                     max_workers=settings.max_burst_workers,
                                     launch_timeout_seconds=settings.cache_launch_timeout_seconds)
                           if settings.cache_pool_cmd else None)
        self.scaler: ScaleRun | None = None  # the scale command's last run
        self.scale_lock = asyncio.Lock()
        self.scale_pending = False
        self.scale_task: asyncio.Task[None] | None = None
        # How many actions this process's release has made ready, and waiting claims' tiers, rank and wake,
        # oldest first (the tie-breaker within a host); see claim.
        self.made_ready = 0
        self.claim_waiters: list[tuple[list[str], ClaimRank, asyncio.Future[str]]] = []
        self.rankings: dict[tuple[str, ...], _Ranking] = {}  # the build claims' shared rankings, by tiers
        self.ranking_reads: dict[tuple[str, ...], asyncio.Task[_Ranking]] = {}
        self.rankings_forgotten = 0  # how many times _forget_rankings dropped one, so reads begun before keep none
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
        # The wakes of the event streams following each batch; see watch.
        self.batch_watchers: dict[UUID, set[asyncio.Event]] = {}

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
        if self.scale_task is not None:
            await self.scale_task
        for releaser in self.releasers.values():
            releaser.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await releaser
        await self.cache.aclose()
        await self.engine.dispose()

    async def submit(
        self, batch: Batch, profile: str, action_class: str = "build", max_heap_mb: int | None = None,
        *, fail_fast: bool = False, priority: int = 0,
    ) -> UUID:
        """Store a batch; its actions without uncached parents become ready."""
        batch_id = uuid4()
        parents: defaultdict[str, int] = defaultdict(int)
        for child, _ in batch.edges:
            parents[child] += 1
        dag_priority = dag_priorities([a.input_key for a in batch.actions], batch.edges)
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
                    "INSERT INTO batches (id, state, profile, max_heap_mb, fail_fast, priority) "
                    "VALUES (:id, :state, :profile, :max_heap_mb, :fail_fast, :priority)"
                ),
                {
                    "id": batch_id,
                    "state": "running" if batch.actions else "done",
                    "profile": profile,
                    "max_heap_mb": max_heap_mb,
                    "fail_fast": fail_fast,
                    "priority": priority,
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
                            "depth": dag_priority[a.input_key].critical_depth,
                            "descendants": dag_priority[a.input_key].descendant_count,
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
        if batch.actions:
            self.request_scale()
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

    @contextlib.contextmanager
    def watch(self, batch_id: UUID) -> Iterator[asyncio.Event]:
        """An event, set from the start and again after each write of this process to ``batch_id``'s actions or
        state commits, for one follower of the batch to clear before each read of its changes."""
        event = asyncio.Event()
        event.set()
        watchers = self.batch_watchers.setdefault(batch_id, set())
        watchers.add(event)
        try:
            yield event
        finally:
            watchers.discard(event)
            if not watchers:
                del self.batch_watchers[batch_id]

    def _batch_changed(self, batch_id: UUID) -> None:
        for event in self.batch_watchers.get(batch_id, ()):
            event.set()

    async def cancel(self, batch_id: UUID) -> str | None:
        """Cancel a running batch; its leases go, so its workers' heartbeats and completions are refused."""
        async with self.engine.begin() as conn:
            state = await self._lock_batch(conn, batch_id)
            if state != "running":
                return state
            await self._end_batch(conn, batch_id, "cancelled", None)
        self._batch_changed(batch_id)
        return "cancelled"

    async def claim(
        self,
        tiers: list[str],
        worker: str,
        wait_s: float = 0,
        disconnected: Callable[[], Awaitable[bool]] | None = None,
        host_id: str | None = None,
        host_rank: int = 0,
    ) -> Claim | None:
        """Lease a ready action to ``worker``, waiting up to ``wait_s`` seconds for one, or None if none became
        ready: of the first of ``tiers`` that has one, the batch with the fewest running actions, then the one
        that least recently had one claimed, then the oldest; within it, the action with the deepest chain of
        dependents, then the most dependents.

        A wait ends early once ``disconnected`` says the worker has gone, so no action is leased to nobody. Each
        action this process's ``release`` makes ready wakes one compatible claim, preferring warm workers, then
        hosts of lower ``host_rank``, then hosts in canonical order, with FIFO ties. Unwoken claims defer each tier to better-ranked waiters, so
        polling workers don't spread work back onto tail hosts. Waits recheck every
        ``CLAIM_RECHECK_SECONDS``, for actions another coordinator process made ready and for an action whose
        woken claim took another one or lost it to another claim; a claim woken that leaves without trying wakes
        the next.
        """
        loop = asyncio.get_running_loop()
        deadline = loop.time() + wait_s
        rank = _claim_rank(tiers, host_id, host_rank)
        woken: asyncio.Future[str] = loop.create_future()  # done once a wake was handed to this claim
        try:
            while True:
                # Taken before the attempt, so an action made ready during it is tried at once, not waited for.
                made_ready = self.made_ready
                eligible_tiers = tiers if woken.done() else [
                    tier for tier in tiers
                    if not any(
                        tier in w_tiers and not w_woken.done() and w_rank < rank
                        for w_tiers, w_rank, w_woken in self.claim_waiters
                    )
                ]
                claimed = await self._claim(eligible_tiers, worker) if eligible_tiers else None
                remaining = deadline - loop.time()
                if claimed is not None or remaining <= 0:
                    return claimed
                woken = loop.create_future()
                if self.made_ready == made_ready:
                    waiter = (tiers, rank, woken)
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
        # Waited for before taking a connection: claims waiting on a ranking while holding one could leave none
        # for the ranking's read.
        started = asyncio.get_running_loop().time()
        try:
            ranking = await self._current_ranking(tuple(tiers))
        except Exception:
            # The shared read failed (say the pool timed out): this claim ranks for itself, as if it had found the
            # ranking used up, rather than every claim that waited for the read failing with it.
            ranking = _Ranking(-math.inf, self.rankings_forgotten, [], set(), set())
        async with self.engine.begin() as conn:
            # A batch's running count and last claim are read without locking its row, so concurrent claims see
            # only each other's committed leases, which at worst lets workers waking together pick the same
            # batch. Locking or updating the batch row here, after the action row, would invert the lock order.
            params = {"tiers": tiers, "classes": ["build"], "run_slots": self.settings.run_slots}
            floor = min(self.settings.run_floor, self.settings.run_slots)
            row = None
            if floor > 0 and await conn.scalar(
                sa.text(
                    "SELECT EXISTS (SELECT 1 FROM actions WHERE state = 'ready' AND class = 'run' "
                    "AND tier = ANY(CAST(:tiers AS text[]))) AND "
                    "(SELECT count(*) FROM actions WHERE state = 'running' AND class = 'run') < :floor"
                ),
                {"tiers": tiers, "floor": floor},
            ):
                # Build claims bypass this lock when the floor is full or no compatible run is ready.
                # CLAIM_CANDIDATES rechecks capacity in a fresh snapshot after any preceding run admission commits.
                await conn.execute(sa.text("SELECT pg_advisory_xact_lock(1752132706, 1)"))
                row = await self._claim_first(conn, {**params, "classes": ["run"], "run_slots": floor})
            if row is None:
                row = await self._claim_build(conn, tiers, ranking, started)
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
                row = await self._claim_first(conn, {**params, "classes": ["build", "run"]})
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
        self._batch_changed(row.batch_id)
        return Claim(token, row.spec_sha256, row.input_key, row.theory, self.settings.lease_seconds, row.max_heap_mb)

    @staticmethod
    async def _claim_first(conn: AsyncConnection, params: dict[str, object]) -> _Claimed | None:
        """Lock the first ready action ``params`` accept that no other claim holds; see CLAIM_CANDIDATES."""
        for candidate in (await conn.execute(CLAIM_CANDIDATES, params)).all():
            row = (
                await conn.execute(
                    CLAIM_ACTION,
                    {"batch_id": candidate.batch_id, "class": candidate.action_class, "tier": candidate.tier},
                )
            ).first()
            if row is not None:
                return _Claimed(candidate.batch_id, row.input_key, row.spec_sha256, row.theory, candidate.max_heap_mb)
        return None

    async def _claim_build(
        self, conn: AsyncConnection, tiers: list[str], ranking: "_Ranking", started: float
    ) -> _Claimed | None:
        """Lock a ready build action of ``tiers`` in the order of CLAIM_CANDIDATES, taken from ``ranking``, which
        the build claims of ``claim_ranking_seconds`` share, so that the ranking, which probes every running batch,
        isn't repeated by every claim.

        Each claim takes the best batch of the ranking and puts it back as if it had one more running action and
        had just had one claimed, before it tries the batch, so concurrent claims spread over the batches as fresh
        rankings would spread them. A batch and tier found without an unlocked ready action are skipped until the
        next ranking; when every one is, and the ranking is older than the claim, which ``started`` then, the claim
        ranks again on ``conn``, for actions made ready since.
        """
        while True:
            while ranking.heap:
                entry = heapq.heappop(ranking.heap)
                tier_position, priority, running, _, _, created_at, batch_id, tier, max_heap_mb = entry
                if (batch_id, tier) in ranking.exhausted:
                    continue
                heapq.heappush(
                    ranking.heap,
                    (tier_position, priority, running + 1, True, self.clock(), created_at, batch_id, tier, max_heap_mb),
                )
                row = (
                    await conn.execute(CLAIM_ACTION, {"batch_id": batch_id, "class": "build", "tier": tier})
                ).first()
                if row is not None:
                    return _Claimed(batch_id, row.input_key, row.spec_sha256, row.theory, max_heap_mb)
                ranking.exhausted.add((batch_id, tier))
            if ranking.at >= started:
                return None
            ranking = await self._rank(conn, tuple(tiers))
            self._keep_ranking(tuple(tiers), ranking)

    async def _current_ranking(self, key: tuple[str, ...]) -> "_Ranking":
        """The build claims' ranking for the tiers ``key``: the last one if younger than ``claim_ranking_seconds``,
        else a new one, which concurrent callers wait for together."""
        ranking = self.rankings.get(key)
        if ranking is not None and asyncio.get_running_loop().time() - ranking.at < self.settings.claim_ranking_seconds:
            return ranking
        read = self.ranking_reads.get(key)
        if read is None:

            async def rank() -> _Ranking:
                async with self.engine.connect() as conn:
                    return await self._rank(conn, key)

            read = asyncio.get_running_loop().create_task(rank())
            self.ranking_reads[key] = read

            def done(_: object) -> None:
                if self.ranking_reads.get(key) is read:
                    del self.ranking_reads[key]
                if not read.cancelled() and read.exception() is None:
                    self._keep_ranking(key, read.result())

            read.add_done_callback(done)
        # Shielded, so a caller cancelled leaves the read to the others.
        return await asyncio.shield(read)

    async def _rank(self, conn: AsyncConnection, key: tuple[str, ...]) -> "_Ranking":
        at = asyncio.get_running_loop().time()
        forgotten = self.rankings_forgotten
        params = {"tiers": list(key), "classes": ["build"], "run_slots": self.settings.run_slots}
        rows = (await conn.execute(CLAIM_CANDIDATES, params)).all()
        heap = [
            (
                key.index(row.tier), -row.priority, row.running, row.last_claimed_at is not None,
                row.last_claimed_at or _NEVER, row.created_at, row.batch_id, row.tier, row.max_heap_mb,
            )
            for row in rows
        ]
        heapq.heapify(heap)
        return _Ranking(at, forgotten, heap, {(row.batch_id, row.tier) for row in rows}, set())

    def _keep_ranking(self, key: tuple[str, ...], ranking: "_Ranking") -> None:
        """Share ``ranking`` with later claims, unless a release dropped a ranking while it was read, since its
        snapshot may predate the actions that release made ready."""
        if ranking.forgotten == self.rankings_forgotten:
            self.rankings[key] = ranking

    def _forget_rankings(self, batch_id: UUID, tiers: set[str]) -> None:
        """Drop the rankings that would pass over actions of ``tiers`` made ready in ``batch_id``: those that didn't
        have it with a ready action of one of them, or have since found it without one. Rankings being read when
        there was none to drop, or one was dropped, are neither joined by later claims nor kept; see _keep_ranking."""
        keys = {key for key in [*self.rankings, *self.ranking_reads] if tiers.intersection(key)}
        stale = {
            key for key in keys
            if (ranking := self.rankings.get(key)) is None or not all(
                (batch_id, tier) in ranking.ranked and (batch_id, tier) not in ranking.exhausted
                for tier in tiers if tier in key
            )
        }
        if stale:
            self.rankings_forgotten += 1
            for key in stale:
                self.rankings.pop(key, None)
                # Claims already waiting for a read still get it; later ones start their own.
                self.ranking_reads.pop(key, None)

    def _wake_claim(self, tier: str) -> None:
        """Count an action of ``tier`` made ready, and wake its best-ranked compatible claim, with FIFO ties."""
        self.made_ready += 1
        waiter = min(
            (w for w in self.claim_waiters if tier in w[0] and not w[2].done()),
            key=lambda w: w[1],
            default=None,
        )
        if waiter is not None:
            waiter[2].set_result(tier)
            self.claim_waiters.remove(waiter)

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
                        "SELECT a.input_key, a.spec_sha256, a.theory, a.tier, a.attempts, a.interruptions, a.last_failure, "
                        "a.class AS action_class, b.profile "
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
                    "UPDATE actions SET log_sha256 = :log, last_failure = :failure, failure_detail = :detail, "
                    "timings = CAST(CAST(:timings AS text) AS jsonb) "
                    "WHERE batch_id = :batch_id AND input_key = :input_key"
                ),
                {
                    "log": result.log_sha256,
                    "failure": result.failure,
                    "detail": result.detail,
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
            elif result.failure == "unavailable" and action.interruptions < self.settings.max_interruptions:
                # The worker couldn't start or finish it, so it doesn't count as an attempt.
                await conn.execute(
                    sa.text(
                        "UPDATE actions SET attempts = attempts - 1, interruptions = interruptions + 1 "
                        "WHERE batch_id = :batch_id AND input_key = :input_key"
                    ),
                    {"batch_id": batch_id, "input_key": action.input_key},
                )
                await self._retry(conn, batch_id, action.input_key)
            elif action.attempts < self.settings.max_attempts and (
                result.failure in ("publish", "toolchain", "internal", "memory", "unavailable")
                or (result.failure == "disk" and action.last_failure != "disk")
            ):
                await self._retry(conn, batch_id, action.input_key)
            elif result.failure == "input-missing":
                self._forget_cache_findings()
                await self._input_missing(conn, batch_id, action.input_key, action.theory, action.attempts, result)
            else:
                detail = f": {result.detail}" if result.detail else ""
                await self._fail(
                    conn, batch_id, action.input_key, action.action_class, f"{action.theory}: {result.failure}{detail}"
                )
        self._batch_changed(batch_id)
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
                if batch_id is None:
                    rows = await conn.execute(RELEASABLE_ALL)
                else:
                    rows = await conn.execute(RELEASABLE_BATCH, {"batch_id": batch_id})
                candidates: defaultdict[UUID, dict[str, list[tuple[str, str]]]] = defaultdict(dict)
                for row in rows:
                    candidates[row.batch_id][row.input_key] = list(row.parents)
            limit = asyncio.Semaphore(RELEASE_CACHE_CHECKS)
            transactions = asyncio.Semaphore(RELEASE_TRANSACTIONS)
            results = await asyncio.gather(
                *(self._release_batch(batch, actions, limit, transactions) for batch, actions in candidates.items()),
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
        self,
        batch_id: UUID,
        candidates: dict[str, list[tuple[str, str]]],
        limit: asyncio.Semaphore,
        transactions: asyncio.Semaphore,
    ) -> bool:
        """``release`` of the ``candidates`` of one batch, their parents' cache checks ``limit`` and its
        transactions ``transactions`` at a time with the other batches' of the pass. Whether it re-queued a parent."""
        present = await self._in_cache_all({ac_key for parents in candidates.values() for _, ac_key in parents}, limit)
        ready = [key for key, parents in candidates.items() if all(present[ac_key] for _, ac_key in parents)]
        if ready:
            # Taking the batch's lock before its actions', as every other writer does.
            async with transactions, self.engine.begin() as conn:
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
            self._batch_changed(batch_id)
            self._forget_rankings(batch_id, set(made_ready))
            for tier in made_ready:
                self._wake_claim(tier)
        requeued = False
        for parents in candidates.values():
            for parent, ac_key in parents:
                if present[ac_key] is False:
                    async with transactions:
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
                            "UPDATE actions SET last_failure = CASE WHEN class = 'run' THEN 'internal' "
                            "ELSE :failure END, failure_detail = NULL "
                            "WHERE batch_id = :batch_id AND input_key = :input_key"
                        ),
                        {"batch_id": batch_id, "input_key": lease.input_key,
                         "failure": f"lease expired {action.attempts} times"},
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
            self._batch_changed(batch_id)

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
            self._batch_changed(batch_id)

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
            counts = await self._counts(conn, COUNT_UNFINISHED)
        demand = burst_demand(
            counts, self.settings.warm_workers, self.settings.max_burst_workers, self.settings.run_slots
        )
        now = self.clock()
        self._forget_silent_hosts(now)
        hosts = [HostStatus(report, round((now - at).total_seconds(), 1)) for at, report in self.hosts.values()]
        return QueueStatus(
            counts,
            max(desired, demand),
            sorted(hosts, key=lambda h: h.report.id),
            self._phase_totals(now),
            self.scaler,
        )

    def _forget_silent_hosts(self, now: datetime) -> None:
        """Drop the hosts no worker reported for in the last ``HOST_REPORT_SECONDS``, making room for new ones."""
        self.hosts = {
            host: (at, report)
            for host, (at, report) in self.hosts.items()
            if (now - at).total_seconds() < HOST_REPORT_SECONDS
        }

    @staticmethod
    async def _counts(conn: AsyncConnection, statement: sa.TextClause) -> QueueCounts:
        """The actions ``statement`` counts, by state and tier; see COUNT_UNFINISHED."""
        count: defaultdict[tuple[str, str], int] = defaultdict(int)
        runs: defaultdict[str, int] = defaultdict(int)
        high_run = 0
        priorities: defaultdict[str, int] = defaultdict(int)
        for state, tier, action_class, prioritized, n in await conn.execute(statement):
            if prioritized:
                priorities[state] += n
            count[state, tier] += n
            if action_class == "run":
                runs[state] += n
                if tier == "high" and state in ("ready", "running"):
                    high_run += n
        return QueueCounts(
            waiting=count["waiting", "standard"] + count["waiting", "high"],
            ready_standard=count["ready", "standard"],
            ready_high=count["ready", "high"],
            running_standard=count["running", "standard"],
            running_high=count["running", "high"],
            ready_run=runs["ready"],
            running_run=runs["running"],
            high_run=high_run,
            ready_priority=priorities["ready"],
            running_priority=priorities["running"],
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
        await self.scale()

    def request_scale(self) -> None:
        """Coalesce batch intake into background scale checks, without delaying the response on the scaler."""
        if self.settings.scale_cmd is None:
            return
        self.scale_pending = True
        if self.scale_task is None or self.scale_task.done():
            self.scale_task = asyncio.create_task(self._run_scales())

    async def _run_scales(self) -> None:
        while self.scale_pending:
            self.scale_pending = False
            try:
                await self.scale()
            except Exception:
                logger.exception("background scale check failed")

    async def scale(self) -> None:
        """Sample demand and apply its held target, serialized with intake and periodic checks."""
        async with self.scale_lock:
            async with self.engine.connect() as conn:
                counts = await self._counts(conn, COUNT_ACTIVE)
            demand = burst_demand(
                counts, self.settings.warm_workers, self.settings.max_burst_workers, self.settings.run_slots
            )
            now = self.clock()
            self._forget_silent_hosts(now)
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
        except asyncio.CancelledError:
            if process.returncode is None:
                process.kill()
            await process.wait()
            raise
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

    async def cache_members(self) -> list[str]:
        """The cache nodes for clients: the permanent ones, then the serving slots'.

        The slots read are reused for ``cache_members_ttl_seconds``, and concurrent calls wait for one read. While
        the database can't answer, the slots last read are kept, so the endpoint answers rather than failing.
        """
        permanent = [node_identity(url) for url in cache_nodes(self.settings.cache_url)]
        if self.cache_pool is None:
            return permanent
        loop = asyncio.get_running_loop()
        async with self.serving_lock:
            if self.serving is None or loop.time() - self.serving[0] >= self.settings.cache_members_ttl_seconds:
                try:
                    serving = await self.cache_pool.ready_urls()
                except DATABASE_UNAVAILABLE as error:
                    logger.warning("reading the serving cache slots failed; keeping the last read: %s", error)
                    serving = [] if self.serving is None else self.serving[1]
                # Stamped when the read ends, failed or not, so the callers that waited for it don't each wait out
                # the pool in turn.
                self.serving = (loop.time(), serving)
        return list(dict.fromkeys(permanent + self.serving[1]))

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
            requeued = action.attempts < self.settings.max_attempts
            if requeued:
                await self._requeue(conn, batch_id, parent)
            else:
                await self._fail_batch(
                    conn, batch_id, parent, f"resubmit: {action.theory} (theory {parent}) is not in the cache after it built"
                )
        self._batch_changed(batch_id)
        return requeued

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
            parent_state = await conn.scalar(
                sa.text("SELECT state FROM actions WHERE batch_id = :batch_id AND input_key = :key"),
                {"batch_id": batch_id, "key": missing.key},
            )
            if parent_state in ("failed", "cancelled"):
                await self._skip(conn, batch_id, input_key, f"skipped because of {rebuilt} ({missing.key})")
                await self._finish_if_done(conn, batch_id)
                return
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
        await conn.execute(FINISH_IF_DONE, {"id": batch_id})

    async def _fail(
        self, conn: AsyncConnection, batch_id: UUID, input_key: str, action_class: str, failure: str
    ) -> None:
        """Fail this action, skipping its descendants while independent work finishes."""
        await self._set_state(conn, batch_id, input_key, "failed")
        if action_class == "build":
            fail_fast = await conn.scalar(sa.text("SELECT fail_fast FROM batches WHERE id = :id"), {"id": batch_id})
            if fail_fast:
                await self._fail_batch(conn, batch_id, input_key, failure)
                return
            await self._skip(conn, batch_id, input_key, f"skipped because of {failure} ({input_key})")
        await self._finish_if_done(conn, batch_id)

    async def _skip(self, conn: AsyncConnection, batch_id: UUID, input_key: str, reason: str) -> None:
        """Skip a blocked action and its descendants, revoking any leases left by a requeued parent."""
        await conn.execute(
            sa.text(
                "WITH RECURSIVE blocked(input_key) AS (SELECT CAST(:key AS text) UNION "
                "SELECT e.input_key FROM edges e JOIN blocked p ON e.parent_key = p.input_key "
                "WHERE e.batch_id = :id), skipped AS ("
                "UPDATE actions SET state = 'cancelled', last_failure = :reason, failure_detail = NULL "
                "WHERE batch_id = :id AND input_key IN (SELECT input_key FROM blocked) "
                "AND state IN ('waiting', 'ready', 'running') RETURNING input_key) "
                "DELETE FROM leases WHERE batch_id = :id AND input_key IN (SELECT input_key FROM skipped)"
            ),
            {"id": batch_id, "key": input_key, "reason": reason},
        )

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
