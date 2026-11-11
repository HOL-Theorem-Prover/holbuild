"""An index of each batch's ready actions in claim order, so a claim locks the first one without sorting them all.

Revision ID: 0012
Revises: 0011
"""

from alembic import op

revision = "0012"
down_revision = "0011"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "CREATE INDEX actions_ready_order ON actions "
        "(batch_id, class, tier, critical_depth DESC, descendant_count DESC, theory, input_key) WHERE state = 'ready'"
    )


def downgrade() -> None:
    op.execute("DROP INDEX actions_ready_order")
