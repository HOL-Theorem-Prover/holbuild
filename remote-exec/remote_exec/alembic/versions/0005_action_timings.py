"""Keep each action's phase timings from its worker's result record.

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
    # Nullable, so older coordinators keep writing rows without it.
    op.execute("ALTER TABLE actions ADD COLUMN timings jsonb")


def downgrade() -> None:
    op.execute("ALTER TABLE actions DROP COLUMN timings")
