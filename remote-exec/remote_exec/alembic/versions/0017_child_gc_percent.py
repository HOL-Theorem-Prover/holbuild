"""Carry the experimental Poly/ML GC percentage on each build batch.

Revision ID: 0017
Revises: 0016
"""

from alembic import op

revision = "0017"
down_revision = "0016"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE batches ADD COLUMN child_gc_percent integer CHECK (child_gc_percent BETWEEN 1 AND 99)")


def downgrade() -> None:
    op.execute("ALTER TABLE batches DROP COLUMN child_gc_percent")
