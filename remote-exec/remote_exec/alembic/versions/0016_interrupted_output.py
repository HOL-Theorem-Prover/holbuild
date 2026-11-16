"""Retain bounded interrupted output independently of result leases."""

from alembic import op

revision = "0016"
down_revision = "0015"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE actions ADD COLUMN latest_attempt_token uuid, ADD COLUMN interrupted_output text "
               "CHECK (octet_length(interrupted_output) <= 65536)")
    op.execute("CREATE UNIQUE INDEX actions_output_token ON actions (latest_attempt_token) "
               "WHERE latest_attempt_token IS NOT NULL")


def downgrade() -> None:
    op.execute("DROP INDEX actions_output_token")
    op.execute("ALTER TABLE actions DROP COLUMN interrupted_output, DROP COLUMN latest_attempt_token")
