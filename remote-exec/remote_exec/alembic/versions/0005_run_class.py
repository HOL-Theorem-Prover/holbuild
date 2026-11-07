"""Separate generic run actions from builds and index run admission.

Revision ID: 0005
Revises: 0004
Create Date: 2026-11-07
"""

from alembic import op

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE actions ADD COLUMN class text NOT NULL DEFAULT 'build' CHECK (class IN ('build', 'run'))")
    op.execute("DROP INDEX actions_ready, actions_unfinished")
    op.execute("CREATE INDEX actions_ready ON actions (class, tier) WHERE state = 'ready'")
    op.execute("CREATE INDEX actions_running_run ON actions (batch_id) WHERE state = 'running' AND class = 'run'")
    op.execute(
        "CREATE INDEX actions_unfinished ON actions (state, tier, class) WHERE state IN ('waiting', 'ready', 'running')"
    )


def downgrade() -> None:
    op.execute("DROP INDEX actions_ready, actions_running_run, actions_unfinished")
    op.execute("CREATE INDEX actions_ready ON actions (tier) WHERE state = 'ready'")
    op.execute(
        "CREATE INDEX actions_unfinished ON actions (state, tier) WHERE state IN ('waiting', 'ready', 'running')"
    )
    op.execute("ALTER TABLE actions DROP COLUMN class")
