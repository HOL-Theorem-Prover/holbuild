"""Indexes that keep a claim and the queue counts from reading every action the database holds.

Revision ID: 0003
Revises: 0002
Create Date: 2026-11-07
"""

from alembic import op

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None

STATEMENTS = [
    # A claim's per-batch running count and last claim time.
    "CREATE INDEX actions_running ON actions (batch_id) WHERE state = 'running'",
    "CREATE INDEX actions_last_claimed_at ON actions (batch_id, last_claimed_at) WHERE last_claimed_at IS NOT NULL",
    # The queue counts.
    "CREATE INDEX actions_unfinished ON actions (state, tier) WHERE state IN ('waiting', 'ready', 'running')",
]


def upgrade() -> None:
    # asyncpg runs one statement per execute.
    for statement in STATEMENTS:
        op.execute(statement)


def downgrade() -> None:
    op.execute("DROP INDEX actions_running, actions_last_claimed_at, actions_unfinished")
