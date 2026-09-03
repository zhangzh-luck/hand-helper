"""Single-owner password, session and login-rate-limit primitives.

The raw session ID exists only in the HttpOnly browser cookie. SQLite receives a
keyed HMAC, so a copied database cannot be used as a list of valid sessions.
"""
from __future__ import annotations

import hashlib
import hmac
import ipaddress
import secrets
from collections import defaultdict, deque
from datetime import datetime, timedelta
from typing import Deque

from argon2 import PasswordHasher, Type
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError
from fastapi import Request
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db_models import AppSession

password_hasher = PasswordHasher(type=Type.ID)


def verify_admin_password(password: str) -> bool:
    """Verify the configured Argon2id hash without exposing verifier details."""
    try:
        return password_hasher.verify(get_settings().admin_password_hash, password)
    except (InvalidHashError, VerificationError, VerifyMismatchError):
        return False


def session_hash(raw_session_id: str) -> str:
    secret = get_settings().session_secret.encode("utf-8")
    return hmac.new(secret, raw_session_id.encode("utf-8"), hashlib.sha256).hexdigest()


async def create_session(db: AsyncSession) -> str:
    """Issue a fresh, high-entropy session ID after a successful password login."""
    raw_session_id = secrets.token_urlsafe(48)
    now = datetime.utcnow()
    db.add(AppSession(
        session_hash=session_hash(raw_session_id),
        expires_at=now + timedelta(seconds=get_settings().session_max_age),
        created_at=now,
    ))
    await db.commit()
    return raw_session_id


async def find_valid_session(db: AsyncSession, raw_session_id: str | None) -> AppSession | None:
    if not raw_session_id:
        return None
    now = datetime.utcnow()
    item = await db.scalar(select(AppSession).where(AppSession.session_hash == session_hash(raw_session_id)))
    if item is None:
        return None
    if item.expires_at <= now:
        await db.delete(item)
        await db.commit()
        return None
    return item


async def destroy_session(db: AsyncSession, raw_session_id: str | None) -> None:
    if raw_session_id:
        await db.execute(delete(AppSession).where(AppSession.session_hash == session_hash(raw_session_id)))
        await db.commit()


class LoginRateLimiter:
    """Small in-process limiter for one deployment instance: five failures / five minutes."""

    def __init__(self) -> None:
        self._failures: dict[tuple[str, str], Deque[datetime]] = defaultdict(deque)
        self._window = timedelta(minutes=5)
        self._limit = 5

    def _prune(self, key: tuple[str, str], now: datetime) -> Deque[datetime]:
        values = self._failures[key]
        cutoff = now - self._window
        while values and values[0] <= cutoff:
            values.popleft()
        return values

    def allowed(self, client_ip: str, username: str) -> bool:
        return len(self._prune((client_ip, username), datetime.utcnow())) < self._limit

    def record_failure(self, client_ip: str, username: str) -> None:
        self._prune((client_ip, username), datetime.utcnow()).append(datetime.utcnow())

    def clear(self, client_ip: str, username: str) -> None:
        self._failures.pop((client_ip, username), None)


login_rate_limiter = LoginRateLimiter()


def client_ip(request: Request) -> str:
    """Use forwarded client IP only after Nginx has sanitized those headers."""
    if get_settings().trust_proxy_headers:
        forwarded = request.headers.get("x-forwarded-for", "")
        candidate = forwarded.split(",", 1)[0].strip()
        try:
            return str(ipaddress.ip_address(candidate))
        except ValueError:
            pass
    return request.client.host if request.client else "unknown"


def csrf_request_is_allowed(request: Request) -> bool:
    """SameSite is the first layer; validate Origin/Referer when browsers provide it."""
    if request.method not in {"POST", "PUT", "PATCH", "DELETE"}:
        return True
    origin = request.headers.get("origin")
    if not origin:
        referer = request.headers.get("referer", "")
        if referer:
            from urllib.parse import urlsplit
            parts = urlsplit(referer)
            origin = f"{parts.scheme}://{parts.netloc}" if parts.scheme and parts.netloc else ""
    if origin:
        return origin in get_settings().cors_origin_list
    # Local HTTP development and test clients may omit both headers. Production
    # HTTPS deployments require an Origin or Referer for every state change.
    return not get_settings().session_cookie_secure
