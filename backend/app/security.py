from __future__ import annotations
import hashlib
import secrets
from datetime import datetime, timedelta, timezone
import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from passlib.context import CryptContext
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from app.config import get_settings
from app.db import get_db
from app.db_models import AppUser, RefreshToken

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
bearer = HTTPBearer(auto_error=False)

def hash_refresh(token: str) -> str: return hashlib.sha256(token.encode()).hexdigest()
def create_access_token(user: AppUser) -> str:
    settings = get_settings()
    return jwt.encode({"sub": str(user.id), "exp": datetime.now(timezone.utc) + timedelta(minutes=settings.access_token_minutes)}, settings.jwt_secret, algorithm="HS256")
async def create_token_pair(db: AsyncSession, user: AppUser) -> tuple[str, str]:
    refresh = secrets.token_urlsafe(48)
    db.add(RefreshToken(token_hash=hash_refresh(refresh), user_id=user.id, expires_at=datetime.utcnow() + timedelta(days=get_settings().refresh_token_days)))
    await db.commit()
    return create_access_token(user), refresh
async def current_user(credentials: HTTPAuthorizationCredentials | None = Depends(bearer), db: AsyncSession = Depends(get_db)) -> AppUser:
    if credentials is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "未提供访问令牌")
    try:
        payload = jwt.decode(credentials.credentials, get_settings().jwt_secret, algorithms=["HS256"])
        user_id = int(payload["sub"])
    except (jwt.InvalidTokenError, KeyError, ValueError):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "访问令牌无效") from None
    user = await db.get(AppUser, user_id)
    if not user:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "用户不存在")
    return user
