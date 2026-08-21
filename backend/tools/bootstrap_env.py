"""交互式初始化根目录 .env；管理员明文密码不会写入终端历史或文件。"""
from __future__ import annotations

import getpass
import secrets
from pathlib import Path

from passlib.hash import bcrypt

ROOT = Path(__file__).resolve().parents[2]
ENV_PATH = ROOT / ".env"


def read_existing() -> dict[str, str]:
    values: dict[str, str] = {}
    if not ENV_PATH.exists():
        return values
    for line in ENV_PATH.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            values[key] = value
    return values


def main() -> None:
    values = read_existing()
    default_user = values.get("APP_ADMIN_USERNAME", "admin")
    username = input(f"应用管理员用户名 [{default_user}]: ").strip() or default_user
    while True:
        password = getpass.getpass("应用管理员密码（不会回显）: ")
        confirm = getpass.getpass("再次输入密码: ")
        if len(password) < 12:
            print("密码至少需要 12 个字符。")
        elif password != confirm:
            print("两次输入不一致，请重试。")
        else:
            break
    values.update(
        {
            "APP_ADMIN_USERNAME": username,
            "APP_ADMIN_PASSWORD_HASH": bcrypt.hash(password),
            "JWT_SECRET": secrets.token_urlsafe(48),
            "DATABASE_URL": values.get("DATABASE_URL", "sqlite+aiosqlite:///./data/ynnu_jw_helper.db"),
            "CORS_ORIGINS": values.get("CORS_ORIGINS", "http://localhost:5173"),
            "ACCESS_TOKEN_MINUTES": values.get("ACCESS_TOKEN_MINUTES", "15"),
            "REFRESH_TOKEN_DAYS": values.get("REFRESH_TOKEN_DAYS", "30"),
        }
    )
    ordered = [
        "APP_ADMIN_USERNAME", "APP_ADMIN_PASSWORD_HASH", "JWT_SECRET", "DATABASE_URL", "CORS_ORIGINS",
        "ACCESS_TOKEN_MINUTES", "REFRESH_TOKEN_DAYS",
    ]
    ENV_PATH.write_text("\n".join(f"{key}={values.get(key, '')}" for key in ordered) + "\n", encoding="utf-8")
    print(f"已安全写入 {ENV_PATH}；请勿提交该文件。")


if __name__ == "__main__":
    main()
