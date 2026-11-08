"""Durable AI analysis job creation, leasing, and execution.

This module intentionally has no FastAPI dependency.  The HTTP API and the
worker both use the same state transitions, so a disconnected client cannot
cancel a persisted task merely by going away.
"""
from __future__ import annotations

import hashlib
import uuid
from datetime import datetime, timedelta

from sqlalchemy import and_, or_, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai_analysis import (
    AiConfigurationError,
    AiServiceError,
    _analysis_messages,
    analysis_configuration_hash,
    _chat_endpoint,
    _decrypt_saved_api_key,
    _grade_snapshot,
    _post_openai_compatible,
)
from app.db_models import AiProviderSetting, Grade, GradeAiAnalysis, GradeAiJob
from app.schemas import GradeAiAnalysisOut, GradeAiJobOut


ACTIVE_STATUSES = ("queued", "running")
TERMINAL_STATUSES = ("succeeded", "failed", "cancelled", "unknown")
LEASE_SECONDS = 120


class AiJobError(ValueError):
    """Safe client-facing job API error."""


class AiJobConflictError(AiJobError):
    """A caller reused an idempotency key for a different request."""


def _now() -> datetime:
    return datetime.utcnow()


def _owner_key(owner: str) -> str:
    return owner.strip().lower()


def _normal_idempotency_key(owner: str, term_id: int, input_hash: str, configuration_hash: str) -> str:
    value = "\x1f".join([_owner_key(owner), str(term_id), input_hash, configuration_hash])
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _same_request(
    job: GradeAiJob,
    *,
    term_id: int,
    input_hash: str,
    provider: str,
    model: str,
    configuration_hash: str,
) -> bool:
    return (
        job.term_id == term_id
        and job.input_hash == input_hash
        and job.provider == provider
        and job.model == model
        and job.configuration_hash == configuration_hash
    )


def _lease_where(job_id: str, worker_id: str, lease_token: str, now: datetime):
    """Fence writes so a late/expired worker cannot overwrite newer state."""
    return (
        GradeAiJob.job_id == job_id,
        GradeAiJob.status == "running",
        GradeAiJob.lease_owner == worker_id,
        GradeAiJob.lease_token == lease_token,
        GradeAiJob.lease_expires_at.is_not(None),
        GradeAiJob.lease_expires_at > now,
    )


def _analysis_out(row: GradeAiAnalysis, *, cached: bool) -> GradeAiAnalysisOut:
    return GradeAiAnalysisOut(
        term_id=row.term_id,
        content=row.content,
        provider=row.provider,
        model=row.model,
        created_at=row.created_at,
        cached=cached,
    )


async def _job_out(db: AsyncSession, job: GradeAiJob, *, reused: bool = False, cached: bool = False) -> GradeAiJobOut:
    analysis: GradeAiAnalysisOut | None = None
    if job.analysis_id is not None:
        row = await db.get(GradeAiAnalysis, job.analysis_id)
        if row is not None:
            analysis = _analysis_out(row, cached=True)
    return GradeAiJobOut(
        job_id=job.job_id,
        term_id=job.term_id,
        input_hash=job.input_hash,
        provider=job.provider,
        model=job.model,
        status=job.status,
        reused=reused,
        cached=cached,
        attempt=job.attempt,
        created_at=job.created_at,
        updated_at=job.updated_at,
        started_at=job.started_at,
        finished_at=job.finished_at,
        error_code=job.error_code,
        error_message=job.error_message,
        analysis_id=job.analysis_id,
        analysis=analysis,
    )


