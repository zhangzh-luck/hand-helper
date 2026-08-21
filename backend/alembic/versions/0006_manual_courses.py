"""add user manual courses

Revision ID: 0006_manual_courses
Revises: 0005_custom_schedules
"""

from alembic import op
import sqlalchemy as sa

revision = "0006_manual_courses"
down_revision = "0005_custom_schedules"
branch_labels = None
depends_on = None


def upgrade() -> None:
    if "manual_courses" in sa.inspect(op.get_bind()).get_table_names():
        return
    op.create_table(
        "manual_courses",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("app_users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("term_id", sa.Integer, sa.ForeignKey("academic_terms.id", ondelete="CASCADE"), nullable=False),
        sa.Column("course_name", sa.String(255), nullable=False),
        sa.Column("teacher", sa.String(255), nullable=True),
        sa.Column("classroom", sa.String(255), nullable=True),
        sa.Column("weekday", sa.Integer, nullable=False),
        sa.Column("start_period", sa.Integer, nullable=False),
        sa.Column("end_period", sa.Integer, nullable=False),
        sa.Column("week_expression", sa.String(255), nullable=False),
        sa.Column("created_at", sa.DateTime, nullable=False),
        sa.Column("updated_at", sa.DateTime, nullable=False),
        sa.UniqueConstraint("user_id", "term_id", "course_name", "weekday", "start_period", "end_period", "week_expression", name="uq_manual_course_rule"),
    )
    op.create_index("ix_manual_courses_user_id", "manual_courses", ["user_id"])
    op.create_index("ix_manual_courses_term_id", "manual_courses", ["term_id"])
    op.create_index("ix_manual_courses_user_term", "manual_courses", ["user_id", "term_id"])


def downgrade() -> None:
    op.drop_table("manual_courses")
