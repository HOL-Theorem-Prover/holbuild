import asyncio
import hashlib
import os
from collections.abc import AsyncIterator
from pathlib import Path

import httpx
import pytest_asyncio
import sqlalchemy as sa
from alembic.config import Config as AlembicConfig
from pydantic import SecretStr
from sqlalchemy.engine import URL, make_url
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from alembic import command
from remote_exec.app import create_app
from remote_exec.coordinator import Coordinator, Settings

REMOTE_EXEC_DIR = Path(__file__).resolve().parents[1]
CLIENT_TOKEN = "client-secret"
WORKER_TOKEN = "worker-secret"


def entry_blob(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()


class FakeCache:
    """bazel-remote holding holbuild entries: ``GET /ac/<key>`` answers 503 for ``broken``, an entry listing the
    blob ``entry_blob(key)`` for ``keys``, and 404 otherwise. It takes no other request. ``asked`` lists the keys of
    the entries asked for."""

    def __init__(self) -> None:
        self.keys: set[str] = set()
        self.broken: set[str] = set()
        self.asked: list[str] = []
        self.hold: asyncio.Event | None = None  # while set to an unset event, entry requests wait for it
        self.hold_only: set[str] | None = None  # if set, only the requests for these entries wait
        self.held = 0  # how many entry requests are waiting for it now

    async def handle_async(self, request: httpx.Request) -> httpx.Response:
        key = request.url.path.removeprefix("/ac/")
        if self.hold is not None and request.url.path.startswith("/ac/") and key in (self.hold_only or {key}):
            self.held += 1
            try:
                await self.hold.wait()
            finally:
                self.held -= 1
        return self.handle(request)

    def handle(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        assert request.method == "GET" and path.startswith("/ac/")
        key = path.removeprefix("/ac/")
        self.asked.append(key)
        if key in self.broken:
            return httpx.Response(503)
        if key not in self.keys:
            return httpx.Response(404)
        blob = entry_blob(key)
        return httpx.Response(
            200,
            text=f"holbuild-remote-cache-action-v2\nmanifest-sha256 0\nmanifest-size 0\nblob {blob} 3\n"
            f"manifest-text-v1\nblob dat {blob}\n",
        )


def upgrade(url: URL) -> None:
    config = AlembicConfig(str(REMOTE_EXEC_DIR / "alembic.ini"))
    config.set_main_option("sqlalchemy.url", url.render_as_string(hide_password=False))
    command.upgrade(config, "head")


@pytest_asyncio.fixture(scope="session")
async def remote_exec_engine() -> AsyncIterator[AsyncEngine]:
    # A Postgres role that may create databases, e.g. postgresql+asyncpg://postgres:postgres@localhost/postgres.
    admin_url = make_url(os.environ["REMOTE_EXEC_TEST_DATABASE_URL"])
    database = f"remote_exec_test_{os.environ.get('PYTEST_XDIST_WORKER', 'main')}"
    test_url = admin_url.set(database=database)
    admin = create_async_engine(admin_url, isolation_level="AUTOCOMMIT")
    async with admin.connect() as connection:
        await connection.execute(sa.text(f'drop database if exists "{database}" with (force)'))
        await connection.execute(sa.text(f'create database "{database}"'))
    # alembic's env drives migrations through asyncio.run, so it runs on a thread without a loop.
    await asyncio.to_thread(upgrade, test_url)
    engine = create_async_engine(test_url)
    try:
        yield engine
    finally:
        await engine.dispose()
        async with admin.connect() as connection:
            await connection.execute(sa.text(f'drop database if exists "{database}" with (force)'))
        await admin.dispose()


@pytest_asyncio.fixture
async def cache() -> FakeCache:
    return FakeCache()


@pytest_asyncio.fixture
async def coordinator(remote_exec_engine: AsyncEngine, cache: FakeCache) -> AsyncIterator[Coordinator]:
    async with remote_exec_engine.begin() as connection:
        await connection.execute(sa.text("TRUNCATE batches, actions, edges, leases, peak_hints, burst_demand"))
    settings = Settings(
        database_url="unused",
        client_token=SecretStr(CLIENT_TOKEN),
        worker_token=SecretStr(WORKER_TOKEN),
        cache_url="http://cache.test",
        lease_seconds=60,
        max_attempts=3,
        standard_tier_mb=1000,
        events_poll_seconds=0.01,
        events_fallback_seconds=0.01,
    )
    async with httpx.AsyncClient(base_url=settings.cache_url, transport=httpx.MockTransport(cache.handle_async)) as client:
        coordinator = Coordinator(remote_exec_engine, client, settings)
        yield coordinator
        await coordinator.released()


class Settled(httpx.ASGITransport):
    """Handles each request once the releases already asked for have run, and answers it once the ones it asked
    for have too, so a test sees the effect of every release before its next request."""

    def __init__(self, app: object, coordinator: Coordinator) -> None:
        super().__init__(app=app)
        self.coordinator = coordinator

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        await self.coordinator.released()
        response = await super().handle_async_request(request)
        await self.coordinator.released()
        return response


@pytest_asyncio.fixture
async def http(coordinator: Coordinator) -> AsyncIterator[httpx.AsyncClient]:
    app = create_app(coordinator, coordinator.settings)
    async with httpx.AsyncClient(transport=Settled(app, coordinator), base_url="http://coordinator.test") as client:
        yield client
