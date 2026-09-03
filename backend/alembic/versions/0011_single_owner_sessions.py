"""replace legacy users and JWT refresh tokens with singleton sessions

Revision ID: 0011_single_owner_sessions
Revises: 0010_remove_question_bank
"""
from alembic import op
import sqlalchemy as sa


revision = "0011_single_owner_sessions"
down_revision = "0010_remove_question_bank"
branch_labels = None
depends_on = None


def _table_names(bind) -> set[str]:
    return set(sa.inspect(bind).get_table_names())


def upgrade() -> None:
    """Keep the owner's existing data while removing the former user model."""
    bind = op.get_bind()
    existing = _table_names(bind)

    # SQLite rebuilds tables for foreign-key/column removal. Foreign-key checks
    # are paused only for this migration and restored before it exits.
    if bind.dialect.name == "sqlite":
        bind.exec_driver_sql("PRAGMA foreign_keys=OFF")
    try:
        if "app_profiles" in existing:
            op.create_table(
                "app_profiles_singleton",
                sa.Column("id", sa.Integer, primary_key=True),
                sa.Column("display_name", sa.String(64), nullable=False),
                sa.Column("avatar_data_url", sa.Text, nullable=True),
                sa.Column("created_at", sa.DateTime, nullable=False),
                sa.Column("updated_at", sa.DateTime, nullable=False),
            )
            # The former application only had one owner. Preserve that profile.
            bind.execute(sa.text(
                "INSERT INTO app_profiles_singleton "
                "(id, display_name, avatar_data_url, created_at, updated_at) "
                "SELECT id, display_name, avatar_data_url, created_at, updated_at "
                "FROM app_profiles ORDER BY id LIMIT 1"
            ))
            op.drop_table("app_profiles")
            op.rename_table("app_profiles_singleton", "app_profiles")

        if "custom_schedules" in existing:
            op.create_table(
                "custom_schedules_singleton",
                sa.Column("id", sa.Integer, primary_key=True),
                sa.Column("title", sa.String(200), nullable=False),
                sa.Column("scheduled_date", sa.Date, nullable=False),
                sa.Column("scheduled_time", sa.String(5), nullable=False),
                sa.Column("created_at", sa.DateTime, nullable=False),
                sa.Column("updated_at", sa.DateTime, nullable=False),
            )
            bind.execute(sa.text(
                "INSERT INTO custom_schedules_singleton "
                "(id, title, scheduled_date, scheduled_time, created_at, updated_at) "
                "SELECT id, title, scheduled_date, scheduled_time, created_at, updated_at "
                "FROM custom_schedules"
            ))
            op.drop_table("custom_schedules")
            op.rename_table("custom_schedules_singleton", "custom_schedules")
            op.create_index("ix_custom_schedules_scheduled_date", "custom_schedules", ["scheduled_date"])

        if "manual_courses" in existing:
            op.create_table(
                "manual_courses_singleton",
                sa.Column("id", sa.Integer, primary_key=True),
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
                sa.UniqueConstraint("term_id", "course_name", "weekday", "start_period", "end_period", "week_expression", name="uq_manual_course_rule"),
            )
            # INSERT OR IGNORE makes an old, impossible multi-user collision
            # deterministic while retaining the first owner record.
            bind.execute(sa.text(
                "INSERT OR IGNORE INTO manual_courses_singleton "
                "(id, term_id, course_name, teacher, classroom, weekday, start_period, end_period, week_expression, created_at, updated_at) "
                "SELECT id, term_id, course_name, teacher, classroom, weekday, start_period, end_period, week_expression, created_at, updated_at "
                "FROM manual_courses"
            ))
            op.drop_table("manual_courses")
            op.rename_table("manual_courses_singleton", "manual_courses")
            op.create_index("ix_manual_courses_term_id", "manual_courses", ["term_id"])

        if "refresh_tokens" in existing:
            op.drop_table("refresh_tokens")
        if "app_users" in existing:
            op.drop_table("app_users")

        op.create_table(
            "app_sessions",
            sa.Column("id", sa.Integer, primary_key=True),
            sa.Column("session_hash", sa.String(64), nullable=False),
            sa.Column("expires_at", sa.DateTime, nullable=False),
            sa.Column("created_at", sa.DateTime, nullable=False),
        )
        op.create_index("ix_app_sessions_session_hash", "app_sessions", ["session_hash"], unique=True)
        op.create_index("ix_app_sessions_expires_at", "app_sessions", ["expires_at"])
    finally:
        if bind.dialect.name == "sqlite":
            bind.exec_driver_sql("PRAGMA foreign_keys=ON")


def downgrade() -> None:
    raise RuntimeError("Single-owner authentication deliberately removes the old multi-user tables and cannot be downgraded.")
