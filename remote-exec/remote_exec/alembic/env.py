import asyncio
import os
from logging.config import fileConfig

from sqlalchemy import pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import create_async_engine

from alembic import context

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name, disable_existing_loggers=False)


def run(connection: Connection) -> None:
    context.configure(connection=connection, version_table=config.get_main_option("version_table") or "alembic_version")
    with context.begin_transaction():
        context.run_migrations()


async def main() -> None:
    url = config.get_main_option("sqlalchemy.url") or os.environ["REMOTE_EXEC_DATABASE_URL"]
    engine = create_async_engine(url, poolclass=pool.NullPool)
    async with engine.connect() as connection:
        await connection.run_sync(run)
    await engine.dispose()


asyncio.run(main())
