"""Retain the latest action claim's worker and completion time.

Revision ID: 0016
Revises: 0015
Create Date: 2026-11-11
"""

from alembic import op

revision = "0016"
down_revision = "0015"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE actions ADD COLUMN finished_at timestamptz, ADD COLUMN worker text")


def downgrade() -> None:
    op.execute("ALTER TABLE actions DROP COLUMN finished_at, DROP COLUMN worker")
