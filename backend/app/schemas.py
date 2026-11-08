from datetime import date, datetime
from typing import Any, Generic, TypeVar
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

T = TypeVar("T")
class ApiError(BaseModel):
    code: str
    message: str
    details: dict[str, Any] = Field(default_factory=dict)
class ApiResponse(BaseModel, Generic[T]):
    success: bool
    data: T | None = None
    error: ApiError | None = None
    request_id: str
    server_time: datetime
class LoginRequest(BaseModel):
    username: str = Field(min_length=1, max_length=128)
    password: str = Field(min_length=1, max_length=512)
class AuthMeOut(BaseModel):
    authenticated: bool = True
    username: str


class PasskeyRegistrationOptionsRequest(BaseModel):
    password: str = Field(min_length=1, max_length=512)
    label: str = Field(default="此设备", min_length=1, max_length=64)


class PasskeyVerificationRequest(BaseModel):
    challenge_id: str = Field(min_length=16, max_length=128)
    credential: dict[str, Any]
    label: str | None = Field(default=None, max_length=64)


class PasskeyCredentialOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    label: str
    device_type: str
    backed_up: bool
    created_at: datetime
    last_used_at: datetime | None


class PasskeyDeleteRequest(BaseModel):
    password: str = Field(min_length=1, max_length=512)
class AppProfileOut(BaseModel):
    display_name: str
    avatar_data_url: str | None = None
    timetable_background_data_url: str | None = None
    home_wallpaper_data_url: str | None = None
    analysis_wallpaper_data_url: str | None = None
    settings_wallpaper_data_url: str | None = None
class AppProfileInput(BaseModel):
    display_name: str = Field(min_length=1, max_length=64)
    avatar_data_url: str | None = Field(default=None, max_length=1_400_000)
    timetable_background_data_url: str | None = Field(default=None, max_length=1_400_000)
    home_wallpaper_data_url: str | None = Field(default=None, max_length=1_400_000)
    analysis_wallpaper_data_url: str | None = Field(default=None, max_length=1_400_000)
    settings_wallpaper_data_url: str | None = Field(default=None, max_length=1_400_000)
class TermOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    source_term_id: str
    display_name: str
    start_date: date | None
    is_current: bool
class TermStartDateInput(BaseModel):
    start_date: date

class PeriodTimeInput(BaseModel):
    start_time: str = Field(pattern=r"^\d{2}:\d{2}$")
    end_time: str = Field(pattern=r"^\d{2}:\d{2}$")

    @model_validator(mode="after")
    def end_must_be_after_start(self):
        if self.end_time <= self.start_time:
            raise ValueError("下课时间必须晚于上课时间")
        return self

class PeriodTimeOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    period_number: int
    start_time: str
    end_time: str
class CourseSessionOut(BaseModel):
    id: int
    course_name: str
    course_code: str
    session_date: date
    start_datetime: datetime
    end_datetime: datetime
    classroom: str | None
    teacher: str | None
    week_expression: str | None = None
    status: str
    source: str = "IMPORTED"
    manual_course_id: int | None = None
    term_id: int | None = None
    weekday: int | None = None
    start_period: int | None = None
    end_period: int | None = None

