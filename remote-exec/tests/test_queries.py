"""Every SQL statement of the coordinator, run against the database of a busy fleet just as a large batch arrives,
with a bound on the rows each handles.

A batch inserted since the database last analyzed its tables is in no statistics, so the planner takes it for about
one row and may plan a join as nested loops that reread the batch once per row: seconds per statement on a batch of
thousands of actions. The fleet's history is analyzed here, the arriving batch isn't, and each statement runs under
the default planner and with nested loops forced, the plan such an estimate leads to on a larger history. Rows
handled, unlike time, are the same on every run on the same data.

To add a statement to the coordinator, add it to STATEMENTS with parameters that make it do real work on the fleet,
and a budget of about twice the rows it handles; test_every_statement_has_a_budget fails until then.
"""

import ast
import asyncio
import hashlib
import json
import os
import random
from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from uuid import UUID, uuid4

import pytest
import pytest_asyncio
import sqlalchemy as sa
from conftest import upgrade
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from remote_exec import coordinator as coordinator_module

# The shape of a gate batch: its actions, the first ROOTS of which have no parents, and each later one up to FAN
# parents among those before it (about 85,000 edges).
ACTIONS, ROOTS, FAN = 5000, 1500, 48


def key(i: int, build: str = "") -> str:
    return hashlib.sha256(f"{build}k{i}".encode()).hexdigest()


def theory(i: int) -> str:
    return f"pkg:t{i}"


def dag() -> list[list[int]]:
    """Each action's parents. The first 20 after the roots have theirs among the first 300 roots only."""
    rng = random.Random(0)
    return [[] for _ in range(ROOTS)] + [
        rng.sample(range(300 if i < ROOTS + 20 else i), i % FAN + 1) for i in range(ROOTS, ACTIONS)
    ]


@dataclass
class Arrival:
    """A batch's actions by state: ``done`` and ``running`` (not ahead) are prefixes of the roots, or of all actions
    for ``done``; then up to ``gen1`` and ``gen2`` waiting actions are claimed ahead, one and two generations below
    the running ones. With ``release``, actions with no parent left to wait for are ready, else only the roots."""

    state: list[str]
    ahead: list[str]
    remaining: list[int]

    @classmethod
    def of(cls, parents: list[list[int]], *, done: int, running: int, gen1: int, gen2: int, release: bool) -> "Arrival":
        state = ["done" if i < done else "waiting" for i in range(ACTIONS)]
        remaining = [sum(state[p] != "done" for p in ps) for ps in parents]
        for i in range(done, ACTIONS):
            if remaining[i] == 0 and (release or i < ROOTS):
                state[i] = "ready"
        for i in [i for i in range(ACTIONS) if state[i] == "ready"][:running]:
            state[i] = "running"
        ahead = ["no"] * ACTIONS
        for generation, count in (("gen1", gen1), ("gen2", gen2)):
            claimable = [
                i
                for i in range(ACTIONS)
                if state[i] == "waiting"
                and remaining[i] > 0
                and all(state[p] in ("done", "running") for p in parents[i])
                and (generation == "gen1") == all(ahead[p] == "no" for p in parents[i])
            ]
            for i in claimable[:count]:
                state[i], ahead[i] = "running", "ahead"
        return cls(state, ahead, remaining)

    def keys(self, state: str, ahead: str = "no") -> list[str]:
        return [key(i) for i in range(ACTIONS) if self.state[i] == state and self.ahead[i] == ahead]


