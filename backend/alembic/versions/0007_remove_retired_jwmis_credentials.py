"""remove retired jwmis credential storage

Revision ID: 0007_remove_retired_jwmis_credentials
Revises: 0006_manual_courses
Create Date: 2026-08-20

The application no longer logs into or requests the JWMIS website.  These two
tables only contained the now-retired encrypted JWMIS account/session state;
course, grade, profile and practice data are not affected.
"""

from alembic import op


revision = "0007_remove_retired_jwmis_credentials"
down_revision = "0006_manual_courses"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.drop_table("jw_sessions")
    op.drop_table("jw_accounts")


def downgrade() -> None:
    raise RuntimeError("不支持恢复已退役的教务系统凭据表")
