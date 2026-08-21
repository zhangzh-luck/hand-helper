from pathlib import Path

import pytest

from app.importers.academic_files import ImportParseError, parse_grade_file, parse_printed_timetable_grid, parse_week_expression


@pytest.mark.parametrize(("expression", "expected"), [("1-16周", set(range(1, 17))), ("1,3,5,7周", {1, 3, 5, 7}), ("1-16周(单)", set(range(1, 17, 2))), ("9-16周", set(range(9, 17))), ("第1-4,7-10周", {1, 2, 3, 4, 7, 8, 9, 10})])
def test_week_expressions(expression, expected):
    assert parse_week_expression(expression) == expected


def test_invalid_week_expression():
    with pytest.raises(ImportParseError):
        parse_week_expression("明年再说")


def test_grade_html_parser_keeps_optional_empty_fields():
    html = (Path(__file__).parent / "fixtures" / "grades.html").read_bytes()
    term_id, grades = parse_grade_file(html, "grades.html", "2025-2026-2")
    assert term_id == "2025-2026-2"
    assert len(grades) == 1 and grades[0].course_code == "C001" and grades[0].usual_score is None and grades[0].grade_point == 3.8


def test_grade_file_requires_term_when_file_has_none():
    with pytest.raises(ImportParseError, match="未标明学期"):
        parse_grade_file("<table><tr><th>课程名称</th><th>成绩</th></tr><tr><td>测试</td><td>90</td></tr></table>".encode("utf-8"), "grades.html")


def test_timetable_grid_parser_keeps_teacher_and_week_rule():
    rows = [["云南师范大学 学生个人课表"], ["学年学期：2026-2027-1"], ["时间", "星期一"], ["08:30-10:05", "就业指导\n(信息学院02)\n脱敏教师\n9-16[周]\n脱敏教室\n[01-02]节"]]
    term_id, courses = parse_printed_timetable_grid(rows)
    assert term_id == "2026-2027-1"
    assert courses[0].week_expression == "9-16周" and courses[0].start_period == 1 and courses[0].end_period == 2
