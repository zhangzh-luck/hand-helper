import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'container_morph_transition.dart';
import 'native_tab_bridge.dart';
import 'today_page.dart' show dataImage;

class AnalysisPage extends StatefulWidget {
  const AnalysisPage({
    super.key,
    required this.api,
    required this.onUnauthorized,
    this.localProfileChanges,
    this.onDetailChanged,
    this.onDetailClosingChanged,
  });
  final ApiClient api;
  final VoidCallback onUnauthorized;
  final ValueListenable<Profile?>? localProfileChanges;
  final ValueChanged<bool>? onDetailChanged;
  final ValueChanged<bool>? onDetailClosingChanged;
  @override
  State<AnalysisPage> createState() => _AnalysisPageState();
}

class _AnalysisPageState extends State<AnalysisPage>
    with SingleTickerProviderStateMixin {
  final GlobalKey _contentStackKey = GlobalKey();
  final Map<int, GlobalKey> _gradeRowKeys = {};
  late final AnimationController _detailAnimation;
  GradeRecord? detailGrade;
  Rect? _gradeRect;
  BorderRadius _gradeRadius = BorderRadius.zero;
  bool closingDetail = false;
  bool fadingClose = false;
  AnalysisData? data;
  int? selectedTermId;
  GradeAnalysis? currentAnalysis;
  bool historyOpen = false;
  bool loading = true;
  bool refreshing = false;
  bool online = false;
  bool analyzing = false;
  String? error;
  String? actionError;
  String? backgroundSource;
  ImageProvider? backgroundImage;
  final scrollController = ScrollController();
  bool compactTitle = false;

  @override
  void initState() {
    super.initState();
    _detailAnimation = AnimationController(
      vsync: this,
      duration: ContainerMorphTransition.duration,
      reverseDuration: ContainerMorphTransition.duration,
    );
    widget.localProfileChanges?.addListener(onLocalProfileChanged);
    scrollController.addListener(() {
      final compact = scrollController.offset > 45;
      if (compact != compactTitle) setState(() => compactTitle = compact);
    });
    initialize();
  }

  @override
  void dispose() {
    widget.localProfileChanges?.removeListener(onLocalProfileChanged);
    _detailAnimation.dispose();
    scrollController.dispose();
    super.dispose();
  }

  void onLocalProfileChanged() {
    if (mounted) setState(() {});
  }

  TermInfo? get selectedTerm {
    final terms = data?.terms ?? [];
    if (terms.isEmpty) return null;
    for (final term in terms) {
      if (term.id == selectedTermId) return term;
    }
    for (final term in terms) {
      if (term.isCurrent) return term;
    }
    final now = DateTime.now();
    final academic = now.month >= 9
        ? '${now.year}-${now.year + 1}-1'
        : '${now.year - 1}-${now.year}-2';
    for (final term in terms) {
      if (term.sourceId == academic) return term;
    }
    return terms.last;
  }

  ImageProvider? imageFor(String? source) {
    if (source != backgroundSource) {
      backgroundSource = source;
      backgroundImage = dataImage(source);
    }
    return backgroundImage;
  }

  Future<void> initialize() async {
    final snapshot = await widget.api.loadAnalysisSnapshot();
    if (!mounted) return;
    setState(() {
      data = snapshot;
      loading = false;
    });
    await refresh();
  }

  Future<void> refresh() async {
    if (refreshing) return;
    setState(() => refreshing = true);
    try {
      final fresh = await widget.api.analysisData();
      if (!mounted) return;
      setState(() {
        data = fresh;
        online = true;
        error = null;
        loading = false;
        if (!fresh.terms.any((term) => term.id == selectedTermId)) {
          selectedTermId = null;
        }
      });
    } on ApiFailure catch (failure) {
      if (failure.unauthorized) {
        if (mounted) widget.onUnauthorized();
        return;
      }
      if (mounted) {
        setState(() {
          online = false;
          error = failure.message;
          loading = false;
        });
      }
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  Future<void> analyze({bool force = false}) async {
    final term = selectedTerm;
    if (!online || term == null || analyzing) return;
    setState(() {
      analyzing = true;
      actionError = null;
    });
    try {
      final result = await widget.api.analyzeGrades(
        term.id,
        forceRefresh: force,
      );
      if (!mounted) return;
      setState(() {
        currentAnalysis = result;
        analyzing = false;
      });
      await refresh();
      if (mounted) showAnalysis(result);
    } on ApiFailure catch (failure) {
      if (failure.unauthorized) {
        if (mounted) widget.onUnauthorized();
        return;
      }
      if (mounted) {
        setState(() {
          actionError = failure.message;
          analyzing = false;
          if (failure.connection) online = false;
        });
      }
    }
  }

  Future<void> removeGrades() async {
    final term = selectedTerm;
    if (!online || term == null) return;
    final count = data?.gradesByTerm[term.id]?.length ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${term.name} 的成绩？'),
        content: Text(
          '将删除该学期已导入的全部 $count 门成绩，以及对应的 AI 分析缓存。此操作无法撤销，其他学期不会受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.deleteGrades(term.id);
      if (!mounted) return;
      setState(() {
        currentAnalysis = null;
        historyOpen = false;
        final previous = data;
        if (previous != null) {
          data = AnalysisData(
            previous.terms,
            {...previous.gradesByTerm}..remove(term.id),
            {...previous.summariesByTerm}..remove(term.id),
            {...previous.historyByTerm}..remove(term.id),
            previous.background,
            previous.savedAt,
          );
        }
      });
      await refresh();
    } on ApiFailure catch (failure) {
      if (failure.unauthorized) {
        if (mounted) widget.onUnauthorized();
        return;
      }
      if (mounted) setState(() => actionError = failure.message);
    }
  }

  Rect? _currentGradeRect(int id) {
    final row = _gradeRowKeys[id]?.currentContext?.findRenderObject();
    final stack = _contentStackKey.currentContext?.findRenderObject();
    if (row is! RenderBox ||
        stack is! RenderBox ||
        !row.hasSize ||
        !stack.hasSize) {
      return null;
    }
    final rect = row.localToGlobal(Offset.zero, ancestor: stack) & row.size;
    final bounds = Offset.zero & stack.size;
    if (!rect.isFinite ||
        rect.width <= 0 ||
        rect.height <= 0 ||
        !rect.overlaps(bounds)) {
      return null;
    }
    return rect;
  }

  BorderRadius _rowRadius(int index, int count) {
    const corner = Radius.circular(18);
    return BorderRadius.only(
      topLeft: index == 0 ? corner : Radius.zero,
      topRight: index == 0 ? corner : Radius.zero,
      bottomLeft: index == count - 1 ? corner : Radius.zero,
      bottomRight: index == count - 1 ? corner : Radius.zero,
    );
  }

  void showGrade(GradeRecord grade, int index, int count) {
    if (detailGrade != null) return;
    final rect = _currentGradeRect(grade.id);
    if (rect == null) return;
    HapticFeedback.lightImpact();
    setState(() {
      detailGrade = grade;
      _gradeRect = rect;
      _gradeRadius = _rowRadius(index, count);
      closingDetail = false;
      fadingClose = false;
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      _detailAnimation.value = 1;
      widget.onDetailChanged?.call(true);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || detailGrade?.id != grade.id || closingDetail) return;
        widget.onDetailChanged?.call(true);
        _detailAnimation.forward(from: 0);
      });
    }
  }

  Future<void> closeGrade({bool fromSystemBack = false}) async {
    if (detailGrade == null || closingDetail) return;
    if (!fromSystemBack) HapticFeedback.lightImpact();
    closingDetail = true;
    widget.onDetailClosingChanged?.call(true);
    final gradeId = detailGrade!.id;
    final validRow = (data?.gradesByTerm[selectedTerm?.id] ?? []).any(
      (grade) => grade.id == gradeId,
    );
    final currentRect = validRow ? _currentGradeRect(gradeId) : null;
    fadingClose = currentRect == null;
    if (currentRect != null) _gradeRect = currentRect;
    setState(() {});
    var dockRestored = false;
    void restoreDock() {
      if (dockRestored || !mounted) return;
      dockRestored = true;
      widget.onDetailChanged?.call(false);
    }

    if (MediaQuery.disableAnimationsOf(context)) {
      _detailAnimation.value = 0;
      restoreDock();
    } else {
      void restoreDockNearEnd() {
        if (_detailAnimation.value <= .42) restoreDock();
      }

      _detailAnimation.addListener(restoreDockNearEnd);
      try {
        await _detailAnimation.reverse();
      } finally {
        _detailAnimation.removeListener(restoreDockNearEnd);
      }
    }
    if (!mounted) return;
    setState(() {
      detailGrade = null;
      _gradeRect = null;
      closingDetail = false;
      fadingClose = false;
    });
    restoreDock();
    widget.onDetailClosingChanged?.call(false);
  }

  Widget _gradeDetailHeader(GradeRecord grade) => Padding(
    key: const Key('analysis-detail-header'),
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('analysis-detail-back'),
            onPressed: () => closeGrade(),
            icon: const Icon(Icons.chevron_left),
            label: const Text('成绩分析'),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          '成绩详情',
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          grade.name,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );

  Widget _gradeDetailBody(GradeRecord grade) => ListView(
    key: const Key('analysis-detail-scroll'),
    padding: EdgeInsets.fromLTRB(
      20,
      0,
      20,
      24 + MediaQuery.viewPaddingOf(context).bottom,
    ),
    children: [
      _detailRow(Icons.book_outlined, '课程名称', grade.name),
      Container(
        key: const Key('analysis-score-card'),
        margin: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xff14253b)
              : const Color(0xffeff6ff),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Expanded(
              child: _scoreCell(
                '总评成绩',
                grade.score ?? '未公布',
                highlighted: true,
              ),
            ),
            Expanded(child: _scoreCell('期末成绩', grade.finalScore ?? '未提供')),
            Expanded(child: _scoreCell('平时成绩', grade.usualScore ?? '未提供')),
          ],
        ),
      ),
      _detailRow(
        Icons.school_outlined,
        '学分 / 绩点',
        '${grade.credits ?? '—'} / ${grade.gradePoint ?? '—'}',
      ),
      _detailRow(Icons.book_outlined, '课程性质', grade.type ?? '未提供'),
      _detailRow(Icons.description_outlined, '考试性质', grade.examType ?? '未提供'),
      _detailRow(
        Icons.refresh_outlined,
        '补考 / 重修',
        '${grade.makeup ? '补考' : '否'} / ${grade.retake ? '重修' : '否'}',
      ),
    ],
  );

  Widget _scoreCell(String label, String value, {bool highlighted = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 13),
        child: Column(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: highlighted
                    ? const Color(0xff007aff)
                    : const Color(0xff64748b),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: highlighted ? 23 : 17,
                fontWeight: FontWeight.w700,
                color: highlighted ? const Color(0xff007aff) : null,
              ),
            ),
          ],
        ),
      );

  Widget _detailRow(IconData icon, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(
      children: [
        Icon(icon, size: 20, color: const Color(0xff6991ba)),
        const SizedBox(width: 11),
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: Color(0xff8590a0)),
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

  Future<void> showAnalysis(GradeAnalysis result) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * .82,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '分析结果',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                children: [
                  _detailRow(Icons.auto_awesome_outlined, '分析模型', result.model),
                  _detailRow(
                    Icons.storage_outlined,
                    '结果来源',
                    result.cached ? '已使用当前成绩快照的缓存结果' : '本次实时生成',
                  ),
                  _detailRow(
                    Icons.schedule_outlined,
                    '生成时间',
                    _dateTime(result.createdAt),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: online
                          ? () {
                              Navigator.pop(sheetContext);
                              analyze(force: true);
                            }
                          : null,
                      child: const Text('重新生成'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _MarkdownReport(content: result.content),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final term = selectedTerm;
    final grades = data?.gradesByTerm[term?.id] ?? [];
    final summary = data?.summariesByTerm[term?.id];
    final history = data?.historyByTerm[term?.id] ?? [];
    final background = imageFor(
      widget.localProfileChanges?.value == null
          ? data?.background
          : widget.localProfileChanges!.value!.analysisWallpaper,
    );
    final cardColor = dark ? const Color(0xe6141416) : const Color(0xedffffff);
    final borderColor = dark ? Colors.white10 : const Color(0x120f172a);
    final activeGrade = detailGrade;
    final detailHeader = activeGrade == null
        ? null
        : _gradeDetailHeader(activeGrade);
    final detailBody = activeGrade == null
        ? null
        : _gradeDetailBody(activeGrade);
    final sourceContent = activeGrade == null
        ? null
        : _gradeRowContent(activeGrade);
    final pageColor = dark ? Colors.black : const Color(0xfff4f7fb);
    final closedColor = Color.alphaBlend(cardColor, pageColor);
    return PopScope(
      canPop: detailGrade == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && detailGrade != null) closeGrade(fromSystemBack: true);
      },
      child: Stack(
        key: _contentStackKey,
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: dark ? Colors.black : const Color(0xfff4f7fb),
            ),
          ),
          if (background != null)
            Positioned.fill(
              child: Opacity(
                opacity: dark ? .6 : .5,
                child: Image(
                  image: background,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
            ),
          Positioned.fill(
            child: ColoredBox(
              color: dark ? const Color(0x6b000000) : const Color(0x52f4f7fb),
            ),
          ),
          IgnorePointer(
            ignoring: detailGrade != null,
            child: ExcludeFocus(
              excluding: detailGrade != null,
              child: ExcludeSemantics(
                excluding: detailGrade != null,
                child: SafeArea(
                  bottom: false,
                  child: Stack(
                    children: [
                      ListView(
                        controller: scrollController,
                        physics: const ClampingScrollPhysics(),
                        padding: EdgeInsets.fromLTRB(
                          18,
                          25,
                          18,
                          NativeTabMetrics.contentBottomPadding(
                            context,
                            android: 118,
                          ),
                        ),
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.school_outlined, size: 25),
                              SizedBox(width: 11),
                              Text(
                                '成绩分析',
                                style: TextStyle(
                                  fontSize: 27,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          _group(
                            cardColor,
                            borderColor,
                            Column(
                              children: [
                                InkWell(
                                  onTap: data?.terms.isNotEmpty == true
                                      ? () => _selectTerm()
                                      : null,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 15,
                                      vertical: 14,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const Text(
                                                '当前学期',
                                                style: TextStyle(
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                              const SizedBox(height: 3),
                                              const Text(
                                                '选择要查看成绩与分析的学期',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: Color(0xff8e8e93),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Flexible(
                                          fit: FlexFit.tight,
                                          child: Text(
                                            term?.name ?? '选择学期',
                                            maxLines: 1,
                                            textAlign: TextAlign.right,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Color(0xff2563eb),
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        const Icon(
                                          Icons.chevron_right,
                                          size: 19,
                                          color: Color(0xff2563eb),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (grades.isNotEmpty && online) ...[
                                  _divider(borderColor),
                                  TextButton.icon(
                                    onPressed: removeGrades,
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 17,
                                    ),
                                    label: const Text('删除本学期成绩'),
                                    style: TextButton.styleFrom(
                                      foregroundColor: const Color(0xffff3b30),
                                      minimumSize: const Size.fromHeight(53),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          _sectionTitle('成绩概览'),
                          const SizedBox(height: 9),
                          _group(
                            cardColor,
                            borderColor,
                            Column(
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: _metric(
                                        '已获学分',
                                        '${summary?.earnedCredits ?? '—'}',
                                      ),
                                    ),
                                    Expanded(
                                      child: _metric(
                                        '平均成绩',
                                        summary?.averageScore?.toStringAsFixed(
                                              1,
                                            ) ??
                                            '—',
                                      ),
                                    ),
                                  ],
                                ),
                                _divider(borderColor),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _metric(
                                        '绩点',
                                        summary?.gpa?.toStringAsFixed(2) ?? '—',
                                      ),
                                    ),
                                    Expanded(
                                      child: _metric(
                                        '不及格',
                                        '${summary?.failedCourses ?? '—'}',
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          _sectionTitle('AI 成绩分析'),
                          const SizedBox(height: 9),
                          _group(
                            cardColor,
                            borderColor,
                            Column(
                              children: [
                                _actionRow(
                                  currentAnalysis == null
                                      ? '生成 AI 成绩分析'
                                      : '查看 AI 成绩分析',
                                  currentAnalysis != null
                                      ? '查看当前学期已生成的分析结果'
                                      : analyzing
                                      ? '正在分析当前学期成绩…'
                                      : '基于当前学期成绩生成学习建议',
                                  onTap: currentAnalysis != null
                                      ? () => showAnalysis(currentAnalysis!)
                                      : (term != null &&
                                                grades.isNotEmpty &&
                                                !analyzing
                                            ? () {
                                                if (online) {
                                                  analyze();
                                                } else {
                                                  ScaffoldMessenger.of(context)
                                                      .showSnackBar(
                                                        const SnackBar(
                                                          content: Text(
                                                            '当前无法同步，暂不能生成分析。',
                                                          ),
                                                        ),
                                                      );
                                                }
                                              }
                                            : null),
                                  highlight: true,
                                  trailing: analyzing ? '分析中…' : null,
                                ),
                                _divider(borderColor),
                                _actionRow(
                                  '历史分析',
                                  history.isEmpty
                                      ? '查看本学期已生成的分析'
                                      : '本学期共 ${history.length} 条记录',
                                  onTap: term == null || data == null
                                      ? null
                                      : () => setState(
                                          () => historyOpen = !historyOpen,
                                        ),
                                  expanded: historyOpen,
                                ),
                                if (historyOpen) ...[
                                  _divider(borderColor),
                                  if (history.isEmpty)
                                    const Padding(
                                      padding: EdgeInsets.all(14),
                                      child: Text(
                                        '当前学期还没有可查看的历史分析。',
                                        style: TextStyle(fontSize: 13),
                                      ),
                                    )
                                  else
                                    for (final entry in history)
                                      _actionRow(
                                        entry.model,
                                        '${_dateTime(entry.createdAt)} · ${entry.provider}',
                                        onTap: () => showAnalysis(
                                          GradeAnalysis(
                                            entry.id,
                                            entry.termId,
                                            entry.content,
                                            entry.provider,
                                            entry.model,
                                            entry.createdAt,
                                            true,
                                          ),
                                        ),
                                      ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 7),
                          const Text(
                            '仅在你点击生成后，将当前学期的课程名称、成绩、学分和绩点发送给已配置的模型服务。',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xff8e8e93),
                              height: 1.5,
                            ),
                          ),
                          if (actionError != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 9),
                              child: Text(
                                actionError!,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.red,
                                ),
                              ),
                            ),
                          const SizedBox(height: 19),
                          if (data == null && !loading)
                            Row(
                              children: [
                                const Expanded(child: Text('成绩尚未缓存，请联网后重试')),
                                TextButton(
                                  onPressed: refreshing ? null : refresh,
                                  child: const Text('重试'),
                                ),
                              ],
                            )
                          else if (loading)
                            const Center(child: CircularProgressIndicator())
                          else if (grades.isEmpty && term != null)
                            _group(
                              cardColor,
                              borderColor,
                              const Padding(
                                padding: EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '暂无课程成绩',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      '导入成绩文件后，这里会显示每门课程的成绩与详情。',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Color(0xff8e8e93),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else ...[
                            _sectionTitle('课程成绩'),
                            const SizedBox(height: 9),
                            _group(
                              cardColor,
                              borderColor,
                              _gradeList(grades, borderColor),
                            ),
                          ],
                          if (summary?.note != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(
                                summary!.note!,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xff8e8e93),
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (compactTitle)
                        Positioned(
                          top: 6,
                          left: 0,
                          right: 0,
                          child: IgnorePointer(
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: cardColor,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: borderColor),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Color(0x150f172a),
                                      blurRadius: 10,
                                    ),
                                  ],
                                ),
                                child: const Text(
                                  '成绩分析',
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (activeGrade != null)
            AnimatedBuilder(
              animation: _detailAnimation,
              builder: (context, _) {
                final size = MediaQuery.sizeOf(context);
                final end = Offset.zero & size;
                final transition = ContainerMorphTransition(
                  progress: fadingClose ? 1 : _detailAnimation.value,
                  isClosing:
                      closingDetail &&
                      _detailAnimation.status == AnimationStatus.reverse,
                  detailInteractive:
                      _detailAnimation.value >= 1 && !closingDetail,
                  startRect: _gradeRect ?? end,
                  endSize: size,
                  startBorderRadius: _gradeRadius,
                  closedColor: closedColor,
                  openColor: pageColor,
                  sourceContent: sourceContent!,
                  detailHeader: detailHeader!,
                  detailBody: detailBody!,
                  surfaceKey: const Key('analysis-transform-surface'),
                  sourceLayerKey: const Key('analysis-source-layer'),
                  detailHeaderLayerKey: const Key(
                    'analysis-detail-header-layer',
                  ),
                  detailBodyLayerKey: const Key('analysis-detail-body-layer'),
                );
                if (!fadingClose) return transition;
                return Positioned.fill(
                  child: Opacity(
                    key: const Key('analysis-fade-close'),
                    opacity: _detailAnimation.value,
                    child: Stack(fit: StackFit.expand, children: [transition]),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  void _selectTerm() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * .72,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              for (final term in data?.terms ?? <TermInfo>[])
                ListTile(
                  title: Text(term.name),
                  trailing: selectedTerm?.id == term.id
                      ? const Icon(Icons.check, color: Color(0xff007aff))
                      : null,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    setState(() {
                      selectedTermId = term.id;
                      currentAnalysis = null;
                      historyOpen = false;
                      actionError = null;
                    });
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String value) => Padding(
    padding: const EdgeInsets.only(left: 1),
    child: Text(
      value,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
    ),
  );

  Widget _gradeList(List<GradeRecord> grades, Color borderColor) => Column(
    children: [
      for (var index = 0; index < grades.length; index++) ...[
        if (index > 0) _divider(borderColor),
        Opacity(
          key: Key('analysis-grade-row-${grades[index].id}'),
          opacity: detailGrade?.id == grades[index].id ? 0 : 1,
          child: InkWell(
            key: _gradeRowKeys.putIfAbsent(grades[index].id, GlobalKey.new),
            onTap: () => showGrade(grades[index], index, grades.length),
            child: _gradeRowContent(grades[index]),
          ),
        ),
      ],
    ],
  );

  Widget _gradeRowContent(GradeRecord grade) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                grade.name,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${grade.type ?? '课程性质未提供'} · ${grade.credits ?? '—'} 学分 · GPA ${grade.gradePoint ?? '—'}',
                style: const TextStyle(fontSize: 12, color: Color(0xff8e8e93)),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Text(
              '成绩',
              style: TextStyle(fontSize: 11, color: Color(0xff8e8e93)),
            ),
            Text(
              grade.score ?? '未公布',
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _group(Color color, Color border, Widget child) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: border),
      boxShadow: const [BoxShadow(color: Color(0x0a0f172a), blurRadius: 10)],
    ),
    child: child,
  );

  Widget _divider(Color color) =>
      Divider(height: 1, thickness: 1, color: color);

  Widget _metric(String label, String value) => Container(
    height: 94,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    alignment: Alignment.centerLeft,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: Color(0xff8e8e93)),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );

  Widget _actionRow(
    String title,
    String subtitle, {
    VoidCallback? onTap,
    bool highlight = false,
    bool expanded = false,
    String? trailing,
  }) => InkWell(
    onTap: onTap,
    child: Container(
      constraints: const BoxConstraints(minHeight: 65),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: highlight && Theme.of(context).brightness != Brightness.dark
          ? const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xa3eff6ff), Colors.transparent],
              ),
            )
          : null,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: onTap == null ? const Color(0xff8e8e93) : null,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff8e8e93),
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null)
            Text(
              trailing,
              style: const TextStyle(color: Color(0xff2563eb), fontSize: 12),
            )
          else
            Icon(
              expanded ? Icons.keyboard_arrow_down : Icons.chevron_right,
              color: const Color(0xff2563eb),
            ),
        ],
      ),
    ),
  );
}

String _dateTime(DateTime value) =>
    '${value.year}年${value.month}月${value.day}日 '
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

class _MarkdownReport extends StatelessWidget {
  const _MarkdownReport({required this.content});
  final String content;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final blocks = <Widget>[];
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('## ')) {
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(top: 9, bottom: 7),
            child: Text(
              trimmed.substring(3),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
          ),
        );
      } else if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
        blocks.add(
          Container(
            margin: const EdgeInsets.only(bottom: 7),
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: dark ? const Color(0x14ffffff) : const Color(0xfff7faff),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  ', style: TextStyle(color: Color(0xff5b8ef7))),
                Expanded(
                  child: Text(
                    trimmed.substring(2),
                    style: const TextStyle(height: 1.6),
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Text(trimmed, style: const TextStyle(height: 1.65)),
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: blocks,
    );
  }
}
