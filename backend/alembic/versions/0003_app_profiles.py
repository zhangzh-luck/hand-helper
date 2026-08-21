"""personal profile and avatar

Revision ID: 0003_app_profiles
Revises: 0002_period_times
"""
from alembic import op
import sqlalchemy as sa

revision = "0003_app_profiles"
down_revision = "0002_period_times"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "app_profiles",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("app_users.id"), nullable=False),
        sa.Column("display_name", sa.String(64), nullable=False),
        sa.Column("avatar_data_url", sa.Text, nullable=True),
        sa.Column("created_at", sa.DateTime, nullable=False),
        sa.Column("updated_at", sa.DateTime, nullable=False),
        sa.UniqueConstraint("user_id"),
    )


def downgrade() -> None:
    op.drop_table("app_profiles")
