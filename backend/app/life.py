"""Life MVP API. All endpoints inherit the application's single-owner session guard."""

import calendar
import re
from datetime import date, timedelta
from typing import Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, Depends, Header, HTTPException
from fastapi.routing import APIRoute
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from sqlalchemy import func, select, update
from sqlalchemy.exc import IntegrityError, SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import get_db
from app.life_models import Budget, Category, Payment, Subscription, Transaction
from app.schemas import ApiResponse
from datetime import datetime
from uuid import uuid4


class SafeLifeRoute(APIRoute):
    """Keep SQL parameter values out of unhandled server exception logs."""

    def get_route_handler(self):
        handler = super().get_route_handler()

        async def guarded(request):
            try:
                return await handler(request)
            except SQLAlchemyError:
                raise HTTPException(500, "生活数据暂时不可用，请稍后重试") from None

        return guarded


router = APIRouter(prefix="/api/v1/life", tags=["life"], route_class=SafeLifeRoute)


def result(data):
    return ApiResponse(
        success=True, data=data, error=None, request_id=str(uuid4()), server_time=datetime.utcnow()
    )


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class Money(Input):
    amount_minor: int = Field(strict=True, gt=0, le=1_000_000_000_000)
    currency: str = Field(pattern=r"^[A-Z]{3}$")


class CategoryInput(Input):
    name: str = Field(min_length=1, max_length=80)
    kind: Literal["income", "expense"]


class TransactionInput(Money):
    kind: Literal["income", "expense"]
    category_id: int | None = Field(default=None, gt=0)
    occurred_on: date
    note: str = Field(default="", max_length=1000)


class BudgetInput(Input):
    amount_minor: int = Field(strict=True, ge=0, le=1_000_000_000_000)
    currency: str = Field(pattern=r"^[A-Z]{3}$")


class SubscriptionInput(Money):
    name: str = Field(min_length=1, max_length=120)
    cycle: Literal["day", "week", "month", "year"]
    interval_count: int = Field(strict=True, ge=1, le=120)
    anchor_date: date
    next_due_date: date
    reminder_days: int = Field(strict=True, ge=0, le=365)
    status: Literal["active", "paused", "ended"] = "active"
    timezone: str = Field(min_length=1, max_length=64)

    @field_validator("timezone")
    @classmethod
    def valid_timezone(cls, value):
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError):
            raise ValueError("invalid time zone") from None
        return value

    @model_validator(mode="after")
    def valid_anchor(self):
        if self.next_due_date < self.anchor_date:
            raise ValueError("next due date must not precede anchor")
        day_delta = (self.next_due_date - self.anchor_date).days
        if self.cycle in ("day", "week"):
            step = self.interval_count * (7 if self.cycle == "week" else 1)
            aligned = day_delta % step == 0
        else:
            months = (self.next_due_date.year - self.anchor_date.year) * 12 + (
                self.next_due_date.month - self.anchor_date.month
            )
            step = self.interval_count * (12 if self.cycle == "year" else 1)
            last_day = calendar.monthrange(self.next_due_date.year, self.next_due_date.month)[1]
            aligned = months % step == 0 and self.next_due_date.day == min(
                self.anchor_date.day, last_day
            )
        if not aligned:
            raise ValueError("next due date does not match subscription cycle")
        return self


class PaymentInput(Input):
    period_date: date
    paid_on: date
    category_id: int | None = Field(default=None, gt=0)


def month_range(month: str) -> tuple[date, date]:
    if not re.fullmatch(r"\d{4}-(0[1-9]|1[0-2])", month):
        raise HTTPException(422, "月份格式无效")
    year, m = map(int, month.split("-"))
    if not 1 <= year <= 9998:
        raise HTTPException(422, "月份超出范围")
    return date(year, m, 1), date(year + (m == 12), m % 12 + 1, 1)


