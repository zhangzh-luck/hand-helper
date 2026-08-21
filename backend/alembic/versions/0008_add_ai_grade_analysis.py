"""add encrypted AI configuration and grade analysis cache

Revision ID: 0008_add_ai_grade_analysis
Revises: 0007_remove_retired_jwmis_credentials
"""
from alembic import op
import sqlalchemy as sa

revision = "0008_add_ai_grade_analysis"
down_revision = "0007_remove_retired_jwmis_credentials"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "ai_provider_settings",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("provider", sa.String(length=64), nullable=False),
        sa.Column("base_url", sa.String(length=512), nullable=False),
        sa.Column("model", sa.String(length=128), nullable=False),
        sa.Column("encrypted_api_key", sa.Text(), nullable=False),
        sa.Column("api_key_hint", sa.String(length=24), nullable=False),
        sa.Column("is_enabled", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
    )
    op.create_table(
        "grade_ai_analyses",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("term_id", sa.Integer(), sa.ForeignKey("academic_terms.id", ondelete="CASCADE"), nullable=False),
        sa.Column("input_hash", sa.String(length=64), nullable=False),
        sa.Column("provider", sa.String(length=64), nullable=False),
        sa.Column("model", sa.String(length=128), nullable=False),
        sa.Column("content", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.UniqueConstraint("term_id", "input_hash", name="uq_grade_ai_analysis_snapshot"),
    )
    op.create_index("ix_grade_ai_analyses_term_id", "grade_ai_analyses", ["term_id"])
    op.create_index("ix_grade_ai_analyses_input_hash", "grade_ai_analyses", ["input_hash"])


def downgrade() -> None:
    op.drop_index("ix_grade_ai_analyses_input_hash", table_name="grade_ai_analyses")
    op.drop_index("ix_grade_ai_analyses_term_id", table_name="grade_ai_analyses")
    op.drop_table("grade_ai_analyses")
    op.drop_table("ai_provider_settings")
