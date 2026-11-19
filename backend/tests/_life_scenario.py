"""Life tests use a newly migrated temporary DB, never the developer database."""

import os
import subprocess
import sqlite3
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import date
from pathlib import Path

from argon2 import PasswordHasher
from fastapi.testclient import TestClient
import pytest
from sqlalchemy import event
from sqlalchemy.exc import IntegrityError


@pytest.fixture(scope="module")
def client(tmp_path_factory):
    root = Path(__file__).resolve().parents[1]
    db = tmp_path_factory.mktemp("life_mvp") / "life.sqlite"
    os.environ.update(
        {
            "ADMIN_USERNAME": "life-test",
            "ADMIN_PASSWORD_HASH": PasswordHasher().hash("temporary-password"),
            "SESSION_SECRET": "test-only-session-secret-1234567890123456",
            "DATABASE_URL": f"sqlite+aiosqlite:///{db.as_posix()}",
            "AUTO_CREATE_SCHEMA": "false",
        }
    )
    environment = {**os.environ, "PYTHONPATH": str(root)}
    subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "0017_harden_grade_ai_job_leases"],
        cwd=root,
        check=True,
        env=environment,
    )
    with sqlite3.connect(db) as connection:
        connection.execute(
            "INSERT INTO app_profiles (id, display_name, created_at, updated_at) VALUES (1, 'migration sentinel', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
        )
    subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"], cwd=root, check=True, env=environment
    )
    with sqlite3.connect(db) as connection:
        assert connection.execute(
            "SELECT display_name FROM app_profiles WHERE id=1"
        ).fetchone() == ("migration sentinel",)
        assert connection.execute("SELECT version_num FROM alembic_version").fetchone() == (
            "0018_life_mvp",
        )
    from app.main import app

    with TestClient(app) as test_client:
        yield test_client


def test_cycles(client):
    from app.life import next_due

    assert next_due(date(2024, 1, 31), date(2024, 1, 31), "month", 1) == date(2024, 2, 29)
    assert next_due(date(2024, 2, 29), date(2024, 1, 31), "month", 1) == date(2024, 3, 31)
    assert next_due(date(2024, 2, 29), date(2024, 2, 29), "year", 1) == date(2025, 2, 28)
    assert next_due(date(2025, 2, 28), date(2024, 2, 29), "year", 3) == date(2028, 2, 29)


def test_validation_and_transaction_crud(client):
    base = "/api/v1/life"
    assert (
        client.post(
            "/api/v1/auth/login", json={"username": "life-test", "password": "temporary-password"}
        ).status_code
        == 200
    )
    category = client.post(base + "/categories", json={"name": "salary", "kind": "income"}).json()[
        "data"
    ]
    cid = category["id"]
    item = {
        "kind": "income",
        "amount_minor": 999,
        "currency": "USD",
        "occurred_on": "2025-12-31",
        "category_id": cid,
    }
    response = client.post(base + "/transactions", json=item)
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store, private"
    tid = response.json()["data"]["id"]
    assert (
        client.put(base + f"/transactions/{tid}", json={**item, "amount_minor": 1000}).status_code
        == 200
    )
    assert client.get(base + f"/transactions/{tid}").json()["data"]["amount_minor"] == 1000
    assert (
        client.put(
            base + f"/categories/{cid}", json={"name": "salary", "kind": "expense"}
        ).status_code
        == 409
    )
    assert client.delete(base + f"/transactions/{tid}").status_code == 200
    assert client.delete(base + f"/categories/{cid}").status_code == 200
    sub = {
        "name": "bad",
        "amount_minor": 1,
        "currency": "USD",
        "cycle": "month",
        "interval_count": 1,
        "anchor_date": "2024-01-31",
        "next_due_date": "2024-02-28",
        "reminder_days": 1,
        "status": "active",
        "timezone": "UTC",
    }
    assert client.post(base + "/subscriptions", json=sub).status_code == 422
    sub["next_due_date"] = "2024-02-29"
    sub["timezone"] = "Not/A_Real_Zone"
    assert client.post(base + "/subscriptions", json=sub).status_code == 422
    sub["timezone"] = "UTC"
    sub["status"] = "paused"
    response = client.post(base + "/subscriptions", json=sub)
    assert response.status_code == 200
    sid = response.json()["data"]["id"]
    assert (
        client.post(
            base + f"/subscriptions/{sid}/payments",
            json={"period_date": "2024-02-29", "paid_on": "2024-02-29"},
            headers={"Idempotency-Key": "paused-subscription"},
        ).status_code
        == 409
    )


