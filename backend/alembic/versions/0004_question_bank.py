"""add personal question bank module

Revision ID: 0004_question_bank
Revises: 0003_app_profiles
"""

from alembic import op
import sqlalchemy as sa

revision = "0004_question_bank"
down_revision = "0003_app_profiles"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # 兼容旧开发版本曾由 FastAPI create_all 提前创建模型表的情况；生产镜像仍先执行 Alembic。
    if "question_banks" in sa.inspect(op.get_bind()).get_table_names():
        return
    op.create_table(
        "question_banks",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("app_users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(200), nullable=False),
        sa.Column("description", sa.Text, nullable=True),
        sa.Column("source_type", sa.String(32), nullable=False),
        sa.Column("source_filename", sa.String(255), nullable=True),
        sa.Column("course_id", sa.Integer, sa.ForeignKey("courses.id", ondelete="SET NULL"), nullable=True),
        sa.Column("created_at", sa.DateTime, nullable=False),
        sa.Column("updated_at", sa.DateTime, nullable=False),
    )
    op.create_index("ix_question_banks_user_id", "question_banks", ["user_id"])
    op.create_index("ix_question_banks_name", "question_banks", ["name"])
    op.create_index("ix_question_banks_course_id", "question_banks", ["course_id"])
    op.create_table(
        "questions",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("question_bank_id", sa.Integer, sa.ForeignKey("question_banks.id", ondelete="CASCADE"), nullable=False),
        sa.Column("question_type", sa.String(32), nullable=False),
        sa.Column("content", sa.Text, nullable=False),
        sa.Column("options_json", sa.Text, nullable=True),
        sa.Column("answer_json", sa.Text, nullable=False),
        sa.Column("explanation", sa.Text, nullable=True),
        sa.Column("sort_order", sa.Integer, nullable=False),
        sa.Column("created_at", sa.DateTime, nullable=False),
        sa.Column("updated_at", sa.DateTime, nullable=False),
    )
    op.create_index("ix_questions_question_bank_id", "questions", ["question_bank_id"])
    op.create_index("ix_questions_question_type", "questions", ["question_type"])
    op.create_index("ix_questions_sort_order", "questions", ["sort_order"])
    op.create_table(
        "question_import_previews",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("app_users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("question_bank_id", sa.Integer, sa.ForeignKey("question_banks.id", ondelete="CASCADE"), nullable=False),
        sa.Column("source_filename", sa.String(255), nullable=False),
        sa.Column("status", sa.String(32), nullable=False),
        sa.Column("drafts_json", sa.Text, nullable=False),
        sa.Column("warnings_json", sa.Text, nullable=False),
        sa.Column("created_at", sa.DateTime, nullable=False),
        sa.Column("confirmed_at", sa.DateTime, nullable=True),
    )
    op.create_index("ix_question_import_previews_user_id", "question_import_previews", ["user_id"])
    op.create_index("ix_question_import_previews_question_bank_id", "question_import_previews", ["question_bank_id"])
    op.create_index("ix_question_import_previews_status", "question_import_previews", ["status"])
    op.create_table(
        "practice_sessions",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("app_users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("question_bank_id", sa.Integer, sa.ForeignKey("question_banks.id", ondelete="SET NULL"), nullable=True),
        sa.Column("mode", sa.String(32), nullable=False),
        sa.Column("question_ids_json", sa.Text, nullable=False),
        sa.Column("total_count", sa.Integer, nullable=False),
        sa.Column("answered_count", sa.Integer, nullable=False),
        sa.Column("correct_count", sa.Integer, nullable=False),
        sa.Column("current_index", sa.Integer, nullable=False),
        sa.Column("started_at", sa.DateTime, nullable=False),
        sa.Column("completed_at", sa.DateTime, nullable=True),
        sa.Column("created_at", sa.DateTime, nullable=False),
        sa.Column("updated_at", sa.DateTime, nullable=False),
    )
    op.create_index("ix_practice_sessions_user_id", "practice_sessions", ["user_id"])
    op.create_index("ix_practice_sessions_question_bank_id", "practice_sessions", ["question_bank_id"])
    op.create_index("ix_practice_sessions_mode", "practice_sessions", ["mode"])
    op.create_table(
        "answer_records",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("session_id", sa.Integer, sa.ForeignKey("practice_sessions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("app_users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("question_id", sa.Integer, sa.ForeignKey("questions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_answer_json", sa.Text, nullable=True),
        sa.Column("is_correct", sa.Boolean, nullable=True),
        sa.Column("self_assessment", sa.String(32), nullable=True),
        sa.Column("duration_ms", sa.Integer, nullable=False),
        sa.Column("answered_at", sa.DateTime, nullable=False),
    )
    op.create_index("ix_answer_records_session_id", "answer_records", ["session_id"])
    op.create_index("ix_answer_records_user_id", "answer_records", ["user_id"])
    op.create_index("ix_answer_records_question_id", "answer_records", ["question_id"])
    op.create_index("ix_answer_records_answered_at", "answer_records", ["answered_at"])
    op.create_table(
        "favorite_questions",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("app_users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("question_id", sa.Integer, sa.ForeignKey("questions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("created_at", sa.DateTime, nullable=False),
        sa.UniqueConstraint("user_id", "question_id", name="uq_favorite_question_user_question"),
    )
    op.create_index("ix_favorite_questions_user_id", "favorite_questions", ["user_id"])
    op.create_index("ix_favorite_questions_question_id", "favorite_questions", ["question_id"])
    op.create_table(
        "wrong_question_states",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("app_users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("question_id", sa.Integer, sa.ForeignKey("questions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("wrong_count", sa.Integer, nullable=False),
        sa.Column("last_wrong_at", sa.DateTime, nullable=False),
        sa.Column("last_reviewed_at", sa.DateTime, nullable=True),
        sa.Column("last_answer_json", sa.Text, nullable=True),
        sa.Column("mastered", sa.Boolean, nullable=False),
        sa.Column("created_at", sa.DateTime, nullable=False),
        sa.Column("updated_at", sa.DateTime, nullable=False),
        sa.UniqueConstraint("user_id", "question_id", name="uq_wrong_question_user_question"),
    )
    op.create_index("ix_wrong_question_states_user_id", "wrong_question_states", ["user_id"])
    op.create_index("ix_wrong_question_states_question_id", "wrong_question_states", ["question_id"])
    op.create_index("ix_wrong_question_states_last_wrong_at", "wrong_question_states", ["last_wrong_at"])


def downgrade() -> None:
    op.drop_table("wrong_question_states")
    op.drop_table("favorite_questions")
    op.drop_table("answer_records")
    op.drop_table("practice_sessions")
    op.drop_table("question_import_previews")
    op.drop_table("questions")
    op.drop_table("question_banks")