@dataclass
class Fleet:
    """The seeded database: ``fresh`` and ``steady`` were inserted after the last ANALYZE, ``old`` is a
    finished batch past retention. ``token`` is a live lease of ``fresh``, ``expired`` an expired one of
    ``steady``. ``since`` numbers the transaction that changed a few of ``fresh``'s actions last."""

    engine: AsyncEngine
    parents: list[list[int]]
    fresh: UUID
    steady: UUID
    old: UUID
    arrival: Arrival
    steady_arrival: Arrival
    token: UUID
    expired: UUID
    since: int

    def parent_of_ahead(self) -> str:
        """A running action of ``fresh`` with children claimed ahead."""
        child = self.arrival.ahead.index("ahead")
        return key(next(p for p in self.parents[child] if self.arrival.state[p] == "running"))

    def ahead_candidates(self) -> list[str]:
        """Waiting actions of ``fresh`` whose unfinished parents all run, which may be claimed ahead."""
        state, parents = self.arrival.state, self.parents
        return [
            key(i)
            for i in range(ROOTS, ACTIONS)
            if state[i] == "waiting"
            and any(state[p] == "running" for p in parents[i])
            and all(state[p] in ("done", "running") for p in parents[i])
        ][:32]


async def insert(
    connection: Any, batch_id: UUID, parents: list[list[int]], arrival: Arrival, build: str = "", **batch: object
) -> None:
    await connection.execute(
        sa.text(
            "INSERT INTO batches (id, state, profile, priority, ahead_cap) "
            "VALUES (:id, :state, 'default', :priority, :ahead_cap)"
        ),
        {"id": batch_id, "state": "running", "priority": 0, "ahead_cap": None, **batch},
    )
    await connection.execute(
        sa.text(
            "INSERT INTO actions (batch_id, input_key, ac_key, spec_sha256, theory, remaining_deps, state, tier, "
            "critical_depth, descendant_count, class, ahead, attempts, last_claimed_at) "
            "SELECT :id, k, 'ac' || k, 's', t, r, s, 'standard', :n - i, :n - i, "
            "CASE WHEN i % 50 = 49 THEN 'run' ELSE 'build' END, a, CASE WHEN s IN ('done', 'running') THEN 1 ELSE 0 END, "
            "CASE WHEN s IN ('done', 'running') THEN now() END "
            "FROM unnest(CAST(:keys AS text[]), CAST(:theories AS text[]), CAST(:remaining AS integer[]), "
            "CAST(:states AS text[]), CAST(:ahead AS text[])) WITH ORDINALITY u (k, t, r, s, a, i)"
        ),
        {
            "id": batch_id,
            "n": len(arrival.state),
            "keys": [key(i, build) for i in range(len(arrival.state))],
            "theories": [theory(i) for i in range(len(arrival.state))],
            "remaining": [r if s != "done" else 0 for r, s in zip(arrival.remaining, arrival.state, strict=True)],
            "states": arrival.state,
            "ahead": arrival.ahead,
        },
    )
    await connection.execute(
        sa.text(
            "INSERT INTO edges (batch_id, input_key, parent_key) "
            "SELECT :id, c, p FROM unnest(CAST(:children AS text[]), CAST(:parents AS text[])) u (c, p)"
        ),
        {
            "id": batch_id,
            "children": [key(i, build) for i, ps in enumerate(parents) for _ in ps],
            "parents": [key(p, build) for ps in parents for p in ps],
        },
    )
    await connection.execute(
        sa.text(
            "INSERT INTO leases (attempt_token, batch_id, input_key, worker, expires_at) "
            "SELECT gen_random_uuid(), :id, k, 'w', now() + interval '1 hour' FROM unnest(CAST(:keys AS text[])) k"
        ),
        {"id": batch_id, "keys": [key(i, build) for i, state in enumerate(arrival.state) if state == "running"]},
    )


