from __future__ import annotations
from collections.abc import AsyncGenerator
from pathlib import Path
from sqlalchemy import event
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase
from app.config import get_settings

class Base(DeclarativeBase):
    pass

database_url = get_settings().database_url
if database_url.startswith("sqlite+") and ":///./" in database_url:
    Path(database_url.rsplit("///./", 1)[1]).parent.mkdir(parents=True, exist_ok=True)
engine = create_async_engine(database_url, future=True)

@event.listens_for(engine.sync_engine, "connect")
def enable_sqlite_wal(connection, _record) -> None:  # type: ignore[no-untyped-def]
    cursor = connection.cursor()
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA foreign_keys=ON")
    cursor.close()

SessionLocal = async_sessionmaker(engine, expire_on_commit=False)

async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with SessionLocal() as session:
        yield session
