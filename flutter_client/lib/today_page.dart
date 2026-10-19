import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'api.dart';
import 'container_morph_transition.dart';
import 'main.dart' show greeting;
import 'native_tab_bridge.dart';

String formatCourseCountdown(Duration remaining) {
  final minutes = (remaining.inMilliseconds / Duration.millisecondsPerMinute)
      .ceil();
  if (minutes > 60) return '${minutes ~/ 60} 小时 ${minutes % 60} 分钟';
  return '$minutes 分钟';
}

class TodayPage extends StatefulWidget {
  const TodayPage({
    super.key,
    required this.api,
    required this.onUnauthorized,
    required this.onProfile,
    this.localProfileChanges,
  });
  final ApiClient api;
  final VoidCallback onUnauthorized;
  final ValueChanged<Profile> onProfile;
  final ValueListenable<Profile?>? localProfileChanges;
  @override
  State<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> with WidgetsBindingObserver {
  final GlobalKey _addScheduleButtonKey = GlobalKey();
  bool _addScheduleOpen = false;
  TodayData? data;
  TimetableData? timetableSnapshot;
  List<CourseSession>? cachedCalendarSessions;
  String? error;
  bool loading = true;
  List<CustomSchedule> localSchedules = const [];
  String? scheduleError;
  String? snapshotDate;
  late String currentDate = dateKey(DateTime.now());
  Timer? dayChangeTimer;
  Timer? minuteTimer;
  Future<void>? timetableLoad;
  int refreshGeneration = 0;
  String? wallpaperSource;
  ImageProvider? wallpaperImage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.localProfileChanges?.addListener(onLocalProfileChanged);
    widget.api.manualCoursesRevision.addListener(readLocalTimetable);
    scheduleDayChange();
    scheduleMinuteUpdate();
    initialize();
  }

  @override
  void dispose() {
    dayChangeTimer?.cancel();
    minuteTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.localProfileChanges?.removeListener(onLocalProfileChanged);
    widget.api.manualCoursesRevision.removeListener(readLocalTimetable);
    super.dispose();
  }

  void onLocalProfileChanged() {
    if (mounted) setState(() {});
  }

  ImageProvider? imageForWallpaper(String? source) {
    if (source != wallpaperSource) {
      wallpaperSource = source;
      wallpaperImage = dataImage(source);
    }
    return wallpaperImage;
  }

  void scheduleDayChange() {
    dayChangeTimer?.cancel();
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    dayChangeTimer = Timer(
      tomorrow.difference(now) + const Duration(seconds: 1),
      () {
        if (!mounted) return;
        checkDayChange();
        scheduleDayChange();
      },
    );
  }

