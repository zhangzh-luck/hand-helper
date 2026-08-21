"""period time configuration

Revision ID: 0002_period_times
Revises: 0001_initial
"""
from alembic import op
import sqlalchemy as sa

revision = "0002_period_times"
down_revision = "0001_initial"
branch_labels = None
depends_on = None

def upgrade() -> None:
    op.create_table("period_times", sa.Column("id", sa.Integer, primary_key=True), sa.Column("period_number", sa.Integer, nullable=False), sa.Column("start_time", sa.String(8), nullable=False), sa.Column("end_time", sa.String(8), nullable=False), sa.Column("created_at", sa.DateTime, nullable=False), sa.Column("updated_at", sa.DateTime, nullable=False), sa.UniqueConstraint("period_number"))

def downgrade() -> None:
    op.drop_table("period_times")
