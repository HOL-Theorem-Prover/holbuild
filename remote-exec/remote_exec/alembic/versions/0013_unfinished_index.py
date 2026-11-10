"""Index each batch's unfinished actions, so the check after each completion that its batch has none left reads one
entry instead of every finished action of a batch near its end.

Revision ID: 0013
Revises: 0012
Create Date: 2026-11-10
"""

from alembic import op

revision = "0013"
down_revision = "0012"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "CREATE INDEX actions_batch_unfinished ON actions (batch_id, input_key) "
        "WHERE state IN ('waiting', 'ready', 'running')"
    )


def downgrade() -> None:
    op.execute("DROP INDEX actions_batch_unfinished")
