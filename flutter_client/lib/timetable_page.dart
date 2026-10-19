import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'container_morph_transition.dart';
import 'native_tab_bridge.dart';
import 'today_page.dart' show dataImage;

DateTime mondayOf(DateTime date) {
  final noon = DateTime(date.year, date.month, date.day, 12);
  return noon.subtract(Duration(days: noon.weekday - 1));
}

DateTime weekAt(DateTime monday, int offset) =>
    DateTime(monday.year, monday.month, monday.day + offset * 7, 12);

int? weekNumber(DateTime monday, TermInfo? term) {
  if (term?.startDate == null) return null;
  final start = mondayOf(DateTime.parse(term!.startDate!));
  final days = monday.difference(start).inDays;
  return days < 0 ? null : days ~/ 7 + 1;
}

String academicTermSourceId(DateTime date) => date.month >= 9
    ? '${date.year}-${date.year + 1}-1'
    : '${date.year - 1}-${date.year}-2';

const defaultPeriods = <PeriodInfo>[
  PeriodInfo(1, '08:30', '09:15'),
  PeriodInfo(2, '09:20', '10:05'),
  PeriodInfo(3, '10:25', '11:10'),
  PeriodInfo(4, '11:15', '12:00'),
  PeriodInfo(5, '13:40', '14:25'),
  PeriodInfo(6, '14:30', '15:15'),
  PeriodInfo(7, '15:30', '16:15'),
  PeriodInfo(8, '16:30', '17:15'),
  PeriodInfo(9, '17:20', '18:05'),
  PeriodInfo(10, '18:20', '19:05'),
  PeriodInfo(11, '19:10', '19:55'),
  PeriodInfo(12, '20:00', '20:45'),
  PeriodInfo(13, '20:50', '21:35'),
];

/// Keep PageView's full-width pages while committing a deliberate short drag.
/// PageView's built-in snapping otherwise needs roughly half the screen when
/// the release velocity is low.
class _WeekSnapPhysics extends ScrollPhysics {
  const _WeekSnapPhysics({required this.startPage, super.parent});

  final int? Function() startPage;

  @override
  _WeekSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _WeekSnapPhysics(startPage: startPage, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (position.viewportDimension <= 0 || position.outOfRange) {
      return super.createBallisticSimulation(position, velocity);
    }
    final page = position.pixels / position.viewportDimension;
    final start = startPage();
    var target = page.round();
    if (start != null) {
      final travel = page - start;
      final flick = velocity.abs() >= 350 && travel.abs() >= .04;
      // The drag recognizer consumes touch slop before the page starts moving.
      // 22% of scroll travel is about a quarter-screen finger movement.
      if (travel.abs() >= .22 || flick) {
        target = start + (flick ? velocity.sign : travel.sign).toInt();
      } else {
        target = start;
      }
    }
    final destination = (target * position.viewportDimension)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    final tolerance = toleranceFor(position);
    if ((destination - position.pixels).abs() < tolerance.distance &&
        velocity.abs() < tolerance.velocity) {
      return null;
    }
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      destination,
      velocity,
      tolerance: tolerance,
    );
  }
}

int? periodStart(TimetableCourse course, List<PeriodInfo> periods) {
  if (course.startPeriod != null) return course.startPeriod;
  final time =
      '${course.start.hour.toString().padLeft(2, '0')}:${course.start.minute.toString().padLeft(2, '0')}';
  for (final period in periods) {
    if (period.start == time) return period.number;
  }
  return null;
}

int? periodEnd(TimetableCourse course, List<PeriodInfo> periods) {
  if (course.endPeriod != null) return course.endPeriod;
  final time =
      '${course.end.hour.toString().padLeft(2, '0')}:${course.end.minute.toString().padLeft(2, '0')}';
  for (final period in periods) {
    if (period.end == time) return period.number;
  }
  return null;
}

class TimetablePage extends StatefulWidget {
  const TimetablePage({
    super.key,
    required this.api,
    required this.onUnauthorized,
    this.localProfileChanges,
  });
  final ApiClient api;
  final VoidCallback onUnauthorized;
  final ValueListenable<Profile?>? localProfileChanges;
  @override
  State<TimetablePage> createState() => _TimetablePageState();
}

class _TimetablePageState extends State<TimetablePage> {
  static const middlePage = 1000;
  late final PageController pager = PageController(initialPage: middlePage);
  DateTime origin = mondayOf(DateTime.now());
  int pageIndex = middlePage;
  int? dragStartPage;
  TimetableData? data;
  String? selectedTermSourceId;
  bool online = false;
  bool loading = true;
  bool refreshing = false;
  String? error;
  (int, int)? armedSlot;
  String? _backgroundSource;
  ImageProvider? _backgroundImage;
  final Expando<GlobalKey> _courseCardKeys = Expando<GlobalKey>();
  TimetableCourse? _activeCourse;
  int? _activeCoursePage;
  String? _activeCourseTerm;

  @override
  void initState() {
    super.initState();
    widget.localProfileChanges?.addListener(onLocalProfileChanged);
    initialize();
  }

  @override
  void dispose() {
    widget.localProfileChanges?.removeListener(onLocalProfileChanged);
    pager.dispose();
    super.dispose();
  }

  void onLocalProfileChanged() {
    if (mounted) setState(() {});
  }

