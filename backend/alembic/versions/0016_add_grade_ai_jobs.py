"""add durable grade AI analysis jobs

Revision ID: 0016_add_grade_ai_jobs
Revises: 0015_page_wallpapers
"""

from alembic import op
import sqlalchemy as sa


revision = "0016_add_grade_ai_jobs"
down_revision = "0015_page_wallpapers"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "grade_ai_jobs",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("job_id", sa.String(length=64), nullable=False),
        sa.Column("owner", sa.String(length=128), nullable=False),
        sa.Column("term_id", sa.Integer(), sa.ForeignKey("academic_terms.id", ondelete="CASCADE"), nullable=False),
        sa.Column("input_hash", sa.String(length=64), nullable=False),
        sa.Column("provider", sa.String(length=64), nullable=False),
        sa.Column("model", sa.String(length=128), nullable=False),
        sa.Column("configuration_hash", sa.String(length=64), nullable=False),
        sa.Column("idempotency_key", sa.String(length=128), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False, server_default="queued"),
        sa.Column("attempt", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("lease_owner", sa.String(length=128), nullable=True),
        sa.Column("lease_expires_at", sa.DateTime(), nullable=True),
        sa.Column("started_at", sa.DateTime(), nullable=True),
        sa.Column("finished_at", sa.DateTime(), nullable=True),
        sa.Column("error_code", sa.String(length=64), nullable=True),
        sa.Column("error_message", sa.String(length=512), nullable=True),
        sa.Column("analysis_id", sa.Integer(), sa.ForeignKey("grade_ai_analyses.id", ondelete="SET NULL"), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.UniqueConstraint("job_id", name="uq_grade_ai_jobs_job_id"),
        sa.UniqueConstraint("owner", "idempotency_key", name="uq_grade_ai_job_owner_idempotency"),
    )
    op.create_index("ix_grade_ai_jobs_job_id", "grade_ai_jobs", ["job_id"])
    op.create_index("ix_grade_ai_jobs_owner", "grade_ai_jobs", ["owner"])
    op.create_index("ix_grade_ai_jobs_term_id", "grade_ai_jobs", ["term_id"])
    op.create_index("ix_grade_ai_jobs_input_hash", "grade_ai_jobs", ["input_hash"])
    op.create_index("ix_grade_ai_jobs_idempotency_key", "grade_ai_jobs", ["idempotency_key"])
    op.create_index("ix_grade_ai_jobs_status", "grade_ai_jobs", ["status"])
    op.create_index("ix_grade_ai_jobs_lease_expires_at", "grade_ai_jobs", ["lease_expires_at"])
    op.create_index("ix_grade_ai_jobs_owner_created", "grade_ai_jobs", ["owner", "created_at"])
    op.create_index("ix_grade_ai_jobs_status_created", "grade_ai_jobs", ["status", "created_at"])
    # SQLite partial index serializes equivalent active work without preventing
    # an explicit force-refresh after a terminal task.
    op.execute(
        "CREATE UNIQUE INDEX uq_grade_ai_job_active_snapshot "
        "ON grade_ai_jobs (owner, term_id, input_hash, provider, model, configuration_hash) "
        "WHERE status IN ('queued', 'running')"
    )
    with op.batch_alter_table("grade_ai_analyses") as batch:
        batch.add_column(sa.Column("configuration_hash", sa.String(length=64), nullable=False, server_default=""))


def downgrade() -> None:
    op.drop_index("uq_grade_ai_job_active_snapshot", table_name="grade_ai_jobs")
    with op.batch_alter_table("grade_ai_analyses") as batch:
        batch.drop_column("configuration_hash")
    op.drop_index("ix_grade_ai_jobs_status_created", table_name="grade_ai_jobs")
    op.drop_index("ix_grade_ai_jobs_owner_created", table_name="grade_ai_jobs")
    op.drop_index("ix_grade_ai_jobs_lease_expires_at", table_name="grade_ai_jobs")
    op.drop_index("ix_grade_ai_jobs_status", table_name="grade_ai_jobs")
    op.drop_index("ix_grade_ai_jobs_idempotency_key", table_name="grade_ai_jobs")
    op.drop_index("ix_grade_ai_jobs_input_hash", table_name="grade_ai_jobs")
    op.drop_index("ix_grade_ai_jobs_term_id", table_name="grade_ai_jobs")
    op.drop_index("ix_grade_ai_jobs_owner", table_name="grade_ai_jobs")
    op.drop_index("ix_grade_ai_jobs_job_id", table_name="grade_ai_jobs")
    op.drop_table("grade_ai_jobs")
