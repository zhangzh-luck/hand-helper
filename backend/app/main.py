from __future__ import annotations
import uuid
import base64
import binascii
import secrets
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta
from fastapi import Depends, FastAPI, HTTPException, Request, UploadFile
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.interval import IntervalTrigger
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from app.config import get_settings
from app.db import Base, SessionLocal, engine, get_db
from app.db_models import AiProviderSetting, AppProfile, AcademicTerm, Course, CourseRule, CourseSession, CustomSchedule, ManualCourse, Grade, PeriodTime
from app.schemas import AiConnectionTestOut, AiModelListOut, AiModelLookupInput, AiModelSelectionInput, AiProviderSettingInput, ApiError, ApiResponse, AppProfileInput, AppProfileOut, AuthMeOut, CourseSessionOut, CustomScheduleInput, CustomScheduleOut, GradeImportConfirmInput, GradeImportItem, GradeImportPreviewOut, ManualCourseInput, ManualCourseOut, GradeOut, LoginRequest, PeriodTimeInput, PeriodTimeOut, TermOut, TermStartDateInput
from app.ai_analysis import AiConfigurationError, AiServiceError, analyze_grades, clear_grade_ai_analyses, delete_ai_setting, list_available_models, list_grade_ai_analyses, refresh_saved_models, save_ai_setting, select_saved_model, setting_out, test_ai_connection
from app.security import client_ip, create_session, csrf_request_is_allowed, destroy_session, find_valid_session, login_rate_limiter, verify_admin_password
from app.services import import_grades, import_printed_timetable, period_times, rebuild_sessions, set_period_time, set_term_start_date
from app.importers.academic_files import ImportParseError, RawGrade, parse_grade_file, parse_printed_timetable_xls, parse_week_expression

def response(data=None, error: ApiError | None = None, request_id: str | None = None):
    return ApiResponse(success=error is None, data=data, error=error, request_id=request_id or str(uuid.uuid4()), server_time=datetime.utcnow())

async def cleanup_expired_custom_schedules(reference_date: date | None = None) -> int:
    """每周清理一次超过七天的过期自定义安排，不触碰课程或未来安排。"""
    cutoff = (reference_date or date.today()) - timedelta(days=7)
    async with SessionLocal() as db:
        rows = (await db.scalars(select(CustomSchedule).where(CustomSchedule.scheduled_date < cutoff))).all()
        for item in rows:
            await db.delete(item)
        await db.commit()
        return len(rows)

@asynccontextmanager
async def lifespan(_app: FastAPI):
    if get_settings().auto_create_schema:
        async with engine.begin() as connection: await connection.run_sync(Base.metadata.create_all)
    scheduler = AsyncIOScheduler()
    scheduler.add_job(
        cleanup_expired_custom_schedules,
        trigger=IntervalTrigger(days=7),
        id="cleanup_expired_custom_schedules",
        replace_existing=True,
    )
    scheduler.start()
    try:
        yield
    finally:
        if scheduler.running:
            scheduler.shutdown(wait=False)
        await engine.dispose()
app=FastAPI(title="航的助手 · Hand Helper", version="0.1.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=get_settings().cors_origin_list, allow_credentials=True, allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"], allow_headers=["Content-Type"])

PUBLIC_API_PATHS = {"/api/auth/login", "/api/v1/auth/login"}
AUTH_RESPONSE_PATHS = {
    "/api/auth/login", "/api/v1/auth/login", "/api/auth/logout", "/api/v1/auth/logout",
    "/api/auth/me", "/api/v1/auth/me",
}


