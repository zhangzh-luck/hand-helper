"""harden durable grade AI job leases and cache identity

Revision ID: 0017_harden_grade_ai_job_leases
Revises: 0016_add_grade_ai_jobs
"""

from alembic import op
import sqlalchemy as sa


revision = "0017_harden_grade_ai_job_leases"
down_revision = "0016_add_grade_ai_jobs"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("grade_ai_jobs") as batch:
        batch.add_column(sa.Column("lease_token", sa.String(length=64), nullable=True))

    # A changed provider endpoint must not overwrite or be returned as the
    # cache entry for a prior configuration of the same model label.
    with op.batch_alter_table("grade_ai_analyses") as batch:
        batch.drop_constraint("uq_grade_ai_analysis_snapshot", type_="unique")
        batch.create_unique_constraint(
            "uq_grade_ai_analysis_snapshot_config",
            ["term_id", "input_hash", "configuration_hash"],
        )


def downgrade() -> None:
    with op.batch_alter_table("grade_ai_analyses") as batch:
        batch.drop_constraint("uq_grade_ai_analysis_snapshot_config", type_="unique")
        batch.create_unique_constraint("uq_grade_ai_analysis_snapshot", ["term_id", "input_hash"])
    with op.batch_alter_table("grade_ai_jobs") as batch:
        batch.drop_column("lease_token")