def next_due(current: date, anchor: date, cycle: str, count: int) -> date:
    if cycle in ("day", "week"):
        return current + timedelta(days=count * (7 if cycle == "week" else 1))
    offset = count * (12 if cycle == "year" else 1)
    year, month0 = divmod(current.year * 12 + current.month - 1 + offset, 12)
    if year > 9999:
        raise ValueError("date exceeds supported range")
    return date(year, month0 + 1, min(anchor.day, calendar.monthrange(year, month0 + 1)[1]))


def out(item):
    return {column.name: getattr(item, column.name) for column in item.__table__.columns}


def subscription_snapshot_conditions(item):
    return [
        getattr(Subscription, key) == getattr(item, key) for key in SubscriptionInput.model_fields
    ]


async def get_item(db, model, item_id):
    item = await db.get(model, item_id)
    if item is None:
        raise HTTPException(404, "记录不存在")
    return item


async def check_category(db, category_id, kind):
    if category_id is not None:
        category = await get_item(db, Category, category_id)
        if category.kind != kind:
            raise HTTPException(422, "分类类型不匹配")


@router.get("/categories")
async def categories(db: AsyncSession = Depends(get_db)):
    return result(
        [out(x) for x in (await db.scalars(select(Category).order_by(Category.id))).all()]
    )


@router.post("/categories")
async def create_category(body: CategoryInput, db: AsyncSession = Depends(get_db)):
    item = Category(**body.model_dump())
    db.add(item)
    try:
        await db.commit()
    except IntegrityError:
        await db.rollback()
        raise HTTPException(409, "分类已存在") from None
    return result(out(item))


@router.put("/categories/{item_id}")
async def update_category(item_id: int, body: CategoryInput, db: AsyncSession = Depends(get_db)):
    item = await get_item(db, Category, item_id)
    if item.kind != body.kind:
        raise HTTPException(409, "分类类型创建后不能更改")
    item.name, item.kind = body.name, body.kind
    try:
        await db.commit()
    except IntegrityError:
        await db.rollback()
        raise HTTPException(409, "分类已存在") from None
    return result(out(item))


@router.delete("/categories/{item_id}")
async def delete_category(item_id: int, db: AsyncSession = Depends(get_db)):
    item = await get_item(db, Category, item_id)
    try:
        await db.delete(item)
        await db.commit()
    except IntegrityError:
        await db.rollback()
        raise HTTPException(409, "分类已被交易使用") from None
    return result({"deleted": True})


@router.get("/transactions")
async def transactions(
    month: str,
    currency: str | None = None,
    limit: int = 100,
    offset: int = 0,
    db: AsyncSession = Depends(get_db),
):
    start, end = month_range(month)
    if (
        not 1 <= limit <= 200
        or offset < 0
        or (currency is not None and not re.fullmatch(r"[A-Z]{3}", currency))
    ):
        raise HTTPException(422, "查询参数无效")
    query = select(Transaction).where(
        Transaction.occurred_on >= start, Transaction.occurred_on < end
    )
    if currency:
        query = query.where(Transaction.currency == currency)
    items = (
        await db.scalars(
            query.order_by(Transaction.occurred_on.desc(), Transaction.id.desc())
            .limit(limit)
            .offset(offset)
        )
    ).all()
    return result([out(x) for x in items])


@router.post("/transactions")
async def create_transaction(body: TransactionInput, db: AsyncSession = Depends(get_db)):
    await check_category(db, body.category_id, body.kind)
    item = Transaction(**body.model_dump())
    db.add(item)
    await db.commit()
    return result(out(item))


@router.get("/transactions/{item_id}")
async def get_transaction(item_id: int, db: AsyncSession = Depends(get_db)):
    return result(out(await get_item(db, Transaction, item_id)))