@app.middleware("http")
async def session_auth_middleware(request: Request, call_next):
    """One guard for all private APIs; no endpoint repeats bearer-token checks."""
    path = request.url.path
    if path.startswith("/api/") and request.method != "OPTIONS":
        if not csrf_request_is_allowed(request):
            return JSONResponse(
                status_code=403,
                content=response(error=ApiError(code="CSRF_FAILED", message="请求来源校验失败"), request_id=request.headers.get("X-Request-ID")).model_dump(mode="json"),
            )
        if path not in PUBLIC_API_PATHS:
            raw_session_id = request.cookies.get(get_settings().session_cookie_name)
            async with SessionLocal() as db:
                session = await find_valid_session(db, raw_session_id)
            if session is None:
                return JSONResponse(
                    status_code=401,
                    content=response(error=ApiError(code="UNAUTHORIZED", message="登录状态已失效，请重新登录"), request_id=request.headers.get("X-Request-ID")).model_dump(mode="json"),
                )
            request.state.session_id = raw_session_id
    result = await call_next(request)
    if path in AUTH_RESPONSE_PATHS:
        result.headers["Cache-Control"] = "no-store, private"
        result.headers["Pragma"] = "no-cache"
    return result

@app.exception_handler(HTTPException)
async def http_error_handler(request: Request, exc: HTTPException):
    return JSONResponse(status_code=exc.status_code, content=response(error=ApiError(code="UNAUTHORIZED" if exc.status_code == 401 else "REQUEST_ERROR", message=str(exc.detail)), request_id=request.headers.get("X-Request-ID")).model_dump(mode="json"))
@app.exception_handler(RequestValidationError)
async def validation_error_handler(request: Request, _exc: RequestValidationError):
    return JSONResponse(status_code=422, content=response(error=ApiError(code="REQUEST_ERROR", message="请求参数无效，请检查必填项和格式"), request_id=request.headers.get("X-Request-ID")).model_dump(mode="json"))
@app.get("/health")
async def health(): return {"status":"ok"}


@app.post("/api/auth/login", include_in_schema=False)
@app.post("/api/v1/auth/login")
async def app_login(body: LoginRequest, request: Request, db: AsyncSession = Depends(get_db)):
    settings = get_settings()
    username = body.username.strip()
    remote = client_ip(request)
    if not username or not login_rate_limiter.allowed(remote, username):
        raise HTTPException(429, "登录尝试过于频繁，请五分钟后再试")
    # Always verify the configured hash, even for a wrong username, to keep the
    # public failure path uniform and avoid making account existence observable.
    valid_password = verify_admin_password(body.password)
    if not secrets.compare_digest(username, settings.admin_username) or not valid_password:
        login_rate_limiter.record_failure(remote, username)
        raise HTTPException(401, "用户名或密码错误")
    login_rate_limiter.clear(remote, username)
    raw_session_id = await create_session(db)
    result = JSONResponse(content=response({"authenticated": True, "username": settings.admin_username}).model_dump(mode="json"))
    result.set_cookie(
        key=settings.session_cookie_name,
        value=raw_session_id,
        max_age=settings.session_max_age,
        httponly=True,
        secure=settings.session_cookie_secure,
        samesite="lax",
        path="/",
    )
    return result


@app.post("/api/auth/logout", include_in_schema=False)
@app.post("/api/v1/auth/logout")
async def logout(request: Request, db: AsyncSession = Depends(get_db)):
    await destroy_session(db, getattr(request.state, "session_id", None))
    result = JSONResponse(content=response({"logged_out": True}).model_dump(mode="json"))
    result.delete_cookie(key=get_settings().session_cookie_name, path="/", secure=get_settings().session_cookie_secure, httponly=True, samesite="lax")
    return result


@app.get("/api/auth/me", include_in_schema=False)
@app.get("/api/v1/auth/me")
async def auth_me():
    return response(AuthMeOut(username=get_settings().admin_username))
def profile_out(profile: AppProfile | None) -> AppProfileOut:
    return AppProfileOut(display_name=profile.display_name if profile else "张自航", avatar_data_url=profile.avatar_data_url if profile else None)
