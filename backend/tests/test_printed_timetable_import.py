from app.importers.academic_files import parse_printed_timetable_grid


def test_printed_timetable_grid_parser_keeps_teacher_and_week_rule():
    rows = [
        ["云南师范大学 学生个人课表"],
        ["学年学期：2026-2027-1 班级：数据科学与大数据技术24H"],
        ["时间", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"],
        ["08:30-10:05", "开源大数据技术\n熊文(副教授)\n1-18[周]\n汇学楼4幢副203(多媒体)\n[01-02]节", "", "", "", "", "", ""],
        ["15:30-18:05", "就业指导\n(信息学院02)\n都俊朕(未定级)\n9-16[周]\n汇学楼3幢312(多媒体)\n[07-08]节", "", "", "", "", "", ""],
        ["备注", "工程实训(2) 1-20周"],
    ]
    term_id, courses = parse_printed_timetable_grid(rows)
    assert term_id == "2026-2027-1"
    assert len(courses) == 2
    assert courses[1].course_name == "就业指导"
    assert courses[1].teacher == "都俊朕(未定级)"
    assert courses[1].week_expression == "9-16周"
    assert (courses[1].start_period, courses[1].end_period) == (7, 8)
