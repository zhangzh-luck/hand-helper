"""第三方模型成绩分析：配置加密、最小化传输与结果缓存。"""
from __future__ import annotations

import hashlib
import ipaddress
import json
from datetime import datetime
from urllib.parse import urlparse

import httpx
from cryptography.fernet import Fernet, InvalidToken
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db_models import AiProviderSetting, Grade, GradeAiAnalysis
from app.schemas import AiModelLookupInput, AiModelSelectionInput, AiProviderSettingInput, AiProviderSettingOut, GradeAiAnalysisHistoryOut, GradeAiAnalysisOut


class AiConfigurationError(ValueError):
    pass


class AiServiceError(RuntimeError):
    pass


LEGACY_APIKEY_FUN_PROVIDER = "APIKEY.FUN"
LEGACY_APIKEY_FUN_BASE_URL = "https://api.apikey.fun/v1"
APIKEY_FAN_PROVIDER = "APIKEY.FAN"
APIKEY_FAN_BASE_URL = "https://api.apikey.fan/v1"


def _is_legacy_apikey_fun(setting: AiProviderSetting) -> bool:
    return (
        setting.provider.strip().upper() == LEGACY_APIKEY_FUN_PROVIDER
        and setting.base_url.strip().rstrip("/").lower() == LEGACY_APIKEY_FUN_BASE_URL
    )


def _fernet() -> Fernet:
    key = get_settings().ai_credential_master_key.strip()
    if not key:
        raise AiConfigurationError("尚未配置 AI_CREDENTIAL_MASTER_KEY，无法安全保存模型密钥")
    try:
        return Fernet(key.encode("utf-8"))
    except (ValueError, TypeError) as exc:
        raise AiConfigurationError("AI_CREDENTIAL_MASTER_KEY 格式无效") from exc


def _validate_base_url(base_url: str) -> str:
    normalized = base_url.strip().rstrip("/")
    parsed = urlparse(normalized)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise AiConfigurationError("模型服务地址必须是无账号信息的 HTTPS 地址")
    host = parsed.hostname.lower()
    if host == "localhost" or host.endswith(".local"):
        raise AiConfigurationError("不允许使用本地模型服务地址")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        address = None
    if address is not None and not address.is_global:
        raise AiConfigurationError("不允许使用内网或本机模型服务地址")
    return normalized


def _chat_endpoint(base_url: str) -> str:
    url = _validate_base_url(base_url)
    return url if url.endswith("/chat/completions") else f"{url}/chat/completions"


def _models_endpoint(base_url: str) -> str:
    url = _validate_base_url(base_url)
    return url if url.endswith("/models") else f"{url}/models"


def _key_hint(api_key: str) -> str:
    tail = api_key.strip()[-4:]
    return f"****{tail}" if tail else "已配置"


def _stored_models(setting: AiProviderSetting) -> list[str]:
    """Read a defensive, bounded model list from SQLite's JSON text column."""
    try:
        raw_models = json.loads(setting.available_models_json or "[]")
    except (TypeError, ValueError):
        return []
    if not isinstance(raw_models, list):
        return []
    models: list[str] = []
    seen: set[str] = set()
    for item in raw_models:
        if not isinstance(item, str):
            continue
        model = item.strip()
        if not model or len(model) > 128 or model in seen:
            continue
        seen.add(model)
        models.append(model)
        if len(models) >= 200:
            break
    return models


def _store_models(setting: AiProviderSetting, models: list[str]) -> None:
    setting.available_models_json = json.dumps(models[:200], ensure_ascii=False, separators=(",", ":"))
    setting.models_synced_at = datetime.utcnow()


def _decrypt_saved_api_key(setting: AiProviderSetting) -> str:
    fernet = _fernet()
    try:
        return fernet.decrypt(setting.encrypted_api_key.encode("ascii")).decode("utf-8")
    except (InvalidToken, UnicodeDecodeError) as exc:
        raise AiConfigurationError("已保存的模型密钥无法解密，请重新配置") from exc


