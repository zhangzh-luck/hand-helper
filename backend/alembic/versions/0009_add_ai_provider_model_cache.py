"""persist the verified model list for the single-user AI provider

Revision ID: 0009_add_ai_provider_model_cache
Revises: 0008_add_ai_grade_analysis
"""
from alembic import op
import sqlalchemy as sa


revision = "0009_add_ai_provider_model_cache"
down_revision = "0008_add_ai_grade_analysis"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("ai_provider_settings") as batch_op:
        batch_op.add_column(sa.Column("available_models_json", sa.Text(), nullable=False, server_default="[]"))
        batch_op.add_column(sa.Column("models_synced_at", sa.DateTime(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("ai_provider_settings") as batch_op:
        batch_op.drop_column("models_synced_at")
        batch_op.drop_column("available_models_json")
