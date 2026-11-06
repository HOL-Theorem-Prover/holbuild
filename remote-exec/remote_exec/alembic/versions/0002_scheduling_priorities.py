"""What claims order by: an action's place in its batch's DAG, and when it was last claimed.

Revision ID: 0002
Revises: 0001
Create Date: 2026-11-06
"""

from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None

STATEMENTS = [
    """
    ALTER TABLE actions
        ADD COLUMN critical_depth integer NOT NULL DEFAULT 0,
        ADD COLUMN descendant_count integer NOT NULL DEFAULT 0,
        ADD COLUMN last_claimed_at timestamptz
    """,
    # A self-edge could only come from an input-missing result naming the action itself; it held the action
    # back until its batch's deadline, so dropping one loses nothing.
    "DELETE FROM edges WHERE input_key = parent_key",
    "ALTER TABLE edges ADD CONSTRAINT edges_no_self_loop CHECK (input_key <> parent_key)",
]


def upgrade() -> None:
    # asyncpg runs one statement per execute.
    for statement in STATEMENTS:
        op.execute(statement)


def downgrade() -> None:
    op.execute("ALTER TABLE edges DROP CONSTRAINT edges_no_self_loop")
    op.execute(
        "ALTER TABLE actions DROP COLUMN critical_depth, DROP COLUMN descendant_count, DROP COLUMN last_claimed_at"
    )
