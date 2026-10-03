"""add independent home wallpaper to app profile

Revision ID: 0014_add_home_wallpaper
Revises: 0013_add_passkeys
"""

from alembic import op
import sqlalchemy as sa


revision = "0014_add_home_wallpaper"
down_revision = "0013_add_passkeys"
branch_labels = None
depends_on = None


def upgrade() -> None:
    bind = op.get_bind()
    columns = {column["name"] for column in sa.inspect(bind).get_columns("app_profiles")}
    if "home_wallpaper_data_url" not in columns:
        with op.batch_alter_table("app_profiles") as batch:
            batch.add_column(sa.Column("home_wallpaper_data_url", sa.Text(), nullable=True))
        # Keep the current home appearance once; future edits use separate columns.
        op.execute(
            "UPDATE app_profiles SET home_wallpaper_data_url = timetable_background_data_url "
            "WHERE home_wallpaper_data_url IS NULL"
        )


def downgrade() -> None:
    bind = op.get_bind()
    columns = {column["name"] for column in sa.inspect(bind).get_columns("app_profiles")}
    if "home_wallpaper_data_url" in columns:
        with op.batch_alter_table("app_profiles") as batch:
            batch.drop_column("home_wallpaper_data_url")
