"""add user custom schedules

Revision ID: 0005_custom_schedules
Revises: 0004_question_bank
"""

from alembic import op
import sqlalchemy as sa

revision = "0005_custom_schedules"
down_revision = "0004_question_bank"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 兼容本地开发环境可能已经由 create_all 创建表的情形。
    if "custom_schedules" in sa.inspect(op.get_bind()).get_table_names():
        return
    op.create_table(
        "custom_schedules",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("app_users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("title", sa.String(200), nullable=False),
        sa.Column("scheduled_date", sa.Date, nullable=False),
        sa.Column("scheduled_time", sa.String(5), nullable=False),
        sa.Column("created_at", sa.DateTime, nullable=False),
        sa.Column("updated_at", sa.DateTime, nullable=False),
    )
    op.create_index("ix_custom_schedules_user_id", "custom_schedules", ["user_id"])
    op.create_index("ix_custom_schedules_scheduled_date", "custom_schedules", ["scheduled_date"])
    op.create_index("ix_custom_schedules_user_date_time", "custom_schedules", ["user_id", "scheduled_date", "scheduled_time"])


def downgrade() -> None:
    op.drop_table("custom_schedules")