  void scheduleMinuteUpdate() {
    minuteTimer?.cancel();
    final now = DateTime.now();
    final nextMinute = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute + 1,
    );
    minuteTimer = Timer(
      nextMinute.difference(now) + const Duration(milliseconds: 50),
      () {
        if (!mounted) return;
        checkDayChange();
        setState(() {});
        scheduleMinuteUpdate();
      },
    );
  }

  void checkDayChange() {
    final date = dateKey(DateTime.now());
    if (date == currentDate) return;
    currentDate = date;
    setState(() {});
    refreshForNewDay();
  }

  Future<void> refreshForNewDay() async {
    final snapshot = await widget.api.loadTodaySnapshot();
    if (!mounted) return;
    setState(() {
      cachedCalendarSessions = snapshot?.calendarSessions;
    });
    readLocalTimetable();
    await loadSchedules();
    await refresh();
  }

  Future<void> loadSchedules() async {
    try {
      final saved = await widget.api.localSchedules(DateTime.now());
      if (mounted)
        setState(() {
          localSchedules = saved;
          scheduleError = null;
        });
    } on ApiFailure catch (e) {
      if (mounted) setState(() => scheduleError = e.message);
    }
  }

  void readLocalTimetable() {
    if (timetableLoad != null) return;
    final load = loadLocalTimetable();
    timetableLoad = load;
    unawaited(load.whenComplete(() => timetableLoad = null));
  }

  Future<void> loadLocalTimetable() async {
    try {
      final timetable = await widget.api.loadTimetableSnapshot();
      if (mounted && timetable != null) {
        setState(() => timetableSnapshot = timetable);
      }
    } catch (_) {
      /* An unreadable cache must not block Today. */
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      checkDayChange();
      scheduleDayChange();
      scheduleMinuteUpdate();
      if (mounted) setState(() {});
    }
  }

  Future<void> initialize() async {
    final snapshot = await widget.api.loadTodaySnapshot();
    final local = snapshot == null ? await widget.api.localProfile() : null;
    if (!mounted) return;
    final initial =
        snapshot?.data ??
        TodayData(
          local ?? const Profile('航的助手', null, null),
          const [],
          const [],
        );
    widget.onProfile(initial.profile);
    setState(() {
      data = initial;
      cachedCalendarSessions = snapshot?.calendarSessions;
      snapshotDate = snapshot?.date;
      loading = false;
    });
    unawaited(_prepareLocalSchedules(snapshot));
    readLocalTimetable();
    await refresh();
  }

  Future<void> _prepareLocalSchedules(TodaySnapshot? snapshot) async {
    try {
      await widget.api.importSnapshotSchedules(snapshot);
      await loadSchedules();
    } on ApiFailure catch (e) {
      if (mounted) setState(() => scheduleError = e.message);
    }
  }

  Future<void> refresh() async {
    final generation = ++refreshGeneration;
    final now = DateTime.now();
    try {
      final fresh = await widget.api.today(now);
      if (mounted && generation == refreshGeneration) {
        widget.onProfile(fresh.profile);
        setState(() {
          data = fresh;
          snapshotDate = dateKey(now);
          error = null;
          loading = false;
        });
        await loadSchedules();
        unawaited(_importServerSchedules());
      }
    } on ApiFailure catch (e) {
      if (!mounted || generation != refreshGeneration) return;
      if (e.unauthorized) {
        if (mounted) widget.onUnauthorized();
        return;
      }
      setState(() {
        error = e.message;
        loading = false;
      });
      readLocalTimetable();
    }
  }

  Future<void> _importServerSchedules() async {
    try {
      await widget.api.importServerSchedulesOnce();
      await loadSchedules();
    } on ApiFailure catch (e) {
      if (e.unauthorized && mounted) widget.onUnauthorized();
      // A failed one-time import is retried on the next online refresh.
    }
  }

  Future<void> edit([CustomSchedule? schedule]) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ScheduleSheet(api: widget.api, schedule: schedule),
    );
    if (changed == true) await loadSchedules();
  }

  Rect? _addScheduleRect() {
    final box = _addScheduleButtonKey.currentContext?.findRenderObject();
    final overlay = Overlay.of(
      context,
      rootOverlay: true,
    ).context.findRenderObject();
    if (box is! RenderBox ||
        overlay is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        !overlay.hasSize ||
        !TickerMode.valuesOf(context).enabled) {
      return null;
    }
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    return rect.isFinite && rect.overlaps(Offset.zero & overlay.size)
        ? rect
        : null;
  }

  Future<void> addSchedule() async {
    if (_addScheduleOpen) return;
    final startRect = _addScheduleRect();
    if (startRect == null) return;
    setState(() => _addScheduleOpen = true);
    var routeClosed = false;
    try {
      final changed = await showGeneralDialog<bool>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        barrierColor: Colors.transparent,
        transitionDuration: Duration.zero,
        pageBuilder: (context, _, _) => _ScheduleMorphDialog(
          api: widget.api,
          startRect: startRect,
          currentSourceRect: () => mounted ? _addScheduleRect() : null,
        ),
      );
      if (!mounted) return;
      setState(() => _addScheduleOpen = false);
      routeClosed = true;
      if (changed == true) await loadSchedules();
    } finally {
      if (!routeClosed && mounted) setState(() => _addScheduleOpen = false);
    }
  }

  Future<void> delete(CustomSchedule schedule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除“${schedule.title}”？'),
        content: const Text('删除后无法恢复这项自定义安排。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除安排'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.deleteSchedule(schedule.id);
      await loadSchedules();
    } on ApiFailure catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final now = DateTime.now();
    if (loading)
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text(
              '后台正在加载…',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      );
    if (data == null)
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('首页加载失败'),
            const SizedBox(height: 8),
            Text(error ?? '无法读取后台数据'),
            TextButton(onPressed: refresh, child: const Text('重新加载')),
          ],
        ),
      );
    final today = data!;
    final profile = widget.localProfileChanges?.value ?? today.profile;
    final hasTodayData = snapshotDate == dateKey(now);
    final localTimetable = timetableSnapshot;
    final hasLocalTimetable =
        localTimetable != null &&
        (localTimetable.terms.isNotEmpty ||
            localTimetable.coursesByTerm.isNotEmpty);
    final calendar = cachedCalendarSessions;
    // A same-day Today snapshot is authoritative; use the full local calendar
    // only after its date has rolled over.
    final localToday = hasLocalTimetable
        ? coursesForDay(localTimetable, now)
        : <CourseSession>[];
    final sessions = hasTodayData
        ? (<CourseSession>[
            for (final session in today.sessions)
              if (!hasLocalTimetable || session.source != 'MANUAL') session,
            for (final session in localToday)
              if (session.source == 'LOCAL') session,
          ]..sort((a, b) => a.start.compareTo(b.start)))
        : hasLocalTimetable
        ? localToday
        : calendar == null
        ? <CourseSession>[]
        : sessionsForDay(calendar, now);
    final schedules = localSchedules;
    final hasCourseData = hasTodayData || hasLocalTimetable || calendar != null;
    final active = sessions
        .where((s) => !now.isBefore(s.start) && now.isBefore(s.end))
        .firstOrNull;
    final upcoming = sessions.where((s) => now.isBefore(s.start)).firstOrNull;
    final status = active != null
        ? '正在上 ${active.name}，距下课约 ${formatCourseCountdown(active.end.difference(now))}'
        : upcoming != null
        ? '下一节 ${upcoming.name}，${formatCourseCountdown(upcoming.start.difference(now))}后上课'
        : schedules.isNotEmpty
        ? '今天有 ${schedules.length} 项自定义安排'
        : '今天的课程已经结束';
    final entries =
        <({String sort, CourseSession? course, CustomSchedule? custom})>[
          for (final s in sessions)
            (sort: clock(s.start), course: s, custom: null),
          for (final s in schedules) (sort: s.time, course: null, custom: s),
        ]..sort((a, b) => a.sort.compareTo(b.sort));
    final wallpaper = imageForWallpaper(profile.wallpaper);
    final complete = active == null && upcoming == null;
    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(
            color: dark ? Colors.black : const Color(0xfff7f9fc),
          ),
        ),
        if (wallpaper != null)
          Positioned.fill(
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (bounds) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black, Colors.black],
                stops: [.16, .39, 1],
              ).createShader(bounds),
              child: Opacity(
                opacity: dark ? .52 : .38,
                child: Image(
                  image: wallpaper,
                  fit: BoxFit.cover,
                  alignment: const Alignment(0, -.1),
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 26, 18, 0),
            child: Column(
              children: [
                _Hero(profile: profile, now: now, dark: dark),
                const SizedBox(height: 25),
                Row(
                  children: [
                    const Text(
                      '今日安排',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (schedules.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: dark
                                  ? const Color(0xff17263c)
                                  : const Color(0xffdbeafe),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '今天有 ${schedules.length} 项自定义安排',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: dark
                                    ? const Color(0xff9bc3ff)
                                    : const Color(0xff1d4ed8),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ] else
                      const Spacer(),
                    IgnorePointer(
                      ignoring: _addScheduleOpen,
                      child: Opacity(
                        opacity: _addScheduleOpen ? 0 : 1,
                        child: TextButton.icon(
                          key: _addScheduleButtonKey,
                          onPressed: addSchedule,
                          icon: const Icon(Icons.add, size: 17),
                          label: const Text('添加安排'),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            backgroundColor: dark
                                ? const Color(0xff17263c)
                                : const Color(0xffe8f1ff),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (entries.isNotEmpty &&
                    (active != null || upcoming != null || schedules.isEmpty))
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      key: Key(
                        complete
                            ? 'today-complete-status'
                            : 'today-course-status',
                      ),
                      width: complete ? null : double.infinity,
                      constraints: complete
                          ? null
                          : const BoxConstraints(minHeight: 62),
                      alignment: complete ? null : Alignment.centerLeft,
                      padding: EdgeInsets.symmetric(
                        horizontal: complete ? 11 : 15,
                        vertical: complete ? 7 : 13,
                      ),
                      margin: const EdgeInsets.fromLTRB(0, 5, 0, 9),
                      decoration: BoxDecoration(
                        color: dark
                            ? const Color(0xff102642)
                            : const Color(0xffe8f1ff),
                        borderRadius: BorderRadius.circular(complete ? 11 : 14),
                        border: Border.all(
                          color: dark
                              ? const Color(0xff234671)
                              : const Color(0xffdbeafe),
                        ),
                      ),
                      child: Text(
                        status,
                        style: TextStyle(
                          fontSize: complete ? 13 : 14,
                          color: dark
                              ? const Color(0xffbfdbfe)
                              : const Color(0xff1d4ed8),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                if (entries.isNotEmpty) const SizedBox(height: 12),
                Expanded(
                  child: ListView(
                    physics: const ClampingScrollPhysics(),
                    padding: EdgeInsets.only(
                      bottom: NativeTabMetrics.contentBottomPadding(
                        context,
                        android: 105,
                      ),
                    ),
                    children: [
                      if (!hasTodayData && !hasCourseData)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '课程数据暂不可用',
                                  style: TextStyle(
                                    color: dark
                                        ? const Color(0xffb2b8c2)
                                        : const Color(0xff64748b),
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: refresh,
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        ),
                      if (scheduleError != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            scheduleError!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      for (final entry in entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: entry.course != null
                              ? _EntryCard(
                                  kind: '课程',
                                  title: entry.course!.name,
                                  time:
                                      '${clock(entry.course!.start)}—${clock(entry.course!.end)}',
                                  detail:
                                      '${entry.course!.room ?? '教室待定'} · ${entry.course!.teacher ?? '教师待定'}',
                                  dark: dark,
                                  active: entry.course == active,
                                  hasWallpaper: wallpaper != null,
                                )
                              : _ScheduleCard(
                                  schedule: entry.custom!,
                                  dark: dark,
                                  hasWallpaper: wallpaper != null,
                                  enabled: true,
                                  onEdit: () => edit(entry.custom!),
                                  onDelete: () => delete(entry.custom!),
                                ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Match the device's local date against the cached, already-expanded sessions.
/// The selected timetable term is only a viewing preference, not today's date.
List<CourseSession> coursesForDay(TimetableData timetable, DateTime day) {
  final date = dateKey(day);
  final matched = <int, CourseSession>{};
  for (final termCourses in timetable.coursesByTerm.values) {
    for (final course in termCourses) {
      if (course.date != date) continue;
      matched.putIfAbsent(
        course.id,
        () => CourseSession(
          course.id,
          course.name,
          course.date,
          course.start,
          course.end,
          course.room,
          course.teacher,
          source: course.source,
        ),
      );
    }
  }
  return matched.values.toList()..sort((a, b) => a.start.compareTo(b.start));
}

List<CourseSession> sessionsForDay(List<CourseSession> calendar, DateTime day) {
  final date = dateKey(day);
  return calendar.where((session) => session.date == date).toList()
    ..sort((a, b) => a.start.compareTo(b.start));
}

String clock(DateTime date) =>
    '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
String chineseDate(DateTime date) =>
    '${date.month}月${date.day}日星期${'一二三四五六日'[date.weekday - 1]}';

ImageProvider? dataImage(String? source) {
  if (source == null) return null;
  try {
    return MemoryImage(base64Decode(source.substring(source.indexOf(',') + 1)));
  } catch (_) {
    return null;
  }
}

class _Hero extends StatefulWidget {
  const _Hero({required this.profile, required this.now, required this.dark});
  final Profile profile;
  final DateTime now;
  final bool dark;

  @override
  State<_Hero> createState() => _HeroState();
}

class _HeroState extends State<_Hero> {
  final GlobalKey _avatarKey = GlobalKey();
  bool avatarPreviewOpen = false;
  String? _avatarSource;
  ImageProvider? _avatarImage;
  ImageStream? _avatarStream;
  ImageStreamListener? _avatarListener;
  Completer<double>? _avatarAspect;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cacheAvatar();
  }

  @override
  void didUpdateWidget(covariant _Hero oldWidget) {
    super.didUpdateWidget(oldWidget);
    _cacheAvatar();
  }

  void _cacheAvatar() {
    final source = widget.profile.avatar;
    if (_avatarSource == source) return;
    if (_avatarStream != null && _avatarListener != null) {
      _avatarStream!.removeListener(_avatarListener!);
    }
    if (_avatarAspect != null && !_avatarAspect!.isCompleted) {
      _avatarAspect!.complete(1);
    }
    _avatarSource = source;
    _avatarImage = dataImage(source);
    _avatarStream = null;
    _avatarListener = null;
    _avatarAspect = _avatarImage == null ? null : Completer<double>();
    if (_avatarImage == null) return;
    final stream = _avatarImage!.resolve(
      createLocalImageConfiguration(context),
    );
    _avatarStream = stream;
    final aspect = _avatarAspect!;
    final listener = ImageStreamListener(
      (info, _) {
        if (!aspect.isCompleted) {
          aspect.complete(info.image.width / info.image.height);
        }
      },
      onError: (_, _) {
        if (!aspect.isCompleted) aspect.complete(1);
      },
    );
    _avatarListener = listener;
    stream.addListener(listener);
  }

  @override
  void dispose() {
    if (_avatarStream != null && _avatarListener != null) {
      _avatarStream!.removeListener(_avatarListener!);
    }
    if (_avatarAspect != null && !_avatarAspect!.isCompleted) {
      _avatarAspect!.complete(1);
    }
    super.dispose();
  }

  Rect? _avatarRect(String source) {
    if (_avatarSource != source || !TickerMode.valuesOf(context).enabled) {
      return null;
    }
    final avatar = _avatarKey.currentContext?.findRenderObject();
    final overlay = Overlay.of(
      context,
      rootOverlay: true,
    ).context.findRenderObject();
    if (avatar is! RenderBox ||
        overlay is! RenderBox ||
        !avatar.attached ||
        !avatar.hasSize ||
        !overlay.hasSize) {
      return null;
    }
    final origin = avatar.localToGlobal(Offset.zero, ancestor: overlay);
    final rect = origin & avatar.size;
    return rect.overlaps(Offset.zero & overlay.size) ? rect : null;
  }

  Future<void> showAvatarPreview(ImageProvider avatar) async {
    if (avatarPreviewOpen) return;
    final source = _avatarSource;
    if (source == null) return;
    final startRect = _avatarRect(source);
    if (startRect == null) return;
    final aspect = await _avatarAspect?.future ?? 1;
    if (!mounted || avatarPreviewOpen || _avatarSource != source) return;
    setState(() => avatarPreviewOpen = true);
    try {
      await showGeneralDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        barrierColor: Colors.transparent,
        transitionDuration: Duration.zero,
        pageBuilder: (context, _, _) => _AvatarMorphPreview(
          image: avatar,
          aspectRatio: aspect,
          startRect: startRect,
          currentSourceRect: () => _avatarRect(source),
          dark: widget.dark,
        ),
      );
    } finally {
      if (mounted) setState(() => avatarPreviewOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final avatar = _avatarImage;
    return Container(
      constraints: const BoxConstraints(minHeight: 158),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 26),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: widget.dark
              ? [const Color(0xff202228), const Color(0xff121418)]
              : [const Color(0xfffbfcfe), const Color(0xffeaf2f9)],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: widget.dark
              ? const Color(0x18ffffff)
              : const Color(0x100f172a),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x120f172a),
            blurRadius: 22,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        children: [
          if (avatar != null)
            Positioned.fill(
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                child: Opacity(
                  opacity: widget.dark ? .25 : .18,
                  child: Image(image: avatar, fit: BoxFit.cover),
                ),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _HeroBadge(
                      '今日 · ${greeting(widget.now.hour)}',
                      dark: widget.dark,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.profile.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 31,
                        fontWeight: FontWeight.w800,
                        color: widget.dark
                            ? Colors.white
                            : const Color(0xff172033),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _HeroBadge(chineseDate(widget.now), dark: widget.dark),
                  ],
                ),
              ),
              Visibility(
                visible: !avatarPreviewOpen,
                maintainState: true,
                maintainAnimation: true,
                maintainSize: true,
                child: GestureDetector(
                  key: const Key('today-avatar-source'),
                  onTap: avatar == null
                      ? null
                      : () => showAvatarPreview(avatar),
                  child: Container(
                    key: _avatarKey,
                    width: 80,
                    height: 80,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: widget.dark ? Colors.black : Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x260f172a),
                          blurRadius: 16,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(17),
                      child: ColoredBox(
                        color: widget.dark
                            ? Colors.black
                            : const Color(0xaaffffff),
                        child: avatar == null
                            ? Center(
                                child: Text(
                                  widget.profile.name == '航的助手' ||
                                          widget.profile.name.isEmpty
                                      ? '航'
                                      : widget.profile.name.characters.last,
                                  style: const TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              )
                            : Image(image: avatar, fit: BoxFit.cover),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AvatarMorphPreview extends StatefulWidget {
  const _AvatarMorphPreview({
    required this.image,
    required this.aspectRatio,
    required this.startRect,
    required this.currentSourceRect,
    required this.dark,
  });

  final ImageProvider image;
  final double aspectRatio;
  final Rect startRect;
  final Rect? Function() currentSourceRect;
  final bool dark;

  @override
  State<_AvatarMorphPreview> createState() => _AvatarMorphPreviewState();
}

class _AvatarMorphPreviewState extends State<_AvatarMorphPreview>
    with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 260);
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: _duration,
    reverseDuration: _duration,
  );
  late final Rect _endRect;
  late Rect _startRect = widget.startRect;
  bool _started = false;
  bool _closing = false;
  double? _frozenProgress;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final availableHeight = size.height - padding.top - padding.bottom - 48;
    final side = math.max(
      0.0,
      math.min(
        size.width - 40,
        math.min(size.height * .75, availableHeight - 86),
      ),
    );
    final groupHeight = side + 14 + 48;
    _endRect = Rect.fromLTWH(
      (size.width - side) / 2,
      padding.top +
          (size.height - padding.top - padding.bottom - groupHeight) / 2,
      side,
      side,
    );
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.value = 1;
    } else {
      _animation.forward();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_closing) return;
    final currentRect = widget.currentSourceRect();
    setState(() {
      _closing = true;
      if (currentRect == null) {
        _frozenProgress = _animation.value;
      } else if (_animation.value >= 1) {
        _startRect = currentRect;
      }
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.value = 0;
    } else {
      await _animation.reverse();
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  Widget _imageSurface(double curved) {
    final padding = lerpDouble(3, 12, curved)!;
    final innerRadius = lerpDouble(17, 18, curved)!;
    final scale = lerpDouble(
      math.max(widget.aspectRatio, 1 / widget.aspectRatio),
      1,
      curved,
    )!;
    return Container(
      key: const Key('today-avatar-morph-image'),
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: Color.lerp(
          widget.dark ? Colors.black : Colors.white,
          widget.dark ? const Color(0xff292b30) : const Color(0xfff7f9fc),
          curved,
        ),
        borderRadius: BorderRadius.circular(lerpDouble(20, 26, curved)!),
        border: Border.all(
          color: Color.lerp(
            Colors.transparent,
            widget.dark ? const Color(0x30ffffff) : Colors.white,
            curved,
          )!,
          width: curved,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(innerRadius),
        child: ColoredBox(
          color: Color.lerp(
            widget.dark ? Colors.black : const Color(0xaaffffff),
            widget.dark ? const Color(0xff14161b) : const Color(0xfff1f5f9),
            curved,
          )!,
          child: ClipRect(
            child: Transform.scale(
              scale: scale,
              child: SizedBox.expand(
                child: Image(
                  key: const Key('today-avatar-morph-photo'),
                  image: widget.image,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _close();
    },
    child: AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        final progress = _animation.value;
        final visualProgress = _frozenProgress ?? progress;
        final curved = Curves.fastOutSlowIn.transform(visualProgress);
        final surfaceRect = Rect.lerp(_startRect, _endRect, curved)!;
        final radius = BorderRadius.circular(lerpDouble(20, 26, curved)!);
        final closeOpacity = ((progress - .55) / .25).clamp(0.0, 1.0);
        final surfaceOpacity = _frozenProgress == null
            ? 1.0
            : _frozenProgress == 0
            ? 0.0
            : (progress / _frozenProgress!).clamp(0.0, 1.0);
        final morph = ContainerMorphTransition(
          progress: visualProgress,
          isClosing: false,
          detailInteractive: false,
          startRect: _startRect,
          endSize: _endRect.size,
          endRect: _endRect,
          startBorderRadius: BorderRadius.circular(20),
          endBorderRadius: BorderRadius.circular(26),
          detailSafeArea: false,
          closedColor: widget.dark ? Colors.black : Colors.white,
          openColor: widget.dark
              ? const Color(0xff292b30)
              : const Color(0xfff7f9fc),
          sourceContent: const SizedBox.shrink(),
          detailHeader: const SizedBox.shrink(),
          detailBody: const SizedBox.shrink(),
          surfaceContentBuilder: (_, curvedProgress) =>
              _imageSurface(curvedProgress),
          surfaceKey: const Key('today-avatar-morph-surface'),
        );
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const Key('today-avatar-morph-scrim'),
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: .54 * progress),
                ),
              ),
            ),
            Positioned.fromRect(
              rect: surfaceRect,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0x260f172a)
                          .withValues(alpha: (0x26 / 255) * surfaceOpacity),
                      blurRadius: lerpDouble(16, 22, curved)!,
                      offset: Offset(0, lerpDouble(6, 8, curved)!),
                    ),
                  ],
                ),
              ),
            ),
            if (_frozenProgress == null)
              morph
            else
              Positioned.fill(
                child: Opacity(
                  key: const Key('today-avatar-morph-fade-close'),
                  opacity: surfaceOpacity,
                  child: Stack(children: [morph]),
                ),
              ),
            Positioned.fromRect(
              rect: Rect.fromLTWH(
                _endRect.left,
                _endRect.bottom + 14,
                _endRect.width,
                48,
              ),
              child: IgnorePointer(
                ignoring: closeOpacity == 0 || _closing,
                child: Opacity(
                  opacity: closeOpacity,
                  child: Center(
                    child: IconButton.filledTonal(
                      key: const Key('today-avatar-morph-close'),
                      onPressed: _close,
                      tooltip: '关闭头像预览',
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _HeroBadge extends StatelessWidget {
  const _HeroBadge(this.label, {required this.dark});
  final String label;
  final bool dark;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: dark ? const Color(0x38000000) : const Color(0x78ffffff),
      borderRadius: BorderRadius.circular(9),
      border: Border.all(
        color: dark ? const Color(0x20ffffff) : const Color(0x99ffffff),
      ),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: dark ? const Color(0xffe0e5ec) : const Color(0xff475b74),
      ),
    ),
  );
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.kind,
    required this.title,
    required this.time,
    required this.detail,
    required this.dark,
    this.active = false,
    this.custom = false,
    this.hasWallpaper = false,
  });
  final String kind, title, time, detail;
  final bool dark, active, custom, hasWallpaper;
  @override
  Widget build(BuildContext context) => Container(
    key: const Key('today-entry-card'),
    height: 144,
    padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: dark
            ? (hasWallpaper
                  ? [const Color(0xc2141416), const Color(0xc2141416)]
                  : [const Color(0xff141416), const Color(0xff141416)])
            : (hasWallpaper
                  ? (custom
                        ? [const Color(0xc7f8fbff), const Color(0xb3e8f2ff)]
                        : [const Color(0xccffffff), const Color(0xb3f7faff)])
                  : custom
                  ? [const Color(0xfff8fbff), const Color(0xffeef5ff)]
                  : active
                  ? [const Color(0xfff4f8ff), Colors.white]
                  : [Colors.white, const Color(0xfffbfdff)]),
      ),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: active
            ? (dark ? const Color(0xff0a84ff) : const Color(0xff60a5fa))
            : dark
            ? const Color(0x18ffffff)
            : custom
            ? const Color(0xffdbeafe)
            : const Color(0xffe3eaf3),
        width: active ? 2 : 1,
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x100f172a),
          blurRadius: 10,
          offset: Offset(0, 2),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          kind,
          style: TextStyle(
            fontSize: 12,
            color: dark
                ? const Color(0xff69adff)
                : custom
                ? const Color(0xff3567b7)
                : const Color(0xff007aff),
            fontWeight: FontWeight.w700,
          ),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 17,
                height: 1.3,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
        Text(
          time,
          style: TextStyle(
            fontSize: 15,
            color: dark ? const Color(0xffd1d1d6) : const Color(0xff334155),
          ),
        ),
        if (detail.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: dark ? const Color(0xffa1a1a6) : const Color(0xff64748b),
            ),
          ),
        ],
      ],
    ),
  );
}

class _ScheduleCard extends StatefulWidget {
  const _ScheduleCard({
    required this.schedule,
    required this.dark,
    required this.hasWallpaper,
    required this.enabled,
    required this.onEdit,
    required this.onDelete,
  });
  final CustomSchedule schedule;
  final bool dark, hasWallpaper, enabled;
  final VoidCallback onEdit, onDelete;
  @override
  State<_ScheduleCard> createState() => _ScheduleCardState();
}

class _ScheduleCardState extends State<_ScheduleCard> {
  double reveal = 0;
  bool dragging = false;

  @override
  void didUpdateWidget(covariant _ScheduleCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      reveal = 0;
      dragging = false;
    }
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: SizedBox(
      height: 144,
      child: Stack(
        children: [
          if (widget.enabled)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: 168,
                  child: Row(
                    children: [
                      Expanded(
                        child: _SwipeAction(
                          label: '编辑',
                          color: const Color(0xff8e8e93),
                          onTap: () {
                            setState(() => reveal = 0);
                            widget.onEdit();
                          },
                        ),
                      ),
                      Expanded(
                        child: _SwipeAction(
                          label: '删除',
                          color: const Color(0xffff3b30),
                          onTap: () {
                            setState(() => reveal = 0);
                            widget.onDelete();
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          AnimatedPositioned(
            duration: dragging
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            left: -reveal,
            right: reveal,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: reveal > 0 ? () => setState(() => reveal = 0) : null,
              onHorizontalDragStart: widget.enabled
                  ? (_) => setState(() => dragging = true)
                  : null,
              onHorizontalDragUpdate: widget.enabled
                  ? (details) => setState(
                      () => reveal = (reveal - details.delta.dx).clamp(
                        0.0,
                        168.0,
                      ),
                    )
                  : null,
              onHorizontalDragEnd: widget.enabled
                  ? (_) => setState(() {
                      dragging = false;
                      reveal = reveal >= 72 ? 168 : 0;
                    })
                  : null,
              child: _EntryCard(
                kind: '自定义安排',
                title: widget.schedule.title,
                time: widget.schedule.time,
                detail: '',
                dark: widget.dark,
                custom: true,
                hasWallpaper: widget.hasWallpaper && reveal == 0 && !dragging,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _SwipeAction extends StatelessWidget {
  const _SwipeAction({
    required this.label,
    required this.color,
    required this.onTap,
  });
  final String label;
  final Color color;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => SizedBox.expand(
    child: Material(
      color: color,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    ),
  );
}

class _ScheduleMorphDialog extends StatefulWidget {
  const _ScheduleMorphDialog({
    required this.api,
    required this.startRect,
    required this.currentSourceRect,
  });

  final ApiClient api;
  final Rect startRect;
  final Rect? Function() currentSourceRect;

  @override
  State<_ScheduleMorphDialog> createState() => _ScheduleMorphDialogState();
}

class _ScheduleMorphDialogState extends State<_ScheduleMorphDialog>
    with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 260);
  final GlobalKey<_ScheduleSheetState> _formKey = GlobalKey();
  final GlobalKey _measureKey = GlobalKey();
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: _duration,
    reverseDuration: _duration,
  );
  late Rect _startRect = widget.startRect;
  Rect? _endRect;
  bool _started = false;
  bool _closing = false;
  double? _frozenProgress;
  Rect? _displayEndRect;
  Rect? _closingEndRect;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closing) return;
      final box = _measureKey.currentContext?.findRenderObject();
      final height = box is RenderBox && box.hasSize ? box.size.height : 360.0;
      setState(() => _endRect = _targetRect(height));
      if (MediaQuery.disableAnimationsOf(context)) {
        _animation.value = 1;
      } else {
        _animation.forward();
      }
    });
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  Rect _targetRect(double measuredHeight) {
    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final width = math.min(560.0, math.max(0.0, size.width - 32));
    final top = safe.top + 16;
    final bottom = math.max(top, size.height - safe.bottom - 16);
    final height = math.min(measuredHeight, bottom - top);
    return Rect.fromLTWH(
      (size.width - width) / 2,
      top + (bottom - top - height) / 2,
      width,
      height,
    );
  }

  Rect _keyboardTargetRect(Rect end) {
    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final top = safe.top + 12;
    final bottom = math.max(
      top,
      size.height - MediaQuery.viewInsetsOf(context).bottom - 12,
    );
    final height = math.min(end.height, bottom - top);
    return Rect.fromLTWH(
      end.left,
      top + (bottom - top - height) / 2,
      end.width,
      height,
    );
  }

  Future<void> _requestClose() async {
    if (_closing) return;
    final form = _formKey.currentState;
    if (form == null) {
      await _close(false);
    } else {
      await form.requestClose();
    }
  }

  Future<void> _close(bool saved) async {
    if (_closing) return;
    final currentRect = widget.currentSourceRect();
    setState(() {
      _closing = true;
      _closingEndRect = _displayEndRect ?? _endRect;
      if (currentRect == null) {
        _frozenProgress = _animation.value;
      } else if (_animation.value >= 1) {
        _startRect = currentRect;
      }
    });
    FocusManager.instance.primaryFocus?.unfocus();
    if (MediaQuery.disableAnimationsOf(context)) {
      _animation.value = 0;
    } else {
      await _animation.reverse();
    }
    if (mounted) Navigator.of(context, rootNavigator: true).pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final size = MediaQuery.sizeOf(context);
    final width = math.min(560.0, math.max(0.0, size.width - 32));
    final end = _endRect;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, _) {
          final progress = _animation.value;
          final visualProgress = _frozenProgress ?? progress;
          final surfaceOpacity = _frozenProgress == null
              ? 1.0
              : _frozenProgress == 0
              ? 0.0
              : (progress / _frozenProgress!).clamp(0.0, 1.0);
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  key: const Key('today-add-schedule-scrim'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _requestClose,
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: .54 * progress),
                  ),
                ),
              ),
              if (end == null) ...[
                Offstage(
                  child: SizedBox(
                    width: width,
                    child: Material(
                      child: ScheduleSheet(
                        api: widget.api,
                        embedded: true,
                        interactive: false,
                        contentKey: _measureKey,
                      ),
                    ),
                  ),
                ),
                Positioned.fromRect(
                  rect: _startRect,
                  child: _scheduleSource(dark),
                ),
              ] else
                TweenAnimationBuilder<Rect?>(
                  tween: RectTween(
                    begin: _displayEndRect ?? end,
                    end: _closing
                        ? (_closingEndRect ?? end)
                        : progress >= 1
                        ? _keyboardTargetRect(end)
                        : end,
                  ),
                  duration: _closing
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  builder: (context, displayEndRect, _) {
                    final currentEndRect = displayEndRect ?? end;
                    _displayEndRect = currentEndRect;
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: Opacity(
                            key: const Key('today-add-schedule-fade-close'),
                            opacity: surfaceOpacity,
                            child: Stack(
                              children: [
                                _transition(
                                  currentEndRect,
                                  visualProgress,
                                  dark,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _transition(Rect end, double progress, bool dark) =>
      ContainerMorphTransition(
        progress: progress,
        isClosing: false,
        detailInteractive: _animation.value >= 1 && !_closing,
        startRect: _startRect,
        endSize: end.size,
        endRect: end,
        startBorderRadius: BorderRadius.circular(20),
        endBorderRadius: BorderRadius.circular(25),
        detailSafeArea: false,
        closedColor: dark ? const Color(0xff17263c) : const Color(0xffe8f1ff),
        openColor: dark ? const Color(0xff1c1e23) : Colors.white,
        sourceContent: _scheduleSource(dark),
        detailHeader: const SizedBox.shrink(),
        detailBody: ScheduleSheet(
          key: _formKey,
          api: widget.api,
          embedded: true,
          interactive: _animation.value >= 1 && !_closing,
          onClose: _close,
        ),
        surfaceKey: const Key('today-add-schedule-surface'),
      );

  Widget _scheduleSource(bool dark) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.add,
              size: 17,
              color: dark ? const Color(0xff9bc3ff) : const Color(0xff2563eb),
            ),
            const SizedBox(width: 8),
            Text(
              '添加安排',
              style: TextStyle(
                color: dark ? const Color(0xff9bc3ff) : const Color(0xff2563eb),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class ScheduleSheet extends StatefulWidget {
  const ScheduleSheet({
    super.key,
    required this.api,
    this.schedule,
    this.embedded = false,
    this.interactive = true,
    this.onClose,
    this.contentKey,
  });
  final ApiClient api;
  final CustomSchedule? schedule;
  final bool embedded;
  final bool interactive;
  final Future<void> Function(bool saved)? onClose;
  final Key? contentKey;
  @override
  State<ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends State<ScheduleSheet> {
  late final title = TextEditingController(text: widget.schedule?.title ?? '');
  late DateTime date = widget.schedule == null
      ? DateTime.now()
      : DateTime.parse(widget.schedule!.date);
  late TimeOfDay time = widget.schedule == null
      ? const TimeOfDay(hour: 9, minute: 0)
      : TimeOfDay(
          hour: int.parse(widget.schedule!.time.split(':')[0]),
          minute: int.parse(widget.schedule!.time.split(':')[1]),
        );
  bool pending = false;
  bool confirmingClose = false;
  String? error;
  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  String get timeText =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  bool get valid =>
      title.text.trim().isNotEmpty &&
      !date.isBefore(
        DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day),
      );
  bool get dirty =>
      title.text.trim() != (widget.schedule?.title.trim() ?? '') ||
      dateKey(date) != (widget.schedule?.date ?? dateKey(DateTime.now())) ||
      timeText != (widget.schedule?.time ?? '09:00');

  Future<void> requestClose() async {
    if (pending || confirmingClose) return;
    if (dirty) {
      confirmingClose = true;
      try {
        final discard = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('放弃未保存的更改？'),
            content: const Text('当前填写的安排尚未保存。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('继续编辑'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('放弃更改'),
              ),
            ],
          ),
        );
        if (discard != true || !mounted) return;
      } finally {
        confirmingClose = false;
      }
    }
    if (!mounted) return;
    if (widget.onClose case final close?) {
      await close(false);
    } else {
      Navigator.pop(context);
    }
  }

  Future<void> save() async {
    if (!valid || !dirty || pending) return;
    setState(() {
      pending = true;
      error = null;
    });
    try {
      await widget.api.saveSchedule(
        id: widget.schedule?.id,
        title: title.text.trim(),
        date: date,
        time: timeText,
      );
      if (mounted) {
        if (widget.onClose case final close?) {
          await close(true);
        } else {
          Navigator.pop(context, true);
        }
      }
    } on ApiFailure catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => pending = false);
    }
  }

  Future<void> chooseDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final chosen = await showDatePicker(
      context: context,
      firstDate: today,
      lastDate: today.add(const Duration(days: 3650)),
      initialDate: date.isBefore(today) ? today : date,
    );
    if (chosen != null) setState(() => date = chosen);
  }

  Future<void> chooseTime() async {
    final chosen = await showTimePicker(context: context, initialTime: time);
    if (chosen != null) setState(() => time = chosen);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final muted = dark ? const Color(0xffb2b8c2) : const Color(0xff64748b);
    final content = SingleChildScrollView(
      child: Padding(
        key: widget.contentKey,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.schedule == null ? '添加安排' : '编辑安排',
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: pending || !widget.interactive
                      ? null
                      : requestClose,
                  icon: const Icon(Icons.close, color: Color(0xff2563eb)),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              decoration: BoxDecoration(
                color: dark ? const Color(0xff181a1f) : const Color(0xfffdfefe),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: dark
                      ? const Color(0x18ffffff)
                      : const Color(0xffe5edf6),
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x120f172a),
                    blurRadius: 12,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                children: [
                  SizedBox(
                    height: 57,
                    child: Row(
                      children: [
                        const SizedBox(width: 15),
                        const Text('安排事项', style: TextStyle(fontSize: 16)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: title,
                            maxLength: 200,
                            onChanged: (_) => setState(() {}),
                            textAlign: TextAlign.end,
                            decoration: const InputDecoration(
                              hintText: '例如：提交课程作业',
                              border: InputBorder.none,
                              counterText: '',
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ),
                        const SizedBox(width: 15),
                      ],
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: dark
                        ? const Color(0x18ffffff)
                        : const Color(0xffe5edf6),
                  ),
                  _ScheduleSettingRow(
                    label: '日期',
                    value: '${date.year}年${date.month}月${date.day}日',
                    onTap: chooseDate,
                    muted: muted,
                  ),
                  Divider(
                    height: 1,
                    color: dark
                        ? const Color(0x18ffffff)
                        : const Color(0xffe5edf6),
                  ),
                  _ScheduleSettingRow(
                    label: '时间',
                    value: timeText,
                    onTap: chooseTime,
                    muted: muted,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 15),
            Text(
              '只能添加今天及以后的安排；时间仅用于当天排序，不会触发系统通知。',
              style: TextStyle(fontSize: 13, height: 1.48, color: muted),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 15),
            SizedBox(
              height: 46,
              child: FilledButton(
                onPressed: pending || !valid || !dirty || !widget.interactive
                    ? null
                    : save,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xff2563eb),
                  disabledBackgroundColor: dark
                      ? const Color(0x18ffffff)
                      : const Color(0xffe2e8f0),
                  disabledForegroundColor: const Color(0xff94a3b8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  pending ? '保存中…' : '保存安排',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (widget.embedded) {
      return IgnorePointer(
        ignoring: !widget.interactive,
        child: ExcludeFocus(excluding: !widget.interactive, child: content),
      );
    }
    final dialog = Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
      backgroundColor: dark ? const Color(0xff1c1e23) : Colors.white,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: content,
      ),
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) requestClose();
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: const Key('schedule-dialog-scrim'),
              behavior: HitTestBehavior.opaque,
              onTap: requestClose,
            ),
          ),
          Center(child: dialog),
        ],
      ),
    );
  }
}

class _ScheduleSettingRow extends StatelessWidget {
  const _ScheduleSettingRow({
    required this.label,
    required this.value,
    required this.onTap,
    required this.muted,
  });
  final String label, value;
  final VoidCallback onTap;
  final Color muted;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: SizedBox(
      height: 57,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15),
        child: Row(
          children: [
            Text(label, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, color: muted),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 18, color: muted),
          ],
        ),
      ),
    ),
  );
}
