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
import os
import shlex
import time
from collections import defaultdict, deque
from collections.abc import Awaitable, Callable, Iterator
from dataclasses import dataclass, fields, replace
from datetime import UTC, datetime
from typing import Annotated, Any, Self
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
    # An event stream reads its batch when a write of this process to the batch wakes it, on average at most once
    # every events_poll_seconds, and at least every events_fallback_seconds, for the writes of other coordinator
    # processes. Up to events_burst reads, events_burst_spacing_seconds apart, may come sooner, so that a short
    # batch's few changes (ready, running, done) reach its client at once.
    events_poll_seconds: float = 1.0
    events_burst: int = 3
    events_burst_spacing_seconds: float = 0.1
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
    # How many generations of unfinished parents an action may be claimed ahead of, 0 for no limit; see
    # AHEAD_CANDIDATES.
    ahead_depth: int = Field(default=1, ge=0)
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

    @property
    def ahead_depth_limit(self) -> int | None:
        """``ahead_depth`` as the statements' :depth, None for no limit."""
        return self.ahead_depth or None

class ScaleCommandError(RuntimeError):
    """The scale command failed or timed out."""


# What a read raises while the database is out of reach or overloaded: no pooled connection came free, a statement
# timed out or lost its connection (wrapped by SQLAlchemy), or a new connection failed to open (not wrapped).
DATABASE_UNAVAILABLE = (sa.exc.TimeoutError, sa.exc.DBAPIError, asyncpg.PostgresError, asyncpg.InterfaceError, OSError)


class ResultMismatch(ValueError):
    """A result record for another action than the one its attempt token leases."""


@dataclass(frozen=True)
class AheadParent:
    """A parent still building when its child was claimed ahead of it."""

    input_key: str
    spec_sha256: str


@dataclass(frozen=True)
class Claim:
    attempt_token: UUID
    spec_sha256: str
    input_key: str
    theory: str
    lease_s: int
    max_heap_mb: int | None
    ahead_parents: tuple[AheadParent, ...] = ()  # empty unless the action was claimed ahead of these parents


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
    waiting_ahead_standard: int = 0  # of the running ones, claimed ahead and waiting for a parent
    waiting_ahead_high: int = 0
    high_run: int = 0  # internal: ready or running high-tier runs, for capped burst demand
    ready_high_run: int = 0  # internal: of those, the ready ones


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
    when the worker can't see HOL children, reporting the result, and in exec-action after its result, as it
    publishes for later actions."""

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
    after_result: PhaseSeconds = 0


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
    in each term; the total is at most ``max_burst_workers``.

    Actions waiting ahead of their parents hold burst workers (only burst workers load ahead) but ask for none
    of their own: the demand is the other actions', plus the workers those hold once ready work needs a burst
    worker, since they don't take it."""
    ready = counts.ready_standard + counts.ready_high
    running = counts.running_standard + counts.running_high
    runs = counts.ready_run + counts.running_run
    ahead = counts.waiting_ahead_standard + counts.waiting_ahead_high
    active = ready + running - ahead - runs + min(run_slots, runs)
    high = (
        counts.ready_high + counts.running_high - counts.waiting_ahead_high
        - counts.high_run + min(run_slots, counts.high_run)
    )
    demand = max(0, active - warm_workers, high)
    # Work beyond what runs is ready work a burst worker could take; runs the run slots hold back are not.
    running_active = running - ahead - counts.running_run + min(run_slots, counts.running_run)
    free_run_slots = max(0, run_slots - counts.running_run)
    ready_high = counts.ready_high - counts.ready_high_run + min(counts.ready_high_run, free_run_slots)
    if ready_high > 0 or active > max(warm_workers, running_active):
        demand += ahead
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
    AND (a.class = 'run' OR a.input_key NOT IN (SELECT input_key FROM leases WHERE expires_at > now()))
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
# A build action whose key another batch's live lease is building is held back (single-flight), here and in
# CLAIM_CANDIDATES: once that build succeeds, Coordinator.complete marks the action done as well; once it fails or
# its lease expires, the action is claimed again. An expired lease stops holding at once, before the sweep deletes it.
# An unclaimed action has no lease in its own batch, so every live lease of its key is another batch's; uncorrelated,
# the lease keys are read once per statement into a hash, rather than once per ready action probed.
CLAIM_ACTION = sa.text("""
SELECT input_key, spec_sha256, theory FROM actions
WHERE batch_id = :batch_id AND state = 'ready' AND class = :class AND tier = :tier
AND (class = 'run' OR input_key NOT IN (SELECT input_key FROM leases WHERE expires_at > now()))
ORDER BY critical_depth DESC, descendant_count DESC, theory, input_key
LIMIT 1 FOR UPDATE SKIP LOCKED
""")

