"""Single-owner life data; no academic tables or credentials are referenced."""

from datetime import date, datetime

from sqlalchemy import (
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class Category(Base):
    __tablename__ = "life_categories"
    __table_args__ = (
        UniqueConstraint("name", "kind", name="uq_life_category_name_kind"),
        CheckConstraint("kind IN ('income', 'expense')", name="ck_life_category_kind"),
    )
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(80))
    kind: Mapped[str] = mapped_column(String(10))


class Transaction(Base):
    __tablename__ = "life_transactions"
    __table_args__ = (
        CheckConstraint("kind IN ('income', 'expense')", name="ck_life_transaction_kind"),
        CheckConstraint("amount_minor > 0", name="ck_life_transaction_amount"),
    )
    id: Mapped[int] = mapped_column(primary_key=True)
    kind: Mapped[str] = mapped_column(String(10))
    amount_minor: Mapped[int] = mapped_column(Integer)
    currency: Mapped[str] = mapped_column(String(3))
    category_id: Mapped[int | None] = mapped_column(
        ForeignKey("life_categories.id", ondelete="RESTRICT")
    )
    occurred_on: Mapped[date] = mapped_column(Date, index=True)
    note: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


class Budget(Base):
    __tablename__ = "life_budgets"
    __table_args__ = (
        UniqueConstraint("month", "currency", name="uq_life_budget_month_currency"),
        CheckConstraint("amount_minor >= 0", name="ck_life_budget_amount"),
    )
    id: Mapped[int] = mapped_column(primary_key=True)
    month: Mapped[str] = mapped_column(String(7))
    currency: Mapped[str] = mapped_column(String(3))
    amount_minor: Mapped[int] = mapped_column(Integer)


class Subscription(Base):
    __tablename__ = "life_subscriptions"
    __table_args__ = (
        CheckConstraint("amount_minor > 0", name="ck_life_subscription_amount"),
        CheckConstraint("cycle IN ('day', 'week', 'month', 'year')", name="ck_life_cycle"),
        CheckConstraint("interval_count > 0", name="ck_life_interval"),
        CheckConstraint("status IN ('active', 'paused', 'ended')", name="ck_life_status"),
    )
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(120))
    amount_minor: Mapped[int] = mapped_column(Integer)
    currency: Mapped[str] = mapped_column(String(3))
    cycle: Mapped[str] = mapped_column(String(8))
    interval_count: Mapped[int] = mapped_column(Integer)
    anchor_date: Mapped[date] = mapped_column(Date)
    next_due_date: Mapped[date] = mapped_column(Date, index=True)
    reminder_days: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(8))
    timezone: Mapped[str] = mapped_column(String(64))


class Payment(Base):
    __tablename__ = "life_subscription_payments"
    __table_args__ = (
        UniqueConstraint("subscription_id", "period_date", name="uq_life_payment_period"),
        UniqueConstraint("idempotency_key", name="uq_life_payment_key"),
        UniqueConstraint("transaction_id", name="uq_life_payment_transaction"),
    )
    id: Mapped[int] = mapped_column(primary_key=True)
    subscription_id: Mapped[int] = mapped_column(
        ForeignKey("life_subscriptions.id", ondelete="RESTRICT")
    )
    transaction_id: Mapped[int] = mapped_column(
        ForeignKey("life_transactions.id", ondelete="RESTRICT")
    )
    period_date: Mapped[date] = mapped_column(Date)
    idempotency_key: Mapped[str] = mapped_column(String(128))
    subscription_name: Mapped[str] = mapped_column(String(120))
    paid_on: Mapped[date] = mapped_column(Date)
