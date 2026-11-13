"""The interrupted-output schema must be usable by its rollback baseline."""

import asyncio

import httpx
import sqlalchemy as sa
from alembic import command
from alembic.config import Config
from sqlalchemy.ext.asyncio import AsyncEngine

from conftest import REMOTE_EXEC_DIR, FakeCache
from test_coordinator import batch, build, submit


def migrate(engine: AsyncEngine, revision: str, *, downgrade: bool = False) -> None:
    config = Config(str(REMOTE_EXEC_DIR / "alembic.ini"))
    config.set_main_option("sqlalchemy.url", engine.url.render_as_string(hide_password=False))
    (command.downgrade if downgrade else command.upgrade)(config, revision)


async def test_interrupted_output_schema_preserves_existing_actions_and_runtime(
    remote_exec_engine: AsyncEngine, http: httpx.AsyncClient, cache: FakeCache,
) -> None:
    await asyncio.to_thread(migrate, remote_exec_engine, "0015", downgrade=True)
    try:
        batch_id = await submit(http, ["a"])
        await asyncio.to_thread(migrate, remote_exec_engine, "head")
        await asyncio.to_thread(migrate, remote_exec_engine, "head")
        async with remote_exec_engine.connect() as connection:
            assert await connection.scalar(sa.text("SELECT version_num FROM remote_exec_alembic_version")) == "0016"
            row = (await connection.execute(sa.text(
                "SELECT latest_attempt_token, interrupted_output FROM actions"
            ))).one()
            assert tuple(row) == (None, None)

        # The baseline runtime never reads the new columns, but still claims and completes old rows.
        await build(http, cache, "a")
        assert (await batch(http, batch_id))["state"] == "done"
        await asyncio.to_thread(migrate, remote_exec_engine, "0015", downgrade=True)
        async with remote_exec_engine.connect() as connection:
            assert await connection.scalar(sa.text("SELECT version_num FROM remote_exec_alembic_version")) == "0015"
            columns = set(await connection.scalars(sa.text(
                "SELECT column_name FROM information_schema.columns WHERE table_name = 'actions'"
            )))
            assert not {"latest_attempt_token", "interrupted_output"} & columns
        assert (await batch(http, batch_id))["state"] == "done"
    finally:
        await asyncio.to_thread(migrate, remote_exec_engine, "head")