  TermInfo? get selectedTerm {
    final terms = data?.terms ?? [];
    if (terms.isEmpty) return null;
    for (final term in terms) {
      if (term.sourceId == selectedTermSourceId) return term;
    }
    for (final term in terms) {
      if (term.isCurrent) return term;
    }
    final academicId = academicTermSourceId(DateTime.now());
    for (final term in terms) {
      if (term.sourceId == academicId) return term;
    }
    return terms.first;
  }

  DateTime get currentMonday => weekAt(origin, pageIndex - middlePage);

  ImageProvider? _backgroundFor(String? source) {
    // MemoryImage compares the byte-buffer identity. Decoding the same data
    // URL on every page change would replace the image stream for one frame.
    if (source != _backgroundSource) {
      _backgroundSource = source;
      _backgroundImage = dataImage(source);
    }
    return _backgroundImage;
  }

  Future<void> initialize() async {
    final savedTerm = await widget.api.selectedTimetableTerm();
    final snapshot = await widget.api.loadTimetableSnapshot();
    if (!mounted) return;
    setState(() {
      selectedTermSourceId = savedTerm;
      data = snapshot;
      loading = false;
    });
    await refresh();
  }

  Future<void> refresh() async {
    if (refreshing) return;
    setState(() => refreshing = true);
    try {
      final fresh = await widget.api.timetable();
      if (!mounted) return;
      final invalidPreferred =
          selectedTermSourceId != null &&
          !fresh.terms.any((term) => term.sourceId == selectedTermSourceId);
      setState(() {
        data = fresh;
        online = true;
        error = null;
        loading = false;
        if (invalidPreferred) selectedTermSourceId = null;
      });
      if (invalidPreferred) {
        try {
          await widget.api.saveSelectedTimetableTerm(null);
        } catch (_) {
          /* The timetable remains usable if preferences are unavailable. */
        }
      }
    } on ApiFailure catch (failure) {
      if (failure.unauthorized) {
        if (mounted) widget.onUnauthorized();
        return;
      }
      if (mounted)
        setState(() {
          online = false;
          error = failure.message;
          loading = false;
        });
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  Future<void> selectTerm(int id) async {
    final matches = data?.terms.where((term) => term.id == id);
    if (matches == null || matches.isEmpty) return;
    final sourceId = matches.first.sourceId;
    setState(() {
      selectedTermSourceId = sourceId;
      armedSlot = null;
    });
    try {
      await widget.api.saveSelectedTimetableTerm(sourceId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('学期已切换，但未能保存到本机。')));
      }
    }
  }