async def seed(engine: AsyncEngine) -> Fleet:
    """Finished builds of other sources, analyzed while nothing ran; since then a batch has been running, and a gate batch arrives
    with 400 of its actions running and some claimed ahead; a last transaction changes a few of its actions.

    With no running or waiting actions in the statistics, the planner takes those of the new batches for a handful,
    as it did when a gate batch stalled the fleet's claims (holbuild#641)."""
    parents = dag()
    fresh, steady, old = uuid4(), uuid4(), uuid4()
    waiting = Arrival.of(parents, done=0, running=0, gen1=0, gen2=0, release=True)
    steady_arrival = Arrival.of(parents, done=3000, running=100, gen1=0, gen2=0, release=True)
    arrival = Arrival.of(parents, done=300, running=400, gen1=8, gen2=4, release=False)
    async with engine.begin() as connection:
        # The fresh batch stays out of the statistics, and the plans the same on every run.
        for table in ("batches", "actions", "edges", "leases"):
            await connection.execute(sa.text(f"ALTER TABLE {table} SET (autovacuum_enabled = false)"))
        # Other sources, so other input keys. Their actions went through the unfinished states, which left pages
        # in the partial indexes. Without either, the planner doesn't take the plan that stalled the fleet's claims.
        for build in ("a", "b"):
            history = uuid4()
            await insert(connection, history, parents, waiting, build, priority=1)
            await connection.execute(sa.text("UPDATE actions SET state = 'done' WHERE batch_id = :id"), {"id": history})
            await connection.execute(sa.text("UPDATE batches SET state = 'done' WHERE id = :id"), {"id": history})
        await insert(connection, old, [[]] * 10, Arrival(["done"] * 10, ["no"] * 10, [0] * 10), state="done")
        await connection.execute(
            sa.text("UPDATE batches SET created_at = now() - interval '30 days' WHERE id = :id"), {"id": old}
        )
        await connection.execute(
            sa.text(
                "INSERT INTO peak_hints (package, theory, profile, peak_rss_mb, updated_at) "
                "SELECT 'pkg', 't' || i, 'default', 1000, now() - make_interval(days => i % 40) "
                "FROM generate_series(0, :n - 1) i"
            ),
            {"n": ACTIONS},
        )
        await connection.execute(
            sa.text(
                "INSERT INTO burst_demand (at, workers) "
                "SELECT now() - make_interval(secs => i), i % 100 FROM generate_series(0, 3599) i"
            )
        )
    async with engine.connect() as connection:
        autocommit = await connection.execution_options(isolation_level="AUTOCOMMIT")
        # A sample of every row, so that the plans are the same on every run.
        await autocommit.execute(sa.text("SET default_statistics_target = 1000"))
        await autocommit.execute(sa.text("VACUUM ANALYZE"))
    async with engine.begin() as connection:
        await insert(connection, steady, parents, steady_arrival)
        expired = await connection.scalar(
            sa.text(
                "UPDATE leases SET expires_at = now() - interval '1 minute' WHERE attempt_token = ("
                "SELECT attempt_token FROM leases WHERE batch_id = :id ORDER BY input_key LIMIT 1) "
                "RETURNING attempt_token"
            ),
            {"id": steady},
        )
        await insert(connection, fresh, parents, arrival, priority=2, ahead_cap=64)
        token = await connection.scalar(
            sa.text("SELECT attempt_token FROM leases WHERE batch_id = :id AND input_key = :key"),
            {"id": fresh, "key": arrival.keys("running")[0]},
        )
    async with engine.begin() as connection:
        since = int(await connection.scalar(sa.text("SELECT CAST(pg_current_xact_id() AS text)")))
        await connection.execute(
            sa.text("UPDATE actions SET log_sha256 = 'log' WHERE batch_id = :id AND input_key = ANY(:keys)"),
            {"id": fresh, "keys": arrival.keys("ready")[:20]},
        )
    return Fleet(engine, parents, fresh, steady, old, arrival, steady_arrival, token, expired, since)


@pytest_asyncio.fixture(scope="session")
async def fleet() -> AsyncIterator[Fleet]:
    admin_url = make_url(os.environ["REMOTE_EXEC_TEST_DATABASE_URL"])
    database = f"remote_exec_fleet_{os.environ.get('PYTEST_XDIST_WORKER', 'main')}"
    admin = create_async_engine(admin_url, isolation_level="AUTOCOMMIT")
    async with admin.connect() as connection:
        await connection.execute(sa.text(f'drop database if exists "{database}" with (force)'))
        await connection.execute(sa.text(f'create database "{database}"'))
    test_url = admin_url.set(database=database)
    await asyncio.to_thread(upgrade, test_url)
    engine = create_async_engine(test_url)
    try:
        yield await seed(engine)
    finally:
        await engine.dispose()
        async with admin.connect() as connection:
            await connection.execute(sa.text(f'drop database if exists "{database}" with (force)'))
        await admin.dispose()


