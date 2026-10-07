from __future__ import annotations
from datetime import date, datetime
from sqlalchemy import Boolean, Date, DateTime, Float, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column
from app.db import Base

class TimestampMixin:
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

class AppProfile(TimestampMixin, Base):
    __tablename__ = "app_profiles"
    id: Mapped[int] = mapped_column(primary_key=True)
    display_name: Mapped[str] = mapped_column(String(64), default="用户")
    avatar_data_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    timetable_background_data_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    home_wallpaper_data_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    analysis_wallpaper_data_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    settings_wallpaper_data_url: Mapped[str | None] = mapped_column(Text, nullable=True)

class AppSession(Base):
    """Server-side session metadata; only an HMAC of the browser secret is stored."""
    __tablename__ = "app_sessions"
    id: Mapped[int] = mapped_column(primary_key=True)
    session_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


class PasskeyOwner(Base):
    """Stable opaque WebAuthn user handle for this single-owner application."""
    __tablename__ = "passkey_owner"
    id: Mapped[int] = mapped_column(primary_key=True, default=1)
    user_handle: Mapped[str] = mapped_column(String(128), unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


class PasskeyCredential(Base):
    __tablename__ = "passkey_credentials"
    id: Mapped[int] = mapped_column(primary_key=True)
    credential_id: Mapped[str] = mapped_column(String(1024), unique=True, index=True)
    public_key: Mapped[str] = mapped_column(Text)
    sign_count: Mapped[int] = mapped_column(Integer, default=0)
    transports_json: Mapped[str] = mapped_column(Text, default="[]")
    device_type: Mapped[str] = mapped_column(String(32), default="single_device")
    backed_up: Mapped[bool] = mapped_column(Boolean, default=False)
    label: Mapped[str] = mapped_column(String(64), default="此设备")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)


class PasskeyChallenge(Base):
    __tablename__ = "passkey_challenges"
    challenge_id: Mapped[str] = mapped_column(String(128), primary_key=True)
    ceremony: Mapped[str] = mapped_column(String(32), index=True)
    challenge: Mapped[str] = mapped_column(String(128))
    expires_at: Mapped[datetime] = mapped_column(DateTime, index=True)
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)

class AcademicTerm(TimestampMixin, Base):
    __tablename__ = "academic_terms"
    id: Mapped[int] = mapped_column(primary_key=True)
    source_term_id: Mapped[str] = mapped_column(String(128), unique=True)
    academic_year: Mapped[str] = mapped_column(String(32))
    term_number: Mapped[str] = mapped_column(String(32))
    display_name: Mapped[str] = mapped_column(String(128))
    start_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    end_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    is_current: Mapped[bool] = mapped_column(Boolean, default=False)

class PeriodTime(TimestampMixin, Base):
    __tablename__ = "period_times"
    id: Mapped[int] = mapped_column(primary_key=True)
    period_number: Mapped[int] = mapped_column(Integer, unique=True)
    start_time: Mapped[str] = mapped_column(String(8))
    end_time: Mapped[str] = mapped_column(String(8))

class Course(TimestampMixin, Base):
    __tablename__ = "courses"
    id: Mapped[int] = mapped_column(primary_key=True)
    source_course_id: Mapped[str] = mapped_column(String(128), unique=True)
    course_code: Mapped[str] = mapped_column(String(64))
    course_name: Mapped[str] = mapped_column(String(255))
    teacher: Mapped[str | None] = mapped_column(String(255), nullable=True)
    credits: Mapped[float | None] = mapped_column(Float, nullable=True)
    classroom: Mapped[str | None] = mapped_column(String(255), nullable=True)
    campus: Mapped[str | None] = mapped_column(String(255), nullable=True)
    term_id: Mapped[int] = mapped_column(ForeignKey("academic_terms.id"))

class CourseRule(TimestampMixin, Base):
    __tablename__ = "course_rules"
    id: Mapped[int] = mapped_column(primary_key=True)
    course_id: Mapped[int] = mapped_column(ForeignKey("courses.id"))
    weekday: Mapped[int] = mapped_column(Integer)
    start_period: Mapped[int | None] = mapped_column(Integer, nullable=True)
    end_period: Mapped[int | None] = mapped_column(Integer, nullable=True)
    start_time: Mapped[str] = mapped_column(String(8))
    end_time: Mapped[str] = mapped_column(String(8))
    week_expression: Mapped[str] = mapped_column(String(255))
    raw_text: Mapped[str | None] = mapped_column(Text, nullable=True)

