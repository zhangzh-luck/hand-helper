"""add passkey credentials and one-time WebAuthn challenges

Revision ID: 0013_add_passkeys
Revises: 0012_add_timetable_background
"""

from alembic import op
import sqlalchemy as sa


revision = "0013_add_passkeys"
down_revision = "0012_add_timetable_background"
branch_labels = None
depends_on = None


def upgrade() -> None:
    bind = op.get_bind()
    tables = set(sa.inspect(bind).get_table_names())
    if "passkey_owner" not in tables:
        op.create_table(
            "passkey_owner",
            sa.Column("id", sa.Integer(), primary_key=True),
            sa.Column("user_handle", sa.String(length=128), nullable=False, unique=True),
            sa.Column("created_at", sa.DateTime(), nullable=False),
        )
    if "passkey_credentials" not in tables:
        op.create_table(
            "passkey_credentials",
            sa.Column("id", sa.Integer(), primary_key=True),
            sa.Column("credential_id", sa.String(length=1024), nullable=False, unique=True),
            sa.Column("public_key", sa.Text(), nullable=False),
            sa.Column("sign_count", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("transports_json", sa.Text(), nullable=False, server_default="[]"),
            sa.Column("device_type", sa.String(length=32), nullable=False, server_default="single_device"),
            sa.Column("backed_up", sa.Boolean(), nullable=False, server_default=sa.false()),
            sa.Column("label", sa.String(length=64), nullable=False, server_default="此设备"),
            sa.Column("created_at", sa.DateTime(), nullable=False),
            sa.Column("last_used_at", sa.DateTime(), nullable=True),
        )
        op.create_index("ix_passkey_credentials_credential_id", "passkey_credentials", ["credential_id"], unique=True)
    if "passkey_challenges" not in tables:
        op.create_table(
            "passkey_challenges",
            sa.Column("challenge_id", sa.String(length=128), primary_key=True),
            sa.Column("ceremony", sa.String(length=32), nullable=False),
            sa.Column("challenge", sa.String(length=128), nullable=False),
            sa.Column("expires_at", sa.DateTime(), nullable=False),
            sa.Column("consumed_at", sa.DateTime(), nullable=True),
            sa.Column("created_at", sa.DateTime(), nullable=False),
        )
        op.create_index("ix_passkey_challenges_ceremony", "passkey_challenges", ["ceremony"])
        op.create_index("ix_passkey_challenges_expires_at", "passkey_challenges", ["expires_at"])


def downgrade() -> None:
    raise RuntimeError("Passkey credentials must be explicitly revoked and are not downgraded automatically.")