def _grade_snapshot(grades: list[Grade]) -> tuple[str, list[dict[str, object]]]:
    items = [
        {
            "course_name": grade.course_name,
            "course_type": grade.course_type,
            "credits": grade.credits,
            "score": grade.score,
            "final_exam_score": grade.final_exam_score,
            "usual_score": grade.usual_score,
            "grade_point": grade.grade_point,
            "exam_type": grade.exam_type,
            "makeup": grade.makeup_flag,
            "retake": grade.retake_flag,
        }
        for grade in sorted(grades, key=lambda row: (row.course_name, row.course_code, row.id))
    ]
    canonical = repr(items).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest(), items


def _analysis_messages(items: list[dict[str, object]]) -> list[dict[str, str]]:
    return [
        {
            "role": "system",
            "content": (
                "你是仅供学生本人使用的成绩分析助手。只根据用户提供的课程成绩进行中文分析，"
                "不要臆测未提供的信息，不要输出医疗、心理诊断或绝对化结论。"
                "必须仅使用 Markdown 输出四个二级标题：‘整体概览’、‘优势课程’、‘需要关注’、‘可执行建议’。"
                "每个小节最多 2 条无嵌套的短列表，总长度控制在 500 个汉字以内；可用 **粗体** 强调关键成绩。"
                "不要使用表格、代码块、引用、HTML 或标题以外的额外开场白。内容应简洁、鼓励且具体。"
            ),
        },
        {
            "role": "user",
            "content": f"请分析以下一学期的已脱敏成绩记录：{items}",
        },
    ]


async def _post_openai_compatible(
    endpoint: str,
    api_key: str,
    model: str,
    messages: list[dict[str, str]],
    *,
    max_tokens: int | None = None,
) -> str:
    payload: dict[str, object] = {"model": model, "messages": messages, "temperature": 0.3}
    if max_tokens is not None:
        payload["max_tokens"] = max_tokens
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(35.0, connect=10.0), follow_redirects=False) as client:
            result = await client.post(
                endpoint,
                headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                json=payload,
            )
    except httpx.HTTPError as exc:
        raise AiServiceError("无法连接模型服务，请检查地址、网络和服务状态") from exc
    if result.status_code in {401, 403}:
        raise AiServiceError("模型服务认证失败，请检查 API Key")
    if result.status_code == 404:
        raise AiServiceError("模型服务未找到 Chat Completions 接口，请检查服务地址")
    if result.status_code == 429:
        raise AiServiceError("模型服务请求过于频繁或额度不足，请稍后再试")
    if result.status_code >= 500:
        raise AiServiceError("模型服务暂时不可用，请稍后再试")
    if result.status_code >= 400:
        raise AiServiceError("模型服务拒绝了请求，请检查模型名称与服务配置")
    try:
        content = result.json()["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError, ValueError) as exc:
        raise AiServiceError("模型服务返回格式异常") from exc
    if not isinstance(content, str) or not content.strip():
        raise AiServiceError("模型服务未返回有效分析内容")
    return content.strip()[:8000]


async def _get_openai_compatible_models(endpoint: str, api_key: str) -> list[str]:
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(20.0, connect=8.0), follow_redirects=False) as client:
            result = await client.get(endpoint, headers={"Authorization": f"Bearer {api_key}"})
    except httpx.HTTPError as exc:
        raise AiServiceError("无法连接模型服务，请检查地址、网络和服务状态") from exc
    if result.status_code in {401, 403}:
        raise AiServiceError("模型服务认证失败，请检查 API Key")
    if result.status_code == 404:
        raise AiServiceError("模型服务未提供模型列表接口，请手动填写模型名称")
    if result.status_code == 429:
        raise AiServiceError("模型服务请求过于频繁或额度不足，请稍后再试")
    if result.status_code >= 500:
        raise AiServiceError("模型服务暂时不可用，请稍后再试")
    if result.status_code >= 400:
        raise AiServiceError("模型服务拒绝了模型列表请求，请检查服务配置")
    try:
        raw_models = result.json().get("data", [])
    except (AttributeError, ValueError) as exc:
        raise AiServiceError("模型服务返回的模型列表格式异常") from exc
    if not isinstance(raw_models, list):
        raise AiServiceError("模型服务返回的模型列表格式异常")
    models: list[str] = []
    seen: set[str] = set()
    for item in raw_models:
        model_id = item.get("id") if isinstance(item, dict) else item if isinstance(item, str) else None
        if not isinstance(model_id, str):
            continue
        model_id = model_id.strip()
        if not model_id or len(model_id) > 128 or model_id in seen:
            continue
        seen.add(model_id)
        models.append(model_id)
        if len(models) >= 200:
            break
    if not models:
        raise AiServiceError("模型服务未返回可用模型，请手动填写模型名称")
    return models


