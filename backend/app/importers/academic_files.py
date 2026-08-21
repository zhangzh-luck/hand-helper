from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass

from bs4 import BeautifulSoup


class ImportParseError(ValueError):
    """用户上传的导出文件无法按已支持格式识别。"""


@dataclass
class RawCourse:
    source_course_id: str
    course_code: str
    course_name: str
    teacher: str | None
    credits: float | None
    classroom: str | None
    campus: str | None
    weekday: int
    start_period: int | None
    end_period: int | None
    start_time: str
    end_time: str
    week_expression: str
    raw_text: str = ""


@dataclass
class RawGrade:
    source_grade_id: str
    course_code: str
    course_name: str
    course_type: str | None
    credits: float | None
    score: str | None
    final_exam_score: str | None = None
    usual_score: str | None = None
    grade_point: float | None = None
    weighted_grade_point: float | None = None
    exam_type: str | None = None
    makeup_flag: bool = False
    retake_flag: bool = False
    raw_text: str = ""


_TERM_PATTERN = re.compile(r"(20\d{2})\s*[-—–－]\s*(20\d{2})\s*[-—–－]?\s*([12])")
_PRINTED_TERM_PATTERN = re.compile(r"学年学期\s*[：:]\s*(\d{4}-\d{4}-[12])")
_PRINTED_WEEK_PATTERN = re.compile(r"(?:第\s*)?([0-9,，、\-—]+)\s*(?:\[|（|\()?[周週](?:\]|）|\))?")
_PRINTED_PERIOD_PATTERN = re.compile(r"\[(\d{1,2})\s*[-—至]\s*(\d{1,2})\]\s*节")


def validate_term_id(value: str) -> str:
    if not re.fullmatch(r"20\d{2}-20\d{2}-[12]", value.strip()):
        raise ImportParseError("学期格式应为 YYYY-YYYY-1 或 YYYY-YYYY-2")
    return value.strip()


def _term_from_text(value: str) -> str | None:
    printed = _PRINTED_TERM_PATTERN.search(value)
    if printed:
        return printed.group(1)
    match = _TERM_PATTERN.search(value)
    return f"{match.group(1)}-{match.group(2)}-{match.group(3)}" if match else None


def _normalise_printed_week_expression(value: str) -> str | None:
    match = _PRINTED_WEEK_PATTERN.search(value)
    if not match:
        return None
    return f"{match.group(1).replace('，', ',').replace('、', ',').replace('—', '-')}周"


def _is_class_label(value: str) -> bool:
    return value.startswith(("(", "（")) and value.endswith((")", "）")) and bool(re.search(r"\d", value))


def parse_week_expression(expression: str) -> set[int]:
    raw = expression.strip().replace("，", ",").replace("第", "").replace("周", "")
    if not raw:
        raise ImportParseError("周次规则为空")
    odd, even = "单" in raw, "双" in raw
    if odd and even:
        raise ImportParseError(f"周次规则冲突: {expression}")
    raw = raw.replace("(单)", "").replace("（单）", "").replace("(双)", "").replace("（双）", "").replace("单", "").replace("双", "")
    weeks: set[int] = set()
    for part in filter(None, (item.strip() for item in raw.split(","))):
        match = re.fullmatch(r"(\d+)\s*-\s*(\d+)", part)
        if match:
            start, end = map(int, match.groups())
            if start < 1 or end < start or end > 60:
                raise ImportParseError(f"非法周次范围: {part}")
            weeks.update(range(start, end + 1))
        elif part.isdigit() and 1 <= int(part) <= 60:
            weeks.add(int(part))
        else:
            raise ImportParseError(f"无法解析周次规则: {expression}")
    if not weeks:
        raise ImportParseError(f"无法解析周次规则: {expression}")
    return {week for week in weeks if (not odd or week % 2) and (not even or not week % 2)}


