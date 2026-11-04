"""Scheduling state of remote holbuild builds: batches, their DAG, leases and retries, over Postgres.

Done means the action's key is in the remote cache's ``/ac/``; Postgres holds no result pointers. Lock order
is a batch row first, then its actions and leases, so a completion, an expiry and a cancel never deadlock.
"""

import asyncio
import logging
import shlex
from collections import defaultdict
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from uuid import UUID, uuid4

import asyncpg
import httpx
import sqlalchemy as sa
from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine, create_async_engine

from remote_exec.formats import Batch, Result

logger = logging.getLogger(__name__)

# A scale command that runs longer than this is killed, so it can't stall the sweep.
SCALE_CMD_TIMEOUT_S = 60


class Settings(BaseSettings):
    """The coordinator's configuration, from ``REMOTE_EXEC_*`` environment variables."""

    # hide_input_in_errors: a validation error would otherwise print every setting, credentials included.
    model_config = SettingsConfigDict(env_prefix="REMOTE_EXEC_", hide_input_in_errors=True)

    database_url: str  # postgresql+asyncpg://...
    client_token: SecretStr
    worker_token: SecretStr
    cache_url: str  # bazel-remote base URL; HEAD <cache_url>/ac/<ac-key>
    lease_seconds: int = 120
    max_attempts: int = 3
    # A theory whose peak hint reaches this goes to the high-memory tier; set it to what a standard worker holds.
    standard_tier_mb: int = 16000
    retention_hours: int = 168
    hint_ttl_days: int = 30
    sweep_seconds: float = 5.0
    events_poll_seconds: float = 1.0
    # Burst workers: workers that a scaler starts and stops on top of `warm_workers` always-on ones.
    warm_workers: int = 0
    max_burst_workers: int = 0
    scale_down_hold_s: float = 900.0
    scale_cmd: str | None = None  # run as `<scale_cmd> <desired burst workers>` when that number changes


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


@dataclass(frozen=True)
class ActionStatus:
    input_key: str
    theory: str
    state: str
    tier: str
    attempts: int
    last_failure: str | None
    log_sha256: str | None


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


@dataclass(frozen=True)
class QueueStatus:
    counts: QueueCounts
    desired_burst_workers: int


def burst_demand(counts: QueueCounts, warm_workers: int, max_burst_workers: int) -> int:
    """Burst workers the queue needs now: every ready or running action beyond the warm workers, and at least
    one per high-tier action, since warm workers are standard-tier; at most ``max_burst_workers``."""
    ready = counts.ready_standard + counts.ready_high
    running = counts.running_standard + counts.running_high
    demand = max(0, ready + running - warm_workers, counts.ready_high + counts.running_high)
    return min(demand, max_burst_workers)


def is_auth_failure(error: BaseException) -> bool:
    """Whether ``error``, or an error it wraps, is the database refusing the coordinator's credentials."""
    seen: BaseException | None = error
    while seen is not None:
        if isinstance(seen, asyncpg.InvalidAuthorizationSpecificationError):
            return True
        seen = seen.__cause__ or getattr(seen, "orig", None)
    return False


# Recompute remaining_deps of the selected waiting or ready actions from their parents' states; an action with
# a parent that isn't done goes back to waiting.
REFRESH = """
UPDATE actions c SET remaining_deps = n.remaining,
    state = CASE WHEN n.remaining > 0 THEN 'waiting' ELSE c.state END
FROM (
    SELECT a.input_key, count(p.input_key) FILTER (WHERE p.state <> 'done') AS remaining
    FROM actions a
    LEFT JOIN edges e ON e.batch_id = a.batch_id AND e.input_key = a.input_key
    LEFT JOIN actions p ON p.batch_id = e.batch_id AND p.input_key = e.parent_key
    WHERE a.batch_id = :batch_id AND a.input_key IN ({selected})
    GROUP BY a.input_key
) n
WHERE c.batch_id = :batch_id AND c.input_key = n.input_key AND c.state IN ('waiting', 'ready')
"""
REFRESH_KEYS = sa.text(REFRESH.format(selected="SELECT unnest(CAST(:keys AS text[]))"))
REFRESH_CHILDREN = sa.text(
    REFRESH.format(selected="SELECT input_key FROM edges WHERE batch_id = :batch_id AND parent_key = ANY(:keys)")
)


# The burst worker target at :now: the highest demand recorded in the hold before it, under the current cap.
HELD_TARGET = sa.text(
    "SELECT least(coalesce(max(workers), 0), :cap) FROM burst_demand "
    "WHERE at >= CAST(:now AS timestamptz) - make_interval(secs => :hold)"
)


