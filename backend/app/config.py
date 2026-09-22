from functools import lru_cache
from pathlib import Path
from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

PROJECT_ROOT = Path(__file__).resolve().parents[2]

class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=PROJECT_ROOT / ".env", extra="ignore")
    # This is deliberately configuration-only: the application has no users table.
    admin_username: str = Field(min_length=1, max_length=128)
    admin_password_hash: str = Field(min_length=20)
    session_secret: str = Field(min_length=32)
    session_max_age: int = Field(default=60 * 60 * 24 * 14, ge=60 * 15, le=60 * 60 * 24 * 90)
    session_cookie_secure: bool = False
    session_cookie_name: str = "hand_helper_session"
    # Enable only behind the repository's Nginx configuration, which overwrites
    # forwarded headers at the public trust boundary.
    trust_proxy_headers: bool = False
    database_url: str = "sqlite+aiosqlite:///./data/ynnu_jw_helper.db"
    # 本地开发既可能通过 localhost 打开，也可能通过 127.0.0.1 打开；两者在浏览器中是不同来源。
    cors_origins: str = "http://localhost:5173,http://127.0.0.1:5173"
    # WebAuthn 不从请求 Host 推导 RP 信息，避免 Host header 混淆。生产环境必须
    # 显式配置为 hand.zhangzh.cc 与 https://hand.zhangzh.cc。
    webauthn_enabled: bool = True
    webauthn_rp_id: str = Field(default="localhost", min_length=1, max_length=253)
    webauthn_rp_name: str = Field(default="航的助手", min_length=1, max_length=128)
    webauthn_origins: str = "http://localhost:5173"
    webauthn_challenge_ttl: int = Field(default=300, ge=60, le=900)
    # 单用户模型配置使用独立主密钥加密；未配置时，模型分析功能保持关闭。
    ai_credential_master_key: str = ""
    # 正式环境只允许 Alembic 变更表结构；测试可显式打开以创建临时库。
    auto_create_schema: bool = False

    @property
    def cors_origin_list(self) -> list[str]:
        configured = [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]
        # Capacitor Android 使用 HTTPS localhost 作为 WebView 来源；兼容旧配置中的 HTTP localhost。
        return list(dict.fromkeys([*configured, "https://localhost", "http://localhost"]))

    @property
    def webauthn_origin_list(self) -> list[str]:
        return [origin.strip().rstrip("/") for origin in self.webauthn_origins.split(",") if origin.strip()]

    @field_validator("admin_password_hash")
    @classmethod
    def argon2id_hash_required(cls, value: str) -> str:
        if not value.startswith("$argon2id$"):
            raise ValueError("ADMIN_PASSWORD_HASH 必须是 Argon2id 哈希")
        return value

@lru_cache
def get_settings() -> Settings:
    return Settings()