def validate_avatar_data_url(value: str | None) -> str | None:
    if value is None:
        return None
    prefixes = ("data:image/png;base64,", "data:image/jpeg;base64,", "data:image/webp;base64,")
    prefix = next((item for item in prefixes if value.startswith(item)), None)
    if not prefix:
        raise ValueError("头像仅支持 PNG、JPEG 或 WebP 图片")
    try:
        image_bytes = base64.b64decode(value[len(prefix):], validate=True)
    except (binascii.Error, ValueError):
        raise ValueError("头像文件格式无效") from None
    if not image_bytes or len(image_bytes) > 1_000_000:
        raise ValueError("头像图片需大于 0 且不超过 1 MB")
    return value
@app.get("/api/v1/profile")
async def get_profile(db: AsyncSession = Depends(get_db)):
    profile = await db.scalar(select(AppProfile).order_by(AppProfile.id).limit(1))
    return response(profile_out(profile))
@app.put("/api/v1/profile")
async def update_profile(body: AppProfileInput, db: AsyncSession = Depends(get_db)):
    profile = await db.scalar(select(AppProfile).order_by(AppProfile.id).limit(1))
    if profile is None:
        profile = AppProfile(display_name=body.display_name)
        db.add(profile)
    else:
        profile.display_name = body.display_name
    if "avatar_data_url" in body.model_fields_set:
        try:
            profile.avatar_data_url = validate_avatar_data_url(body.avatar_data_url)
        except ValueError as exc:
            raise HTTPException(422, str(exc))
    await db.commit()
    await db.refresh(profile)
    return response(profile_out(profile))

@app.get("/api/v1/custom-schedules")
async def list_custom_schedules(scheduled_date: date | None = None, db: AsyncSession = Depends(get_db)):
    query = select(CustomSchedule)
    if scheduled_date is not None:
        query = query.where(CustomSchedule.scheduled_date == scheduled_date)
    rows = (await db.scalars(query.order_by(CustomSchedule.scheduled_date, CustomSchedule.scheduled_time, CustomSchedule.id))).all()
    return response([CustomScheduleOut.model_validate(item) for item in rows])

@app.post("/api/v1/custom-schedules")
async def create_custom_schedule(body: CustomScheduleInput, db: AsyncSession = Depends(get_db)):
    title = body.title.strip()
    if not title:
        raise HTTPException(422, "安排事项不能为空")
    if body.scheduled_date < date.today():
        raise HTTPException(422, "不能添加今天之前的安排")
    item = CustomSchedule(title=title, scheduled_date=body.scheduled_date, scheduled_time=body.scheduled_time)
    db.add(item)
    await db.commit()
    await db.refresh(item)
    return response(CustomScheduleOut.model_validate(item))

async def existing_custom_schedule(schedule_id: int, db: AsyncSession) -> CustomSchedule:
    item = await db.scalar(select(CustomSchedule).where(CustomSchedule.id == schedule_id))
    if item is None:
        raise HTTPException(404, "安排不存在")
    return item

@app.patch("/api/v1/custom-schedules/{schedule_id}")
async def update_custom_schedule(schedule_id: int, body: CustomScheduleInput, db: AsyncSession = Depends(get_db)):
    item = await existing_custom_schedule(schedule_id, db)
    title = body.title.strip()
    if not title:
        raise HTTPException(422, "安排事项不能为空")
    if body.scheduled_date < date.today():
        raise HTTPException(422, "不能设置今天之前的安排")
    item.title = title
    item.scheduled_date = body.scheduled_date
    item.scheduled_time = body.scheduled_time
    await db.commit()
    await db.refresh(item)
    return response(CustomScheduleOut.model_validate(item))

@app.delete("/api/v1/custom-schedules/{schedule_id}")
async def delete_custom_schedule(schedule_id: int, db: AsyncSession = Depends(get_db)):
    item = await existing_custom_schedule(schedule_id, db)
    await db.delete(item)
    await db.commit()
    return response({"deleted": True})