async def create_or_reuse_job(
    db: AsyncSession,
    *,
    owner: str,
    term_id: int,
    force_refresh: bool,
    idempotency_key: str | None,
) -> GradeAiJobOut:
    """Persist a task before execution and atomically deduplicate active work."""
    setting = await db.get(AiProviderSetting, 1)
    if setting is None or not setting.is_enabled:
        raise AiConfigurationError("请先在设置中配置模型服务")
    grades = list((await db.scalars(select(Grade).where(Grade.term_id == term_id))).all())
    if not grades:
        raise AiServiceError("该学期尚无导入成绩，无法分析", code="NO_GRADES")
    input_hash, _ = _grade_snapshot(grades)
    configuration_hash = analysis_configuration_hash(setting.provider, setting.base_url, setting.model)
    owner = _owner_key(owner)
    key = (idempotency_key or "").strip()
    if key and len(key) > 128:
        raise AiJobError("幂等键长度不能超过 128 个字符")
    # A forced refresh without a caller-provided key is deliberately a new job,
    # while ordinary requests remain naturally idempotent for this snapshot.
    if not key:
        key = uuid.uuid4().hex if force_refresh else _normal_idempotency_key(owner, term_id, input_hash, configuration_hash)
    prior = await db.scalar(
        select(GradeAiJob).where(GradeAiJob.owner == owner, GradeAiJob.idempotency_key == key)
    )
    if prior is not None:
        if not _same_request(
            prior,
            term_id=term_id,
            input_hash=input_hash,
            provider=setting.provider,
            model=setting.model,
            configuration_hash=configuration_hash,
        ):
            raise AiJobConflictError("该幂等键已用于不同的成绩分析请求，请使用新的幂等键")
        return await _job_out(db, prior, reused=True, cached=prior.status == "succeeded")

    existing_analysis = await db.scalar(
        select(GradeAiAnalysis).where(
            GradeAiAnalysis.term_id == term_id,
            GradeAiAnalysis.input_hash == input_hash,
            GradeAiAnalysis.provider == setting.provider,
            GradeAiAnalysis.model == setting.model,
            GradeAiAnalysis.configuration_hash == configuration_hash,
        )
    )
    if existing_analysis is not None and not force_refresh:
        now = _now()
        cached_job = GradeAiJob(
            job_id=f"cache-{uuid.uuid4().hex}",
            owner=owner,
            term_id=term_id,
            input_hash=input_hash,
            provider=setting.provider,
            model=setting.model,
            configuration_hash=configuration_hash,
            idempotency_key=key,
            status="succeeded",
            attempt=0,
            started_at=now,
            finished_at=now,
            analysis_id=existing_analysis.id,
        )
        db.add(cached_job)
        await db.commit()
        await db.refresh(cached_job)
        return await _job_out(db, cached_job, reused=True, cached=True)

    active = await db.scalar(
        select(GradeAiJob).where(
            GradeAiJob.owner == owner,
            GradeAiJob.term_id == term_id,
            GradeAiJob.input_hash == input_hash,
            GradeAiJob.provider == setting.provider,
            GradeAiJob.model == setting.model,
            GradeAiJob.configuration_hash == configuration_hash,
            GradeAiJob.status.in_(ACTIVE_STATUSES),
        ).order_by(GradeAiJob.created_at.desc())
    )
    if active is not None:
        return await _job_out(db, active, reused=True)

    job = GradeAiJob(
        job_id=uuid.uuid4().hex,
        owner=owner,
        term_id=term_id,
        input_hash=input_hash,
        provider=setting.provider,
        model=setting.model,
        configuration_hash=configuration_hash,
        idempotency_key=key,
        status="queued",
        attempt=0,
    )
    db.add(job)
    try:
        await db.commit()
    except IntegrityError:
        # The partial unique index is the final guard when two HTTP requests
        # observe no active job at the same time.
        await db.rollback()
        existing = await db.scalar(
            select(GradeAiJob).where(
                GradeAiJob.owner == owner,
                or_(
                    GradeAiJob.idempotency_key == key,
                    and_(
                        GradeAiJob.term_id == term_id,
                        GradeAiJob.input_hash == input_hash,
                        GradeAiJob.provider == setting.provider,
                        GradeAiJob.model == setting.model,
                        GradeAiJob.configuration_hash == configuration_hash,
                        GradeAiJob.status.in_(ACTIVE_STATUSES),
                    ),
                ),
            ).order_by(GradeAiJob.created_at.desc())
        )
        if existing is None:
            raise
        if existing.idempotency_key == key and not _same_request(
            existing,
            term_id=term_id,
            input_hash=input_hash,
            provider=setting.provider,
            model=setting.model,
            configuration_hash=configuration_hash,
        ):
            raise AiJobConflictError("该幂等键已用于不同的成绩分析请求，请使用新的幂等键")
        return await _job_out(db, existing, reused=True, cached=existing.status == "succeeded")
    await db.refresh(job)
    return await _job_out(db, job)


