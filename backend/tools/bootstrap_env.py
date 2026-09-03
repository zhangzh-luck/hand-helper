"""交互式初始化根目录 .env；管理员明文密码不会写入终端历史或文件。"""
from __future__ import annotations

import getpass
import secrets
from pathlib import Path

from argon2 import PasswordHasher, Type

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
    default_user = values.get("ADMIN_USERNAME", "admin")
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
            "ADMIN_USERNAME": username,
            "ADMIN_PASSWORD_HASH": PasswordHasher(type=Type.ID).hash(password),
            "SESSION_SECRET": secrets.token_urlsafe(48),
            "SESSION_MAX_AGE": values.get("SESSION_MAX_AGE", "1209600"),
            "SESSION_COOKIE_SECURE": values.get("SESSION_COOKIE_SECURE", "false"),
            "TRUST_PROXY_HEADERS": values.get("TRUST_PROXY_HEADERS", "false"),
            "DATABASE_URL": values.get("DATABASE_URL", "sqlite+aiosqlite:///./data/ynnu_jw_helper.db"),
            "CORS_ORIGINS": values.get("CORS_ORIGINS", "http://localhost:5173"),
        }
    )
    ordered = [
        "ADMIN_USERNAME", "ADMIN_PASSWORD_HASH", "SESSION_SECRET", "SESSION_MAX_AGE", "SESSION_COOKIE_SECURE",
        "TRUST_PROXY_HEADERS", "DATABASE_URL", "CORS_ORIGINS",
    ]
    # Keep unrelated settings such as AI_CREDENTIAL_MASTER_KEY. Drop only the
    # retired JWT configuration so running this helper never discards an API key.
    for key in {"APP_ADMIN_USERNAME", "APP_ADMIN_PASSWORD_HASH", "JWT_SECRET", "ACCESS_TOKEN_MINUTES", "REFRESH_TOKEN_DAYS"}:
        values.pop(key, None)
    remaining = [key for key in values if key not in ordered]
    ENV_PATH.write_text("\n".join(f"{key}={values.get(key, '')}" for key in [*ordered, *remaining]) + "\n", encoding="utf-8")
    print(f"已安全写入 {ENV_PATH}；请勿提交该文件。")


if __name__ == "__main__":
    main()