# Loading ahead: in a batch with an ``ahead_cap``, a waiting build action may be claimed before its parents are done
# when each parent that isn't done is running, up to ``ahead_depth`` generations ahead: generation 0 is a running
# action that waits for no parent, and an action claimed ahead is one generation after its latest unfinished parent.
# Its worker loads what it can and waits for the unfinished ancestors' outputs. An action whose claim ahead gave up
# is ``abandoned`` and waits for its parents from then on.
#
# AHEAD_WALK: the unfinished ancestors of the actions :keys of :batch_id, with the action each was reached from
# (``root``) and each of its distances from it: their unfinished parents, and, above a running parent that was
# itself claimed ahead and still waits for parents, its unfinished parents, up to :depth generations up. Each step
# reads one action's edges and parents by key: the lookups are subqueries on the row they start from, so that the
# database plans them by key whatever it guesses of a batch inserted since its last statistics.
AHEAD_WALK = """
WITH RECURSIVE walk(batch_id, root, input_key, distance) AS (
    SELECT a.batch_id, a.input_key, e.parent_key, 1 FROM actions a
    CROSS JOIN LATERAL unnest(ARRAY(
        SELECT e.parent_key FROM edges e WHERE e.batch_id = a.batch_id AND e.input_key = a.input_key
    )) AS e(parent_key)
    WHERE a.batch_id = :batch_id AND a.input_key = ANY(CAST(:keys AS text[]))
    UNION
    SELECT w.batch_id, w.root, e.parent_key, w.distance + 1 FROM walk w
    CROSS JOIN LATERAL unnest(ARRAY(
        SELECT e.parent_key FROM edges e WHERE e.batch_id = w.batch_id AND e.input_key = w.input_key
    )) AS e(parent_key)
    WHERE (CAST(:depth AS integer) IS NULL OR w.distance < :depth) AND (
        SELECT p.state = 'running' AND p.remaining_deps > 0 FROM actions p
        WHERE p.batch_id = w.batch_id AND p.input_key = w.input_key
    )
), ancestors AS MATERIALIZED (
    SELECT w.root, w.input_key, w.distance, p.spec_sha256, p.state, p.remaining_deps
    FROM walk w JOIN actions p ON p.batch_id = w.batch_id AND p.input_key = w.input_key
    WHERE p.state <> 'done'
)
"""
# The actions that may be claimed ahead, best first: the children of running actions of generation below
# ``ahead_depth`` of running batches below their ``ahead_cap``. See Coordinator._claim_ahead. Read from the running
# parents down (edges_parent) rather than per waiting action, since a gate's batch has thousands of those: a child is
# a candidate when such running parents are all its unfinished ones, by ``remaining_deps``. An action's generation
# is its longest chain of running actions claimed ahead, down from one of generation 0. CLAIM_AHEAD_ACTION checks
# the rule itself under the batch's lock. The CTEs are materialized so the children are counted once whatever the
# planner guesses of a batch inserted since its last statistics.
AHEAD_CANDIDATES = sa.text("""
WITH RECURSIVE ahead_batches AS MATERIALIZED (
    SELECT b.id, b.priority FROM batches b
    WHERE b.state = 'running' AND b.ahead_cap IS NOT NULL AND (
        SELECT count(*) FROM actions w
        WHERE w.batch_id = b.id AND w.state = 'running' AND w.ahead = 'ahead' AND w.remaining_deps > 0
    ) < b.ahead_cap
), generations(batch_id, input_key, generation) AS (
    SELECT r.batch_id, r.input_key, 0
    FROM ahead_batches b JOIN actions r ON r.batch_id = b.id AND r.state = 'running' AND r.remaining_deps = 0
    UNION
    SELECT g.batch_id, c.input_key, g.generation + 1
    FROM generations g
    JOIN edges e ON e.batch_id = g.batch_id AND e.parent_key = g.input_key
    JOIN actions c ON c.batch_id = e.batch_id AND c.input_key = e.input_key
    WHERE (CAST(:depth AS integer) IS NULL OR g.generation < :depth)
    AND c.state = 'running' AND c.ahead = 'ahead' AND c.remaining_deps > 0
), running AS MATERIALIZED (
    SELECT batch_id, input_key FROM generations GROUP BY batch_id, input_key
    HAVING CAST(:depth AS integer) IS NULL OR max(generation) < :depth
), children AS MATERIALIZED (
    SELECT r.batch_id, e.input_key, count(*) AS running_parents
    FROM running r
    JOIN edges e ON e.batch_id = r.batch_id AND e.parent_key = r.input_key
    GROUP BY r.batch_id, e.input_key
)
SELECT a.batch_id, a.input_key, a.tier, b.priority
FROM children c
JOIN ahead_batches b ON b.id = c.batch_id
JOIN actions a ON a.batch_id = c.batch_id AND a.input_key = c.input_key
WHERE a.state = 'waiting' AND a.class = 'build' AND a.ahead <> 'abandoned' AND a.remaining_deps = c.running_parents
AND a.input_key NOT IN (SELECT input_key FROM leases WHERE expires_at > now())
ORDER BY b.priority DESC, a.critical_depth DESC, a.descendant_count DESC, a.theory, a.input_key
""")

# Lock the best of a batch's candidates ``keys`` of ``tier`` that may still be claimed ahead, but not one whose key
# another batch's live lease is building (single-flight; see CLAIM_ACTION): one with an unfinished ancestor in its
# walk that isn't running, or one :depth generations up that still waits for parents.
CLAIM_AHEAD_ACTION = sa.text(f"""{AHEAD_WALK}
SELECT a.input_key, a.spec_sha256, a.theory FROM actions a
WHERE a.batch_id = :batch_id AND a.input_key = ANY(CAST(:keys AS text[])) AND a.tier = :tier
AND a.state = 'waiting' AND a.class = 'build' AND a.ahead <> 'abandoned' AND a.remaining_deps > 0
AND a.input_key NOT IN (
    SELECT root FROM ancestors WHERE state <> 'running' OR (distance = :depth AND remaining_deps > 0)
)
AND a.input_key NOT IN (SELECT input_key FROM leases WHERE expires_at > now())
ORDER BY a.critical_depth DESC, a.descendant_count DESC, a.theory, a.input_key
LIMIT 1 FOR UPDATE SKIP LOCKED
""")
# The unfinished ancestors an action claimed ahead waits for, ancestors first (by their longest distance from it,
# which for the first is the action's generation), then by key.
AHEAD_PARENTS = sa.text(f"""{AHEAD_WALK}
SELECT input_key, spec_sha256, max(distance) AS distance FROM ancestors
GROUP BY input_key, spec_sha256 ORDER BY max(distance) DESC, input_key
""")
# The most candidates of a batch CLAIM_AHEAD_ACTION checks at once, the best of the shared read: its cost grows with
# their edges, under the batch's lock.
AHEAD_CLAIM_KEYS = 32
# The actions of a batch claimed ahead and still waiting for a parent, which count against its ``ahead_cap``.
COUNT_WAITING_AHEAD = sa.text(
    "SELECT count(*) FROM actions "
    "WHERE batch_id = :batch_id AND state = 'running' AND ahead = 'ahead' AND remaining_deps > 0"
)
# Recount the parents not done of the running actions claimed ahead of :key that waited for one, returning the new
# counts. REFRESH leaves running actions alone. :key's children are read once, by key, rather than per running
# action claimed ahead, of which a batch may have 64.
REFRESH_AHEAD_CHILDREN = sa.text("""
UPDATE actions c SET remaining_deps = (
    SELECT count(*) FROM edges e
    WHERE e.batch_id = c.batch_id AND e.input_key = c.input_key AND (
        SELECT p.state FROM actions p WHERE p.batch_id = e.batch_id AND p.input_key = e.parent_key
    ) <> 'done'
)
WHERE c.batch_id = :batch_id AND c.input_key = ANY(ARRAY(
    SELECT input_key FROM edges WHERE batch_id = :batch_id AND parent_key = :key
)) AND c.state = 'running' AND c.ahead = 'ahead' AND c.remaining_deps > 0
RETURNING c.remaining_deps
""")