async def validated_manual_course_values(body: ManualCourseInput, db: AsyncSession) -> dict[str, object]:
    course_name = body.course_name.strip()
    week_expression = body.week_expression.strip()
    if not course_name:
        raise HTTPException(422, "课程名称不能为空")
    try:
        weeks = parse_week_expression(week_expression)
    except ImportParseError as exc:
        raise HTTPException(422, f"周次规则无法识别：{exc}") from None
    if not weeks or min(weeks) < 1 or max(weeks) > 20 or len(weeks) > 20:
        raise HTTPException(422, "手动课程仅支持第 1 至第 20 周，且最多选择 20 周")
    term = await db.get(AcademicTerm, body.term_id)
    if term is None:
        raise HTTPException(404, "学期不存在")
    if term.start_date is None:
        raise HTTPException(422, "请先在时间设置中配置该学期第一周的周一日期")
    configured_periods = {item.period_number for item in (await db.scalars(select(PeriodTime))).all()}
    if body.start_period not in configured_periods or body.end_period not in configured_periods:
        raise HTTPException(422, "所选节次尚未配置上课时间")
    return {
        "term_id": body.term_id,
        "course_name": course_name,
        "teacher": body.teacher.strip() if body.teacher and body.teacher.strip() else None,
        "classroom": body.classroom.strip() if body.classroom and body.classroom.strip() else None,
        "weekday": body.weekday,
        "start_period": body.start_period,
        "end_period": body.end_period,
        "week_expression": week_expression,
    }

async def existing_manual_course(course_id: int, db: AsyncSession) -> ManualCourse:
    course = await db.scalar(select(ManualCourse).where(ManualCourse.id == course_id))
    if course is None:
        raise HTTPException(404, "手动课程不存在")
    return course

@app.get("/api/v1/manual-courses")
async def list_manual_courses(term_id: int | None = None, db: AsyncSession = Depends(get_db)):
    query = select(ManualCourse)
    if term_id is not None:
        query = query.where(ManualCourse.term_id == term_id)
    courses = (await db.scalars(query.order_by(ManualCourse.term_id, ManualCourse.weekday, ManualCourse.start_period, ManualCourse.id))).all()
    return response([ManualCourseOut.model_validate(course) for course in courses])

@app.post("/api/v1/manual-courses")
async def create_manual_course(body: ManualCourseInput, db: AsyncSession = Depends(get_db)):
    values = await validated_manual_course_values(body, db)
    course = ManualCourse(**values)
    db.add(course)
    try:
        await db.commit()
    except Exception as exc:
        await db.rollback()
        if "uq_manual_course_rule" in str(exc).lower() or "unique constraint" in str(exc).lower():
            raise HTTPException(409, "相同的手动课程规则已经存在") from None
        raise
    await db.refresh(course)
    return response(ManualCourseOut.model_validate(course))

@app.patch("/api/v1/manual-courses/{course_id}")
async def update_manual_course(course_id: int, body: ManualCourseInput, db: AsyncSession = Depends(get_db)):
    course = await existing_manual_course(course_id, db)
    values = await validated_manual_course_values(body, db)
    for key, value in values.items():
        setattr(course, key, value)
    try:
        await db.commit()
    except Exception as exc:
        await db.rollback()
        if "uq_manual_course_rule" in str(exc).lower() or "unique constraint" in str(exc).lower():
            raise HTTPException(409, "相同的手动课程规则已经存在") from None
        raise
    await db.refresh(course)
    return response(ManualCourseOut.model_validate(course))

@app.delete("/api/v1/manual-courses/{course_id}")
async def delete_manual_course(course_id: int, db: AsyncSession = Depends(get_db)):
    course = await existing_manual_course(course_id, db)
    await db.delete(course)
    await db.commit()
    return response({"deleted": True})

@app.get("/api/v1/terms")
async def terms(db: AsyncSession=Depends(get_db)):
    # 学期仅来自用户导入的课表或成绩文件；不再请求教务系统。
    query = select(AcademicTerm).where(AcademicTerm.source_term_id >= "2024-2025-1").order_by(AcademicTerm.source_term_id)
    return response([TermOut.model_validate(row) for row in (await db.scalars(query)).all()])
