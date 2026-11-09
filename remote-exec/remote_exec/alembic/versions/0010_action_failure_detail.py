"""Keep why an action failed when its result record has no log, for the client to show.

Revision ID: 0010
Revises: 0009
Create Date: 2026-11-09
"""

from alembic import op

revision = "0010"
down_revision = "0009"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE actions ADD COLUMN failure_detail text")


def downgrade() -> None:
    op.execute("ALTER TABLE actions DROP COLUMN failure_detail")
