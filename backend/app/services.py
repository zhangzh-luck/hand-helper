from __future__ import annotations

import hashlib
from datetime import date, datetime, timedelta

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db_models import AcademicTerm, Course, CourseRule, CourseSession, Grade, PeriodTime
from app.importers.academic_files import RawCourse, RawGrade, parse_week_expression, validate_term_id

CONFIRMED_TERM_START_DATES = {"2026-2027-1": date(2026, 9, 7), "2026-2027-2": date(2027, 3, 1)}
CONFIRMED_PERIOD_TIMES = {
    1: ("08:30", "09:15"), 2: ("09:20", "10:05"), 3: ("10:25", "11:10"), 4: ("11:15", "12:00"),
    5: ("13:40", "14:25"), 6: ("14:30", "15:15"), 7: ("15:30", "16:15"), 8: ("16:30", "17:15"),
    9: ("17:20", "18:05"), 10: ("18:20", "19:05"), 11: ("19:10", "19:55"), 12: ("20:00", "20:45"), 13: ("20:50", "21:35"),
}


def stable_hash(*values: object) -> str:
    return hashlib.sha256("|".join(str(value) for value in values).encode()).hexdigest()


async def ensure_period_times(db: AsyncSession) -> None:
    if await db.scalar(select(PeriodTime.id).limit(1)):
        return
    db.add_all([PeriodTime(period_number=number, start_time=value[0], end_time=value[1]) for number, value in CONFIRMED_PERIOD_TIMES.items()])
    await db.commit()


async def period_times(db: AsyncSession) -> list[PeriodTime]:
    await ensure_period_times(db)
    return list((await db.scalars(select(PeriodTime).order_by(PeriodTime.period_number))).all())


async def ensure_local_term(db: AsyncSession, source_term_id: str) -> AcademicTerm:
    source_term_id = validate_term_id(source_term_id)
    term = await db.scalar(select(AcademicTerm).where(AcademicTerm.source_term_id == source_term_id))
    if term:
        return term
    year, term_number = source_term_id.rsplit("-", 1)
    term = AcademicTerm(source_term_id=source_term_id, academic_year=year, term_number=term_number, display_name=source_term_id, start_date=CONFIRMED_TERM_START_DATES.get(source_term_id), end_date=None, is_current=False)
    db.add(term)
    await db.flush()
    return term


async def set_term_start_date(db: AsyncSession, term_id: int, start_date: date) -> int:
    if start_date.weekday() != 0:
        raise ValueError("学期第一周日期必须是星期一")
    term = await db.get(AcademicTerm, term_id)
    if not term:
        raise ValueError("学期不存在")
    term.start_date = start_date
    await db.commit()
    return await rebuild_sessions(db, term_id)


async def set_period_time(db: AsyncSession, period_number: int, start_time: str, end_time: str) -> int:
    if period_number < 1:
        raise ValueError("节次编号必须大于 0")
    await ensure_period_times(db)
    row = await db.scalar(select(PeriodTime).where(PeriodTime.period_number == period_number))
    if not row:
        raise ValueError("该节次不存在")
    row.start_time, row.end_time = start_time, end_time
    rules = (await db.scalars(select(CourseRule).where((CourseRule.start_period == period_number) | (CourseRule.end_period == period_number)))).all()
    for rule in rules:
        if rule.start_period == period_number:
            rule.start_time = start_time
        if rule.end_period == period_number:
            rule.end_time = end_time
    await db.commit()
    count = 0
    for term in (await db.scalars(select(AcademicTerm).where(AcademicTerm.start_date.is_not(None)))).all():
        count += await rebuild_sessions(db, term.id)
    return count


async def import_printed_timetable(db: AsyncSession, source_term_id: str, raw_courses: list[RawCourse]) -> tuple[int, int]:
    """导入用户上传的打印课表快照，完全不访问教务系统。"""
    await ensure_period_times(db)
    term = await ensure_local_term(db, source_term_id)
    times = {item.period_number: item for item in (await db.scalars(select(PeriodTime))).all()}
    existing_course_ids = list((await db.scalars(select(Course.id).where(Course.term_id == term.id))).all())
    if existing_course_ids:
        await db.execute(delete(CourseSession).where(CourseSession.course_id.in_(existing_course_ids)))
        await db.execute(delete(CourseRule).where(CourseRule.course_id.in_(existing_course_ids)))
        await db.execute(delete(Course).where(Course.id.in_(existing_course_ids)))
    for raw in raw_courses:
        if raw.start_period not in times or raw.end_period not in times:
            raise ValueError(f"未配置第 {raw.start_period}-{raw.end_period} 节时间")
        course = Course(source_course_id=raw.source_course_id, course_code=raw.course_code, course_name=raw.course_name, teacher=raw.teacher, credits=raw.credits, classroom=raw.classroom, campus=raw.campus, term_id=term.id)
        db.add(course)
        await db.flush()
        db.add(CourseRule(course_id=course.id, weekday=raw.weekday, start_period=raw.start_period, end_period=raw.end_period, start_time=times[raw.start_period].start_time, end_time=times[raw.end_period].end_time, week_expression=raw.week_expression, raw_text=raw.raw_text))
    await db.commit()
    return len(raw_courses), await rebuild_sessions(db, term.id) if term.start_date else 0


async def rebuild_sessions(db: AsyncSession, term_id: int) -> int:
    term = await db.get(AcademicTerm, term_id)
    if not term or not term.start_date:
        raise ValueError("尚未配置学期第一周周一，无法生成课程日期")
    courses = list((await db.scalars(select(Course).where(Course.term_id == term_id))).all())
    course_ids = [course.id for course in courses]
    if course_ids:
        await db.execute(delete(CourseSession).where(CourseSession.course_id.in_(course_ids)))
    count = 0
    for course in courses:
        for rule in (await db.scalars(select(CourseRule).where(CourseRule.course_id == course.id))).all():
            for week in parse_week_expression(rule.week_expression):
                day = term.start_date + timedelta(days=(week - 1) * 7 + rule.weekday - 1)
                start = datetime.combine(day, datetime.strptime(rule.start_time, "%H:%M").time())
                end = datetime.combine(day, datetime.strptime(rule.end_time, "%H:%M").time())
                db.add(CourseSession(course_id=course.id, session_date=day, start_datetime=start, end_datetime=end, classroom=course.classroom, teacher=course.teacher, status="NORMAL", source_hash=stable_hash(course.id, day, start, end, rule.week_expression)))
                count += 1
    await db.commit()
    return count


async def import_grades(db: AsyncSession, source_term_id: str, raw_grades: list[RawGrade]) -> tuple[AcademicTerm, int]:
    """以用户确认的文件预览覆盖一个学期的成绩缓存；不保存上传原文件。"""
    term = await ensure_local_term(db, source_term_id)
    await db.execute(delete(Grade).where(Grade.term_id == term.id))
    now = datetime.utcnow()
    for raw in raw_grades:
        db.add(Grade(source_grade_id=raw.source_grade_id, term_id=term.id, course_code=raw.course_code, course_name=raw.course_name, course_type=raw.course_type, credits=raw.credits, score=raw.score, final_exam_score=raw.final_exam_score, usual_score=raw.usual_score, grade_point=raw.grade_point, weighted_grade_point=raw.weighted_grade_point, exam_type=raw.exam_type, makeup_flag=raw.makeup_flag, retake_flag=raw.retake_flag, source_hash=stable_hash(raw.source_grade_id, raw.score, raw.grade_point), synced_at=now))
    await db.commit()
    return term, len(raw_grades)
