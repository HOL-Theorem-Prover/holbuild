"""Order ready batches by explicit scheduling priority.

Revision ID: 0014
Revises: 0013
Create Date: 2026-11-09
"""

from alembic import op

revision = "0014"
down_revision = "0013"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE batches ADD COLUMN priority integer NOT NULL DEFAULT 0 CHECK (priority >= 0)")


def downgrade() -> None:
    op.execute("ALTER TABLE batches DROP COLUMN priority")
