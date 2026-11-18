"""Allow batches to opt out of keeping independent actions going.

Revision ID: 0011
Revises: 0010
"""

from alembic import op

revision = "0011"
down_revision = "0010"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE batches ADD COLUMN fail_fast boolean NOT NULL DEFAULT false")


def downgrade() -> None:
    op.execute("ALTER TABLE batches DROP COLUMN fail_fast")