@router.put("/transactions/{item_id}")
async def update_transaction(
    item_id: int, body: TransactionInput, db: AsyncSession = Depends(get_db)
):
    item = await get_item(db, Transaction, item_id)
    if await db.scalar(select(Payment.id).where(Payment.transaction_id == item_id)):
        raise HTTPException(409, "订阅付款关联的交易不可修改")
    await check_category(db, body.category_id, body.kind)
    for key, value in body.model_dump().items():
        setattr(item, key, value)
    await db.commit()
    return result(out(item))


@router.delete("/transactions/{item_id}")
async def delete_transaction(item_id: int, db: AsyncSession = Depends(get_db)):
    item = await get_item(db, Transaction, item_id)
    try:
        await db.delete(item)
        await db.commit()
    except IntegrityError:
        await db.rollback()
        raise HTTPException(409, "订阅付款关联的交易不可删除") from None
    return result({"deleted": True})


@router.put("/budgets/{month}")
async def set_budget(month: str, body: BudgetInput, db: AsyncSession = Depends(get_db)):
    month_range(month)
    item = await db.scalar(
        select(Budget).where(Budget.month == month, Budget.currency == body.currency)
    )
    if item is None:
        item = Budget(month=month, **body.model_dump())
        db.add(item)
    else:
        item.amount_minor = body.amount_minor
    try:
        await db.commit()
    except IntegrityError:
        await db.rollback()
        raise HTTPException(409, "预算已被更新，请重试") from None
    return result(out(item))


@router.get("/budgets/{month}")
async def get_budget(month: str, currency: str, db: AsyncSession = Depends(get_db)):
    month_range(month)
    if not re.fullmatch(r"[A-Z]{3}", currency):
        raise HTTPException(422, "币种无效")
    item = await db.scalar(select(Budget).where(Budget.month == month, Budget.currency == currency))
    return result(out(item) if item else None)


@router.get("/summary")
async def summary(month: str, currency: str, db: AsyncSession = Depends(get_db)):
    start, end = month_range(month)
    if not re.fullmatch(r"[A-Z]{3}", currency):
        raise HTTPException(422, "币种无效")
    rows = (
        await db.execute(
            select(Transaction.kind, func.sum(Transaction.amount_minor))
            .where(
                Transaction.occurred_on >= start,
                Transaction.occurred_on < end,
                Transaction.currency == currency,
            )
            .group_by(Transaction.kind)
        )
    ).all()
    totals = dict(rows)
    budget = await db.scalar(
        select(Budget).where(Budget.month == month, Budget.currency == currency)
    )
    expense = totals.get("expense", 0)
    return result(
        {
            "month": month,
            "currency": currency,
            "income_minor": totals.get("income", 0),
            "expense_minor": expense,
            "budget_minor": budget.amount_minor if budget else None,
            "remaining_minor": budget.amount_minor - expense if budget else None,
        }
    )


@router.get("/subscriptions")
async def subscriptions(db: AsyncSession = Depends(get_db)):
    return result(
        [
            out(x)
            for x in (
                await db.scalars(
                    select(Subscription).order_by(Subscription.next_due_date, Subscription.id)
                )
            ).all()
        ]
    )


@router.post("/subscriptions")
async def create_subscription(body: SubscriptionInput, db: AsyncSession = Depends(get_db)):
    item = Subscription(**body.model_dump())
    db.add(item)
    await db.commit()
    return result(out(item))


@router.get("/subscriptions/{item_id}")
async def get_subscription(item_id: int, db: AsyncSession = Depends(get_db)):
    return result(out(await get_item(db, Subscription, item_id)))


@router.put("/subscriptions/{item_id}")
async def update_subscription(
    item_id: int, body: SubscriptionInput, db: AsyncSession = Depends(get_db)
):
    item = await get_item(db, Subscription, item_id)
    changed = await db.execute(
        update(Subscription)
        .where(Subscription.id == item_id, *subscription_snapshot_conditions(item))
        .values(**body.model_dump())
    )
    if changed.rowcount != 1:
        await db.rollback()
        raise HTTPException(409, "订阅已被更新，请重试")
    await db.commit()
    return result(out(item))


