"""add timetable background to app profile

Revision ID: 0012_add_timetable_background
Revises: 0011_single_owner_sessions
Create Date: 2026-09-19
"""

from alembic import op
import sqlalchemy as sa


revision = "0012_add_timetable_background"
down_revision = "0011_single_owner_sessions"
branch_labels = None
depends_on = None


def upgrade() -> None:
    bind = op.get_bind()
    columns = {column["name"] for column in sa.inspect(bind).get_columns("app_profiles")}
    if "timetable_background_data_url" not in columns:
        with op.batch_alter_table("app_profiles") as batch:
            batch.add_column(sa.Column("timetable_background_data_url", sa.Text(), nullable=True))


def downgrade() -> None:
    bind = op.get_bind()
    columns = {column["name"] for column in sa.inspect(bind).get_columns("app_profiles")}
    if "timetable_background_data_url" in columns:
        with op.batch_alter_table("app_profiles") as batch:
            batch.drop_column("timetable_background_data_url")
