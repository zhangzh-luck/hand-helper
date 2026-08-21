from functools import lru_cache
from pathlib import Path
from pydantic_settings import BaseSettings, SettingsConfigDict

PROJECT_ROOT = Path(__file__).resolve().parents[2]

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=PROJECT_ROOT / ".env", extra="ignore")
    app_admin_username: str = "admin"
    app_admin_password_hash: str = "$2b$12$invalid"
    jwt_secret: str = "development-secret-change-me-please-32-chars"
    database_url: str = "sqlite+aiosqlite:///./data/ynnu_jw_helper.db"
    # 本地开发既可能通过 localhost 打开，也可能通过 127.0.0.1 打开；两者在浏览器中是不同来源。
    cors_origins: str = "http://localhost:5173,http://127.0.0.1:5173"
    access_token_minutes: int = 15
    refresh_token_days: int = 30
    # 单用户模型配置使用独立主密钥加密；未配置时，模型分析功能保持关闭。
    ai_credential_master_key: str = ""
    # 正式环境只允许 Alembic 变更表结构；测试可显式打开以创建临时库。
    auto_create_schema: bool = False

    @property
    def cors_origin_list(self) -> list[str]:
        configured = [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]
        # Capacitor Android 使用 HTTPS localhost 作为 WebView 来源；兼容旧配置中的 HTTP localhost。
        return list(dict.fromkeys([*configured, "https://localhost", "http://localhost"]))

@lru_cache
def get_settings() -> Settings:
    return Settings()
