"""Retain the latest action claim's worker and completion time, and index the running batches, so that the
statements that look for them read only those, not every finished batch retention keeps.

Revision ID: 0016
Revises: 0015
"""

from alembic import op

revision = "0016"
down_revision = "0015"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Built without blocking the coordinator's writes to batches. First, so that a run that failed after it starts
    # again from a clean slate: a failed concurrent build leaves an invalid index behind, which is dropped here.
    with op.get_context().autocommit_block():
        op.execute("DROP INDEX CONCURRENTLY IF EXISTS batches_running")
        op.execute("CREATE INDEX CONCURRENTLY batches_running ON batches (id) WHERE state = 'running'")
    op.execute("ALTER TABLE actions ADD COLUMN finished_at timestamptz, ADD COLUMN worker text")


def downgrade() -> None:
    op.execute("ALTER TABLE actions DROP COLUMN finished_at, DROP COLUMN worker")
    with op.get_context().autocommit_block():
        op.execute("DROP INDEX CONCURRENTLY IF EXISTS batches_running")
