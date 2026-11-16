"""The additive action columns must be usable by, and removable for, the runtime that predates them."""

import asyncio

import httpx
import sqlalchemy as sa
from alembic import command
from alembic.config import Config
from sqlalchemy.ext.asyncio import AsyncEngine

from conftest import REMOTE_EXEC_DIR, FakeCache
from test_coordinator import batch, build, submit

NEW_COLUMNS = {"finished_at", "worker"}


def migrate(engine: AsyncEngine, revision: str, *, downgrade: bool = False) -> None:
    config = Config(str(REMOTE_EXEC_DIR / "alembic.ini"))
    config.set_main_option("sqlalchemy.url", engine.url.render_as_string(hide_password=False))
    (command.downgrade if downgrade else command.upgrade)(config, revision)


async def actions_columns(engine: AsyncEngine) -> set[str]:
    async with engine.connect() as connection:
        return set(await connection.scalars(sa.text(
            "SELECT column_name FROM information_schema.columns WHERE table_name = 'actions'"
        )))


async def version(engine: AsyncEngine) -> str:
    async with engine.connect() as connection:
        return await connection.scalar(sa.text("SELECT version_num FROM remote_exec_alembic_version"))


async def test_action_column_baseline_preserves_existing_actions_and_downgrades(
    remote_exec_engine: AsyncEngine, http: httpx.AsyncClient, cache: FakeCache,
) -> None:
    await asyncio.to_thread(migrate, remote_exec_engine, "0015", downgrade=True)
    try:
        batch_id = await submit(http, ["a"])
        await asyncio.to_thread(migrate, remote_exec_engine, "head")
        await asyncio.to_thread(migrate, remote_exec_engine, "head")
        assert await version(remote_exec_engine) == "0016"
        assert NEW_COLUMNS <= await actions_columns(remote_exec_engine)
        async with remote_exec_engine.connect() as connection:
            row = (await connection.execute(sa.text("SELECT finished_at, worker FROM actions"))).one()
        assert tuple(row) == (None, None)

        # The runtime never reads the new columns, but still claims and completes rows that predate them.
        await build(http, cache, "a")
        assert (await batch(http, batch_id))["state"] == "done"
        await asyncio.to_thread(migrate, remote_exec_engine, "0015", downgrade=True)
        assert await version(remote_exec_engine) == "0015"
        assert not NEW_COLUMNS & await actions_columns(remote_exec_engine)
        assert (await batch(http, batch_id))["state"] == "done"
    finally:
        await asyncio.to_thread(migrate, remote_exec_engine, "head")
