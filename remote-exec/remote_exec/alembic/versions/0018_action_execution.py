"""Retain the latest action claim's worker and completion time.

Revision ID: 0018
Revises: 0017
"""

from alembic import op

revision = "0018"
down_revision = "0017"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE actions ADD COLUMN finished_at timestamptz, ADD COLUMN worker text")


def downgrade() -> None:
    op.execute("ALTER TABLE actions DROP COLUMN finished_at, DROP COLUMN worker")