@app.put("/api/v1/terms/{term_id}/start-date")
async def update_term_start_date(term_id: int, body: TermStartDateInput, db: AsyncSession = Depends(get_db)):
    try:
        return response({"sessions_generated": await set_term_start_date(db, term_id, body.start_date)})
    except ValueError as exc:
        raise HTTPException(422, str(exc))
@app.get("/api/v1/settings/period-times")
async def get_period_times(db: AsyncSession = Depends(get_db)):
    return response([PeriodTimeOut.model_validate(row) for row in await period_times(db)])
@app.put("/api/v1/settings/period-times/{period_number}")
async def update_period_time(period_number: int, body: PeriodTimeInput, db: AsyncSession = Depends(get_db)):
    try:
        return response({"sessions_generated": await set_period_time(db, period_number, body.start_time, body.end_time)})
    except ValueError as exc:
        raise HTTPException(422, str(exc))
def make_session_out(row: CourseSession, course: Course, rule: CourseRule | None = None)->CourseSessionOut:
    return CourseSessionOut(id=row.id,course_name=course.course_name,course_code=course.course_code,session_date=row.session_date,start_datetime=row.start_datetime,end_datetime=row.end_datetime,classroom=row.classroom,teacher=row.teacher,week_expression=rule.week_expression if rule else None,status=row.status,source="IMPORTED",term_id=course.term_id)

async def manual_course_sessions(
    db: AsyncSession,
    term_id: int | None = None,
    start_date: date | None = None,
    end_date: date | None = None,
) -> list[CourseSessionOut]:
    query = select(ManualCourse, AcademicTerm).join(AcademicTerm, AcademicTerm.id == ManualCourse.term_id)
    if term_id is not None:
        query = query.where(ManualCourse.term_id == term_id)
    period_map = {period.period_number: period for period in (await db.scalars(select(PeriodTime))).all()}
    result: list[CourseSessionOut] = []
    for course, term in (await db.execute(query.order_by(ManualCourse.id))).all():
        if term.start_date is None:
            continue
        start_period = period_map.get(course.start_period)
        end_period = period_map.get(course.end_period)
        if start_period is None or end_period is None:
            continue
        for week in sorted(parse_week_expression(course.week_expression)):
            session_day = term.start_date + timedelta(days=(week - 1) * 7 + course.weekday - 1)
            if start_date is not None and session_day < start_date:
                continue
            if end_date is not None and session_day > end_date:
                continue
            start_at = datetime.combine(session_day, datetime.strptime(start_period.start_time, "%H:%M").time())
            end_at = datetime.combine(session_day, datetime.strptime(end_period.end_time, "%H:%M").time())
            result.append(CourseSessionOut(
                id=-(course.id * 1000 + week), course_name=course.course_name, course_code="MANUAL",
                session_date=session_day, start_datetime=start_at, end_datetime=end_at,
                classroom=course.classroom, teacher=course.teacher, week_expression=course.week_expression,
                status="NORMAL", source="MANUAL", manual_course_id=course.id, term_id=course.term_id,
                weekday=course.weekday, start_period=course.start_period, end_period=course.end_period,
            ))
    return result

@app.get("/api/v1/timetable")
async def timetable(date_: str | None=None, term_id:int|None=None, db:AsyncSession=Depends(get_db)):
    query=select(CourseSession,Course,CourseRule).join(Course,Course.id==CourseSession.course_id).outerjoin(CourseRule,CourseRule.course_id==Course.id).order_by(CourseSession.start_datetime)
    target_date = datetime.fromisoformat(date_).date() if date_ else None
    if target_date: query=query.where(CourseSession.session_date==target_date)
    if term_id: query=query.where(Course.term_id==term_id)
    course_sessions = [make_session_out(a,b,c) for a,b,c in (await db.execute(query)).all()]
    manual_sessions = await manual_course_sessions(db, term_id=term_id, start_date=target_date, end_date=target_date)
    return response(sorted([*course_sessions, *manual_sessions], key=lambda item: item.start_datetime))