def module_statements() -> dict[str, sa.TextClause]:
    return {name: value for name, value in vars(coordinator_module).items() if isinstance(value, sa.TextClause)}


def inline_statements() -> set[str]:
    """The text of every ``sa.text`` call in coordinator.py but the module statements', whitespace collapsed. A call
    whose text isn't a literal fails, as does a module-level assignment of one that isn't a module statement: their
    statements can't be matched to a budget."""
    tree = ast.parse(Path(coordinator_module.__file__).read_text())
    texts = set()
    module = module_statements()
    for top in tree.body:
        calls = [
            node
            for node in ast.walk(top)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "text"
        ]
        if isinstance(top, ast.Assign) and len(top.targets) == 1 and isinstance(top.targets[0], ast.Name):
            assert not calls or top.targets[0].id in module, f"coordinator.py:{top.lineno}: not a module statement"
            continue
        for node in calls:
            (argument,) = node.args
            assert isinstance(argument, ast.Constant), (
                f"coordinator.py:{node.lineno}: sa.text of a computed string; make it a module-level statement"
            )
            texts.add(" ".join(argument.value.split()))
    return texts


def matching(fragment: str, texts: set[str]) -> list[str]:
    """The statement that is ``fragment``, else those that start with it."""
    return [fragment] if fragment in texts else [text for text in texts if text.startswith(fragment)]


@dataclass(frozen=True)
class Statement:
    """A statement of the coordinator, a module-level one or the one an inline ``sa.text`` whose text is or starts
    with ``statement``; parameters with which it does real work on the fleet; and the most rows it may handle."""

    statement: sa.TextClause | str
    parameters: Callable[[Fleet], dict[str, object]]
    budget: int

    @property
    def name(self) -> str:
        if isinstance(self.statement, str):
            return self.statement
        return next(name for name, value in module_statements().items() if value is self.statement)

    def text(self) -> str:
        if isinstance(self.statement, sa.TextClause):
            return self.statement.text
        (text,) = matching(self.statement, inline_statements())
        return text


def now() -> datetime:
    return datetime.now(UTC)


def lease(fleet: Fleet) -> dict[str, object]:
    return {"batch_id": fleet.fresh, "input_key": fleet.arrival.keys("running")[0]}