class CustomScheduleInput(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    scheduled_date: date
    scheduled_time: str = Field(pattern=r"^\d{2}:\d{2}$")

class CustomScheduleOut(CustomScheduleInput):
    model_config = ConfigDict(from_attributes=True)
    id: int
    created_at: datetime
    updated_at: datetime

class ManualCourseInput(BaseModel):
    term_id: int
    course_name: str = Field(min_length=1, max_length=255)
    teacher: str | None = Field(default=None, max_length=255)
    classroom: str | None = Field(default=None, max_length=255)
    weekday: int = Field(ge=1, le=7)
    start_period: int = Field(ge=1, le=13)
    end_period: int = Field(ge=1, le=13)
    week_expression: str = Field(min_length=1, max_length=255)

    @model_validator(mode="after")
    def period_range_is_valid(self):
        if self.end_period < self.start_period:
            raise ValueError("结束节次不能早于开始节次")
        return self

class ManualCourseOut(ManualCourseInput):
    model_config = ConfigDict(from_attributes=True)
    id: int
    created_at: datetime
    updated_at: datetime

class GradeOut(BaseModel):
    id: int
    term_id: int
    course_code: str
    course_name: str
    course_type: str | None
    credits: float | None
    score: str | None
    final_exam_score: str | None
    usual_score: str | None
    grade_point: float | None
    weighted_grade_point: float | None
    exam_type: str | None
    makeup_flag: bool
    retake_flag: bool

class GradeImportItem(BaseModel):
    course_code: str = Field(default="", max_length=64)
    course_name: str = Field(min_length=1, max_length=255)
    course_type: str | None = Field(default=None, max_length=128)
    credits: float | None = None
    score: str | None = Field(default=None, max_length=64)
    final_exam_score: str | None = Field(default=None, max_length=64)
    usual_score: str | None = Field(default=None, max_length=64)
    grade_point: float | None = None
    weighted_grade_point: float | None = None
    exam_type: str | None = Field(default=None, max_length=64)
    makeup_flag: bool = False
    retake_flag: bool = False
    source_grade_id: str = Field(min_length=1, max_length=128)

class GradeImportPreviewOut(BaseModel):
    source_term_id: str
    grades: list[GradeImportItem]

class GradeImportConfirmInput(BaseModel):
    source_term_id: str = Field(pattern=r"^20\d{2}-20\d{2}-[12]$")
    grades: list[GradeImportItem] = Field(min_length=1, max_length=500)


class AiProviderSettingInput(BaseModel):
    provider: str = Field(min_length=1, max_length=64)
    base_url: str = Field(min_length=12, max_length=512)
    model: str = Field(min_length=1, max_length=128)
    api_key: str = Field(min_length=8, max_length=512)

    @field_validator("base_url")
    @classmethod
    def https_url_required(cls, value: str) -> str:
        value = value.strip().rstrip("/")
        if not value.startswith("https://"):
            raise ValueError("模型服务地址必须使用 HTTPS")
        return value


class AiModelLookupInput(BaseModel):
    provider: str = Field(min_length=1, max_length=64)
    base_url: str = Field(min_length=12, max_length=512)
    api_key: str = Field(min_length=8, max_length=512)

    @field_validator("base_url")
    @classmethod
    def https_url_required(cls, value: str) -> str:
        value = value.strip().rstrip("/")
        if not value.startswith("https://"):
            raise ValueError("模型服务地址必须使用 HTTPS")
        return value


class AiProviderSettingOut(BaseModel):
    configured: bool
    provider: str | None = None
    base_url: str | None = None
    model: str | None = None
    api_key_hint: str | None = None
    available_models: list[str] = Field(default_factory=list)
    models_synced_at: datetime | None = None
    is_enabled: bool = False
    requires_apikey_fan_migration: bool = False


class AiModelSelectionInput(BaseModel):
    model: str = Field(min_length=1, max_length=128)


class AiConnectionTestOut(BaseModel):
    message: str
    provider: str
    model: str


class AiModelListOut(BaseModel):
    models: list[str]


class GradeAiAnalysisOut(BaseModel):
    term_id: int
    content: str
    provider: str
    model: str
    created_at: datetime
    cached: bool


class GradeAiAnalysisHistoryOut(BaseModel):
    """A saved analysis is metadata plus generated text, never the uploaded source file."""

    id: int
    term_id: int
    content: str
    provider: str
    model: str
    created_at: datetime


class GradeAiJobOut(BaseModel):
    job_id: str
    term_id: int
    input_hash: str
    provider: str
    model: str
    status: str
    reused: bool = False
    cached: bool = False
    attempt: int
    created_at: datetime
    updated_at: datetime
    started_at: datetime | None = None
    finished_at: datetime | None = None
    error_code: str | None = None
    error_message: str | None = None
    analysis_id: int | None = None
    analysis: GradeAiAnalysisOut | None = None