def parse_printed_timetable_grid(rows: list[list[str]]) -> tuple[str, list[RawCourse]]:
    if len(rows) < 4:
        raise ImportParseError("课表文件结构变化：缺少课程网格")
    term_id = _term_from_text(" ".join(" ".join(row) for row in rows[:3]))
    if not term_id:
        raise ImportParseError("课表文件结构变化：未找到学年学期")
    courses: list[RawCourse] = []
    for row in rows[3:]:
        if row and str(row[0]).strip().startswith("备注"):
            break
        for weekday, value in enumerate(row[1:8], start=1):
            text = str(value or "").strip()
            if not text:
                continue
            lines = [line.strip() for line in re.split(r"[\r\n]+", text) if line.strip()]
            period_line = next((line for line in lines if _PRINTED_PERIOD_PATTERN.search(line)), None)
            week_line = next((line for line in lines if _normalise_printed_week_expression(line)), None)
            if not period_line or not week_line:
                raise ImportParseError("课表文件结构变化：课程格缺少周次或节次")
            period_match = _PRINTED_PERIOD_PATTERN.search(period_line)
            assert period_match
            start_period, end_period = map(int, period_match.groups())
            if not 1 <= start_period <= end_period <= 13:
                raise ImportParseError(f"课表文件中的节次不受支持：{start_period}-{end_period}")
            week_index = lines.index(week_line)
            teacher_candidates = [line for line in lines[1:week_index] if not _is_class_label(line)]
            classroom_candidates = [line for line in lines[week_index + 1:] if line != period_line]
            week_expression = _normalise_printed_week_expression(week_line)
            assert week_expression
            source_id = hashlib.sha256(f"printed-xls|{term_id}|{weekday}|{start_period}|{text}".encode("utf-8")).hexdigest()
            courses.append(RawCourse(source_id, "", lines[0], teacher_candidates[-1] if teacher_candidates else None, None, classroom_candidates[0] if classroom_candidates else None, None, weekday, start_period, end_period, "", "", week_expression, text))
    if not courses:
        raise ImportParseError("课表文件中没有可导入的理论课程")
    return term_id, courses


def _xls_rows(content: bytes, label: str) -> list[list[str]]:
    if len(content) < 8 or not content.startswith(bytes.fromhex("D0CF11E0")):
        raise ImportParseError(f"仅支持教务系统导出的 .xls {label}文件")
    try:
        import xlrd
        workbook = xlrd.open_workbook(file_contents=content, on_demand=True)
        sheet = workbook.sheet_by_index(0)
        return [[str(sheet.cell_value(row, col)).strip() for col in range(sheet.ncols)] for row in range(sheet.nrows)]
    except Exception as exc:
        raise ImportParseError(f"{label}文件无法读取，请重新从教务系统导出 .xls 文件") from exc


def parse_printed_timetable_xls(content: bytes) -> tuple[str, list[RawCourse]]:
    return parse_printed_timetable_grid(_xls_rows(content, "课表"))


def _normalise_header(value: str) -> str:
    return re.sub(r"\s+", "", value).replace("（", "(").replace("）", ")")


_COLUMN_ALIASES = {
    "course_code": {"课程编号", "课程代码", "课程号"},
    "course_name": {"课程名称", "课程名"},
    "course_type": {"课程性质", "课程类别", "课程类型"},
    "usual_score": {"平时成绩", "平时"},
    "final_exam_score": {"期末成绩", "期末", "卷面成绩"},
    "score": {"成绩", "总评成绩", "最终成绩", "总成绩"},
    "credits": {"学分", "学分数"},
    "grade_point": {"绩点"},
    "weighted_grade_point": {"学分绩点", "加权绩点"},
    "makeup_retake": {"补重学期", "补考重修", "补考/重修"},
    "exam_type": {"考试性质", "考试类型"},
}


def _number(value: str | None) -> float | None:
    if not value:
        return None
    match = re.fullmatch(r"\s*(-?\d+(?:\.\d+)?)\s*", value)
    return float(match.group(1)) if match else None


