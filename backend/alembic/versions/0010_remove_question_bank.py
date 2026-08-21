"""remove retired question-bank feature and its data

Revision ID: 0010_remove_question_bank
Revises: 0009_add_ai_provider_model_cache
"""

from alembic import op
import sqlalchemy as sa


revision = "0010_remove_question_bank"
down_revision = "0009_add_ai_provider_model_cache"
branch_labels = None
depends_on = None


def upgrade() -> None:
    """Permanently discard retired personal question-bank data."""
    bind = op.get_bind()
    existing = set(sa.inspect(bind).get_table_names())
    # Drop dependent tables first. The guards keep upgrade safe for databases
    # where the former optional module was never initialized.
    for table in (
        "wrong_question_states",
        "favorite_questions",
        "answer_records",
        "practice_sessions",
        "question_import_previews",
        "questions",
        "question_banks",
    ):
        if table in existing:
            op.drop_table(table)


def downgrade() -> None:
    raise RuntimeError("The retired question-bank feature and its data cannot be restored by downgrade.")
