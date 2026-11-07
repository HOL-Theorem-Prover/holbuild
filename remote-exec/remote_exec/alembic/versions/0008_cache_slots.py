"""Reserve stable identities for temporary cache members.

Revision ID: 0008
Revises: 0007
Create Date: 2026-11-07
"""

from alembic import op

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("""
        CREATE TABLE cache_slots (
            slot text PRIMARY KEY,
            url text NOT NULL UNIQUE,
            owner text NOT NULL UNIQUE,
            phase text NOT NULL CHECK (phase IN
                ('boot','dns','ready','admit','serving','drain','flush','stop','withdraw','terminate')),
            assigned_at timestamptz NOT NULL DEFAULT clock_timestamp(),
            token text,
            context text,
            error text,
            ingress_stopped_at timestamptz
        )
    """)
    op.execute("CREATE TABLE cache_cpu_demand (at timestamptz NOT NULL, target integer NOT NULL)")


def downgrade() -> None:
    op.execute("DROP TABLE cache_cpu_demand")
    op.execute("DROP TABLE cache_slots")