cm = coordinator_module
STATEMENTS = [
    Statement(cm.REFRESH_KEYS, lambda f: {"batch_id": f.fresh, "keys": f.arrival.keys("waiting")[:50]}, 15_000),
    Statement(cm.REFRESH_CHILDREN, lambda f: {"batch_id": f.fresh, "keys": f.arrival.keys("running")[:1]}, 14_000),
    Statement(cm.RELEASABLE_ALL, lambda f: {}, 13_000),
    Statement(cm.RELEASABLE_BATCH, lambda f: {"batch_id": f.fresh}, 13_000),
    Statement(cm.CHANGED_ACTIONS, lambda f: {"batch_id": f.fresh, "since": str(f.since)}, 100),
    Statement(
        cm.CLAIM_CANDIDATES, lambda f: {"tiers": ["standard"], "classes": ["build", "run"], "run_slots": 30}, 16_000
    ),
    Statement(
        cm.CLAIM_ACTION, lambda f: {"batch_id": f.fresh, "class": "build", "tier": "standard", "taken": []}, 2_900
    ),
    Statement(cm.LOCK_KEY, lambda f: {"key": f.arrival.keys("ready")[0]}, 100),
    Statement(cm.KEY_LEASED, lambda f: {"key": f.arrival.keys("ready")[0]}, 2_100),
    Statement(cm.AHEAD_CANDIDATES, lambda f: {"depth": 2}, 120_000),
    Statement(
        cm.CLAIM_AHEAD_ACTION,
        lambda f: {"batch_id": f.fresh, "keys": f.ahead_candidates(), "tier": "standard", "depth": 2, "taken": []},
        22_000,
    ),
    Statement(
        cm.AHEAD_PARENTS,
        lambda f: {"batch_id": f.fresh, "keys": f.arrival.keys("running", "ahead")[-1:], "depth": 2},
        11_000,
    ),
    Statement(cm.COUNT_WAITING_AHEAD, lambda f: {"batch_id": f.fresh}, 1_100),
    Statement(cm.REFRESH_AHEAD_CHILDREN, lambda f: {"batch_id": f.fresh, "key": f.parent_of_ahead()}, 1_100),
    Statement(cm.REVOKE_AHEAD, lambda f: {"batch_id": f.fresh, "keys": [f.parent_of_ahead()]}, 12_000),
    Statement(cm.PEERS, lambda f: {"batch_id": f.fresh, "input_key": f.steady_arrival.keys("waiting")[0]}, 13_000),
    Statement(cm.FINISH_IF_DONE, lambda f: {"id": f.fresh}, 14_000),
    Statement(cm.COUNT_UNFINISHED, lambda f: {}, 93_000),
    Statement(cm.COUNT_ACTIVE, lambda f: {}, 18_000),
    Statement(cm.HELD_TARGET, lambda f: {"now": now(), "hold": 900.0, "cap": 100}, 1_800),
    # submit
    Statement(
        "WITH locked AS (SELECT package, theory, profile FROM peak_hints WHERE profile = :profile",
        lambda f: {"profile": "default", "packages": ["pkg"] * 100, "names": [f"t{i}" for i in range(100)]},
        22_000,
    ),
    Statement(
        "INSERT INTO batches (id, state, profile, max_heap_mb, fail_fast, priority, ahead_cap)",
        lambda f: {
            "id": uuid4(),
            "state": "running",
            "profile": "default",
            "max_heap_mb": None,
            "fail_fast": False,
            "priority": 2,
            "ahead_cap": 64,
        },
        100,
    ),
    Statement(
        "INSERT INTO actions (batch_id, input_key, ac_key, spec_sha256, theory, remaining_deps, state, tier,",
        lambda f: {
            "batch_id": f.fresh,
            "input_key": "new",
            "ac_key": "ac",
            "spec": "s",
            "theory": "pkg:new",
            "remaining": 0,
            "tier": "standard",
            "depth": 1,
            "descendants": 1,
            "class": "build",
        },
        100,
    ),
    Statement(
        "INSERT INTO edges (batch_id, input_key, parent_key) VALUES (:batch_id, :child, :parent)",
        lambda f: {"batch_id": f.fresh, "child": key(ACTIONS - 1), "parent": key(ACTIONS - 2)},
        100,
    ),
    # changes
    Statement("SELECT state, failure, CAST(pg_snapshot_xmin", lambda f: {"id": f.fresh}, 100),
    # claims of run actions
    Statement(
        "SELECT EXISTS (SELECT 1 FROM actions WHERE state = 'ready' AND class = 'run'",
        lambda f: {"tiers": ["standard"], "run_slots": 30},
        100,
    ),
    Statement("SELECT pg_advisory_xact_lock(1752132706, 1)", lambda f: {}, 100),
    Statement(
        "SELECT EXISTS (SELECT 1 FROM actions WHERE state = 'ready' AND class = 'build'",
        lambda f: {"tiers": ["standard"]},
        1_100,
    ),
    # leases
    Statement(
        "UPDATE actions SET state = 'running', attempts = attempts + 1",
        lambda f: {"ahead": False, "batch_id": f.fresh, "input_key": f.arrival.keys("ready")[0]},
        10_000,
    ),
    Statement(
        "INSERT INTO leases (attempt_token, batch_id, input_key, worker, expires_at)",
        lambda f: {
            "token": uuid4(),
            "batch_id": f.fresh,
            "input_key": f.arrival.keys("ready")[0],
            "worker": "w",
            "lease": 120,
        },
        100,
    ),
    Statement("SELECT ahead_cap, max_heap_mb FROM batches", lambda f: {"id": f.fresh}, 100),
    Statement(
        "UPDATE actions SET state = 'done', log_sha256 = :log",
        lambda f: {"log": "log", "batch_id": f.steady, "input_key": f.steady_arrival.keys("ready")[0]},
        11_000,
    ),
    Statement("UPDATE leases SET expires_at", lambda f: {"lease": 120, "token": f.token}, 100),
    # complete
    Statement("SELECT batch_id FROM leases WHERE attempt_token = :token", lambda f: {"token": f.token}, 100),
    Statement(
        "DELETE FROM leases WHERE attempt_token = :token AND expires_at > now()", lambda f: {"token": f.token}, 100
    ),
    Statement("SELECT a.input_key, a.spec_sha256, a.theory, a.tier, a.attempts, a.interruptions", lease, 11_000),
    Statement(
        "UPDATE actions SET log_sha256 = :log, last_failure = :failure",
        lambda f: {**lease(f), "log": "log", "failure": None, "detail": None, "timings": json.dumps({"total": 1.0})},
        10_000,
    ),
    Statement("UPDATE actions SET tier = 'high'", lease, 10_000),
    Statement("UPDATE actions SET attempts = attempts - 1, ahead = 'abandoned'", lease, 10_000),
    Statement("UPDATE actions SET attempts = attempts - 1, interruptions = interruptions + 1", lease, 10_000),
    # releases
    Statement(
        "UPDATE actions SET state = 'ready' WHERE batch_id = :batch_id",
        lambda f: {"batch_id": f.fresh, "keys": f.arrival.keys("waiting")},
        11_000,
    ),
    # expiry
    Statement("SELECT attempt_token, batch_id FROM leases WHERE expires_at <= now()", lambda f: {}, 1_100),
    Statement(
        "DELETE FROM leases WHERE attempt_token = :token AND expires_at <= now()", lambda f: {"token": f.expired}, 100
    ),
    Statement("SELECT a.input_key, a.spec_sha256, a.theory, a.state, a.attempts", lease, 11_000),
    Statement("UPDATE actions SET last_failure = CASE", lambda f: {**lease(f), "failure": "timeout"}, 10_000),
    # sweeps
    Statement("SELECT id FROM batches WHERE state = 'running' AND created_at", lambda f: {"secs": 3600}, 100),
    Statement("DELETE FROM batches WHERE id IN", lambda f: {"hours": 168}, 100),
    Statement(
        "WITH locked AS (SELECT package, theory, profile FROM peak_hints WHERE updated_at",
        lambda f: {"days": 30},
        33_000,
    ),
    Statement("DELETE FROM burst_demand", lambda f: {"now": now(), "hold": 900.0}, 7_200),
    Statement("INSERT INTO burst_demand", lambda f: {"now": now(), "workers": 10}, 100),
    # requeues, skips and the end of a batch
    Statement("SELECT state, ahead_cap FROM batches", lambda f: {"id": f.fresh}, 100),
    Statement("SELECT theory, state, attempts FROM actions", lease, 11_000),
    Statement("SELECT theory FROM actions WHERE batch_id = :batch_id AND input_key = :input_key", lease, 10_000),
    Statement(
        "SELECT state FROM actions WHERE batch_id = :batch_id AND input_key = :key",
        lambda f: {"batch_id": f.fresh, "key": key(0)},
        10_000,
    ),
    Statement(
        "SELECT input_key, parent_key FROM edges WHERE batch_id = :batch_id", lambda f: {"batch_id": f.fresh}, 180_000
    ),
    Statement(
        "SELECT input_key, critical_depth, descendant_count FROM actions", lambda f: {"batch_id": f.fresh}, 10_000
    ),
    Statement(
        "INSERT INTO edges (batch_id, input_key, parent_key) VALUES (:batch_id, :child, :parent) ON CONFLICT",
        lambda f: {"batch_id": f.fresh, "child": key(ACTIONS - 1), "parent": key(0)},
        100,
    ),
    Statement(
        "UPDATE actions SET critical_depth = :depth", lambda f: {**lease(f), "depth": 2, "descendants": 2}, 10_000
    ),
    Statement(
        "UPDATE actions SET state = 'waiting' WHERE batch_id = :batch_id",
        lambda f: {"batch_id": f.fresh, "input_key": key(0)},
        10_000,
    ),
    Statement(
        "UPDATE actions SET ahead = 'no'",
        lambda f: {"batch_id": f.fresh, "input_key": f.arrival.keys("running", "ahead")[0]},
        10_000,
    ),
    Statement("SELECT state FROM batches WHERE id = :id FOR UPDATE", lambda f: {"id": f.fresh}, 100),
    Statement("UPDATE actions SET state = :state", lambda f: {**lease(f), "state": "failed"}, 10_000),
    Statement("SELECT fail_fast FROM batches", lambda f: {"id": f.fresh}, 100),
    Statement(
        cm.SKIP_DESCENDANTS,
        lambda f: {"id": f.fresh, "key": f.arrival.keys("ready")[0], "reason": "dependency-failed"},
        230_000,
    ),
    Statement(
        "UPDATE batches SET state = :state, failure = :failure",
        lambda f: {"id": f.fresh, "state": "failed", "failure": "x"},
        100,
    ),
    Statement("UPDATE actions SET state = 'cancelled' WHERE batch_id = :id", lambda f: {"id": f.fresh}, 10_000),
    Statement("DELETE FROM leases WHERE batch_id = :id", lambda f: {"id": f.fresh}, 1_700),
    Statement(
        "INSERT INTO peak_hints", lambda f: {"package": "pkg", "theory": "t0", "profile": "default", "peak": 2000}, 100
    ),
]