def test_life_api(client):
    base = "/api/v1/life"
    client.cookies.clear()
    assert client.get(base + "/categories").status_code == 401
    assert (
        client.post(
            "/api/v1/auth/login", json={"username": "life-test", "password": "temporary-password"}
        ).status_code
        == 200
    )
    category = client.post(base + "/categories", json={"name": "测试", "kind": "expense"}).json()[
        "data"
    ]
    txn = {
        "kind": "expense",
        "amount_minor": 123,
        "currency": "CNY",
        "occurred_on": "2024-02-29",
        "category_id": category["id"],
    }
    assert client.post(base + "/transactions", json={**txn, "amount_minor": 1.5}).status_code == 422
    assert client.post(base + "/transactions", json=txn).status_code == 200
    assert (
        client.post(base + "/transactions", json={**txn, "occurred_on": "2024-03-01"}).status_code
        == 200
    )
    assert client.post(base + "/transactions", json={**txn, "currency": "USD"}).status_code == 200
    assert (
        client.put(
            base + "/budgets/2024-02", json={"currency": "CNY", "amount_minor": 100}
        ).status_code
        == 200
    )
    summary = client.get(base + "/summary", params={"month": "2024-02", "currency": "CNY"}).json()[
        "data"
    ]
    assert (summary["expense_minor"], summary["remaining_minor"]) == (123, -23)
    assert (
        client.get(base + "/summary", params={"month": "2024-13", "currency": "CNY"}).status_code
        == 422
    )
    assert client.delete(base + f"/categories/{category['id']}").status_code == 409
    sub = {
        "name": "测试订阅",
        "amount_minor": 599,
        "currency": "CNY",
        "cycle": "month",
        "interval_count": 1,
        "anchor_date": "2024-01-31",
        "next_due_date": "2024-02-29",
        "reminder_days": 3,
        "status": "active",
        "timezone": "UTC",
    }
    response = client.post(base + "/subscriptions", json=sub)
    assert response.status_code == 200, response.text
    sub_id = response.json()["data"]["id"]
    endpoint = base + f"/subscriptions/{sub_id}/payments"
    payment = {"period_date": "2024-02-29", "paid_on": "2024-02-28", "category_id": category["id"]}
    headers = {"Idempotency-Key": "life-test-payment-1"}
    first = client.post(endpoint, json=payment, headers=headers)
    assert first.status_code == 200, first.text
    again = client.post(endpoint, json=payment, headers=headers)
    assert again.status_code == 200 and again.json()["data"]["id"] == first.json()["data"]["id"]
    assert (
        client.post(
            endpoint, json={**payment, "paid_on": "2024-02-29"}, headers=headers
        ).status_code
        == 409
    )
    assert (
        client.post(
            endpoint, json=payment, headers={"Idempotency-Key": "different-key"}
        ).status_code
        == 409
    )
    assert (
        client.get(base + f"/subscriptions/{sub_id}").json()["data"]["next_due_date"]
        == "2024-03-31"
    )
    transaction_id = first.json()["data"]["transaction_id"]
    assert client.delete(base + f"/transactions/{transaction_id}").status_code == 409
    assert client.put(base + f"/transactions/{transaction_id}", json=txn).status_code == 409
    assert client.delete(base + f"/subscriptions/{sub_id}").status_code == 409
    summary = client.get(base + "/summary", params={"month": "2024-02", "currency": "CNY"}).json()[
        "data"
    ]
    assert summary["expense_minor"] == 722