async def get_job(db: AsyncSession, *, owner: str, job_id: str) -> GradeAiJobOut:
    job = await db.scalar(select(GradeAiJob).where(GradeAiJob.job_id == job_id, GradeAiJob.owner == _owner_key(owner)))
    if job is None:
        raise AiJobError("分析任务不存在")
    return await _job_out(db, job)


async def cancel_job(db: AsyncSession, *, owner: str, job_id: str) -> GradeAiJobOut:
    owner = _owner_key(owner)
    job = await db.scalar(select(GradeAiJob).where(GradeAiJob.job_id == job_id, GradeAiJob.owner == owner))
    if job is None:
        raise AiJobError("分析任务不存在")
    if job.status in {"queued", "running"}:
        now = _now()
        await db.execute(
            update(GradeAiJob)
            .where(GradeAiJob.job_id == job_id, GradeAiJob.owner == owner, GradeAiJob.status.in_(("queued", "running")))
            .values(
                status="cancelled",
                finished_at=now,
                lease_expires_at=None,
                lease_owner=None,
                lease_token=None,
                error_code="CANCELLED",
                error_message="已取消本地分析任务；上游请求如已发出，可能仍在处理。",
            )
        )
        await db.commit()
        job = await db.scalar(select(GradeAiJob).where(GradeAiJob.job_id == job_id, GradeAiJob.owner == owner))
        if job is None:
            raise AiJobError("分析任务不存在")
    return await _job_out(db, job)


async def recover_expired_leases(db: AsyncSession) -> int:
    now = _now()
    result = await db.execute(
        update(GradeAiJob)
        .where(GradeAiJob.status == "running", GradeAiJob.lease_expires_at.is_not(None), GradeAiJob.lease_expires_at < now)
        .values(
            status="unknown",
            finished_at=now,
            lease_expires_at=None,
            lease_owner=None,
            lease_token=None,
            error_code="WORKER_LEASE_EXPIRED",
            error_message="工作进程在上游结果确认前失联；为避免重复计费，未自动重试。",
        )
    )
    await db.commit()
    return int(result.rowcount or 0)


async def claim_next_job(db: AsyncSession, *, worker_id: str, lease_seconds: int = LEASE_SECONDS) -> str | None:
    """Claim one queued row with a conditional update suitable for SQLite WAL."""
    await recover_expired_leases(db)
    candidate = await db.scalar(
        select(GradeAiJob.job_id).where(GradeAiJob.status == "queued").order_by(GradeAiJob.created_at).limit(1)
    )
    if candidate is None:
        return None
    now = _now()
    lease_token = uuid.uuid4().hex
    result = await db.execute(
        update(GradeAiJob)
        .where(GradeAiJob.job_id == candidate, GradeAiJob.status == "queued")
        .values(
            status="running",
            attempt=GradeAiJob.attempt + 1,
            lease_owner=worker_id,
            lease_token=lease_token,
            lease_expires_at=now + timedelta(seconds=lease_seconds),
            started_at=now,
            error_code=None,
            error_message=None,
        )
    )
    await db.commit()
    return candidate if result.rowcount == 1 else None


async def _fail_job(
    db: AsyncSession,
    *,
    job_id: str,
    worker_id: str,
    lease_token: str,
    code: str,
    message: str,
) -> None:
    now = _now()
    await db.execute(
        update(GradeAiJob)
        .where(*_lease_where(job_id, worker_id, lease_token, now))
        .values(
            status="failed",
            finished_at=now,
            lease_expires_at=None,
            lease_owner=None,
            lease_token=None,
            error_code=code[:64],
            error_message=message[:512],
        )
    )
    await db.commit()


