"""Carry the client heap limit on a batch.

Revision ID: 0007
Revises: 0006
Create Date: 2026-11-07
"""

from alembic import op

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE batches ADD COLUMN max_heap_mb integer CHECK (max_heap_mb > 0)")


def downgrade() -> None:
    op.execute("ALTER TABLE batches DROP COLUMN max_heap_mb")
