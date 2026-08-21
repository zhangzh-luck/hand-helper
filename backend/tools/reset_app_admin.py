"""安全重置本应用管理员密码；不会触碰已导入的学习数据。"""
from __future__ import annotations

import asyncio
import getpass

from sqlalchemy import select

from app.config import get_settings
from app.db import Base, SessionLocal, engine
from app.db_models import AppUser
from app.security import pwd_context


async def main() -> None:
    settings = get_settings()
    username = input(f"管理员用户名 [{settings.app_admin_username}]: ").strip() or settings.app_admin_username
    while True:
        password = getpass.getpass("新的管理员密码（至少 12 位，不会回显）: ")
        confirm = getpass.getpass("再次输入密码: ")
        if len(password) < 12:
            print("密码至少需要 12 位。")
        elif password != confirm:
            print("两次输入不一致，请重试。")
        else:
            break
    async with engine.begin() as connection:
        await connection.run_sync(Base.metadata.create_all)
    async with SessionLocal() as db:
        user = await db.scalar(select(AppUser).where(AppUser.username == username))
        if user is None:
            db.add(AppUser(username=username, password_hash=pwd_context.hash(password)))
        else:
            user.password_hash = pwd_context.hash(password)
        await db.commit()
    await engine.dispose()
    print("管理员密码已重置。")


if __name__ == "__main__":
    asyncio.run(main())
