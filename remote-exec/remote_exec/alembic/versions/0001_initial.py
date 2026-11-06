"""The coordinator's tables.

Revision ID: 0001
Revises:
Create Date: 2026-11-03
"""

from alembic import op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

STATEMENTS = [
    """
    CREATE TABLE batches (
        id uuid PRIMARY KEY,
        created_at timestamptz NOT NULL DEFAULT now(),
        state text NOT NULL CHECK (state IN ('running', 'failed', 'cancelled', 'done')),
        failure text,
        profile text NOT NULL
    )
    """,
    "CREATE INDEX batches_terminal_created_at ON batches (created_at) WHERE state <> 'running'",
    """
    CREATE TABLE actions (
        batch_id uuid NOT NULL REFERENCES batches (id) ON DELETE CASCADE,
        input_key text NOT NULL,
        ac_key text NOT NULL,
        spec_sha256 text NOT NULL,
        theory text NOT NULL,
        remaining_deps integer NOT NULL,
        state text NOT NULL CHECK (state IN ('waiting', 'ready', 'running', 'done', 'failed', 'cancelled')),
        tier text NOT NULL CHECK (tier IN ('standard', 'high')),
        attempts integer NOT NULL DEFAULT 0,
        last_failure text,
        log_sha256 text,
        PRIMARY KEY (batch_id, input_key)
    )
    """,
    "CREATE INDEX actions_ready ON actions (tier) WHERE state = 'ready'",
    "CREATE INDEX actions_releasable ON actions (batch_id) WHERE state = 'waiting' AND remaining_deps = 0",
    """
    CREATE TABLE edges (
        batch_id uuid NOT NULL,
        input_key text NOT NULL,
        parent_key text NOT NULL,
        PRIMARY KEY (batch_id, input_key, parent_key),
        FOREIGN KEY (batch_id, input_key) REFERENCES actions (batch_id, input_key) ON DELETE CASCADE,
        FOREIGN KEY (batch_id, parent_key) REFERENCES actions (batch_id, input_key) ON DELETE CASCADE
    )
    """,
    "CREATE INDEX edges_parent ON edges (batch_id, parent_key)",
    """
    CREATE TABLE leases (
        attempt_token uuid PRIMARY KEY,
        batch_id uuid NOT NULL,
        input_key text NOT NULL,
        worker text NOT NULL,
        expires_at timestamptz NOT NULL,
        FOREIGN KEY (batch_id, input_key) REFERENCES actions (batch_id, input_key) ON DELETE CASCADE
    )
    """,
    "CREATE INDEX leases_expires_at ON leases (expires_at)",
    "CREATE INDEX leases_action ON leases (batch_id, input_key)",
    """
    CREATE TABLE peak_hints (
        package text NOT NULL,
        theory text NOT NULL,
        profile text NOT NULL,
        peak_rss_mb integer NOT NULL,
        updated_at timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (package, theory, profile)
    )
    """,
    # One row per sweep: the burst workers the queue needed then. The target is the maximum over the hold.
    "CREATE TABLE burst_demand (at timestamptz NOT NULL, workers integer NOT NULL)",
    "CREATE INDEX burst_demand_at ON burst_demand (at)",
]


def upgrade() -> None:
    # asyncpg runs one statement per execute.
    for statement in STATEMENTS:
        op.execute(statement)


def downgrade() -> None:
    op.execute("DROP TABLE burst_demand, peak_hints, leases, edges, actions, batches")