  void move(int direction) {
    final term = selectedTerm;
    if (direction > 0 &&
        term?.startDate != null &&
        currentMonday.isBefore(mondayOf(DateTime.parse(term!.startDate!)))) {
      final next = mondayOf(DateTime.parse(term.startDate!));
      setState(() {
        origin = next;
        pageIndex = middlePage;
        armedSlot = null;
      });
      pager.jumpToPage(middlePage);
      return;
    }
    pager.animateToPage(
      pageIndex + direction,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void jumpToday() {
    setState(() {
      origin = mondayOf(DateTime.now());
      pageIndex = middlePage;
      armedSlot = null;
    });
    pager.jumpToPage(middlePage);
  }

  Rect? _courseRect(TimetableCourse course) {
    if (!identical(_activeCourse, course) ||
        _activeCoursePage != pageIndex ||
        _activeCourseTerm != selectedTerm?.sourceId ||
        !(data?.coursesByTerm[selectedTerm?.id] ?? []).any(
          (item) => identical(item, course),
        )) {
      return null;
    }
    final box = _courseCardKeys[course]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (!rect.isFinite || rect.width <= 0 || rect.height <= 0) return null;
    var ancestor = box.parent;
    while (ancestor != null) {
      if (ancestor is RenderViewport) {
        final viewport = ancestor.localToGlobal(Offset.zero) & ancestor.size;
        if (!rect.overlaps(viewport)) return null;
      }
      ancestor = ancestor.parent;
    }
    return rect.overlaps(Offset.zero & MediaQuery.sizeOf(context))
        ? rect
        : null;
  }

  Rect? _courseGridViewportRect(TimetableCourse course) {
    final box = _courseCardKeys[course]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    var ancestor = box.parent;
    while (ancestor != null) {
      // SingleChildScrollView uses a private RenderAbstractViewport rather
      // than RenderViewport. It is the nearest viewport around a course card;
      // the outer (horizontal) week PageView comes later in the ancestry.
      if (ancestor is RenderAbstractViewport && ancestor is RenderBox) {
        final viewport = ancestor as RenderBox;
        return viewport.localToGlobal(Offset.zero) & viewport.size;
      }
      ancestor = ancestor.parent;
    }
    return null;
  }

  Future<void> showCourse(TimetableCourse course, int span) async {
    if (_activeCourse != null) return;
    _activeCourse = course;
    _activeCoursePage = pageIndex;
    _activeCourseTerm = selectedTerm?.sourceId;
    final startRect = _courseRect(course);
    if (startRect == null) {
      _activeCourse = null;
      _activeCoursePage = null;
      _activeCourseTerm = null;
      return;
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final gridViewportRect = _courseGridViewportRect(course);
    final tone = _courseColor(course.name, dark);
    final closedColor = Color.alphaBlend(
      tone,
      dark ? const Color(0xff1c1c1e) : const Color(0xfff4f7fb),
    );
    HapticFeedback.lightImpact();
    setState(() => armedSlot = null);
    try {
      final action = await showGeneralDialog<_CourseDetailAction>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        barrierColor: Colors.transparent,
        transitionDuration: Duration.zero,
        pageBuilder: (context, _, _) => _CourseMorphDialog(
          course: course,
          startRect: startRect,
          gridViewportRect: gridViewportRect,
          currentSourceRect: () => mounted ? _courseRect(course) : null,
          closedColor: closedColor,
          sourceContent: _courseCardText(course, span),
        ),
      );
      if (!mounted) return;
      setState(() {
        _activeCourse = null;
        _activeCoursePage = null;
        _activeCourseTerm = null;
      });
      if (action == _CourseDetailAction.edit) {
        await editCourse(course: course);
      } else if (action == _CourseDetailAction.delete) {
        await deleteCourse(course);
      }
    } finally {
      if (mounted) {
        setState(() {
          _activeCourse = null;
          _activeCoursePage = null;
          _activeCourseTerm = null;
        });
      }
    }
  }

  Widget _courseCardText(TimetableCourse course, int span) {
    final labels = Column(
      mainAxisSize: span > 1 ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          course.name,
          maxLines: span > 1 ? 3 : 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 12,
            height: 1.12,
            fontWeight: FontWeight.w700,
            color: Color(0xff202025),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          course.room ?? '教室待定',
          maxLines: span > 1 ? 3 : 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: Color(0xff303039)),
        ),
        if (span > 1) ...[
          const Spacer(),
          Text(
            _teacher(course.teacher),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: Color(0xff484850)),
          ),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.all(5),
      child: ClipRect(
        child: span > 1
            ? labels
            : LayoutBuilder(
                builder: (context, size) => FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: size.maxWidth, child: labels),
                ),
              ),
      ),
    );
  }

  Future<void> editCourse({
    TimetableCourse? course,
    int? weekday,
    int? period,
  }) async {
    if (course == null && _activeCourse != null) return;
    if (selectedTerm == null ||
        selectedTerm!.startDate == null ||
        data?.periods.isEmpty != false)
      return;
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => ManualCourseEditor(
        api: widget.api,
        term: selectedTerm!,
        periods: data!.periods.isEmpty ? defaultPeriods : data!.periods,
        course: course,
        weekday: weekday,
        period: period,
        initialWeek: weekNumber(currentMonday, selectedTerm) ?? 1,
      ),
    );
    if (changed == true) await reloadLocalCourses();
  }

  Future<void> deleteCourse(TimetableCourse course) async {
    if (course.manualId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除“${course.name}”？'),
        content: const Text('删除后无法恢复这门手动添加的课程。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除课程'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.deleteManualCourse(course.manualId!);
      await reloadLocalCourses();
    } on ApiFailure catch (failure) {
      if (failure.unauthorized) {
        widget.onUnauthorized();
        return;
      }
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }

  Future<void> reloadLocalCourses() async {
    final snapshot = await widget.api.loadTimetableSnapshot();
    if (mounted && snapshot != null)
      setState(() {
        data = snapshot;
        armedSlot = null;
      });
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final term = selectedTerm;
    final number = weekNumber(currentMonday, term);
    final terms = data?.terms ?? [];
    final background = _backgroundFor(
      widget.localProfileChanges?.value == null
          ? data?.background
          : widget.localProfileChanges!.value!.timetableBackground,
    );
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Container(
            height: 66 * math.max(1, textScale),
            padding: const EdgeInsets.fromLTRB(18, 4, 12, 4),
            decoration: BoxDecoration(
              color: dark ? const Color(0xff141416) : Colors.white,
              border: Border(
                bottom: BorderSide(
                  color: dark ? Colors.white10 : const Color(0xffe8eaf0),
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: PopupMenuButton<int>(
                    enabled: terms.isNotEmpty,
                    onSelected: selectTerm,
                    itemBuilder: (context) => [
                      for (final item in terms)
                        PopupMenuItem(value: item.id, child: Text(item.name)),
                    ],
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              number == null ? '假期中' : '第 $number 周',
                              style: const TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(width: 5),
                            const Icon(Icons.keyboard_arrow_down, size: 18),
                          ],
                        ),
                        Text(
                          term?.name ?? '选择学期',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: dark
                                ? Colors.white60
                                : const Color(0xff64748b),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => move(-1),
                  icon: const Icon(Icons.chevron_left),
                  tooltip: '上一周',
                ),
                TextButton(onPressed: jumpToday, child: const Text('今天')),
                IconButton(
                  onPressed: () => move(1),
                  icon: const Icon(Icons.chevron_right),
                  tooltip: '下一周或开学周',
                ),
              ],
            ),
          ),
          if (loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (data == null)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('课表尚未缓存，请联网后重试'),
                    TextButton(
                      onPressed: refreshing ? null : refresh,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            )
          else if (terms.isEmpty)
            const Expanded(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('请在“设置 → 数据与导入”中导入教务系统打印的课程表文件。'),
                ),
              ),
            )
          else
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    key: const Key('timetable-fixed-backdrop'),
                    child: background == null
                        ? CustomPaint(painter: _FallbackBackdrop(dark))
                        : Image(
                            image: background,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          ),
                  ),
                  Positioned.fill(
                    child: ColoredBox(
                      color: dark
                          ? const Color(0x57000000)
                          : const Color(0x29ffffff),
                    ),
                  ),
                  NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification.depth != 0 ||
                          notification.metrics.axis != Axis.horizontal) {
                        return false;
                      }
                      if (notification is ScrollStartNotification &&
                          notification.dragDetails != null) {
                        dragStartPage = (pager.page ?? pageIndex.toDouble())
                            .round();
                      } else if (notification is ScrollEndNotification) {
                        dragStartPage = null;
                      }
                      return false;
                    },
                    child: PageView.builder(
                      controller: pager,
                      pageSnapping: false,
                      physics: _WeekSnapPhysics(startPage: () => dragStartPage),
                      onPageChanged: (index) => setState(() {
                        pageIndex = index;
                        armedSlot = null;
                      }),
                      itemBuilder: (context, index) => _weekPage(
                        weekAt(origin, index - middlePage),
                        term,
                        dark,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _weekPage(DateTime monday, TermInfo? term, bool dark) {
    final periods = data!.periods.isEmpty ? defaultPeriods : data!.periods;
    final courses = data!.coursesByTerm[term?.id] ?? [];
    final week = weekNumber(monday, term);
    final canAdd =
        _activeCourse == null &&
        term?.startDate != null &&
        data!.periods.isNotEmpty &&
        week != null &&
        week <= 20;
    return LayoutBuilder(
      builder: (context, size) {
        const railWidth = 45.0;
        const rowHeight = 66.0;
        final dayWidth = (size.maxWidth - railWidth) / 7;
        final today = dateKey(DateTime.now());
        final firstPeriod = periods.first.number;
        return Column(
          children: [
            Container(
              height: 59,
              color: dark ? const Color(0xbe141416) : const Color(0xadffffff),
              child: Row(
                children: [
                  SizedBox(
                    width: railWidth,
                    child: Center(
                      child: Text(
                        '${monday.month}月',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  for (var day = 0; day < 7; day++)
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final date = DateTime(
                            monday.year,
                            monday.month,
                            monday.day + day,
                            12,
                          );
                          final active = dateKey(date) == today;
                          return Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '周${'一二三四五六日'[day]}',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: dark
                                      ? Colors.white70
                                      : const Color(0xff64748b),
                                ),
                              ),
                              const SizedBox(height: 3),
                              Container(
                                width: 27,
                                height: 27,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: active
                                      ? const Color(0xff0a84ff)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Text(
                                  '${date.day}',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: active ? Colors.white : null,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                padding: EdgeInsets.only(
                  bottom: NativeTabMetrics.contentBottomPadding(
                    context,
                    android: 100,
                  ),
                ),
                child: SizedBox(
                  height: periods.length * rowHeight,
                  child: Row(
                    children: [
                      SizedBox(
                        width: railWidth,
                        child: Column(
                          children: [
                            for (final period in periods)
                              Container(
                                height: rowHeight,
                                width: railWidth,
                                decoration: BoxDecoration(
                                  color: dark
                                      ? const Color(0xbe141416)
                                      : const Color(0xb8ffffff),
                                  border: Border(
                                    bottom: BorderSide(
                                      color: dark
                                          ? Colors.white12
                                          : Colors.black12,
                                    ),
                                  ),
                                ),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.topCenter,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const SizedBox(height: 5),
                                      Text(
                                        '${period.number}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                        ),
                                      ),
                                      Text(
                                        period.start,
                                        style: const TextStyle(fontSize: 8),
                                      ),
                                      Text(
                                        period.end,
                                        style: const TextStyle(fontSize: 8),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Stack(
                          children: [
                            for (var row = 0; row < periods.length; row++)
                              for (var day = 0; day < 7; day++)
                                Positioned(
                                  left: day * dayWidth,
                                  top: row * rowHeight,
                                  width: dayWidth,
                                  height: rowHeight,
                                  child: InkWell(
                                    onTap: canAdd
                                        ? () {
                                            if (_activeCourse != null) return;
                                            final slot = (
                                              day + 1,
                                              firstPeriod + row,
                                            );
                                            if (armedSlot == slot) {
                                              editCourse(
                                                weekday: slot.$1,
                                                period: slot.$2,
                                              );
                                            } else {
                                              setState(() => armedSlot = slot);
                                            }
                                          }
                                        : null,
                                    child: Container(
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color:
                                            armedSlot ==
                                                    (
                                                      day + 1,
                                                      firstPeriod + row,
                                                    ) &&
                                                canAdd
                                            ? const Color(0x774aa3f0)
                                            : (dark
                                                  ? const Color(0x0a000000)
                                                  : const Color(0x16ffffff)),
                                        border: Border(
                                          right: BorderSide(
                                            color: dark
                                                ? Colors.white24
                                                : Colors.black12,
                                          ),
                                          bottom: BorderSide(
                                            color: dark
                                                ? Colors.white24
                                                : Colors.black12,
                                          ),
                                        ),
                                      ),
                                      child:
                                          armedSlot ==
                                                  (
                                                    day + 1,
                                                    firstPeriod + row,
                                                  ) &&
                                              canAdd
                                          ? const Icon(
                                              Icons.add,
                                              color: Colors.white,
                                            )
                                          : null,
                                    ),
                                  ),
                                ),
                            for (final course in courses)
                              if (_inWeek(course, monday))
                                Builder(
                                  builder: (context) {
                                    final start = periodStart(course, periods);
                                    final end = periodEnd(course, periods);
                                    final weekday =
                                        course.weekday ?? course.start.weekday;
                                    if (start == null ||
                                        end == null ||
                                        start < firstPeriod ||
                                        end >= firstPeriod + periods.length ||
                                        weekday < 1 ||
                                        weekday > 7) {
                                      return const SizedBox.shrink();
                                    }
                                    final span = end - start + 1;
                                    final tone = _courseColor(
                                      course.name,
                                      dark,
                                    );
                                    return Positioned(
                                      left: (weekday - 1) * dayWidth + 1,
                                      top:
                                          (start - firstPeriod) * rowHeight + 1,
                                      width: dayWidth - 2,
                                      height: span * rowHeight - 2,
                                      child: Opacity(
                                        opacity:
                                            identical(_activeCourse, course)
                                            ? 0
                                            : 1,
                                        child: Material(
                                          key: _courseCardKeys[course] ??=
                                              GlobalKey(),
                                          color: Colors.transparent,
                                          child: InkWell(
                                            onTap: () =>
                                                showCourse(course, span),
                                            borderRadius: BorderRadius.circular(
                                              9,
                                            ),
                                            child: Container(
                                              decoration: BoxDecoration(
                                                color: tone,
                                                borderRadius:
                                                    BorderRadius.circular(9),
                                                border: Border.all(
                                                  color: dark
                                                      ? Colors.white30
                                                      : Colors.white70,
                                                ),
                                                boxShadow: const [
                                                  BoxShadow(
                                                    color: Color(0x1a263548),
                                                    blurRadius: 6,
                                                    offset: Offset(0, 2),
                                                  ),
                                                ],
                                              ),
                                              child: _courseCardText(
                                                course,
                                                span,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

enum _CourseDetailAction { edit, delete }

class _CourseViewportClipper extends CustomClipper<Rect> {
  const _CourseViewportClipper(this.viewport, this.progress);

  final Rect? viewport;
  final double progress;

  @override
  Rect getClip(Size size) {
    if (viewport == null) return Offset.zero & size;
    // The source has completely faded out by 0.35. Only then may the
    // transition grow beyond the grid's vertical viewport. On closing the
    // same progress range restores the clip before the source fades back in.
    final reveal = ((progress - 0.35) / 0.27).clamp(0.0, 1.0);
    final top = viewport!.top * (1 - reveal);
    final bottom = viewport!.bottom + (size.height - viewport!.bottom) * reveal;
    // Never clip the horizontal expansion or the floating card's side shadow.
    return Rect.fromLTRB(0, top, size.width, bottom);
  }

  @override
  bool shouldReclip(covariant _CourseViewportClipper oldClipper) =>
      viewport != oldClipper.viewport || progress != oldClipper.progress;
}

class _CourseMorphDialog extends StatefulWidget {
  const _CourseMorphDialog({
    required this.course,
    required this.startRect,
    required this.gridViewportRect,
    required this.currentSourceRect,
    required this.closedColor,
    required this.sourceContent,
  });

  final TimetableCourse course;
  final Rect startRect;
  final Rect? gridViewportRect;
  final Rect? Function() currentSourceRect;
  final Color closedColor;
  final Widget sourceContent;

  @override
  State<_CourseMorphDialog> createState() => _CourseMorphDialogState();
}

class _CourseMorphDialogState extends State<_CourseMorphDialog>
    with SingleTickerProviderStateMixin {
  static const _morphDuration = Duration(milliseconds: 260);
  final GlobalKey _detailMeasureKey = GlobalKey();
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: _morphDuration,
    reverseDuration: _morphDuration,
  );
  late Rect _startRect = widget.startRect;
  Rect? _endRect;
  bool _started = false;
  bool _closing = false;
  bool _fadingClose = false;
  double? _frozenProgress;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closing) return;
      final box = _detailMeasureKey.currentContext?.findRenderObject();
      final measuredHeight = box is RenderBox && box.hasSize
          ? box.size.height
          : 520.0;
      setState(() => _endRect = _detailEndRect(measuredHeight));
      if (MediaQuery.disableAnimationsOf(context)) {
        _animation.value = 1;
      } else {
        _animation.forward(from: 0);
      }
    });
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  Future<void> _close({
    bool userInitiated = false,
    _CourseDetailAction? action,
  }) async {
    if (_closing) return;
    if (userInitiated) HapticFeedback.lightImpact();
    final currentRect = widget.currentSourceRect();
    setState(() {
      _closing = true;
      _fadingClose = currentRect == null;
      if (currentRect == null) {
        // Keep the exact in-flight surface when its source disappears. Only
        // its opacity changes during reverse; it must not jump to endRect.
        _frozenProgress = _animation.value;
      } else if (_animation.value >= 1) {
        // Re-anchor only after a completed opening. Changing the start rect
        // mid-flight would move the current surface on the reversal frame.
        _startRect = currentRect;
      }
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.value = 0;
    } else {
      await _animation.reverse();
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop(action);
  }

  Widget _detailRow(IconData icon, String title, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 21, color: const Color(0xff6890b7)),
        const SizedBox(width: 13),
        SizedBox(
          width: 70,
          child: Text(
            title,
            style: const TextStyle(fontSize: 13, color: Color(0xff8b95a3)),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );

  Widget _detailContent() {
    final course = widget.course;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _detailRow(Icons.book_outlined, '课程名称', course.name),
        _detailRow(
          Icons.schedule_outlined,
          '上课时间',
          '${course.date} ${_clock(course.start)}—${_clock(course.end)}',
        ),
        _detailRow(Icons.location_on_outlined, '教室', course.room ?? '未提供'),
        _detailRow(Icons.person_outline, '教师', course.teacher ?? '未提供'),
        _detailRow(Icons.calendar_month_outlined, '周次', course.weeks ?? '未提供'),
        if (course.source == 'LOCAL' && course.manualId != null) ...[
          const SizedBox(height: 18),
          const Text('手动添加课程', style: TextStyle(fontSize: 13)),
          Row(
            children: [
              TextButton(
                onPressed: () => _close(action: _CourseDetailAction.edit),
                child: const Text('编辑'),
              ),
              TextButton(
                onPressed: () => _close(action: _CourseDetailAction.delete),
                child: const Text('删除', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _detailBody() => SingleChildScrollView(
    key: const Key('timetable-detail-scroll'),
    padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
    child: _detailContent(),
  );

  Widget _detailHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(22, 12, 10, 5),
    child: Row(
      children: [
        Expanded(
          child: Text(
            '课程详情',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        IconButton(
          key: const Key('timetable-detail-close'),
          tooltip: '关闭课程详情',
          onPressed: () => _close(userInitiated: true),
          icon: const Icon(Icons.close),
        ),
      ],
    ),
  );

  Rect _detailEndRect(double contentHeight) {
    final screen = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final width = math.min(420.0, math.max(0.0, screen.width - 32));
    final topLimit = padding.top + 16;
    // Leave the floating dock visible beneath the dimmed modal barrier.
    final bottomLimit = math.max(
      topLimit,
      screen.height - padding.bottom - 100,
    );
    final height = math.min(
      contentHeight,
      math.min(520.0, bottomLimit - topLimit),
    );
    return Rect.fromLTWH(
      (screen.width - width) / 2,
      topLimit + (bottomLimit - topLimit - height) / 2,
      width,
      height,
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final endRect = _endRect ?? _detailEndRect(520);
    final openColor = dark ? const Color(0xff1c1c1e) : Colors.white;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, _) {
          final progress = _animation.value;
          // The same mapping in both directions makes reverse() continuous
          // for geometry, corner radius, and every content opacity layer.
          final visualProgress = _frozenProgress ?? progress;
          final curved = Curves.fastOutSlowIn.transform(visualProgress);
          final surfaceRect = Rect.lerp(_startRect, endRect, curved)!;
          final transition = ContainerMorphTransition(
            progress: visualProgress,
            isClosing: false,
            detailInteractive: progress >= .44 && !_closing,
            startRect: _startRect,
            endSize: endRect.size,
            endRect: endRect,
            startBorderRadius: BorderRadius.circular(9),
            endBorderRadius: BorderRadius.circular(22),
            detailSafeArea: false,
            closedColor: widget.closedColor,
            openColor: openColor,
            sourceContent: widget.sourceContent,
            detailHeader: _detailHeader(),
            detailBody: _detailBody(),
            courseDetailTextHandoff: true,
            sourceLayerKey: const Key('timetable-detail-source-text'),
            detailHeaderLayerKey: const Key('timetable-detail-header-text'),
            detailBodyLayerKey: const Key('timetable-detail-body-text'),
            surfaceKey: const Key('timetable-detail-surface'),
          );
          return Stack(
            children: [
              if (_endRect == null)
                Offstage(
                  child: ExcludeFocus(
                    child: ExcludeSemantics(
                      child: SizedBox(
                        width: endRect.width,
                        child: SingleChildScrollView(
                          child: Column(
                            key: _detailMeasureKey,
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _detailHeader(),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  22,
                                  0,
                                  22,
                                  24,
                                ),
                                child: _detailContent(),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned.fill(
                child: GestureDetector(
                  key: const Key('timetable-detail-scrim'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _close(userInitiated: true),
                  child: ColoredBox(
                    color: Colors.black.withValues(
                      alpha: (dark ? .45 : .34) * progress,
                    ),
                  ),
                ),
              ),
              Positioned.fromRect(
                rect: surfaceRect,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                ),
              ),
              if (!_fadingClose)
                Positioned.fill(
                  child: ClipRect(
                    key: const Key('timetable-detail-viewport-clip'),
                    clipper: _CourseViewportClipper(
                      widget.gridViewportRect,
                      visualProgress,
                    ),
                    child: Stack(children: [transition]),
                  ),
                )
              else
                Positioned.fill(
                  child: Opacity(
                    key: const Key('timetable-detail-fade-close'),
                    opacity: _frozenProgress == 0
                        ? 0
                        : (progress / _frozenProgress!).clamp(0.0, 1.0),
                    child: ClipRect(
                      clipper: _CourseViewportClipper(
                        widget.gridViewportRect,
                        visualProgress,
                      ),
                      child: Stack(children: [transition]),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

bool _inWeek(TimetableCourse course, DateTime monday) {
  final date = DateTime.parse(course.date);
  final day = DateTime(date.year, date.month, date.day);
  final start = DateTime(monday.year, monday.month, monday.day);
  final end = DateTime(monday.year, monday.month, monday.day + 7);
  return !day.isBefore(start) && day.isBefore(end);
}

String _clock(DateTime date) =>
    '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
String _teacher(String? value) => (value ?? '教师待定')
    .replaceFirst(RegExp(r'\s*[（(][^（）()]*[）)]\s*$'), '')
    .trim();

Color _courseColor(String name, bool dark) {
  const light = [
    Color(0xffcdbff9),
    Color(0xffb4dff6),
    Color(0xffb6e7cf),
    Color(0xfff6dca6),
    Color(0xfff3c2cf),
    Color(0xffaee6e8),
    Color(0xffd5e8aa),
    Color(0xfff4c3aa),
  ];
  var hash = 0;
  for (final unit in name.codeUnits) {
    hash = (hash * 31 + unit) & 0xffffffff;
  }
  return light[hash % light.length].withValues(alpha: dark ? .82 : .78);
}

/// Native counterpart of the PWA's timetable/backdrop.svg.
class _FallbackBackdrop extends CustomPainter {
  const _FallbackBackdrop(this.dark);
  final bool dark;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 1440, size.height / 1000);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 1440, 1000),
      Paint()..color = dark ? const Color(0xff242426) : const Color(0xffe9e6e0),
    );
    final wave = Path()
      ..moveTo(-100, 880)
      ..cubicTo(160, 570, 260, 790, 510, 510)
      ..cubicTo(690, 310, 760, 670, 950, 430)
      ..cubicTo(1150, 175, 1280, 320, 1530, 30);
    canvas.drawPath(
      wave,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 110
        ..color = const Color(0xffa6bbc2).withValues(alpha: dark ? .22 : .42),
    );
    final topWave = Path()
      ..moveTo(-40, 155)
      ..cubicTo(210, 10, 390, 185, 570, 50)
      ..cubicTo(750, -85, 970, 160, 1190, 0)
      ..cubicTo(1300, -80, 1420, -80, 1520, -35);
    canvas.drawPath(
      topWave,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 115
        ..color = const Color(0xffd9bfc4).withValues(alpha: dark ? .18 : .38),
    );
    canvas.drawCircle(
      const Offset(1230, 690),
      195,
      Paint()
        ..color = const Color(0xffc5d4c0).withValues(alpha: dark ? .20 : .52),
    );
    canvas.drawCircle(
      const Offset(250, 475),
      135,
      Paint()
        ..color = const Color(0xffecd6ac).withValues(alpha: dark ? .20 : .50),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FallbackBackdrop oldDelegate) =>
      oldDelegate.dark != dark;
}

class ManualCourseEditor extends StatefulWidget {
  const ManualCourseEditor({
    super.key,
    required this.api,
    required this.term,
    required this.periods,
    required this.initialWeek,
    this.course,
    this.weekday,
    this.period,
  });
  final ApiClient api;
  final TermInfo term;
  final List<PeriodInfo> periods;
  final int initialWeek;
  final TimetableCourse? course;
  final int? weekday;
  final int? period;
  @override
  State<ManualCourseEditor> createState() => _ManualCourseEditorState();
}

class _ManualCourseEditorState extends State<ManualCourseEditor> {
  final name = TextEditingController();
  final room = TextEditingController();
  final teacher = TextEditingController();
  final weeks = <int>{};
  late int weekday;
  late int startPeriod;
  late int endPeriod;
  bool pending = false;
  String? error;

  @override
  void initState() {
    super.initState();
    final course = widget.course;
    name.text = course?.name ?? '';
    room.text = course?.room ?? '';
    teacher.text = course?.teacher ?? '';
    weekday = course?.weekday ?? widget.weekday ?? 1;
    startPeriod =
        course?.startPeriod ?? widget.period ?? widget.periods.first.number;
    endPeriod = course?.endPeriod ?? widget.period ?? startPeriod;
    weeks.addAll(
      course == null
          ? [widget.initialWeek.clamp(1, 20)]
          : _parseWeeks(course.weeks),
    );
  }

  @override
  void dispose() {
    name.dispose();
    room.dispose();
    teacher.dispose();
    super.dispose();
  }

  Future<void> chooseWeeks() async {
    FocusScope.of(context).unfocus();
    final selected = await showModalBottomSheet<Set<int>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _ManualWeekPicker(selected: weeks),
    );
    if (selected != null && mounted) {
      setState(
        () => weeks
          ..clear()
          ..addAll(selected),
      );
    }
  }

  Future<void> save() async {
    if (pending ||
        name.text.trim().isEmpty ||
        weeks.isEmpty ||
        endPeriod < startPeriod)
      return;
    setState(() {
      pending = true;
      error = null;
    });
    try {
      await widget.api.saveManualCourse(
        id: widget.course?.manualId,
        term: widget.term,
        name: name.text.trim(),
        weeks: '${(weeks.toList()..sort()).join(',')}周',
        weekday: weekday,
        startPeriod: startPeriod,
        endPeriod: endPeriod,
        room: room.text.trim().isEmpty ? null : room.text.trim(),
        teacher: teacher.text.trim().isEmpty ? null : teacher.text.trim(),
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiFailure catch (failure) {
      if (mounted)
        setState(() {
          error = failure.message;
          pending = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.course == null ? '添加课程' : '编辑课程',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: pending ? null : () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Text(
              '课程只保存在本机，离线也可修改；不会同步到网页版。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: '课程名称'),
            ),
            const SizedBox(height: 12),
            Material(
              color: Colors.transparent,
              child: InkWell(
                key: const Key('manual-week-trigger'),
                onTap: pending ? null : chooseWeeks,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 56),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Theme.of(context).dividerColor),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Text('上课周次', style: TextStyle(fontSize: 16)),
                      const Spacer(),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.sizeOf(context).width * .52,
                        ),
                        child: Text(
                          weeks.isEmpty
                              ? '请选择上课周次'
                              : '第 ${(weeks.toList()..sort()).join('、')} 周',
                          key: const Key('manual-week-summary'),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right,
                        size: 20,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            DropdownButtonFormField<int>(
              initialValue: weekday,
              decoration: const InputDecoration(labelText: '星期'),
              items: [
                for (var day = 1; day <= 7; day++)
                  DropdownMenuItem(
                    value: day,
                    child: Text('周${'一二三四五六日'[day - 1]}'),
                  ),
              ],
              onChanged: (value) => setState(() => weekday = value ?? weekday),
            ),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: startPeriod,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '开始节次'),
                    items: [
                      for (final period in widget.periods)
                        DropdownMenuItem(
                          value: period.number,
                          child: Text(
                            '第${period.number}节 ${period.start}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => startPeriod = value ?? startPeriod),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: endPeriod,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '结束节次'),
                    items: [
                      for (final period in widget.periods)
                        DropdownMenuItem(
                          value: period.number,
                          child: Text(
                            '第${period.number}节 ${period.end}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => endPeriod = value ?? endPeriod),
                  ),
                ),
              ],
            ),
            TextField(
              controller: room,
              decoration: const InputDecoration(labelText: '教室地点（可选）'),
            ),
            TextField(
              controller: teacher,
              decoration: const InputDecoration(labelText: '任课教师（可选）'),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: pending || weeks.isEmpty ? null : save,
                child: Text(pending ? '保存中…' : '保存课程'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ManualWeekPicker extends StatefulWidget {
  const _ManualWeekPicker({required this.selected});
  final Set<int> selected;

  @override
  State<_ManualWeekPicker> createState() => _ManualWeekPickerState();
}

class _ManualWeekPickerState extends State<_ManualWeekPicker> {
  late Set<int> draft;
  String? notice;

  @override
  void initState() {
    super.initState();
    draft = {...widget.selected};
  }

  void setPattern(Iterable<int> values) => setState(() {
    draft = values.toSet();
    notice = null;
  });

  void complete() {
    if (draft.isEmpty) {
      setState(() => notice = '请至少选择一个上课周次');
      return;
    }
    Navigator.pop(context, draft);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final primary = dark ? const Color(0xff0a84ff) : const Color(0xff4f80f6);
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .86,
          ),
          decoration: BoxDecoration(
            color: dark ? const Color(0xff1c1c1e) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.dividerColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                      const Expanded(
                        child: Text(
                          '上课周次',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton(onPressed: complete, child: const Text('完成')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      for (final pattern in ['全选', '单周', '双周', '清空']) ...[
                        if (pattern != '全选') const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => setPattern(switch (pattern) {
                              '全选' => Iterable<int>.generate(
                                20,
                                (index) => index + 1,
                              ),
                              '单周' => Iterable<int>.generate(
                                10,
                                (index) => index * 2 + 1,
                              ),
                              '双周' => Iterable<int>.generate(
                                10,
                                (index) => index * 2 + 2,
                              ),
                              _ => const <int>[],
                            }),
                            style: OutlinedButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(0, 38),
                            ),
                            child: Text(
                              pattern,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      notice ?? '已选择 ${draft.length} / 20 周',
                      key: const Key('manual-week-count'),
                      style: TextStyle(
                        fontSize: 13,
                        color: notice == null
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.error,
                      ),
                    ),
                  ),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: 20,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 5,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          childAspectRatio: 1,
                        ),
                    itemBuilder: (context, index) {
                      final week = index + 1;
                      final selected = draft.contains(week);
                      return Semantics(
                        button: true,
                        selected: selected,
                        label: '第 $week 周',
                        child: Material(
                          color: selected
                              ? primary
                              : dark
                              ? const Color(0xff111214)
                              : Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(
                              color: selected ? primary : theme.dividerColor,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => setState(() {
                              if (selected) {
                                draft.remove(week);
                              } else {
                                draft.add(week);
                              }
                              notice = null;
                            }),
                            child: Center(
                              child: Text(
                                '$week',
                                style: TextStyle(
                                  fontSize: 17,
                                  color: selected
                                      ? Colors.white
                                      : theme.colorScheme.onSurface,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Set<int> _parseWeeks(String? expression) {
  if (expression == null) return {};
  final result = <int>{};
  for (final part
      in expression
          .replaceAll('周', '')
          .replaceAll('，', ',')
          .replaceAll('、', ',')
          .split(',')) {
    final range = part.split('-');
    final first = int.tryParse(range.first.trim());
    if (first == null) continue;
    final last = range.length > 1
        ? int.tryParse(range.last.trim()) ?? first
        : first;
    for (
      var week = first < last ? first : last;
      week <= (first > last ? first : last) && week <= 20;
      week++
    ) {
      if (week > 0) result.add(week);
    }
  }
  return result;
}