def _field(row: dict[str, str], name: str) -> str:
    aliases = _COLUMN_ALIASES[name]
    return next((value for header, value in row.items() if _normalise_header(header) in aliases), "").strip()


def _grades_from_rows(rows: list[list[str]], term_id: str) -> list[RawGrade]:
    headers: list[str] | None = None
    data_rows: list[list[str]] = []
    for index, row in enumerate(rows):
        normalised = {_normalise_header(value) for value in row if value}
        if normalised & _COLUMN_ALIASES["course_name"] and normalised & _COLUMN_ALIASES["score"]:
            headers = row
            data_rows = rows[index + 1:]
            break
    if not headers:
        raise ImportParseError("成绩文件缺少“课程名称”和“成绩”表头")
    grades: list[RawGrade] = []
    for index, values in enumerate(data_rows, start=1):
        if not any(values):
            continue
        row = dict(zip(headers, values, strict=False))
        course_name = _field(row, "course_name")
        if not course_name:
            continue
        course_code = _field(row, "course_code")
        score = _field(row, "score") or None
        makeup_or_retake = _field(row, "makeup_retake")
        source_id = hashlib.sha256(f"imported-grade|{term_id}|{course_code}|{course_name}|{score or ''}|{index}".encode()).hexdigest()
        grades.append(RawGrade(
            source_grade_id=source_id, course_code=course_code, course_name=course_name,
            course_type=_field(row, "course_type") or None, credits=_number(_field(row, "credits")),
            score=score, final_exam_score=_field(row, "final_exam_score") or None,
            usual_score=_field(row, "usual_score") or None, grade_point=_number(_field(row, "grade_point")),
            weighted_grade_point=_number(_field(row, "weighted_grade_point")), exam_type=_field(row, "exam_type") or None,
            makeup_flag="补" in makeup_or_retake, retake_flag="重" in makeup_or_retake,
            raw_text=" | ".join(f"{key}={value}" for key, value in row.items()),
        ))
    if not grades:
        raise ImportParseError("成绩文件中没有可导入的课程成绩")
    return grades


def parse_grades_html(html: str, term_id: str) -> list[RawGrade]:
    soup = BeautifulSoup(html, "lxml")
    for table in soup.find_all("table"):
        rows = [[cell.get_text(" ", strip=True) for cell in row.find_all(["th", "td"], recursive=False)] for row in table.find_all("tr")]
        try:
            return _grades_from_rows(rows, term_id)
        except ImportParseError:
            continue
    raise ImportParseError("成绩文件中未找到包含“课程名称”和“成绩”的表格")


def parse_grade_file(content: bytes, filename: str, selected_term_id: str | None = None) -> tuple[str, list[RawGrade]]:
    name = filename.lower()
    explicit_term = validate_term_id(selected_term_id) if selected_term_id else None
    if name.endswith((".html", ".htm")) or content.lstrip().startswith(b"<"):
        for encoding in ("utf-8", "gb18030"):
            try:
                html = content.decode(encoding)
                term_id = explicit_term or _term_from_text(BeautifulSoup(html, "lxml").get_text(" ", strip=True))
                if not term_id:
                    raise ImportParseError("成绩文件未标明学期，请先在页面选择学期")
                return term_id, parse_grades_html(html, term_id)
            except UnicodeDecodeError:
                continue
        raise ImportParseError("成绩 HTML 文件编码无法识别")
    if not name.endswith(".xls"):
        raise ImportParseError("目前支持教务系统导出的 .xls 成绩文件或保存的 .html 成绩表")
    rows = _xls_rows(content, "成绩")
    term_id = explicit_term or _term_from_text(" ".join(" ".join(row) for row in rows[:8]))
    if not term_id:
        raise ImportParseError("成绩文件未标明学期，请先在页面选择学期")
    return term_id, _grades_from_rows(rows, term_id)