class Coordinator:
    """Owns the database engine and the cache client; every rule of the coordinator lives here."""

    def __init__(self, engine: AsyncEngine, cache: httpx.AsyncClient, settings: Settings) -> None:
        self.engine = engine
        self.cache = cache
        self.settings = settings
        self.clock: Callable[[], datetime] = lambda: datetime.now(UTC)
        self.scaled_to: int | None = None  # what the scale command last accepted

    @classmethod
    def from_settings(cls, settings: Settings) -> "Coordinator":
        return cls(
            create_async_engine(settings.database_url, pool_pre_ping=True),
            httpx.AsyncClient(base_url=settings.cache_url, timeout=30, follow_redirects=True),
            settings,
        )

    async def aclose(self) -> None:
        await self.cache.aclose()
        await self.engine.dispose()

    async def submit(self, batch: Batch, profile: str) -> UUID:
        """Store a batch; its actions without uncached parents become ready."""
        batch_id = uuid4()
        parents: defaultdict[str, int] = defaultdict(int)
        for child, _ in batch.edges:
            parents[child] += 1
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
                sa.text("INSERT INTO batches (id, state, profile) VALUES (:id, :state, :profile)"),
                {"id": batch_id, "state": "running" if batch.actions else "done", "profile": profile},
            )
            if batch.actions:
                await conn.execute(
                    sa.text(
                        "INSERT INTO actions "
                        "(batch_id, input_key, ac_key, spec_sha256, theory, remaining_deps, state, tier) "
                        "VALUES (:batch_id, :input_key, :ac_key, :spec, :theory, :remaining, 'waiting', :tier)"
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
        async with self.engine.connect() as conn:
            batch = (
                await conn.execute(sa.text("SELECT state, failure FROM batches WHERE id = :id"), {"id": batch_id})
            ).first()
            if batch is None:
                return None
            actions = await conn.execute(
                sa.text(
                    "SELECT input_key, theory, state, tier, attempts, last_failure, log_sha256 FROM actions "
                    "WHERE batch_id = :id ORDER BY theory, input_key"
                ),
                {"id": batch_id},
            )
            return BatchStatus(batch_id, batch.state, batch.failure, [ActionStatus(*row) for row in actions])

    async def cancel(self, batch_id: UUID) -> str | None:
        """Cancel a running batch; its leases go, so its workers' heartbeats and completions are refused."""
        async with self.engine.begin() as conn:
            state = await self._lock_batch(conn, batch_id)
            if state != "running":
                return state
            await conn.execute(sa.text("UPDATE batches SET state = 'cancelled' WHERE id = :id"), {"id": batch_id})
            await self._stop_actions(conn, batch_id)
            return "cancelled"

    async def claim(self, tiers: list[str], worker: str) -> Claim | None:
        """Lease a ready action to ``worker``, or None if none: of the first of ``tiers`` that has one, the oldest
        batch's first (by theory)."""
        async with self.engine.begin() as conn:
            row = (
                await conn.execute(
                    sa.text(
                        "SELECT a.batch_id, a.input_key, a.spec_sha256, a.theory FROM actions a "
                        "JOIN batches b ON b.id = a.batch_id "
                        "WHERE a.state = 'ready' AND a.tier = ANY(CAST(:tiers AS text[])) AND b.state = 'running' "
                        "ORDER BY array_position(CAST(:tiers AS text[]), a.tier), b.created_at, a.theory, a.input_key "
                        "LIMIT 1 FOR UPDATE OF a SKIP LOCKED"
                    ),
                    {"tiers": tiers},
                )
            ).first()
            if row is None:
                return None
            token = uuid4()
            await conn.execute(
                sa.text(
                    "UPDATE actions SET state = 'running', attempts = attempts + 1 "
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
        return Claim(token, row.spec_sha256, row.input_key, row.theory, self.settings.lease_seconds)

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
                        "SELECT a.input_key, a.spec_sha256, a.theory, a.tier, a.attempts, a.last_failure, b.profile "
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
                    "UPDATE actions SET log_sha256 = :log, last_failure = :failure "
                    "WHERE batch_id = :batch_id AND input_key = :input_key"
                ),
                {
                    "log": result.log_sha256,
                    "failure": result.failure,
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
                await conn.execute(
                    sa.text(
                        "UPDATE batches SET state = 'done' WHERE id = :id AND NOT EXISTS "
                        "(SELECT 1 FROM actions WHERE batch_id = :id AND state <> 'done')"
                    ),
                    {"id": batch_id},
                )
            elif result.failure == "memory" and action.tier == "standard":
                # The tier it failed on is the hint: future batches place this theory on the high tier.
                await self._record_peak(conn, package, theory, action.profile, self.settings.standard_tier_mb)
                await conn.execute(
                    sa.text("UPDATE actions SET tier = 'high' WHERE batch_id = :batch_id AND input_key = :input_key"),
                    {"batch_id": batch_id, "input_key": action.input_key},
                )
                await self._retry(conn, batch_id, action.input_key)
            elif action.attempts < self.settings.max_attempts and (
                result.failure in ("publish", "toolchain")
                or (result.failure == "disk" and action.last_failure != "disk")
            ):
                await self._retry(conn, batch_id, action.input_key)
            elif result.failure == "input-missing" and result.missing is not None and result.missing.kind == "theory":
                await self._requeue_missing(conn, batch_id, action.input_key, action.attempts, result.missing.key)
            elif result.failure == "input-missing":
                missing = f"{result.missing.kind} {result.missing.key}" if result.missing else "an input"
                await self._fail_batch(
                    conn, batch_id, action.input_key, f"resubmit: {action.theory} is missing {missing}"
                )
            else:
                await self._fail_batch(conn, batch_id, action.input_key, f"{action.theory}: {result.failure}")
        await self.release(batch_id)
        return True

    async def release(self, batch_id: UUID | None = None) -> None:
        """Make waiting actions whose parents are all done ready, once every parent's key answers ``HEAD /ac/``.

        A parent the cache doesn't hold is re-queued; a parent the cache can't be asked about leaves its children
        waiting for the next sweep. No transaction is open during the HEADs.
        """
        while True:
            async with self.engine.connect() as conn:
                rows = await conn.execute(
                    sa.text(
                        "SELECT a.batch_id, a.input_key, p.input_key AS parent, p.ac_key FROM actions a "
                        "JOIN batches b ON b.id = a.batch_id "
                        "LEFT JOIN edges e ON e.batch_id = a.batch_id AND e.input_key = a.input_key "
                        "LEFT JOIN actions p ON p.batch_id = e.batch_id AND p.input_key = e.parent_key "
                        "WHERE a.state = 'waiting' AND a.remaining_deps = 0 AND b.state = 'running' "
                        "AND (CAST(:batch_id AS uuid) IS NULL OR a.batch_id = :batch_id)"
                    ),
                    {"batch_id": batch_id},
                )
                candidates: defaultdict[tuple[UUID, str], list[tuple[str, str]]] = defaultdict(list)
                for row in rows:
                    parents = candidates[row.batch_id, row.input_key]
                    if row.parent is not None:
                        parents.append((row.parent, row.ac_key))
            present: dict[str, bool | None] = {}
            for parents in candidates.values():
                for _, ac_key in parents:
                    if ac_key not in present:
                        present[ac_key] = await self._in_cache(ac_key)
            requeued = False
            for (candidate_batch, input_key), parents in candidates.items():
                answers = [present[ac_key] for _, ac_key in parents]
                if all(answers):
                    async with self.engine.begin() as conn:
                        await conn.execute(
                            sa.text(
                                "UPDATE actions SET state = 'ready' WHERE batch_id = :batch_id "
                                "AND input_key = :input_key AND state = 'waiting' AND remaining_deps = 0"
                            ),
                            {"batch_id": candidate_batch, "input_key": input_key},
                        )
                for parent, ac_key in parents:
                    if present[ac_key] is False:
                        requeued |= await self._requeue_evicted(candidate_batch, parent)
            if not requeued:
                return

    async def expire_leases(self) -> None:
        """Send the actions of expired leases back to waiting, or fail them once they used up their attempts.

        ``sweep`` releases them afterwards.
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
                            "SELECT theory, state, attempts FROM actions "
                            "WHERE batch_id = :batch_id AND input_key = :input_key FOR UPDATE"
                        ),
                        {"batch_id": batch_id, "input_key": lease.input_key},
                    )
                ).one()
                if action.state != "running":
                    continue
                if action.attempts >= self.settings.max_attempts:
                    await self._fail_batch(
                        conn, batch_id, lease.input_key, f"{action.theory}: lease expired {action.attempts} times"
                    )
                else:
                    await self._retry(conn, batch_id, lease.input_key)

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
        """The unfinished actions and the burst worker target: the highest demand of the last
        ``scale_down_hold_s`` seconds, which the sweeps of every replica record, and of now."""
        async with self.engine.connect() as conn:
            desired = await conn.scalar(HELD_TARGET, self._held_target_params(self.clock()))
            rows = await conn.execute(
                sa.text(
                    "SELECT state, tier, count(*) FROM actions "
                    "WHERE state IN ('waiting', 'ready', 'running') GROUP BY state, tier"
                )
            )
            count = {(state, tier): n for state, tier, n in rows}
        counts = QueueCounts(
            waiting=count.get(("waiting", "standard"), 0) + count.get(("waiting", "high"), 0),
            ready_standard=count.get(("ready", "standard"), 0),
            ready_high=count.get(("ready", "high"), 0),
            running_standard=count.get(("running", "standard"), 0),
            running_high=count.get(("running", "high"), 0),
        )
        demand = burst_demand(counts, self.settings.warm_workers, self.settings.max_burst_workers)
        return QueueStatus(counts, max(desired, demand))

    async def sweep(self) -> None:
        """The periodic pass: expired leases, releases a failed HEAD left waiting, retention, then the burst
        worker target, which the scale command gets whenever it changes.

        The demand samples behind the target are in the database, so a restarted coordinator keeps holding it. A
        failing scale command is logged and retried on the next sweep; it never stops the sweep.
        """
        await self.expire_leases()
        await self.release()
        await self.delete_expired()
        counts = (await self.queue()).counts
        demand = burst_demand(counts, self.settings.warm_workers, self.settings.max_burst_workers)
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
        if self.settings.scale_cmd is None or desired == self.scaled_to:
            return
        try:
            await self._scale(self.settings.scale_cmd, desired)
        except (OSError, ScaleCommandError) as error:
            logger.warning("scaling to %d burst workers failed: %s", desired, error)
            return
        self.scaled_to = desired

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

    async def _in_cache(self, ac_key: str) -> bool | None:
        try:
            response = await self.cache.head(f"/ac/{ac_key}")
        except httpx.HTTPError:
            return None
        if response.status_code == 200:
            return True
        return False if response.status_code == 404 else None

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
                    conn, batch_id, parent, f"resubmit: {action.theory} is not in the cache after it built"
                )
                return False
            await self._requeue(conn, batch_id, parent)
            return True

    async def _requeue_missing(
        self, conn: AsyncConnection, batch_id: UUID, input_key: str, attempts: int, missing: str
    ) -> None:
        """Handle ``input-missing`` naming a theory: re-queue it if the batch builds it, else ask to resubmit.

        The missing theory may be a transitive dependency, which the batch has no edge for; the edge added here
        holds the action back until that theory is rebuilt and its key answers ``HEAD /ac/`` again.
        """
        theory = await conn.scalar(
            sa.text("SELECT theory FROM actions WHERE batch_id = :batch_id AND input_key = :input_key"),
            {"batch_id": batch_id, "input_key": missing},
        )
        if theory is None:
            await self._fail_batch(conn, batch_id, input_key, f"resubmit: theory {missing} is no longer in the cache")
            return
        if attempts >= self.settings.max_attempts:
            await self._fail_batch(
                conn, batch_id, input_key, f"{theory}: still missing after {attempts} attempts of a child"
            )
            return
        await conn.execute(
            sa.text(
                "INSERT INTO edges (batch_id, input_key, parent_key) VALUES (:batch_id, :input_key, :missing) "
                "ON CONFLICT DO NOTHING"
            ),
            {"batch_id": batch_id, "input_key": input_key, "missing": missing},
        )
        await self._set_state(conn, batch_id, input_key, "waiting")
        await self._requeue(conn, batch_id, missing)

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
        """Send a failed or expired action back to waiting, so ``release`` checks its parents' keys again.

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

    async def _fail_batch(self, conn: AsyncConnection, batch_id: UUID, input_key: str, failure: str) -> None:
        """Fail ``input_key`` finally and with it the batch; its other unfinished actions are cancelled."""
        await conn.execute(
            sa.text("UPDATE batches SET state = 'failed', failure = :failure WHERE id = :id"),
            {"id": batch_id, "failure": failure},
        )
        await self._set_state(conn, batch_id, input_key, "failed")
        await self._stop_actions(conn, batch_id)

    async def _stop_actions(self, conn: AsyncConnection, batch_id: UUID) -> None:
        await conn.execute(
            sa.text(
                "UPDATE actions SET state = 'cancelled' "
                "WHERE batch_id = :id AND state IN ('waiting', 'ready', 'running')"
            ),
            {"id": batch_id},
        )
        await conn.execute(sa.text("DELETE FROM leases WHERE batch_id = :id"), {"id": batch_id})

    async def _record_peak(self, conn: AsyncConnection, package: str, theory: str, profile: str, peak: int) -> None:
        await conn.execute(
            sa.text(
                "INSERT INTO peak_hints (package, theory, profile, peak_rss_mb) "
                "VALUES (:package, :theory, :profile, :peak) "
                "ON CONFLICT (package, theory, profile) DO UPDATE SET peak_rss_mb = :peak, updated_at = now()"
            ),
            {"package": package, "theory": theory, "profile": profile, "peak": peak},
        )
