"""Stamp each action row with the transaction that last wrote it, so event streams read only what changed.

Revision ID: 0004
Revises: 0003
Create Date: 2026-11-07
"""

from alembic import op

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None

STATEMENTS = [
    # Existing rows get 0, older than any stream's position.
    "ALTER TABLE actions ADD COLUMN changed_xid xid8 NOT NULL DEFAULT '0'",
    """
    CREATE FUNCTION actions_stamp_change() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
        NEW.changed_xid := pg_current_xact_id();
        RETURN NEW;
    END
    $$
    """,
    """
    CREATE TRIGGER actions_stamp_change BEFORE INSERT OR UPDATE ON actions
    FOR EACH ROW EXECUTE FUNCTION actions_stamp_change()
    """,
    "CREATE INDEX actions_changed ON actions (batch_id, changed_xid)",
]


def upgrade() -> None:
    # Takes an exclusive lock on actions until the index is built, so run it with the coordinator stopped, as the image's
    # `migrate` before the coordinator starts does. asyncpg runs one statement per execute.
    for statement in STATEMENTS:
        op.execute(statement)


def downgrade() -> None:
    op.execute("DROP TRIGGER actions_stamp_change ON actions")
    op.execute("DROP FUNCTION actions_stamp_change()")
    op.execute("ALTER TABLE actions DROP COLUMN changed_xid")