@app.get("/api/v1/timetable/today")
async def timetable_today(db:AsyncSession=Depends(get_db)): return await timetable(datetime.now().date().isoformat(),None,db)
@app.get("/api/v1/timetable/week")
async def timetable_week(week_start:str, db:AsyncSession=Depends(get_db)):
    start=datetime.fromisoformat(week_start).date(); end=start + timedelta(days=6)
    rows=(await db.execute(select(CourseSession,Course,CourseRule).join(Course).outerjoin(CourseRule,CourseRule.course_id==Course.id).where(CourseSession.session_date.between(start,end)).order_by(CourseSession.start_datetime))).all()
    course_sessions = [make_session_out(a,b,c) for a,b,c in rows]
    manual_sessions = await manual_course_sessions(db, start_date=start, end_date=end)
    return response(sorted([*course_sessions, *manual_sessions], key=lambda item: item.start_datetime))
@app.post("/api/v1/timetable/import-file")
async def timetable_import_file(file: UploadFile, db: AsyncSession = Depends(get_db)):
    if not (file.filename or "").lower().endswith(".xls"):
        raise HTTPException(422, "请选择教务系统打印导出的 .xls 课表文件")
    content = await file.read(2_000_001)
    if len(content) > 2_000_000:
        raise HTTPException(422, "课表文件不能超过 2 MB")
    try:
        source_term_id, raw_courses = parse_printed_timetable_xls(content)
        courses_imported, sessions_generated = await import_printed_timetable(db, source_term_id, raw_courses)
    except (ImportParseError, ValueError) as exc:
        raise HTTPException(422, str(exc))
    return response({"term_id": source_term_id, "courses_imported": courses_imported, "sessions_generated": sessions_generated, "ignored_notes": True})
@app.post("/api/v1/timetable/rebuild-sessions")
async def timetable_rebuild(term_id:int, db:AsyncSession=Depends(get_db)):
    try: return response({"sessions_generated":await rebuild_sessions(db,term_id)})
    except ValueError as exc: raise HTTPException(422,str(exc))
@app.get("/api/v1/grades")
async def grades(term_id:int|None=None, db:AsyncSession=Depends(get_db)):
    q=select(Grade).order_by(Grade.synced_at.desc());
    if term_id:q=q.where(Grade.term_id==term_id)
    return response([GradeOut.model_validate(x,from_attributes=True) for x in (await db.scalars(q)).all()])
@app.get("/api/v1/ai/settings")
async def get_ai_settings(db: AsyncSession = Depends(get_db)):
    return response(setting_out(await db.get(AiProviderSetting, 1)))
@app.put("/api/v1/ai/settings")
async def update_ai_settings(body: AiProviderSettingInput, db: AsyncSession = Depends(get_db)):
    try:
        return response(await save_ai_setting(db, body))
    except AiConfigurationError as exc:
        raise HTTPException(422, str(exc))
@app.post("/api/v1/ai/settings/test")
async def test_ai_settings(body: AiProviderSettingInput):
    try:
        return response(AiConnectionTestOut(**(await test_ai_connection(body))))
    except (AiConfigurationError, AiServiceError) as exc:
        raise HTTPException(422, str(exc))
@app.post("/api/v1/ai/settings/models")
async def ai_model_list(body: AiModelLookupInput):
    try:
        return response(AiModelListOut(models=await list_available_models(body)))
    except (AiConfigurationError, AiServiceError) as exc:
        raise HTTPException(422, str(exc))
@app.post("/api/v1/ai/settings/models/refresh")
async def refresh_ai_model_list(db: AsyncSession = Depends(get_db)):
    try:
        return response(await refresh_saved_models(db))
    except (AiConfigurationError, AiServiceError) as exc:
        raise HTTPException(422, str(exc))