@router.delete("/subscriptions/{item_id}")
async def delete_subscription(item_id: int, db: AsyncSession = Depends(get_db)):
    item = await get_item(db, Subscription, item_id)
    try:
        await db.delete(item)
        await db.commit()
    except IntegrityError:
        await db.rollback()
        raise HTTPException(409, "已有付款记录，请改为结束订阅") from None
    return result({"deleted": True})


@router.get("/subscriptions/{item_id}/payments")
async def payments(item_id: int, db: AsyncSession = Depends(get_db)):
    await get_item(db, Subscription, item_id)
    items = (
        await db.scalars(
            select(Payment)
            .where(Payment.subscription_id == item_id)
            .order_by(Payment.period_date.desc())
        )
    ).all()
    return result([out(x) for x in items])


async def matches_payment(db, payment, item_id, body):
    if (
        payment.subscription_id != item_id
        or payment.period_date != body.period_date
        or payment.paid_on != body.paid_on
    ):
        return False
    transaction = await db.get(Transaction, payment.transaction_id)
    return transaction is not None and transaction.category_id == body.category_id


@router.post("/subscriptions/{item_id}/payments")
async def pay(
    item_id: int,
    body: PaymentInput,
    idempotency_key: str = Header(alias="Idempotency-Key", min_length=1, max_length=128),
    db: AsyncSession = Depends(get_db),
):
    existing = await db.scalar(select(Payment).where(Payment.idempotency_key == idempotency_key))
    if existing:
        if not await matches_payment(db, existing, item_id, body):
            raise HTTPException(409, "幂等键已用于其他付款")
        return result(out(existing))
    sub = await get_item(db, Subscription, item_id)
    if sub.status != "active" or sub.next_due_date != body.period_date:
        existing = await db.scalar(
            select(Payment).where(Payment.idempotency_key == idempotency_key)
        )
        if existing and await matches_payment(db, existing, item_id, body):
            return result(out(existing))
        raise HTTPException(409, "订阅状态或账期已变化")
    await check_category(db, body.category_id, "expense")
    try:
        following = next_due(sub.next_due_date, sub.anchor_date, sub.cycle, sub.interval_count)
    except (OverflowError, ValueError):
        raise HTTPException(422, "下次续费日期超出范围") from None
    # Conditional update serializes competing confirmations for the same period.
    changed = await db.execute(
        update(Subscription)
        .where(
            Subscription.id == item_id,
            Subscription.next_due_date == body.period_date,
            Subscription.status == "active",
            *subscription_snapshot_conditions(sub),
        )
        .values(next_due_date=following)
    )
    if changed.rowcount != 1:
        await db.rollback()
        existing = await db.scalar(
            select(Payment).where(Payment.idempotency_key == idempotency_key)
        )
        if existing and await matches_payment(db, existing, item_id, body):
            return result(out(existing))
        raise HTTPException(409, "账期已被处理")
    transaction = Transaction(
        kind="expense",
        amount_minor=sub.amount_minor,
        currency=sub.currency,
        category_id=body.category_id,
        occurred_on=body.paid_on,
        note="",
    )
    db.add(transaction)
    try:
        await db.flush()
        payment = Payment(
            subscription_id=item_id,
            transaction_id=transaction.id,
            period_date=body.period_date,
            idempotency_key=idempotency_key,
            subscription_name=sub.name,
            paid_on=body.paid_on,
        )
        db.add(payment)
        await db.commit()
    except IntegrityError:
        await db.rollback()
        existing = await db.scalar(
            select(Payment).where(Payment.idempotency_key == idempotency_key)
        )
        if existing and await matches_payment(db, existing, item_id, body):
            return result(out(existing))
        raise HTTPException(409, "付款已记录或幂等键冲突") from None
    return result(out(payment))