# Revoke the leases of the running actions claimed ahead of one of :keys, and of those claimed ahead of them, sending
# them back to waiting as abandoned without the attempt counting. Their parents went back to waiting, so they could
# only wait out their limit, holding a worker and a slot of the cap; when a parent is re-queued, its outputs they
# may have taken are gone too. An action claimed ahead of :keys has one as a parent, or up to :depth generations up
# across parents that were claimed ahead too, running or since done (an action keeps ``ahead`` once done). With no
# limit, the walk keeps no distance, so it reaches each ancestor once whatever the number of paths to it. The
# batch's few running actions claimed ahead are read first and each is tested by its edges, so the statement reads
# no more than those whatever the planner guesses of a batch inserted since its last statistics; a join here would
# be planned over all the batch's edges.
REVOKE_AHEAD = sa.text("""
WITH RECURSIVE ahead_running AS MATERIALIZED (
    SELECT a.batch_id, a.input_key, ARRAY(
        SELECT e.parent_key FROM edges e WHERE e.batch_id = a.batch_id AND e.input_key = a.input_key
    ) AS parents
    FROM actions a WHERE a.batch_id = :batch_id AND a.state = 'running' AND a.ahead = 'ahead'
), revoked(input_key) AS (
    SELECT c.input_key FROM ahead_running c WHERE EXISTS (
        WITH RECURSIVE up(input_key, distance) AS (
            SELECT parent_key, 1 FROM unnest(c.parents) AS parent_key
            UNION
            SELECT e.parent_key, CASE WHEN CAST(:depth AS integer) IS NULL THEN 0 ELSE u.distance + 1 END FROM up u
            CROSS JOIN LATERAL unnest(ARRAY(
                SELECT e.parent_key FROM edges e WHERE e.batch_id = c.batch_id AND e.input_key = u.input_key
            )) AS e(parent_key)
            WHERE (CAST(:depth AS integer) IS NULL OR u.distance < :depth) AND (
                SELECT p.ahead FROM actions p WHERE p.batch_id = c.batch_id AND p.input_key = u.input_key
            ) = 'ahead'
        )
        SELECT 1 FROM up WHERE input_key = ANY(CAST(:keys AS text[]))
    )
    UNION
    SELECT c.input_key FROM revoked r CROSS JOIN ahead_running c WHERE r.input_key = ANY(c.parents)
), unleased AS (
    UPDATE actions SET state = 'waiting', ahead = 'abandoned', attempts = attempts - 1
    WHERE batch_id = :batch_id AND input_key = ANY(ARRAY(SELECT input_key FROM revoked)) RETURNING input_key
)
DELETE FROM leases WHERE batch_id = :batch_id AND input_key = ANY(ARRAY(SELECT input_key FROM unleased))
""")


@dataclass
class _AheadRead:
    """AHEAD_CANDIDATES read at ``at``, as (batch, input key, tier), best first, which the claims ahead of
    ``claim_ranking_seconds`` share, less those they claimed, and the batches and tiers found since with nothing
    left to claim ahead."""

    at: float
    candidates: list[tuple[UUID, str, str, int]]
    exhausted: set[tuple[UUID, str]]