@app.patch("/api/v1/ai/settings/model")
async def select_ai_model(body: AiModelSelectionInput, db: AsyncSession = Depends(get_db)):
    try:
        return response(await select_saved_model(db, body))
    except AiConfigurationError as exc:
        raise HTTPException(422, str(exc))
@app.delete("/api/v1/ai/settings")
async def clear_ai_settings(db: AsyncSession = Depends(get_db)):
    await delete_ai_setting(db)
    return response({"deleted": True})
@app.post("/api/v1/grades/ai-analysis")
async def grade_ai_analysis(term_id: int, force_refresh: bool = False, db: AsyncSession = Depends(get_db)):
    try:
        return response(await analyze_grades(db, term_id, force_refresh))
    except AiConfigurationError as exc:
        raise HTTPException(422, str(exc))
    except AiServiceError as exc:
        raise HTTPException(422, str(exc))

@app.get("/api/v1/grades/ai-analyses")
async def grade_ai_analysis_history(term_id: int | None = None, db: AsyncSession = Depends(get_db)):
    return response(await list_grade_ai_analyses(db, term_id))

@app.delete("/api/v1/grades/ai-analyses")
async def clear_grade_ai_analysis_history(term_id: int | None = None, db: AsyncSession = Depends(get_db)):
    return response({"deleted": await clear_grade_ai_analyses(db, term_id)})
@app.post("/api/v1/grades/import-file")
async def grades_import_preview(file: UploadFile, term_id: str | None = None):
    filename = file.filename or ""
    if not filename.lower().endswith((".xls", ".html", ".htm")):
        raise HTTPException(422, "请选择教务系统导出的 .xls 成绩文件或保存的 .html 成绩表")
    content = await file.read(2_000_001)
    if len(content) > 2_000_000:
        raise HTTPException(422, "成绩文件不能超过 2 MB")
    try:
        source_term_id, raw_grades = parse_grade_file(content, filename, term_id)
    except ImportParseError as exc:
        raise HTTPException(422, str(exc))
    items = [GradeImportItem(**raw.__dict__) for raw in raw_grades]
    return response(GradeImportPreviewOut(source_term_id=source_term_id, grades=items))

@app.post("/api/v1/grades/import-confirm")
async def grades_import_confirm(body: GradeImportConfirmInput, db: AsyncSession = Depends(get_db)):
    raw_grades = [RawGrade(**item.model_dump()) for item in body.grades]
    term, count = await import_grades(db, body.source_term_id, raw_grades)
    return response({"term_id": term.id, "source_term_id": term.source_term_id, "grades_imported": count})
@app.get("/api/v1/grades/summary")
async def grade_summary(term_id:int|None=None, db:AsyncSession=Depends(get_db)):
    query=select(Grade)
    if term_id: query=query.where(Grade.term_id==term_id)
    rows=(await db.scalars(query)).all(); numeric=[float(x.score) for x in rows if x.score and x.score.replace(".", "", 1).isdigit()]; gpa_rows=[x for x in rows if x.grade_point is not None and x.credits is not None]; credits=sum(x.credits or 0 for x in rows); earned=sum(x.credits or 0 for x in rows if x.score not in {"不及格","缺考","不通过"} and (not x.score or not x.score.isdigit() or float(x.score)>=60)); return response({"total_courses":len(rows),"total_credits":credits,"earned_credits":earned,"failed_courses":sum(1 for x in rows if x.score in {"不及格","缺考","不通过"} or (x.score and x.score.isdigit() and float(x.score)<60)),"average_score":sum(numeric)/len(numeric) if numeric else None,"gpa":sum((x.grade_point or 0)*(x.credits or 0) for x in gpa_rows)/sum(x.credits or 0 for x in gpa_rows) if gpa_rows else None,"gpa_note":"基于已获取课程数据的估算值" if gpa_rows else None})
