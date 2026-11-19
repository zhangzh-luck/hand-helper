"""Add independent single-owner ledger and subscription tables."""

from alembic import op
import sqlalchemy as sa

revision = "0018_life_mvp"
down_revision = "0017_harden_grade_ai_job_leases"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "life_categories",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("name", sa.String(80), nullable=False),
        sa.Column("kind", sa.String(10), nullable=False),
        sa.UniqueConstraint("name", "kind", name="uq_life_category_name_kind"),
        sa.CheckConstraint("kind IN ('income', 'expense')", name="ck_life_category_kind"),
    )
    op.create_table(
        "life_transactions",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("kind", sa.String(10), nullable=False),
        sa.Column("amount_minor", sa.Integer, nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column(
            "category_id", sa.Integer, sa.ForeignKey("life_categories.id", ondelete="RESTRICT")
        ),
        sa.Column("occurred_on", sa.Date, nullable=False),
        sa.Column("note", sa.Text, nullable=False),
        sa.Column("created_at", sa.DateTime, nullable=False),
        sa.CheckConstraint("kind IN ('income', 'expense')", name="ck_life_transaction_kind"),
        sa.CheckConstraint("amount_minor > 0", name="ck_life_transaction_amount"),
    )
    op.create_index("ix_life_transactions_occurred_on", "life_transactions", ["occurred_on"])
    op.create_table(
        "life_budgets",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("month", sa.String(7), nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("amount_minor", sa.Integer, nullable=False),
        sa.UniqueConstraint("month", "currency", name="uq_life_budget_month_currency"),
        sa.CheckConstraint("amount_minor >= 0", name="ck_life_budget_amount"),
    )
    op.create_table(
        "life_subscriptions",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("amount_minor", sa.Integer, nullable=False),
        sa.Column("currency", sa.String(3), nullable=False),
        sa.Column("cycle", sa.String(8), nullable=False),
        sa.Column("interval_count", sa.Integer, nullable=False),
        sa.Column("anchor_date", sa.Date, nullable=False),
        sa.Column("next_due_date", sa.Date, nullable=False),
        sa.Column("reminder_days", sa.Integer, nullable=False),
        sa.Column("status", sa.String(8), nullable=False),
        sa.Column("timezone", sa.String(64), nullable=False),
        sa.CheckConstraint("amount_minor > 0", name="ck_life_subscription_amount"),
        sa.CheckConstraint("cycle IN ('day', 'week', 'month', 'year')", name="ck_life_cycle"),
        sa.CheckConstraint("interval_count > 0", name="ck_life_interval"),
        sa.CheckConstraint("status IN ('active', 'paused', 'ended')", name="ck_life_status"),
    )
    op.create_index("ix_life_subscriptions_next_due_date", "life_subscriptions", ["next_due_date"])
    op.create_table(
        "life_subscription_payments",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column(
            "subscription_id",
            sa.Integer,
            sa.ForeignKey("life_subscriptions.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column(
            "transaction_id",
            sa.Integer,
            sa.ForeignKey("life_transactions.id", ondelete="RESTRICT"),
            nullable=False,
        ),
        sa.Column("period_date", sa.Date, nullable=False),
        sa.Column("idempotency_key", sa.String(128), nullable=False),
        sa.Column("subscription_name", sa.String(120), nullable=False),
        sa.Column("paid_on", sa.Date, nullable=False),
        sa.UniqueConstraint("subscription_id", "period_date", name="uq_life_payment_period"),
        sa.UniqueConstraint("idempotency_key", name="uq_life_payment_key"),
        sa.UniqueConstraint("transaction_id", name="uq_life_payment_transaction"),
    )


def downgrade() -> None:
    op.drop_table("life_subscription_payments")
    op.drop_index("ix_life_subscriptions_next_due_date", table_name="life_subscriptions")
    op.drop_table("life_subscriptions")
    op.drop_table("life_budgets")
    op.drop_index("ix_life_transactions_occurred_on", table_name="life_transactions")
    op.drop_table("life_transactions")
    op.drop_table("life_categories")
