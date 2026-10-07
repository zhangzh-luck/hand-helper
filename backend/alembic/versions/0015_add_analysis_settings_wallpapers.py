"""add independent analysis and settings wallpapers

Revision ID: 0015_page_wallpapers
Revises: 0014_add_home_wallpaper
"""

from alembic import op
import sqlalchemy as sa


revision = "0015_page_wallpapers"
down_revision = "0014_add_home_wallpaper"
branch_labels = None
depends_on = None


def upgrade() -> None:
    bind = op.get_bind()
    columns = {column["name"] for column in sa.inspect(bind).get_columns("app_profiles")}
    with op.batch_alter_table("app_profiles") as batch:
        if "analysis_wallpaper_data_url" not in columns:
            batch.add_column(sa.Column("analysis_wallpaper_data_url", sa.Text(), nullable=True))
        if "settings_wallpaper_data_url" not in columns:
            batch.add_column(sa.Column("settings_wallpaper_data_url", sa.Text(), nullable=True))


def downgrade() -> None:
    bind = op.get_bind()
    columns = {column["name"] for column in sa.inspect(bind).get_columns("app_profiles")}
    with op.batch_alter_table("app_profiles") as batch:
        if "settings_wallpaper_data_url" in columns:
            batch.drop_column("settings_wallpaper_data_url")
        if "analysis_wallpaper_data_url" in columns:
            batch.drop_column("analysis_wallpaper_data_url")