class CourseSession(TimestampMixin, Base):
    __tablename__ = "course_sessions"
    __table_args__ = (UniqueConstraint("course_id", "session_date", "start_datetime"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    course_id: Mapped[int] = mapped_column(ForeignKey("courses.id"))
    session_date: Mapped[date] = mapped_column(Date, index=True)
    start_datetime: Mapped[datetime] = mapped_column(DateTime, index=True)
    end_datetime: Mapped[datetime] = mapped_column(DateTime)
    classroom: Mapped[str | None] = mapped_column(String(255), nullable=True)
    teacher: Mapped[str | None] = mapped_column(String(255), nullable=True)
    status: Mapped[str] = mapped_column(String(32), default="NORMAL")
    source_hash: Mapped[str] = mapped_column(String(64))

class CustomSchedule(TimestampMixin, Base):
    """用户自行添加的日程；与教务课程数据完全隔离。"""
    __tablename__ = "custom_schedules"
    id: Mapped[int] = mapped_column(primary_key=True)
    title: Mapped[str] = mapped_column(String(200))
    scheduled_date: Mapped[date] = mapped_column(Date, index=True)
    scheduled_time: Mapped[str] = mapped_column(String(5))

class ManualCourse(TimestampMixin, Base):
    """用户手动维护的课程；不会被打印课表文件导入覆盖。"""
    __tablename__ = "manual_courses"
    __table_args__ = (UniqueConstraint("term_id", "course_name", "weekday", "start_period", "end_period", "week_expression", name="uq_manual_course_rule"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    term_id: Mapped[int] = mapped_column(ForeignKey("academic_terms.id", ondelete="CASCADE"), index=True)
    course_name: Mapped[str] = mapped_column(String(255))
    teacher: Mapped[str | None] = mapped_column(String(255), nullable=True)
    classroom: Mapped[str | None] = mapped_column(String(255), nullable=True)
    weekday: Mapped[int] = mapped_column(Integer)
    start_period: Mapped[int] = mapped_column(Integer)
    end_period: Mapped[int] = mapped_column(Integer)
    week_expression: Mapped[str] = mapped_column(String(255))

class Grade(TimestampMixin, Base):
    __tablename__ = "grades"
    id: Mapped[int] = mapped_column(primary_key=True)
    source_grade_id: Mapped[str] = mapped_column(String(128), unique=True)
    term_id: Mapped[int] = mapped_column(ForeignKey("academic_terms.id"))
    course_code: Mapped[str] = mapped_column(String(64))
    course_name: Mapped[str] = mapped_column(String(255))
    course_type: Mapped[str | None] = mapped_column(String(128), nullable=True)
    credits: Mapped[float | None] = mapped_column(Float, nullable=True)
    score: Mapped[str | None] = mapped_column(String(64), nullable=True)
    final_exam_score: Mapped[str | None] = mapped_column(String(64), nullable=True)
    usual_score: Mapped[str | None] = mapped_column(String(64), nullable=True)
    grade_point: Mapped[float | None] = mapped_column(Float, nullable=True)
    weighted_grade_point: Mapped[float | None] = mapped_column(Float, nullable=True)
    exam_type: Mapped[str | None] = mapped_column(String(64), nullable=True)
    makeup_flag: Mapped[bool] = mapped_column(Boolean, default=False)
    retake_flag: Mapped[bool] = mapped_column(Boolean, default=False)
    source_hash: Mapped[str] = mapped_column(String(64))
    source_updated_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    synced_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


class AiProviderSetting(TimestampMixin, Base):
    """单用户模型配置。API Key 只以 Fernet 密文保存，永不返回给客户端。"""
    __tablename__ = "ai_provider_settings"
    id: Mapped[int] = mapped_column(primary_key=True, default=1)
    provider: Mapped[str] = mapped_column(String(64))
    base_url: Mapped[str] = mapped_column(String(512))
    model: Mapped[str] = mapped_column(String(128))
    encrypted_api_key: Mapped[str] = mapped_column(Text)
    api_key_hint: Mapped[str] = mapped_column(String(24))
    # Model IDs are not credentials. Persisting the last verified list lets the
    # UI switch models without asking the user to re-enter an API key.
    available_models_json: Mapped[str] = mapped_column(Text, default="[]")
    models_synced_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    is_enabled: Mapped[bool] = mapped_column(Boolean, default=True)


class GradeAiAnalysis(Base):
    """按学期和成绩快照缓存的分析结果，不保存原始上传文件。"""
    __tablename__ = "grade_ai_analyses"
    __table_args__ = (UniqueConstraint("term_id", "input_hash", name="uq_grade_ai_analysis_snapshot"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    term_id: Mapped[int] = mapped_column(ForeignKey("academic_terms.id", ondelete="CASCADE"), index=True)
    input_hash: Mapped[str] = mapped_column(String(64), index=True)
    provider: Mapped[str] = mapped_column(String(64))
    model: Mapped[str] = mapped_column(String(128))
    content: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)

class SyncJob(TimestampMixin, Base):
    __tablename__ = "sync_jobs"
    id: Mapped[int] = mapped_column(primary_key=True)
    job_type: Mapped[str] = mapped_column(String(64))
    status: Mapped[str] = mapped_column(String(32))
    started_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    error_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    error_message: Mapped[str | None] = mapped_column(Text, nullable=True)
    result_summary: Mapped[str | None] = mapped_column(Text, nullable=True)
