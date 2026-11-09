"""Allow batches to opt out of keeping independent actions going.

Revision ID: 0010
Revises: 0009
"""

from alembic import op

revision = "0010"
down_revision = "0009"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE batches ADD COLUMN fail_fast boolean NOT NULL DEFAULT false")


def downgrade() -> None:
    op.execute("ALTER TABLE batches DROP COLUMN fail_fast")