async def list_available_models(body: AiModelLookupInput) -> list[str]:
    """临时使用页面提交的密钥读取模型 ID；不写数据库。"""
    api_key = body.api_key.strip()
    if not api_key:
        raise AiConfigurationError("请输入 API Key 后再读取模型")
    return await _get_openai_compatible_models(_models_endpoint(body.base_url), api_key)


async def test_ai_connection(body: AiProviderSettingInput) -> dict[str, str]:
    """用固定短文本验证 Chat Completions 配置；不会读取或发送成绩。"""
    api_key = body.api_key.strip()
    if not api_key:
        raise AiConfigurationError("请输入 API Key 后再测试连接")
    await _post_openai_compatible(
        _chat_endpoint(body.base_url),
        api_key,
        body.model.strip(),
        [
            {"role": "system", "content": "你正在执行模型服务连通性测试。"},
            {"role": "user", "content": "请只回复：连接成功"},
        ],
        max_tokens=16,
    )
    return {"message": "模型服务连接成功，尚未保存配置", "provider": body.provider.strip(), "model": body.model.strip()}


def setting_out(setting: AiProviderSetting | None) -> AiProviderSettingOut:
    if setting is None:
        return AiProviderSettingOut(configured=False)
    return AiProviderSettingOut(
        configured=True,
        provider=setting.provider,
        base_url=setting.base_url,
        model=setting.model,
        api_key_hint=setting.api_key_hint,
        available_models=_stored_models(setting),
        models_synced_at=setting.models_synced_at,
        is_enabled=setting.is_enabled,
        requires_apikey_fan_migration=_is_legacy_apikey_fun(setting),
    )


async def save_ai_setting(db: AsyncSession, body: AiProviderSettingInput) -> AiProviderSettingOut:
    fernet = _fernet()
    base_url = _validate_base_url(body.base_url)
    api_key = body.api_key.strip()
    models = await _get_openai_compatible_models(_models_endpoint(base_url), api_key)
    selected_model = body.model.strip()
    if selected_model not in models:
        raise AiConfigurationError("请选择当前 API Key 可用模型列表中的模型")
    setting = await db.get(AiProviderSetting, 1)
    if setting is None:
        setting = AiProviderSetting(id=1, provider=body.provider.strip(), base_url=base_url, model=body.model.strip(), encrypted_api_key="", api_key_hint="")
        db.add(setting)
    setting.provider = body.provider.strip()
    setting.base_url = base_url
    setting.model = selected_model
    setting.encrypted_api_key = fernet.encrypt(api_key.encode("utf-8")).decode("ascii")
    setting.api_key_hint = _key_hint(api_key)
    _store_models(setting, models)
    setting.is_enabled = True
    await db.commit()
    await db.refresh(setting)
    return setting_out(setting)


async def refresh_saved_models(db: AsyncSession) -> AiProviderSettingOut:
    """Refresh a saved provider's model cache without returning its encrypted API key."""
    setting = await db.get(AiProviderSetting, 1)
    if setting is None or not setting.is_enabled:
        raise AiConfigurationError("请先保存模型服务配置")
    models = await _get_openai_compatible_models(_models_endpoint(setting.base_url), _decrypt_saved_api_key(setting))
    _store_models(setting, models)
    if setting.model not in models:
        setting.model = models[0]
    await db.commit()
    await db.refresh(setting)
    return setting_out(setting)