async def execute_job(db: AsyncSession, *, worker_id: str, job_id: str) -> None:
    """Execute a claimed job once.  Unknown outbound results are never retried."""
    job = await db.scalar(
        select(GradeAiJob).where(
            GradeAiJob.job_id == job_id,
            GradeAiJob.status == "running",
            GradeAiJob.lease_owner == worker_id,
        )
    )
    if job is None:
        return
    lease_token = job.lease_token
    if not lease_token:
        return
    job_term_id = job.term_id
    job_input_hash = job.input_hash
    job_provider = job.provider
    job_model = job.model
    job_configuration_hash = job.configuration_hash
    setting = await db.get(AiProviderSetting, 1)
    if setting is None or not setting.is_enabled:
        await _fail_job(db, job_id=job_id, worker_id=worker_id, lease_token=lease_token, code="CONFIGURATION_MISSING", message="模型服务配置已不存在或已关闭")
        return
    # ``rollback()`` below intentionally releases the SQLite read transaction
    # while the upstream request is in flight.  SQLAlchemy expires ORM objects
    # on rollback, including with ``expire_on_commit=False``; never access this
    # setting instance after that boundary.
    setting_provider = setting.provider
    setting_base_url = setting.base_url
    setting_model = setting.model
    try:
        endpoint = _chat_endpoint(setting_base_url)
        api_key = _decrypt_saved_api_key(setting)
    except AiConfigurationError as exc:
        await _fail_job(db, job_id=job_id, worker_id=worker_id, lease_token=lease_token, code="CONFIGURATION_ERROR", message=str(exc))
        return
    if analysis_configuration_hash(setting_provider, setting_base_url, setting_model) != job_configuration_hash:
        await _fail_job(db, job_id=job_id, worker_id=worker_id, lease_token=lease_token, code="CONFIGURATION_CHANGED", message="模型服务配置已变化，未发送旧任务")
        return
    grades = list((await db.scalars(select(Grade).where(Grade.term_id == job_term_id))).all())
    current_hash, items = _grade_snapshot(grades)
    if not grades or current_hash != job_input_hash:
        await _fail_job(db, job_id=job_id, worker_id=worker_id, lease_token=lease_token, code="SNAPSHOT_CHANGED", message="成绩数据已变化，请重新创建分析任务")
        return
    # Never retain an SQLite read transaction while waiting for an upstream
    # model. All writes below are additionally fenced by the lease token.
    await db.rollback()
    try:
        content = await _post_openai_compatible(
            endpoint,
            api_key,
            job_model,
            _analysis_messages(items),
        )
    except AiConfigurationError as exc:
        await _fail_job(db, job_id=job_id, worker_id=worker_id, lease_token=lease_token, code="CONFIGURATION_ERROR", message=str(exc))
        return
    except AiServiceError as exc:
        await _fail_job(db, job_id=job_id, worker_id=worker_id, lease_token=lease_token, code=exc.code, message=str(exc))
        return
    except Exception:
        # Do not include an upstream exception body: it may contain credentials
        # or provider-specific request details.
        await _fail_job(db, job_id=job_id, worker_id=worker_id, lease_token=lease_token, code="UNEXPECTED_ERROR", message="模型服务处理异常，请稍后重新生成")
        return

    now = _now()
    async with db.begin():
        # This starts the write transaction before mutating the cache. A cancel,
        # lease expiry, or another claimant that won the race makes rowcount 0,
        # leaving no late result in the shared cache.
        held = await db.execute(
            update(GradeAiJob)
            .where(*_lease_where(job_id, worker_id, lease_token, now))
            .values(lease_expires_at=now + timedelta(seconds=LEASE_SECONDS))
        )
        if held.rowcount != 1:
            return
        analysis = await db.scalar(
            select(GradeAiAnalysis).where(
                GradeAiAnalysis.term_id == job_term_id,
                GradeAiAnalysis.input_hash == job_input_hash,
                GradeAiAnalysis.configuration_hash == job_configuration_hash,
            )
        )
        if analysis is None:
            analysis = GradeAiAnalysis(
                term_id=job_term_id,
                input_hash=job_input_hash,
                provider=job_provider,
                model=job_model,
                configuration_hash=job_configuration_hash,
                content=content,
            )
            db.add(analysis)
            await db.flush()
        else:
            analysis.provider = job_provider
            analysis.model = job_model
            analysis.content = content
            analysis.created_at = now
            await db.flush()
        completed = await db.execute(
            update(GradeAiJob)
            .where(*_lease_where(job_id, worker_id, lease_token, now))
            .values(
                status="succeeded",
                finished_at=now,
                lease_expires_at=None,
                lease_owner=None,
                lease_token=None,
                error_code=None,
                error_message=None,
                analysis_id=analysis.id,
            )
        )
        if completed.rowcount != 1:
            raise RuntimeError("AI job lease was lost while persisting its result")