def test_ios_read_contracts(client):
    client.cookies.clear()
    assert (
        client.post(
            "/api/v1/auth/login", json={"username": "life-test", "password": "temporary-password"}
        ).status_code
        == 200
    )
    base = "/api/v1/life"
    categories = client.get(base + "/categories").json()["data"]
    assert categories and {"id", "name", "kind"} <= categories[0].keys()
    response = client.get(
        base + "/transactions",
        params={"month": "2024-02", "currency": "CNY", "limit": 200, "offset": 0},
    )
    assert response.status_code == 200
    records = response.json()["data"]
    assert (
        records
        and {"id", "kind", "amount_minor", "currency", "category_id", "occurred_on", "note"}
        <= records[0].keys()
    )
    budget = client.get(base + "/budgets/2024-02", params={"currency": "CNY"}).json()["data"]
    assert budget["amount_minor"] == 100
    assert client.get(base + "/budgets/2024-02", params={"currency": "JPY"}).json()["data"] is None
    subscriptions = client.get(base + "/subscriptions").json()["data"]
    assert (
        subscriptions
        and {"id", "name", "amount_minor", "currency", "next_due_date", "status"}
        <= subscriptions[0].keys()
    )


def test_concurrent_confirmation(client):
    base = "/api/v1/life"
    sub = {
        "name": "并发测试",
        "amount_minor": 101,
        "currency": "USD",
        "cycle": "month",
        "interval_count": 1,
        "anchor_date": "2024-01-31",
        "next_due_date": "2024-01-31",
        "reminder_days": 0,
        "status": "active",
        "timezone": "UTC",
    }
    sub_id = client.post(base + "/subscriptions", json=sub).json()["data"]["id"]
    endpoint = base + f"/subscriptions/{sub_id}/payments"
    body = {"period_date": "2024-01-31", "paid_on": "2024-01-31"}
    with ThreadPoolExecutor(max_workers=4) as executor:
        responses = list(
            executor.map(
                lambda _: client.post(
                    endpoint, json=body, headers={"Idempotency-Key": "life-concurrent-test"}
                ),
                range(4),
            )
        )
    assert all(r.status_code == 200 for r in responses), [
        (r.status_code, r.text) for r in responses
    ]
    assert len({r.json()["data"]["id"] for r in responses}) == 1
    items = client.get(base + f"/subscriptions/{sub_id}/payments").json()["data"]
    assert len(items) == 1


def test_payment_insert_failure_rolls_back_ledger_and_due_date(client):
    from app.life_models import Payment

    base = "/api/v1/life"
    sub = {
        "name": "rollback test",
        "amount_minor": 501,
        "currency": "EUR",
        "cycle": "month",
        "interval_count": 1,
        "anchor_date": "2024-04-30",
        "next_due_date": "2024-04-30",
        "reminder_days": 0,
        "status": "active",
        "timezone": "UTC",
    }
    sub_id = client.post(base + "/subscriptions", json=sub).json()["data"]["id"]
    body = {"period_date": "2024-04-30", "paid_on": "2024-04-30"}

    def fail_insert(_mapper, _connection, _target):
        raise IntegrityError("injected", {}, Exception("test-only"))

    event.listen(Payment, "before_insert", fail_insert)
    try:
        response = client.post(
            base + f"/subscriptions/{sub_id}/payments",
            json=body,
            headers={"Idempotency-Key": "rollback-test"},
        )
        assert response.status_code == 409
    finally:
        event.remove(Payment, "before_insert", fail_insert)
    assert (
        client.get(base + f"/subscriptions/{sub_id}").json()["data"]["next_due_date"]
        == "2024-04-30"
    )
    assert (
        client.get(base + "/transactions", params={"month": "2024-04", "currency": "EUR"}).json()[
            "data"
        ]
        == []
    )
