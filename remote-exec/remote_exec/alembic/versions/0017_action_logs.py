"""Record compressed action logs and publication failures.

Revision ID: 0017
Revises: 0016
"""

from alembic import op

revision = "0017"
down_revision = "0016"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE actions ADD COLUMN log_zstd text, ADD COLUMN log_error text")


def downgrade() -> None:
    op.execute("ALTER TABLE actions DROP COLUMN log_zstd, DROP COLUMN log_error")
