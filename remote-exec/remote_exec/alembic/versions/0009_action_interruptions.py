"""Count an action's refunded unavailable results, so they can be capped.

Revision ID: 0009
Revises: 0008
Create Date: 2026-11-08
"""

from alembic import op

revision = "0009"
down_revision = "0008"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE actions ADD COLUMN interruptions integer NOT NULL DEFAULT 0")


def downgrade() -> None:
    op.execute("ALTER TABLE actions DROP COLUMN interruptions")
