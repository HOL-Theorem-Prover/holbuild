"""Let a batch opt into loading ahead: a capped number of its actions may be claimed while their parents still run.

``batches.ahead_cap`` is the most actions of the batch that may wait ahead at once, NULL for a batch that doesn't
load ahead. ``actions.ahead`` is ``ahead`` while an action was claimed ahead, and ``abandoned`` once a claim ahead
of it gave up, after which it is only claimed once its parents are done.

Revision ID: 0015
Revises: 0014
Create Date: 2026-11-11
"""

from alembic import op

revision = "0015"
down_revision = "0014"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE batches ADD COLUMN ahead_cap integer CHECK (ahead_cap > 0)")
    op.execute(
        "ALTER TABLE actions ADD COLUMN ahead text NOT NULL DEFAULT 'no' CHECK (ahead IN ('no', 'ahead', 'abandoned'))"
    )
    op.execute(
        "CREATE INDEX actions_waiting_ahead ON actions (batch_id, tier) "
        "WHERE state = 'running' AND ahead = 'ahead' AND remaining_deps > 0"
    )


def downgrade() -> None:
    op.execute("DROP INDEX actions_waiting_ahead")
    op.execute("ALTER TABLE actions DROP COLUMN ahead")
    op.execute("ALTER TABLE batches DROP COLUMN ahead_cap")