def handled(plan: dict[str, Any]) -> float:
    """Rows a plan node and those below it produced or read and dropped, over all their runs."""
    rows = plan["Actual Rows"] + sum(
        plan.get(removed, 0)
        for removed in ("Rows Removed by Filter", "Rows Removed by Join Filter", "Rows Removed by Index Recheck")
    )
    return rows * plan["Actual Loops"] + sum(handled(child) for child in plan.get("Plans", []))


async def rows_handled(fleet: Fleet, statement: Statement, *, nested_loops: bool) -> int:
    """Rows ``statement`` handles on ``fleet``, in a transaction rolled back after it."""
    async with fleet.engine.begin() as connection:
        await connection.execute(sa.text("SET LOCAL statement_timeout = '10s'"))
        if nested_loops:
            await connection.execute(sa.text("SET LOCAL enable_hashjoin = off"))
            await connection.execute(sa.text("SET LOCAL enable_mergejoin = off"))
        plan = await connection.scalar(
            sa.text(f"EXPLAIN (ANALYZE, FORMAT JSON) {statement.text()}"), statement.parameters(fleet)
        )
        await connection.rollback()
    return round(handled(plan[0]["Plan"]))


def test_every_statement_has_a_budget() -> None:
    """Each statement of the coordinator is in STATEMENTS once, and each entry of STATEMENTS is one statement."""
    module, inline = module_statements(), inline_statements()
    covered = {s.statement for s in STATEMENTS if isinstance(s.statement, sa.TextClause)}
    assert [name for name, value in module.items() if value not in covered] == [], "module statements with no budget"
    fragments = [s.statement for s in STATEMENTS if isinstance(s.statement, str)]
    matches = {fragment: matching(fragment, inline) for fragment in fragments}
    assert {fragment: texts for fragment, texts in matches.items() if len(texts) != 1} == {}, "ambiguous fragments"
    matched = [texts[0] for texts in matches.values()]
    assert sorted(inline - set(matched)) == [], "inline statements with no budget"
    assert len(matched) == len(set(matched)), "inline statements with two budgets"


@pytest.mark.parametrize("nested_loops", [False, True], ids=["default", "nested-loops"])
@pytest.mark.parametrize("statement", STATEMENTS, ids=lambda s: s.name[:60])
async def test_each_statement_handles_few_rows_of_a_busy_fleet(
    fleet: Fleet, statement: Statement, nested_loops: bool
) -> None:
    rows = await rows_handled(fleet, statement, nested_loops=nested_loops)
    assert 0 < rows <= statement.budget, f"{statement.name}: {rows} rows handled, budget {statement.budget}"