async def migrate_legacy_apikey_fun_setting(db: AsyncSession) -> AiProviderSettingOut:
    """Safely move the retired APIKEY.FUN preset only after the new API accepts its saved key."""
    setting = await db.get(AiProviderSetting, 1)
    if setting is None or not setting.is_enabled:
        raise AiConfigurationError("请先保存模型服务配置")
    if not _is_legacy_apikey_fun(setting):
        raise AiConfigurationError("当前配置不是需要迁移的 APIKEY.FUN 预设")
    models = await _get_openai_compatible_models(
        _models_endpoint(APIKEY_FAN_BASE_URL),
        _decrypt_saved_api_key(setting),
    )
    setting.provider = APIKEY_FAN_PROVIDER
    setting.base_url = APIKEY_FAN_BASE_URL
    if setting.model not in models:
        setting.model = models[0]
    _store_models(setting, models)
    await db.commit()
    await db.refresh(setting)
    return setting_out(setting)


async def select_saved_model(db: AsyncSession, body: AiModelSelectionInput) -> AiProviderSettingOut:
    setting = await db.get(AiProviderSetting, 1)
    if setting is None or not setting.is_enabled:
        raise AiConfigurationError("请先保存模型服务配置")
    model = body.model.strip()
    if model not in _stored_models(setting):
        raise AiConfigurationError("该模型不在当前供应商已缓存的可用列表中，请先刷新模型")
    setting.model = model
    await db.commit()
    await db.refresh(setting)
    return setting_out(setting)


async def delete_ai_setting(db: AsyncSession) -> None:
    setting = await db.get(AiProviderSetting, 1)
    if setting is not None:
        await db.delete(setting)
        await db.commit()


async def analyze_grades(db: AsyncSession, term_id: int, force_refresh: bool = False) -> GradeAiAnalysisOut:
    setting = await db.get(AiProviderSetting, 1)
    if setting is None or not setting.is_enabled:
        raise AiConfigurationError("请先在设置中配置模型服务")
    api_key = _decrypt_saved_api_key(setting)
    grades = (await db.scalars(select(Grade).where(Grade.term_id == term_id))).all()
    if not grades:
        raise AiServiceError("该学期尚无导入成绩，无法分析")
    input_hash, items = _grade_snapshot(grades)
    existing = await db.scalar(select(GradeAiAnalysis).where(GradeAiAnalysis.term_id == term_id, GradeAiAnalysis.input_hash == input_hash))
    if existing is not None and not force_refresh:
        return GradeAiAnalysisOut(term_id=term_id, content=existing.content, provider=existing.provider, model=existing.model, created_at=existing.created_at, cached=True)
    content = await _post_openai_compatible(_chat_endpoint(setting.base_url), api_key, setting.model, _analysis_messages(items))
    if existing is None:
        existing = GradeAiAnalysis(term_id=term_id, input_hash=input_hash, provider=setting.provider, model=setting.model, content=content)
        db.add(existing)
    else:
        existing.provider, existing.model, existing.content, existing.created_at = setting.provider, setting.model, content, datetime.utcnow()
    await db.commit()
    await db.refresh(existing)
    return GradeAiAnalysisOut(term_id=term_id, content=existing.content, provider=existing.provider, model=existing.model, created_at=existing.created_at, cached=False)


async def list_grade_ai_analyses(db: AsyncSession, term_id: int | None = None) -> list[GradeAiAnalysisHistoryOut]:
    """Return a bounded, newest-first local history without calling the model service."""
    statement = select(GradeAiAnalysis).order_by(GradeAiAnalysis.created_at.desc()).limit(100)
    if term_id is not None:
        statement = statement.where(GradeAiAnalysis.term_id == term_id)
    rows = (await db.scalars(statement)).all()
    return [
        GradeAiAnalysisHistoryOut(
            id=row.id,
            term_id=row.term_id,
            content=row.content,
            provider=row.provider,
            model=row.model,
            created_at=row.created_at,
        )
        for row in rows
    ]


async def clear_grade_ai_analyses(db: AsyncSession, term_id: int | None = None) -> int:
    """Clear generated analysis text only; grades and model configuration stay untouched."""
    statement = delete(GradeAiAnalysis)
    if term_id is not None:
        statement = statement.where(GradeAiAnalysis.term_id == term_id)
    result = await db.execute(statement)
    await db.commit()
    return int(result.rowcount or 0)