# The unfinished, unclaimed build actions of other running batches with the same key as a build whose lease just ended;
# see CLAIM_ACTION. With their spec, since a forced or traced build has the same keys as a plain one: only a copy with
# the same spec is done with the build, the others are just no longer held. Read by primary key, a probe per running
# batch: no index leads with input_key.
PEERS = sa.text("""
SELECT batch_id, tier, state, spec_sha256,
    (SELECT ahead_cap IS NOT NULL FROM batches WHERE id = actions.batch_id) AS ahead_batch
FROM actions
WHERE batch_id = ANY(ARRAY(SELECT id FROM batches WHERE state = 'running' AND id <> :batch_id))
AND input_key = :input_key AND class = 'build' AND state IN ('waiting', 'ready')
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
# Both also count the running actions claimed ahead that wait for a parent, as state ``ahead``, for burst_demand:
# they hold a worker but no burst worker should start for them alone.
COUNT_UNFINISHED = sa.text(
    "SELECT a.state, a.tier, a.class, b.priority > 0, count(*) FROM actions a "
    "JOIN batches b ON b.id = a.batch_id "
    "WHERE a.state IN ('waiting', 'ready', 'running') "
    "GROUP BY a.state, a.tier, a.class, b.priority > 0 "
    "UNION ALL SELECT 'ahead', a.tier, a.class, b.priority > 0, count(*) FROM actions a "
    "JOIN batches b ON b.id = a.batch_id "
    "WHERE a.state = 'running' AND a.ahead = 'ahead' AND a.remaining_deps > 0 "
    "GROUP BY a.tier, a.class, b.priority > 0"
)
COUNT_ACTIVE = sa.text(
    "SELECT state, tier, class, false, count(*) FROM actions "
    "WHERE state IN ('ready', 'running') GROUP BY state, tier, class "
    "UNION ALL SELECT 'ahead', tier, class, false, count(*) FROM actions "
    "WHERE state = 'running' AND ahead = 'ahead' AND remaining_deps > 0 GROUP BY tier, class"
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
        # How many actions this process's release has made ready, and waiting claims' tiers, rank, wake (the tier
        # and whether it was for a claim ahead) and whether they may claim ahead, oldest first (the tie-breaker
        # within a host); see claim.
        self.made_ready = 0
        self.claim_waiters: list[tuple[list[str], ClaimRank, asyncio.Future[tuple[str, bool]], bool]] = []
        self.rankings: dict[tuple[str, ...], _Ranking] = {}  # the build claims' shared rankings, by tiers
        self.ranking_reads: dict[tuple[str, ...], asyncio.Task[_Ranking]] = {}
        self.run_admission = asyncio.Lock()  # wait before checkout; the DB advisory lock still spans replicas
        self.rankings_forgotten = 0  # how many times _forget_rankings dropped one, so reads begun before keep none
        # The claims ahead's shared read, the lock its readers take, and how many times _ahead_changed dropped it.
        self.ahead_read: _AheadRead | None = None
        self.ahead_lock = asyncio.Lock()
        self.ahead_changes = 0
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
        *, fail_fast: bool = False, priority: int = 0, ahead_cap: int | None = None,
    ) -> UUID:
        """Store a batch; its actions without uncached parents become ready. With ``ahead_cap``, up to that many
        of its actions at once may be claimed ahead of their parents; see _claim_ahead."""
        batch_id = uuid4()
        parents: defaultdict[str, int] = defaultdict(int)
        for child, _ in batch.edges:
            parents[child] += 1
        dag_priority = dag_priorities([a.input_key for a in batch.actions], batch.edges)
        packages = [a.theory.split(":", 1)[0] for a in batch.actions]
        names = [a.theory.split(":", 1)[1] for a in batch.actions]
        async with self.engine.begin() as conn:
            # Retention takes the same key order: heap/index scan order can otherwise deadlock overlapping writes.
            hints = await conn.execute(
                sa.text(
                    "WITH locked AS (SELECT package, theory, profile FROM peak_hints WHERE profile = :profile "
                    "AND (package, theory) IN "
                    "(SELECT * FROM unnest(CAST(:packages AS text[]), CAST(:names AS text[]))) "
                    "ORDER BY package, theory, profile FOR UPDATE) "
                    "UPDATE peak_hints h SET updated_at = now() FROM locked l "
                    "WHERE (h.package, h.theory, h.profile) = (l.package, l.theory, l.profile) "
                    "RETURNING h.package || ':' || h.theory, h.peak_rss_mb"
                ),
                {"profile": profile, "packages": packages, "names": names},
            )
            high = {theory for theory, peak in hints if peak >= self.settings.standard_tier_mb}
            await conn.execute(
                sa.text(
                    "INSERT INTO batches (id, state, profile, max_heap_mb, fail_fast, priority, ahead_cap) "
                    "VALUES (:id, :state, :profile, :max_heap_mb, :fail_fast, :priority, :ahead_cap)"
                ),
                {
                    "id": batch_id,
                    "state": "running" if batch.actions else "done",
                    "profile": profile,
                    "max_heap_mb": max_heap_mb,
                    "fail_fast": fail_fast,
                    "priority": priority,
                    "ahead_cap": ahead_cap,
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
        *,
        ahead: bool = False,
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

        A claim ``ahead`` comes from a worker that can load ahead: when nothing is ready, it may get an action of a
        batch that loads ahead whose parents still run; see _claim_ahead.
        """
        loop = asyncio.get_running_loop()
        deadline = loop.time() + wait_s
        rank = _claim_rank(tiers, host_id, host_rank)
        woken: asyncio.Future[tuple[str, bool]] = loop.create_future()  # done once a wake was handed to this claim

        def undeferred(*, ahead_only: bool) -> list[str]:
            """The tiers no better-ranked unwoken waiter takes, of those that may claim ahead if ``ahead_only``."""
            # An ahead wake bypassed better-ranked waiters that can't claim ahead, so it lifts only the ahead deferral.
            return tiers if woken.done() and (ahead_only or not woken.result()[1]) else [
                tier for tier in tiers
                if not any(
                    tier in w_tiers and not w_woken.done() and w_rank < rank and (w_ahead or not ahead_only)
                    for w_tiers, w_rank, w_woken, w_ahead in self.claim_waiters
                )
            ]

        try:
            while True:
                # Work made claimable during the attempt is retried at once, for workers that can take it.
                seen = (self.made_ready, self.ahead_changes if ahead else 0)
                eligible_tiers = undeferred(ahead_only=False)
                # A better-ranked waiter that can't claim ahead leaves the actions claimed ahead to this one.
                ahead_tiers = undeferred(ahead_only=True) if ahead else []
                outranked = (
                    await self._outranked_by_ahead(tiers, ahead_tiers) if ahead_tiers and eligible_tiers else None
                )
                claimed = await self._claim(eligible_tiers, worker, outranked) if eligible_tiers else None
                if claimed is None and ahead_tiers:
                    claimed = await self._claim_ahead(ahead_tiers, worker)
                remaining = deadline - loop.time()
                if claimed is not None or remaining <= 0:
                    return claimed
                woken = loop.create_future()
                if (self.made_ready, self.ahead_changes if ahead else 0) == seen:
                    waiter = (tiers, rank, woken, ahead)
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

    async def _outranked_by_ahead(
        self, tiers: list[str], ahead_tiers: list[str]
    ) -> Callable[[str, int], list[str]] | None:
        """For a ready build of a tier and priority, the tiers of ``ahead_tiers`` no later than its tier in
        ``tiers`` with an action that may be claimed ahead of a batch of a higher priority, which ranks before the
        build; none when there is no such action. Ready builds of the same priority come first, so with no
        priorities set claims ahead wait for every ready build, as they did before priorities ranked them. None
        when nothing may be claimed ahead."""
        read = await self._ahead_candidates()
        best: dict[str, int] = {}  # the highest priority of a candidate of each tier
        for batch_id, _, tier, priority in read.candidates:
            if tier in ahead_tiers and (batch_id, tier) not in read.exhausted:
                best[tier] = max(best.get(tier, priority), priority)
        if not best:
            return None
        return lambda tier, priority: [
            t for t in ahead_tiers if t in best and best[t] > priority and tiers.index(t) <= tiers.index(tier)
        ]

    async def _claim(
        self,
        tiers: list[str],
        worker: str,
        outranked: Callable[[str, int], list[str]] | None = None,
    ) -> Claim | None:
        """Lease a ready build of ``tiers`` from the shared ranking, else a run action. Before a ready build that
        ranks after an action that may be claimed ahead, claim one of the tiers ``outranked`` gives for it, of a
        higher priority than the build's; failing that, the build is claimed after all."""
        started = asyncio.get_running_loop().time()
        key = tuple(tiers)
        ranking = await self._current_ranking(key)
        floor = min(self.settings.run_floor, self.settings.run_slots)
        if floor > 0:
            claimed, _ = await self._claim_run(tiers, worker, floor)
            if claimed is not None:
                return claimed
        while True:
            async with self.engine.begin() as conn:
                # Never lock a batch after an action: batch writers take those locks in the opposite order.
                row = await self._claim_build(conn, ranking, outranked)
                if row is not None:
                    claimed, ahead_batch = await self._lease(conn, row, worker)
            if row is not None:
                self._leased(row.batch_id, ahead_batch=ahead_batch)
                return claimed
            if ranking.heap and (not ranking.ranked or ranking.at >= started):
                # The next ready build ranks after an action that may be claimed ahead, by a ranking read since
                # this claim started.
                assert outranked is not None
                _, priority, *_, tier, _ = ranking.heap[0]
                claimed = await self._claim_ahead(outranked(tier, -priority), worker, above=-priority)
                if claimed is not None:
                    return claimed
                outranked = None
                continue
            if not ranking.heap and (not ranking.ranked or ranking.at >= started):
                claimed, retry_builds = await self._claim_run(
                    tiers, worker, self.settings.run_slots, builds_first=True
                )
                if not retry_builds:
                    return claimed
                started = asyncio.get_running_loop().time()
            # Refresh outside the transaction: waiting here with a connection could starve the shared read.
            if self.rankings.get(key) is ranking:
                self.rankings.pop(key)
            ranking = await self._current_ranking(key, after=started)

    async def _claim_run(
        self, tiers: list[str], worker: str, slots: int, *, builds_first: bool = False
    ) -> tuple[Claim | None, bool]:
        """Return a run lease or a request to retry builds, queuing before taking a pooled connection."""
        if slots == 0:
            return None, False
        available = sa.text(
            "SELECT EXISTS (SELECT 1 FROM actions WHERE state = 'ready' AND class = 'run' "
            "AND tier = ANY(CAST(:tiers AS text[]))) AND "
            "(SELECT count(*) FROM actions WHERE state = 'running' AND class = 'run') < :run_slots"
        )
        params = {"tiers": tiers, "classes": ["run"], "run_slots": slots}
        async with self.engine.connect() as conn:
            if not await conn.scalar(available, params):
                return None, False
        # Only one connection per process may wait for cross-replica run admission. Builds bypass this gate.
        async with self.run_admission, self.engine.begin() as conn:
            await conn.execute(sa.text("SELECT pg_advisory_xact_lock(1752132706, 1)"))
            # A build made ready during the wait still precedes a fallback run. Rank it outside this transaction.
            if builds_first and await conn.scalar(
                sa.text(
                    "SELECT EXISTS (SELECT 1 FROM actions WHERE state = 'ready' AND class = 'build' "
                    "AND tier = ANY(CAST(:tiers AS text[])) "
                    "AND input_key NOT IN (SELECT input_key FROM leases WHERE expires_at > now()) "
                    "FOR UPDATE SKIP LOCKED)"
                ),
                params,
            ):
                return None, True
            # A preceding admission may have filled the floor/cap; don't rank every batch again in that case.
            if not await conn.scalar(available, params):
                return None, False
            row = await self._claim_first(conn, params)
            if row is None:
                return None, False
            claimed, ahead_batch = await self._lease(conn, row, worker)
        self._leased(row.batch_id, ahead_batch=ahead_batch)
        return claimed, False

    async def _lease(
        self, conn: AsyncConnection, row: _Claimed, worker: str, ahead_parents: tuple[AheadParent, ...] = ()
    ) -> tuple[Claim, bool]:
        """Record a lease for the action locked by this transaction, claimed ahead of ``ahead_parents`` when there
        are any. Also whether it was a plain claim in a batch that loads ahead, whose waiting children may now be
        claimed ahead: see _leased.

        A plain claim of an action a claim ahead left waiting isn't one ahead; one abandoned stays so."""
        token = uuid4()
        leased = (
            await conn.execute(
                sa.text(
                    "UPDATE actions SET state = 'running', attempts = attempts + 1, last_claimed_at = now(), "
                    "ahead = CASE WHEN :ahead THEN 'ahead' WHEN ahead = 'abandoned' THEN ahead ELSE 'no' END "
                    "WHERE batch_id = :batch_id AND input_key = :input_key "
                    "RETURNING (SELECT ahead_cap IS NOT NULL FROM batches WHERE id = :batch_id) AS ahead_batch"
                ),
                {"batch_id": row.batch_id, "input_key": row.input_key, "ahead": bool(ahead_parents)},
            )
        ).one()
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
        claim = Claim(
            token, row.spec_sha256, row.input_key, row.theory, self.settings.lease_seconds, row.max_heap_mb,
            ahead_parents,
        )
        return claim, leased.ahead_batch and not ahead_parents

    def _leased(self, batch_id: UUID, *, ahead_batch: bool) -> None:
        """After a lease of ``_lease`` committed: tell the batch's followers, and for a plain claim in a batch that
        loads ahead, let the claims ahead see the children of the action leased."""
        self._batch_changed(batch_id)
        if ahead_batch:
            self._ahead_changed()

    async def _claim_ahead(self, tiers: list[str], worker: str, *, above: int | None = None) -> Claim | None:
        """Lease an action of ``tiers`` ahead of its parents: of the running batches with an ``ahead_cap`` and
        fewer than that many actions waiting ahead, the action whose chain of dependents is deepest of those whose
        unfinished parents all run, at most ``ahead_depth`` generations ahead (CLAIM_AHEAD_ACTION). Its claim names
        its unfinished ancestors, ancestors first, whose outputs its worker waits for.

        Candidates come from a read the claims of ``claim_ranking_seconds`` share; each batch is then locked, as
        every writer of it does first, so its cap and the parents' states are rechecked against concurrent claims
        and completions. A batch and tier found with nothing to claim are skipped until the next read. With
        ``above``, only batches of a higher priority are claimed from.
        """
        read = await self._ahead_candidates()
        # Tier by tier, as a plain claim takes them, then in the read's order.
        for tier in tiers:
            for batch_id in dict.fromkeys(
                b for b, _, t, priority in read.candidates if t == tier and (above is None or priority > above)
            ):
                if (batch_id, tier) in read.exhausted:
                    continue
                claimed = await self._claim_ahead_in(read, batch_id, tier, worker)
                if claimed is not None:
                    return claimed
        return None

    async def _claim_ahead_in(self, read: _AheadRead, batch_id: UUID, tier: str, worker: str) -> Claim | None:
        """Lease the best action of ``tier`` of ``batch_id`` that ``read`` found may be claimed ahead, if any still
        may, or mark the batch and tier exhausted in ``read``."""
        keys = [key for b, key, t, _ in read.candidates if (b, t) == (batch_id, tier)][:AHEAD_CLAIM_KEYS]
        async with self.engine.begin() as conn:
            batch = (
                await conn.execute(
                    sa.text(
                        "SELECT ahead_cap, max_heap_mb FROM batches WHERE id = :id AND state = 'running' FOR UPDATE"
                    ),
                    {"id": batch_id},
                )
            ).first()
            row = None
            depth = self.settings.ahead_depth_limit
            waiting = 0
            if batch is not None:
                # Counted after the lock, in a snapshot that sees every claim ahead committed before it.
                waiting = await conn.scalar(COUNT_WAITING_AHEAD, {"batch_id": batch_id})
                if waiting < batch.ahead_cap:
                    row = (
                        await conn.execute(
                            CLAIM_AHEAD_ACTION, {"batch_id": batch_id, "keys": keys, "tier": tier, "depth": depth}
                        )
                    ).first()
            if row is None:
                read.exhausted.add((batch_id, tier))
                return None
            parents = (
                await conn.execute(AHEAD_PARENTS, {"batch_id": batch_id, "keys": [row.input_key], "depth": depth})
            ).all()
            ahead_parents = tuple(AheadParent(p.input_key, p.spec_sha256) for p in parents)
            claimed, _ = await self._lease(
                conn,
                _Claimed(batch_id, row.input_key, row.spec_sha256, row.theory, batch.max_heap_mb),
                worker,
                ahead_parents,
            )
        # Out of the shared read, so the next claim of this read orders the batches by what remains.
        read.candidates = [c for c in read.candidates if (c[0], c[1]) != (batch_id, row.input_key)]
        self._batch_changed(batch_id)
        # Below the last generation, its own waiting children may now be claimed ahead, while the cap has room.
        if (depth is None or max(p.distance for p in parents) < depth) and waiting + 1 < batch.ahead_cap:
            self._ahead_changed()
        return claimed

    async def _ahead_candidates(self) -> _AheadRead:
        """The last read of AHEAD_CANDIDATES if younger than ``claim_ranking_seconds``, else a new one, which
        concurrent callers wait for together."""
        loop = asyncio.get_running_loop()
        async with self.ahead_lock:
            read = self.ahead_read
            if read is not None and loop.time() - read.at < self.settings.claim_ranking_seconds:
                return read
            changes = self.ahead_changes
            at = loop.time()
            async with self.engine.connect() as conn:
                rows = (await conn.execute(AHEAD_CANDIDATES, {"depth": self.settings.ahead_depth_limit})).all()
            read = _AheadRead(at, [(row.batch_id, row.input_key, row.tier, row.priority) for row in rows], set())
            # Not shared when a change since the read began may have made other actions candidates.
            if changes == self.ahead_changes:
                self.ahead_read = read
            return read

    def _ahead_changed(self) -> None:
        """Drop the claims ahead's shared read, since actions of a batch that loads ahead may have become
        candidates, and wake a claim of each tier that may claim ahead: their tiers aren't known here."""
        self.ahead_read = None
        self.ahead_changes += 1
        for tier in ("standard", "high"):
            self._wake_claim(tier, ahead=True)

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
        self, conn: AsyncConnection, ranking: "_Ranking", outranked: Callable[[str, int], list[str]] | None = None
    ) -> _Claimed | None:
        """Lock a ready build from the shared ranking, without refreshing it inside the transaction.

        Put each candidate back with one more running action before trying it, so concurrent claims spread over
        batches as fresh rankings would. Exhausted batch/tier pairs are skipped until the next shared read. Stop
        at a candidate ``outranked`` says ranks after a claim ahead, leaving it first in the ranking.
        """
        while ranking.heap:
            entry = heapq.heappop(ranking.heap)
            tier_position, priority, running, _, _, created_at, batch_id, tier, max_heap_mb = entry
            if (batch_id, tier) in ranking.exhausted:
                continue
            if outranked is not None and outranked(tier, -priority):
                heapq.heappush(ranking.heap, entry)
                return None
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
        return None

    async def _current_ranking(self, key: tuple[str, ...], *, after: float = 0) -> "_Ranking":
        """Share one read per tier key, fresh enough for invalidations seen on entry and ``after``.

        An empty ranking stays valid for the TTL, until a release invalidates it. An exhausted nonempty ranking
        needs a new read. A release during a read leaves it shared, but callers arriving after the release wait
        for it outside the pool and then share another read that includes the newly ready actions.
        """
        forgotten = self.rankings_forgotten
        while True:
            ranking = self.rankings.get(key)
            if (
                ranking is not None and ranking.forgotten >= forgotten
                and asyncio.get_running_loop().time() - ranking.at < self.settings.claim_ranking_seconds
                and (ranking.heap or not ranking.ranked) and ranking.at >= after
            ):
                return ranking
            read = self.ranking_reads.get(key)
            if read is None or read.done():

                async def rank() -> _Ranking:
                    try:
                        async with self.engine.connect() as conn:
                            ranking = await self._rank(conn, key)
                        self._keep_ranking(key, ranking)
                        return ranking
                    finally:
                        # Clear before completion: awaiting a done stale read never yields to a cleanup callback.
                        if self.ranking_reads.get(key) is asyncio.current_task():
                            del self.ranking_reads[key]

                read = asyncio.get_running_loop().create_task(rank())
                self.ranking_reads[key] = read

                def done(task: asyncio.Task[_Ranking]) -> None:
                    # Observe failures even when every shielded caller was cancelled.
                    if not task.cancelled():
                        task.exception()

                read.add_done_callback(done)
            # Cancellation belongs to the caller; the read still serves other claims.
            ranking = await asyncio.shield(read)
            if ranking.forgotten >= forgotten and ranking.at >= after:
                return ranking

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
        have it with a ready action of one of them, or have since found it without one. Rankings being read then,
        may predate those actions. Keep the in-flight read shared; later callers require a post-release read
        after it finishes, and _keep_ranking discards its stale result."""
        keys = {key for key in [*self.rankings, *self.ranking_reads] if tiers.intersection(key)}
        stale = {
            key for key in keys
            if key in self.ranking_reads
            or (ranking := self.rankings.get(key)) is None or not all(
                (batch_id, tier) in ranking.ranked and (batch_id, tier) not in ranking.exhausted
                for tier in tiers if tier in key
            )
        }
        if stale:
            self.rankings_forgotten += 1
            for key in stale:
                self.rankings.pop(key, None)

    def _wake_claim(self, tier: str, *, ahead: bool = False) -> None:
        """Wake the best-ranked compatible claim, with FIFO ties. Only normal wakes count newly ready work;
        changes for capable claims are recorded by _ahead_changed."""
        if not ahead:
            self.made_ready += 1
        waiter = min(
            (w for w in self.claim_waiters if tier in w[0] and not w[2].done() and (w[3] or not ahead)),
            key=lambda w: w[1],
            default=None,
        )
        if waiter is not None:
            waiter[2].set_result((tier, ahead))
            self.claim_waiters.remove(waiter)

    def _pass_wake(self, woken: asyncio.Future[tuple[str, bool]]) -> None:
        """Hand the wake of a claim leaving without trying, if it got one, to the next claim it was for."""
        if woken.done() and not woken.cancelled():
            tier, ahead = woken.result()
            if not ahead:
                self.made_ready -= 1
            self._wake_claim(tier, ahead=ahead)

    async def _peers(self, batch_id: UUID, action: sa.Row[Any]) -> list[sa.Row[Any]]:
        """The waiting and ready copies of build ``action`` of ``batch_id``, whose lease just ended, in other
        running batches, with their batch, tier, state, spec and ahead opt-in; see PEERS. Read once the lease's deletion
        committed, so a batch submitted meanwhile is either found or was never held."""
        if action.action_class != "build":
            return []
        async with self.engine.connect() as conn:
            return list(await conn.execute(PEERS, {"batch_id": batch_id, "input_key": action.input_key}))

    def _wake_peers(self, peers: list[sa.Row[Any]]) -> None:
        """Have claims take the ``peers`` now that the lease holding them back ended: the ready ones as if just made
        ready, the waiting ones ahead of their parents."""
        for peer in peers:
            if peer.state == "ready":
                self._forget_rankings(peer.batch_id, {peer.tier})
                self._wake_claim(peer.tier)
        if any(peer.state == "waiting" and peer.ahead_batch for peer in peers):
            self._ahead_changed()

    async def _finish_peer(
        self, batch_id: UUID, input_key: str, log_sha256: str | None, *, ahead_batch: bool
    ) -> None:
        """Mark done the copy in ``batch_id`` of build ``input_key``, which another batch's worker just finished
        and published, if no claim took it meanwhile; it keeps that worker's log for the client to show."""
        async with self.engine.begin() as conn:
            if await self._lock_batch(conn, batch_id) != "running":
                return
            done = await conn.scalar(
                sa.text(
                    "UPDATE actions SET state = 'done', log_sha256 = :log, last_failure = NULL, failure_detail = NULL "
                    "WHERE batch_id = :batch_id AND input_key = :input_key AND state IN ('waiting', 'ready') "
                    "RETURNING input_key"
                ),
                {"batch_id": batch_id, "input_key": input_key, "log": log_sha256},
            )
            if done is None:
                return
            await conn.execute(REFRESH_CHILDREN, {"batch_id": batch_id, "keys": [input_key]})
            await self._finish_if_done(conn, batch_id)
        self._batch_changed(batch_id)
        self.request_release(batch_id)
        if ahead_batch:
            self._ahead_changed()  # its children may now be claimed ahead

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
                        "a.class AS action_class, a.ahead, a.remaining_deps, b.profile, b.ahead_cap IS NOT NULL AS ahead_batch "
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
            # Whether a slot of the batch's cap may be free, or the action's children may be claimed ahead, now: a
            # failure frees the action's slot if it was claimed ahead, and those of the actions claimed ahead of it,
            # which it revokes or cancels.
            unblocked = action.ahead_batch and result.status == "failed"
            if result.failure == "memory" and action.tier == "standard":
                # The tier it failed on is the hint: future batches place this theory on the high tier.
                await self._record_peak(conn, package, theory, action.profile, self.settings.standard_tier_mb)
                await conn.execute(
                    sa.text("UPDATE actions SET tier = 'high' WHERE batch_id = :batch_id AND input_key = :input_key"),
                    {"batch_id": batch_id, "input_key": action.input_key},
                )
            if result.status != "failed":
                await self._set_state(conn, batch_id, action.input_key, "done")
                if result.peak_rss_mb is not None:
                    await self._record_peak(conn, package, theory, action.profile, result.peak_rss_mb)
                await conn.execute(REFRESH_CHILDREN, {"batch_id": batch_id, "keys": [action.input_key]})
                if action.ahead_batch:
                    refreshed = (
                        await conn.execute(REFRESH_AHEAD_CHILDREN, {"batch_id": batch_id, "key": action.input_key})
                    ).all()
                    unblocked = any(child.remaining_deps == 0 for child in refreshed)
                    if self.settings.ahead_depth != 1:
                        # A child still waiting for a parent may be a generation nearer, so its own children may be
                        # claimed ahead now; and an action claimed ahead that finished before its parents' results
                        # came frees its slot of the cap.
                        unblocked = bool(refreshed) or (action.ahead == "ahead" and action.remaining_deps > 0)
                await self._finish_if_done(conn, batch_id)
            elif result.failure == "ahead-abandoned" and action.ahead == "ahead":
                # Loading ahead gave up; the action is built once its parents are done, and the try costs no attempt.
                await conn.execute(
                    sa.text(
                        "UPDATE actions SET attempts = attempts - 1, ahead = 'abandoned' "
                        "WHERE batch_id = :batch_id AND input_key = :input_key"
                    ),
                    {"batch_id": batch_id, "input_key": action.input_key},
                )
                await self._retry(conn, batch_id, action.input_key, ahead_batch=action.ahead_batch)
            elif result.failure == "unavailable" and action.interruptions < self.settings.max_interruptions:
                # The worker couldn't start or finish it, so it doesn't count as an attempt.
                await conn.execute(
                    sa.text(
                        "UPDATE actions SET attempts = attempts - 1, interruptions = interruptions + 1 "
                        "WHERE batch_id = :batch_id AND input_key = :input_key"
                    ),
                    {"batch_id": batch_id, "input_key": action.input_key},
                )
                await self._retry(conn, batch_id, action.input_key, ahead_batch=action.ahead_batch)
            elif action.attempts < self.settings.max_attempts and (
                # ``ahead-abandoned`` from an action not claimed ahead is an error in the worker.
                result.failure in ("publish", "toolchain", "internal", "memory", "unavailable", "ahead-abandoned")
                or (result.failure == "disk" and action.last_failure != "disk")
            ):
                await self._retry(conn, batch_id, action.input_key, ahead_batch=action.ahead_batch)
            elif result.failure == "input-missing":
                self._forget_cache_findings()
                await self._input_missing(
                    conn, batch_id, action.input_key, action.theory, action.attempts, result,
                    ahead_batch=action.ahead_batch,
                )
            else:
                detail = f": {result.detail}" if result.detail else ""
                await self._fail(
                    conn, batch_id, action.input_key, action.action_class, f"{action.theory}: {result.failure}{detail}"
                )
        self._batch_changed(batch_id)
        self.request_release(batch_id)
        if unblocked:
            self._ahead_changed()
        peers = await self._peers(batch_id, action)
        done = [] if result.status == "failed" else [peer for peer in peers if peer.spec_sha256 == action.spec_sha256]
        self._wake_peers([peer for peer in peers if peer not in done])
        for peer in done:
            await self._finish_peer(peer.batch_id, action.input_key, result.log_sha256, ahead_batch=peer.ahead_batch)
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
            ahead_freed = False
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
                            "SELECT a.input_key, a.spec_sha256, a.theory, a.state, a.attempts, a.class AS action_class, "
                            "a.ahead, a.remaining_deps, b.ahead_cap IS NOT NULL AS ahead_batch "
                            "FROM actions a JOIN batches b ON b.id = a.batch_id "
                            "WHERE a.batch_id = :batch_id AND a.input_key = :input_key FOR UPDATE OF a"
                        ),
                        {"batch_id": batch_id, "input_key": lease.input_key},
                    )
                ).one()
                if action.state != "running":
                    continue
                if action.ahead == "ahead" and action.remaining_deps > 0:
                    # Lost while waiting ahead (a reclaimed burst host, say): given up as loading ahead is, without
                    # the attempt counting.
                    await conn.execute(
                        sa.text(
                            "UPDATE actions SET attempts = attempts - 1, ahead = 'abandoned' "
                            "WHERE batch_id = :batch_id AND input_key = :input_key"
                        ),
                        {"batch_id": batch_id, "input_key": lease.input_key},
                    )
                    await self._retry(conn, batch_id, lease.input_key, ahead_batch=True)
                    ahead_freed = True
                elif action.attempts >= self.settings.max_attempts:
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
                    await self._retry(conn, batch_id, lease.input_key, ahead_batch=action.ahead_batch)
                    ahead_freed = action.ahead_batch  # the retry revokes what was claimed ahead of it
            # After the commit, so the claims woken see the slots of the cap this freed.
            if ahead_freed:
                self._ahead_changed()
            self._wake_peers(await self._peers(batch_id, action))
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
                sa.text(
                    "WITH locked AS (SELECT package, theory, profile FROM peak_hints "
                    "WHERE updated_at < now() - make_interval(days => :days) "
                    "ORDER BY package, theory, profile FOR UPDATE) "
                    "DELETE FROM peak_hints h USING locked l "
                    "WHERE (h.package, h.theory, h.profile) = (l.package, l.theory, l.profile)"
                ),
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
        ready_high_run = 0
        priorities: defaultdict[str, int] = defaultdict(int)
        for state, tier, action_class, prioritized, n in await conn.execute(statement):
            if state == "ahead":
                count[state, tier] += n
                continue
            if prioritized:
                priorities[state] += n
            count[state, tier] += n
            if action_class == "run":
                runs[state] += n
                if tier == "high" and state in ("ready", "running"):
                    high_run += n
                if tier == "high" and state == "ready":
                    ready_high_run += n
        return QueueCounts(
            waiting=count["waiting", "standard"] + count["waiting", "high"],
            ready_standard=count["ready", "standard"],
            ready_high=count["ready", "high"],
            running_standard=count["running", "standard"],
            running_high=count["running", "high"],
            ready_run=runs["ready"],
            running_run=runs["running"],
            high_run=high_run,
            ready_high_run=ready_high_run,
            ready_priority=priorities["ready"],
            running_priority=priorities["running"],
            waiting_ahead_standard=count["ahead", "standard"],
            waiting_ahead_high=count["ahead", "high"],
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
            return ranked_nodes(self.cache_nodes, digest)
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
        # Every node is asked before a miss: a worker writes to the node nearest to it, and until that node has
        # written the entry through to the shared store, no other node holds it.
        for node in await self.cache_read_nodes(ac_key):
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
            batch = (
                await conn.execute(
                    sa.text("SELECT state, ahead_cap FROM batches WHERE id = :id FOR UPDATE"), {"id": batch_id}
                )
            ).first()
            if batch is None or batch.state != "running":
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
                await self._requeue(conn, batch_id, parent, ahead_batch=batch.ahead_cap is not None)
            else:
                await self._fail_batch(
                    conn, batch_id, parent, f"resubmit: {action.theory} (theory {parent}) is not in the cache after it built"
                )
        self._batch_changed(batch_id)
        return requeued

    async def _input_missing(
        self, conn: AsyncConnection, batch_id: UUID, input_key: str, theory: str, attempts: int, result: Result,
        *, ahead_batch: bool,
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
            await self._back_to_waiting(conn, batch_id, input_key, ahead_batch=ahead_batch)
            await self._requeue(conn, batch_id, missing.key, ahead_batch=ahead_batch)
        else:
            await self._retry(conn, batch_id, input_key, ahead_batch=ahead_batch)

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

    async def _requeue(self, conn: AsyncConnection, batch_id: UUID, input_key: str, *, ahead_batch: bool) -> None:
        """Send a done action back to waiting, to be built again. In a batch that loads ahead, the actions claimed
        ahead of it lose their leases and wait as abandoned, without the attempt counting (REVOKE_AHEAD)."""
        requeued = await conn.execute(
            sa.text(
                "UPDATE actions SET state = 'waiting' WHERE batch_id = :batch_id AND input_key = :input_key "
                "AND state = 'done'"
            ),
            {"batch_id": batch_id, "input_key": input_key},
        )
        if ahead_batch and requeued.rowcount:
            await conn.execute(
                REVOKE_AHEAD, {"batch_id": batch_id, "keys": [input_key], "depth": self.settings.ahead_depth_limit}
            )
        await conn.execute(REFRESH_KEYS, {"batch_id": batch_id, "keys": [input_key]})
        await conn.execute(REFRESH_CHILDREN, {"batch_id": batch_id, "keys": [input_key]})

    async def _retry(self, conn: AsyncConnection, batch_id: UUID, input_key: str, *, ahead_batch: bool) -> None:
        """Send a failed or expired action back to waiting, so ``release`` checks its parents' keys again, or
        trusts what it found within ``IN_CACHE_TRUST_SECONDS``.

        A parent may have been re-queued while the action ran; going straight to ready would skip that check.
        """
        await self._back_to_waiting(conn, batch_id, input_key, ahead_batch=ahead_batch)
        await conn.execute(REFRESH_KEYS, {"batch_id": batch_id, "keys": [input_key]})

    async def _back_to_waiting(self, conn: AsyncConnection, batch_id: UUID, input_key: str, *, ahead_batch: bool) -> None:
        """Set a running action of ``batch_id`` waiting. In a batch that loads ahead, a claim ahead of it no longer
        waits for a running parent, so it is revoked (REVOKE_AHEAD), and the action, if it was claimed
        ahead itself, is a plain one from now on unless it was abandoned."""
        if ahead_batch:
            await conn.execute(
                REVOKE_AHEAD, {"batch_id": batch_id, "keys": [input_key], "depth": self.settings.ahead_depth_limit}
            )
            await conn.execute(
                sa.text(
                    "UPDATE actions SET ahead = 'no' "
                    "WHERE batch_id = :batch_id AND input_key = :input_key AND ahead = 'ahead'"
                ),
                {"batch_id": batch_id, "input_key": input_key},
            )
        await self._set_state(conn, batch_id, input_key, "waiting")

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
