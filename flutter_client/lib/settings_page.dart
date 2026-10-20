import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:crop_your_image/crop_your_image.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'appearance_mode_selector.dart';
import 'container_morph_transition.dart';
import 'native_period_time_picker.dart';
import 'native_term_start_date_picker.dart';
import 'native_tab_bridge.dart';
import 'passkey_management_page.dart';

enum _LeavePersonalChoice { discard, save }

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.api,
    required this.onUnauthorized,
    required this.onSignedOut,
    required this.themeMode,
    required this.onThemeModeChanged,
    this.onProfileChanged,
    this.onSectionChanged,
    this.onSectionClosingChanged,
  });
  final ApiClient api;
  final VoidCallback onUnauthorized;
  final VoidCallback onSignedOut;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final ValueChanged<Profile>? onProfileChanged;
  final ValueChanged<bool>? onSectionChanged;
  final ValueChanged<bool>? onSectionClosingChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with SingleTickerProviderStateMixin {
  final GlobalKey _contentStackKey = GlobalKey();
  final Map<String, GlobalKey> _entryKeys = {
    for (final name in [
      'account',
      'time',
      'personal',
      'data',
      'analysis',
      'about',
    ])
      name: GlobalKey(),
  };
  late final AnimationController _sectionAnimation;
  Rect? _entryRect;
  SettingsData? data;
  AiProviderSettings? ai;
  String? section;
  String? error;
  String? notice;
  bool loading = true;
  bool online = false;
  bool busy = false;
  bool confirmingLeave = false;
  bool closingSection = false;
  final NativePeriodTimePicker _nativeTimePicker = NativePeriodTimePicker();
  int? _activeTimeRequestId;
  int _timeRequestGeneration = 0;
  final NativeTermStartDatePicker _nativeDatePicker =
      NativeTermStartDatePicker();
  int? _activeDateRequestId;
  int _dateRequestGeneration = 0;
  int? selectedTermId;
  int? selectedPeriodNumber;
  String? draftName;
  final Map<String, dynamic> profileChanges = {};
  String provider = 'APIKEY.FAN';
  String baseUrl = 'https://api.apikey.fan/v1';
  String model = '';
  String apiKey = '';
  List<String> models = [];
  String? appVersion;
  bool versionRequested = false;

  @override
  void initState() {
    super.initState();
    _sectionAnimation = AnimationController(
      vsync: this,
      duration: ContainerMorphTransition.duration,
      reverseDuration: ContainerMorphTransition.duration,
    );
    initialize();
  }

  @override
  void dispose() {
    final requestId = _activeTimeRequestId;
    if (requestId != null) {
      unawaited(_dismissTimePicker(requestId));
    }
    final dateRequestId = _activeDateRequestId;
    if (dateRequestId != null) {
      unawaited(_dismissDatePicker(dateRequestId));
    }
    _sectionAnimation.dispose();
    super.dispose();
  }

  Future<void> _dismissTimePicker(int requestId) async {
    _timeRequestGeneration++;
    try {
      await _nativeTimePicker.dismiss(requestId);
    } on PlatformException {
      // A scene can close before the outstanding native picker is dismissed.
    } on MissingPluginException {
      // The Flutter engine may already be detached during disposal.
    } finally {
      if (_activeTimeRequestId == requestId) _activeTimeRequestId = null;
    }
  }

  Future<void> _dismissDatePicker(int requestId) async {
    _dateRequestGeneration++;
    try {
      await _nativeDatePicker.dismiss(requestId);
    } on PlatformException {
      // The scene may close while its native date sheet is still presented.
    } on MissingPluginException {
      // The Flutter engine may already be detached during disposal.
    } finally {
      if (_activeDateRequestId == requestId) _activeDateRequestId = null;
    }
  }

  Future<void> initialize() async {
    final snapshot = await widget.api.loadSettingsSnapshot();
    if (!mounted) return;
    setState(() {
      data = snapshot;
      loading = false;
    });
    await recoverPickedImage();
    await refresh();
  }

  Future<void> recoverPickedImage() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(pendingLocalPhotoKey);
    if (key == null) return;
    await prefs.remove(pendingLocalPhotoKey);
    try {
      final response = await ImagePicker().retrieveLostData();
      final files = response.files;
      if (!mounted || response.isEmpty || files == null || files.isEmpty)
        return;
      setState(() => section = 'personal');
      // Android may recreate the activity while the photo picker is open.
      // There is no originating row to animate from after restoration.
      _sectionAnimation.value = 1;
      widget.onSectionChanged?.call(true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) await cropPickedImage(key, files.first);
    } catch (_) {
      if (mounted) message('上次选择的图片未能恢复，请重新选择。');
    }
  }

  Future<void> refresh() async {
    try {
      final fresh = await widget.api.settingsData();
      if (!mounted) return;
      setState(() {
        data = fresh;
        online = true;
        error = null;
        loading = false;
      });
      if (section == 'analysis') await loadAi();
    } on ApiFailure catch (failure) {
      if (failure.unauthorized) {
        if (mounted) widget.onUnauthorized();
        return;
      }
      if (mounted) {
        setState(() {
          online = false;
          // A cached/local Settings page remains usable without a server.
          error = data == null ? failure.message : null;
          loading = false;
        });
      }
    }
  }

  Future<void> loadAi() async {
    if (!online) return;
    try {
      final result = await widget.api.aiSettings();
      if (!mounted) return;
      setState(() {
        ai = result;
        provider = result.provider ?? 'APIKEY.FAN';
        baseUrl = result.baseUrl ?? 'https://api.apikey.fan/v1';
        model = result.model ?? '';
        models = result.models;
        apiKey = '';
      });
    } on ApiFailure catch (failure) {
      if (failure.unauthorized) {
        if (mounted) widget.onUnauthorized();
        return;
      }
      if (mounted) setState(() => error = failure.message);
    }
  }

  void open(String value) {
    if (section != null) return;
    final source = _entryKeys[value]?.currentContext?.findRenderObject();
    final stack = _contentStackKey.currentContext?.findRenderObject();
    if (source is RenderBox && stack is RenderBox && source.hasSize) {
      _entryRect =
          source.localToGlobal(Offset.zero, ancestor: stack) & source.size;
    } else {
      _entryRect = null;
    }
    HapticFeedback.lightImpact();
    setState(() {
      section = value;
      error = null;
      notice = null;
    });
    if (MediaQuery.disableAnimationsOf(context) || _entryRect == null) {
      _sectionAnimation.value = 1;
      widget.onSectionChanged?.call(true);
    } else {
      // Mount and lay out both destination layers before the first moving
      // frame; otherwise their first layout happens halfway through a drag.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || section != value) return;
        widget.onSectionChanged?.call(true);
        _sectionAnimation.forward(from: 0);
      });
    }
    if (value == 'analysis') loadAi();
    if (value == 'about') loadAppVersion();
  }

  Future<void> loadAppVersion() async {
    if (versionRequested) return;
    versionRequested = true;
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => appVersion = 'v${info.version}');
    } catch (_) {
      if (mounted) setState(() => appVersion = '版本暂不可用');
    }
  }

  bool get hasUnsavedProfile {
    final saved = data?.profile ?? const Profile('航的助手', null, null);
    if (draftName != null && draftName != saved.name) return true;
    for (final entry in profileChanges.entries) {
      final previous = switch (entry.key) {
        'avatar_data_url' => saved.avatar,
        'home_wallpaper_data_url' => saved.wallpaper,
        'timetable_background_data_url' => saved.timetableBackground,
        'analysis_wallpaper_data_url' => saved.analysisWallpaper,
        'settings_wallpaper_data_url' => saved.settingsWallpaper,
        _ => null,
      };
      if (entry.value != previous) return true;
    }
    return false;
  }

  Future<void> returnToRoot({bool discardDraft = false}) async {
    if (closingSection) return;
    closingSection = true;
    widget.onSectionClosingChanged?.call(true);
    var dockRestored = false;
    void restoreDock() {
      if (dockRestored || !mounted) return;
      dockRestored = true;
      widget.onSectionChanged?.call(false);
    }

    if (MediaQuery.disableAnimationsOf(context)) {
      _sectionAnimation.value = 0;
      restoreDock();
    } else {
      // Start bringing the dock back during the last part of the collapse,
      // but keep it non-interactive until the detail is completely closed.
      void restoreDockNearEnd() {
        if (_sectionAnimation.value <= .42) restoreDock();
      }

      _sectionAnimation.addListener(restoreDockNearEnd);
      try {
        await _sectionAnimation.reverse();
      } finally {
        _sectionAnimation.removeListener(restoreDockNearEnd);
      }
    }
    if (!mounted) return;
    setState(() {
      section = null;
      error = null;
      notice = null;
      _entryRect = null;
      if (discardDraft) {
        draftName = null;
        profileChanges.clear();
      }
    });
    restoreDock();
    closingSection = false;
    widget.onSectionClosingChanged?.call(false);
  }

  Future<void> requestBack({bool fromSystemBack = false}) async {
    final dateRequestId = _activeDateRequestId;
    if (dateRequestId != null) {
      await _dismissDatePicker(dateRequestId);
      return;
    }
    final requestId = _activeTimeRequestId;
    if (requestId != null) {
      await _dismissTimePicker(requestId);
      return;
    }
    if (section == null || busy || confirmingLeave || closingSection) return;
    if (!fromSystemBack) HapticFeedback.lightImpact();
    if (section != 'personal' || !hasUnsavedProfile) {
      returnToRoot(discardDraft: section == 'personal');
      return;
    }
    confirmingLeave = true;
    try {
      final choice = await showDialog<_LeavePersonalChoice>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('有未保存的更改'),
          content: const Text('头像、姓名或壁纸的更改尚未保存到此设备。要先保存再返回设置吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('继续编辑'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, _LeavePersonalChoice.discard),
              child: const Text('放弃更改'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, _LeavePersonalChoice.save),
              child: const Text('保存并返回'),
            ),
          ],
        ),
      );
      if (!mounted || section != 'personal') return;
      if (choice == _LeavePersonalChoice.discard)
        returnToRoot(discardDraft: true);
      if (choice == _LeavePersonalChoice.save &&
          await saveProfile() &&
          mounted) {
        returnToRoot();
      }
    } finally {
      confirmingLeave = false;
    }
  }

  void message(String value) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));

  Future<T?> action<T>(Future<T> Function() task, {String? success}) async {
    if (busy) return null;
    if (!online) {
      message('当前无法同步，设置暂不能修改。');
      return null;
    }
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      final result = await task();
      if (mounted) setState(() => notice = success);
      return result;
    } on ApiFailure catch (failure) {
      if (failure.unauthorized) {
        if (mounted) widget.onUnauthorized();
        return null;
      }
      if (mounted) setState(() => error = failure.message);
      return null;
    } catch (_) {
      if (mounted) setState(() => error = '操作失败，请检查文件或稍后重试。');
      return null;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Profile get displayedProfile {
    final profile = data?.profile ?? const Profile('航的助手', null, null);
    return Profile(
      draftName ?? profile.name,
      profileChanges.containsKey('avatar_data_url')
          ? profileChanges['avatar_data_url'] as String?
          : profile.avatar,
      profileChanges.containsKey('home_wallpaper_data_url')
          ? profileChanges['home_wallpaper_data_url'] as String?
          : profile.wallpaper,
      timetableBackground:
          profileChanges.containsKey('timetable_background_data_url')
          ? profileChanges['timetable_background_data_url'] as String?
          : profile.timetableBackground,
      analysisWallpaper:
          profileChanges.containsKey('analysis_wallpaper_data_url')
          ? profileChanges['analysis_wallpaper_data_url'] as String?
          : profile.analysisWallpaper,
      settingsWallpaper:
          profileChanges.containsKey('settings_wallpaper_data_url')
          ? profileChanges['settings_wallpaper_data_url'] as String?
          : profile.settingsWallpaper,
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final heading = switch (section) {
      'account' => '账号安全',
      'time' => '时间设置',
      'personal' => '个性化设置',
      'data' => '数据与导入',
      'analysis' => '成绩分析设置',
      'about' => '关于助手',
      _ => '设置',
    };
    // Build the content when Settings state changes, not on every animation
    // tick. The transition only updates its geometry and opacity.
    final rootContent = SafeArea(bottom: false, child: _settingsList(dark));
    final detailHeader = section == null ? null : _detailHeader(heading);
    final detailBody = section == null ? null : _detailBody(dark);
    final sourceContent = section == null ? null : _sourceTile(section!);
    return PopScope(
      canPop: section == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && section != null) requestBack(fromSystemBack: true);
      },
      child: Stack(
        key: _contentStackKey,
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: dark ? Colors.black : const Color(0xfff4f7fb),
            ),
          ),
          AnimatedBuilder(
            animation: _sectionAnimation,
            builder: (context, _) => _buildSectionTransition(
              dark,
              rootContent,
              detailHeader,
              detailBody,
              sourceContent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTransition(
    bool dark,
    Widget rootContent,
    Widget? detailHeader,
    Widget? detailBody,
    Widget? sourceContent,
  ) {
    final progress = _sectionAnimation.value;
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            ignoring: section != null,
            child: ExcludeFocus(
              excluding: section != null,
              child: ExcludeSemantics(
                excluding: section != null,
                child: rootContent,
              ),
            ),
          ),
        ),
        if (section != null)
          _buildExpandingDetail(
            dark,
            progress,
            detailHeader!,
            detailBody!,
            sourceContent!,
          ),
      ],
    );
  }

  Widget _buildExpandingDetail(
    bool dark,
    double progress,
    Widget detailHeader,
    Widget detailBody,
    Widget sourceContent,
  ) {
    final size = MediaQuery.sizeOf(context);
    final end = Offset.zero & size;
    final start = _entryRect ?? end;
    final closing =
        closingSection && _sectionAnimation.status == AnimationStatus.reverse;
    final pageColor = dark ? Colors.black : const Color(0xfff4f7fb);
    final groupColor = dark ? const Color(0xe5222630) : const Color(0xf5ffffff);
    final closedColor = Color.alphaBlend(groupColor, pageColor);
    return ContainerMorphTransition(
      progress: progress,
      isClosing: closing,
      detailInteractive: progress >= 1 && !closingSection,
      startRect: start,
      endSize: size,
      startBorderRadius: _entryBorderRadius(section!),
      closedColor: closedColor,
      openColor: pageColor,
      sourceContent: sourceContent,
      detailHeader: detailHeader,
      detailBody: detailBody,
      surfaceKey: const Key('settings-transform-surface'),
      sourceLayerKey: const Key('settings-source-layer'),
      detailHeaderLayerKey: const Key('settings-detail-header-layer'),
      detailBodyLayerKey: const Key('settings-detail-body-layer'),
    );
  }

  BorderRadius _entryBorderRadius(String value) {
    const rounded = Radius.circular(18);
    return switch (value) {
      'account' => BorderRadius.circular(18),
      'time' ||
      'data' => const BorderRadius.only(topLeft: rounded, topRight: rounded),
      'personal' || 'about' => const BorderRadius.only(
        bottomLeft: rounded,
        bottomRight: rounded,
      ),
      _ => BorderRadius.zero,
    };
  }

  Widget _sourceTile(String value) => switch (value) {
    'account' => _row('账号安全', '密码、通行密钥与退出', Icons.key_outlined),
    'time' => _row('时间设置', '学期第一周与节次时间', Icons.schedule_outlined),
    'personal' => _row('个性化设置', '姓名、头像与独立壁纸', Icons.palette_outlined),
    'data' => _row('数据与导入', '课表和成绩文件', Icons.upload_file_outlined),
    'analysis' => _row('成绩分析设置', '第三方模型服务与 API Key', Icons.school_outlined),
    _ => _row('关于助手', '版本、数据保护与使用说明', Icons.info_outline),
  };

  Widget _settingsList(bool dark) => ListView(
    key: const Key('settings-content-root'),
    padding: EdgeInsets.fromLTRB(
      18,
      19,
      18,
      NativeTabMetrics.contentBottomPadding(context, android: 120),
    ),
    children: [
      const Row(
        children: [
          Icon(Icons.settings_outlined, size: 25),
          SizedBox(width: 11),
          Expanded(
            child: Text(
              '设置',
              style: TextStyle(fontSize: 27, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      const SizedBox(height: 18),
      if (loading)
        const Center(child: CircularProgressIndicator())
      else
        _root(dark),
    ],
  );

  Widget _detailHeader(String heading) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 19, 18, 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('settings-detail-back'),
            onPressed: () => requestBack(),
            icon: const Icon(Icons.chevron_left),
            label: const Text('设置'),
          ),
        ),
        Text(
          heading,
          style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );

  Widget _detailBody(bool dark) => ListView(
    key: ValueKey('settings-content-$section'),
    padding: EdgeInsets.fromLTRB(
      18,
      0,
      18,
      24 + MediaQuery.viewPaddingOf(context).bottom,
    ),
    children: [
      if (loading)
        const Center(child: CircularProgressIndicator())
      else ...[
        if (section == 'account') _account(dark),
        if (section == 'time') _time(dark),
        if (section == 'personal') _personal(dark),
        if (section == 'data') _imports(dark),
        if (section == 'analysis') _analysis(dark),
        if (section == 'about') _about(dark),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(error!, style: const TextStyle(color: Colors.red)),
          ),
        if (notice != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              notice!,
              style: const TextStyle(color: Color(0xff2563eb)),
            ),
          ),
      ],
    ],
  );

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 17, 0, 8),
    child: Text(
      title,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: Color(0xff64748b),
      ),
    ),
  );

  Widget _group(List<Widget> children, bool dark) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: dark ? const Color(0xe5222630) : const Color(0xf5ffffff),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: dark ? Colors.white12 : const Color(0xffe5eaf0),
      ),
      boxShadow: const [BoxShadow(color: Color(0x100f172a), blurRadius: 9)],
    ),
    child: Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                indent: 16,
                color: dark ? Colors.white12 : const Color(0xffe8ecf1),
              ),
            children[i],
          ],
        ],
      ),
    ),
  );

  Widget _row(
    String title,
    String subtitle,
    IconData icon, {
    VoidCallback? onTap,
    String? trailing,
    Color? color,
  }) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 6),
    leading: Icon(icon, color: color ?? const Color(0xff2563eb), size: 21),
    title: Text(
      title,
      style: TextStyle(fontWeight: FontWeight.w700, color: color),
    ),
    subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
    trailing: trailing == null
        ? const Icon(Icons.chevron_right, size: 19)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 125),
                child: Text(
                  trailing,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff64748b),
                  ),
                ),
              ),
              const Icon(Icons.chevron_right, size: 19),
            ],
          ),
    onTap: onTap,
  );

  Widget _root(bool dark) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _sectionTitle('账户'),
      _group([
        _entryRow('account', '账号安全', '密码、通行密钥与退出', Icons.key_outlined),
      ], dark),
      _sectionTitle('偏好设置'),
      _group([
        _entryRow('time', '时间设置', '学期第一周与节次时间', Icons.schedule_outlined),
        _entryRow('personal', '个性化设置', '姓名、头像与独立壁纸', Icons.palette_outlined),
      ], dark),
      _sectionTitle('数据与助手'),
      _group([
        _entryRow('data', '数据与导入', '课表和成绩文件', Icons.upload_file_outlined),
        _entryRow(
          'analysis',
          '成绩分析设置',
          '第三方模型服务与 API Key',
          Icons.school_outlined,
        ),
        _entryRow('about', '关于助手', '版本、数据保护与使用说明', Icons.info_outline),
      ], dark),
      if (data == null)
        Padding(
          padding: const EdgeInsets.only(top: 18),
          child: Row(
            children: [
              const Expanded(child: Text('设置资料尚未缓存，请联网后重试。')),
              TextButton(onPressed: refresh, child: const Text('重试')),
            ],
          ),
        ),
    ],
  );

  Widget _entryRow(
    String value,
    String title,
    String subtitle,
    IconData icon,
  ) => KeyedSubtree(
    key: _entryKeys[value],
    child: Opacity(
      // The animated surface owns the tapped tile while it expands.
      opacity: section == value ? 0 : 1,
      child: _row(title, subtitle, icon, onTap: () => open(value)),
    ),
  );

  Widget _account(bool dark) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _sectionTitle('单用户认证'),
      _group([
        const ListTile(
          title: Text('服务器环境认证', style: TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text('账号凭据由服务器环境配置管理；这里不会展示或保存密码。'),
        ),
      ], dark),
      _sectionTitle('通行密钥'),
      _group([
        _row(
          '通行密钥管理',
          '查看、添加或移除用于登录的通行密钥',
          Icons.key_outlined,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => PasskeyManagementPage(
                api: widget.api,
                onUnauthorized: widget.onUnauthorized,
              ),
            ),
          ),
        ),
      ], dark),
      _sectionTitle('账户操作'),
      _group([
        _row(
          '退出航的助手',
          '返回登录页；不会清除后端数据',
          Icons.logout,
          color: const Color(0xffdc2626),
          onTap: confirmLogout,
        ),
      ], dark),
    ],
  );

  Future<void> confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认退出航的助手？'),
        content: const Text('退出后返回登录页。已导入的课程表、成绩和自定义安排不会从后端删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认退出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.logout();
    } on ApiFailure catch (_) {
      /* Local sign-out still completes if the server is unavailable. */
    }
    if (mounted) widget.onSignedOut();
  }

  TermInfo? get chosenTerm {
    final terms = data?.terms ?? [];
    if (terms.isEmpty) return null;
    for (final term in terms) {
      if (term.id == selectedTermId) return term;
    }
    for (final term in terms) {
      if (term.isCurrent) return term;
    }
    return terms.first;
  }

  PeriodInfo? get chosenPeriod {
    final periods = data?.periods ?? [];
    if (periods.isEmpty) return null;
    for (final period in periods) {
      if (period.number == selectedPeriodNumber) return period;
    }
    return periods.first;
  }

  Future<T?> _choose<T>(
    String title,
    List<T> values,
    String Function(T) label,
  ) => showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .7,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            for (final value in values)
              ListTile(
                title: Text(label(value)),
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _time(bool dark) {
    final term = chosenTerm;
    final period = chosenPeriod;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('学期第一周'),
        _group(
          term == null
              ? [
                  const ListTile(
                    title: Text('尚无学期数据'),
                    subtitle: Text('请先导入打印课表文件。'),
                  ),
                ]
              : [
                  _row(
                    '学期',
                    '选择要配置的学期',
                    Icons.calendar_month_outlined,
                    trailing: term.name,
                    onTap: () async {
                      final picked = await _choose(
                        '选择学期',
                        data!.terms,
                        (TermInfo value) => value.name,
                      );
                      if (picked != null && mounted)
                        setState(() => selectedTermId = picked.id);
                    },
                  ),
                  _row(
                    '第一周周一',
                    '保存后重新生成课程日程',
                    Icons.event_outlined,
                    trailing: term.startDate ?? '选择日期',
                    onTap: () => pickStartDate(term),
                  ),
                ],
          dark,
        ),
        _sectionTitle('节次时间'),
        _group(
          period == null
              ? [const ListTile(title: Text('节次时间尚未缓存'))]
              : [
                  _row(
                    '节次',
                    '选择要配置的节次',
                    Icons.numbers_outlined,
                    trailing: '第 ${period.number} 节',
                    onTap: () async {
                      final picked = await _choose(
                        '选择节次',
                        data!.periods,
                        (PeriodInfo value) =>
                            '第 ${value.number} 节 · ${value.start}—${value.end}',
                      );
                      if (picked != null && mounted)
                        setState(() => selectedPeriodNumber = picked.number);
                    },
                  ),
                  _row(
                    '上课时间',
                    '第 ${period.number} 节',
                    Icons.access_time_outlined,
                    trailing: period.start,
                    onTap: () => pickPeriodTime(period, true),
                  ),
                  _row(
                    '下课时间',
                    '第 ${period.number} 节',
                    Icons.access_time_filled_outlined,
                    trailing: period.end,
                    onTap: () => pickPeriodTime(period, false),
                  ),
                ],
          dark,
        ),
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text(
            '调整学期起始日或节次时间会重新生成对应课程日程。',
            style: TextStyle(fontSize: 12, color: Color(0xff64748b)),
          ),
        ),
      ],
    );
  }

  Future<void> pickStartDate(TermInfo term) async {
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        (_activeDateRequestId != null || _activeTimeRequestId != null)) {
      return;
    }
    final initial = DateTime.tryParse(term.startDate ?? '') ?? DateTime.now();
    DateTime? picked;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final requestId = NativeTermStartDatePicker.nextRequestId();
      final generation = ++_dateRequestGeneration;
      _activeDateRequestId = requestId;
      FocusManager.instance.primaryFocus?.unfocus();
      try {
        picked = await _nativeDatePicker.pickDate(
          initialDate: initial,
          requestId: requestId,
        );
      } on PlatformException {
        if (mounted &&
            section == 'time' &&
            generation == _dateRequestGeneration) {
          message('系统日期选择器暂不可用，请重试。');
        }
        return;
      } on MissingPluginException {
        if (mounted &&
            section == 'time' &&
            generation == _dateRequestGeneration) {
          message('系统日期选择器暂不可用，请重试。');
        }
        return;
      } on FormatException {
        if (mounted &&
            section == 'time' &&
            generation == _dateRequestGeneration) {
          message('系统日期选择结果无效，请重试。');
        }
        return;
      } finally {
        if (_activeDateRequestId == requestId) _activeDateRequestId = null;
      }
      if (!mounted ||
          generation != _dateRequestGeneration ||
          section != 'time' ||
          chosenTerm?.id != term.id) {
        return;
      }
    } else {
      picked = await showDatePicker(
        context: context,
        initialDate: initial,
        firstDate: DateTime(2010),
        lastDate: DateTime(2100),
      );
    }
    if (picked == null || !mounted) return;
    if (picked.weekday != DateTime.monday) {
      message('请选择星期一作为第一周的开始日期。');
      return;
    }
    final date =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    if (date == term.startDate) return;
    await action(
      () => widget.api.updateTermStart(term.id, date),
      success: '学期第一周已保存。',
    );
    if (notice != null) await refresh();
  }

  Future<void> pickPeriodTime(PeriodInfo period, bool start) async {
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        (_activeTimeRequestId != null || _activeDateRequestId != null)) {
      return;
    }
    final value = start ? period.start : period.end;
    final parts = value.split(':');
    final initialTime = TimeOfDay(
      hour: int.parse(parts[0]),
      minute: int.parse(parts[1]),
    );
    TimeOfDay? picked;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final requestId = NativePeriodTimePicker.nextRequestId();
      final generation = ++_timeRequestGeneration;
      _activeTimeRequestId = requestId;
      FocusManager.instance.primaryFocus?.unfocus();
      try {
        picked = await _nativeTimePicker.pickTime(
          initialTime: initialTime,
          title: start ? '上课时间' : '下课时间',
          requestId: requestId,
        );
      } on PlatformException {
        if (mounted &&
            section == 'time' &&
            generation == _timeRequestGeneration) {
          message('系统时间选择器暂不可用，请重试。');
        }
        return;
      } on MissingPluginException {
        if (mounted &&
            section == 'time' &&
            generation == _timeRequestGeneration) {
          message('系统时间选择器暂不可用，请重试。');
        }
        return;
      } on FormatException {
        if (mounted &&
            section == 'time' &&
            generation == _timeRequestGeneration) {
          message('系统时间选择结果无效，请重试。');
        }
        return;
      } finally {
        if (_activeTimeRequestId == requestId) _activeTimeRequestId = null;
      }
      if (!mounted ||
          generation != _timeRequestGeneration ||
          section != 'time' ||
          chosenPeriod?.number != period.number) {
        return;
      }
    } else {
      picked = await showTimePicker(
        context: context,
        initialTime: initialTime,
        initialEntryMode: TimePickerEntryMode.dialOnly,
      );
    }
    if (picked == null || !mounted) return;
    final formatted =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    final newStart = start ? formatted : period.start;
    final newEnd = start ? period.end : formatted;
    if (newStart == period.start && newEnd == period.end) return;
    if (newStart.compareTo(newEnd) >= 0) {
      message('下课时间必须晚于上课时间。');
      return;
    }
    await action(
      () => widget.api.updatePeriod(period.number, newStart, newEnd),
      success: '第 ${period.number} 节时间已保存。',
    );
    if (notice != null) await refresh();
  }

  Widget _personal(bool dark) {
    final profile = displayedProfile;
    final count = [
      profile.wallpaper,
      profile.timetableBackground,
      profile.analysisWallpaper,
    ].where((value) => value != null).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '姓名、头像与壁纸仅保存在此设备，可离线修改；网页版不会同步这些更改。',
          style: TextStyle(fontSize: 13, color: Color(0xff64748b)),
        ),
        _sectionTitle('个人资料'),
        _group([
          _row(
            '头像',
            '显示在首页和底部导航栏',
            Icons.account_circle_outlined,
            trailing: profile.avatar == null ? '未设置' : '已设置',
            onTap: () => editImage('avatar_data_url', profile.avatar),
          ),
          _row(
            '显示姓名',
            '首页和头像占位图',
            Icons.person_outline,
            trailing: profile.name,
            onTap: editName,
          ),
          _row(
            '页面壁纸',
            '首页、课表、分析；设置页暂不显示壁纸',
            Icons.wallpaper_outlined,
            trailing: '已设置 $count/3',
            onTap: editWallpaper,
          ),
        ], dark),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: !hasUnsavedProfile || busy ? null : saveProfile,
          child: Text(busy ? '正在保存…' : '保存更改'),
        ),
        _sectionTitle('外观模式'),
        _group([
          Padding(
            padding: const EdgeInsets.all(12),
            child: AppearanceModeSelector(
              selected: widget.themeMode,
              onSelected: widget.onThemeModeChanged,
            ),
          ),
        ], dark),
      ],
    );
  }

  Future<void> editName() async {
    var edited = displayedProfile.name;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('显示姓名'),
        content: TextFormField(
          initialValue: edited,
          onChanged: (value) => edited = value,
          maxLength: 64,
          autofocus: true,
          decoration: const InputDecoration(labelText: '姓名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, edited.trim()),
            child: const Text('完成编辑'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty && mounted)
      setState(() => draftName = result);
  }

  Future<void> editWallpaper() async {
    const choices = <(String, String)>[
      ('home_wallpaper_data_url', '首页壁纸'),
      ('timetable_background_data_url', '课表背景'),
      ('analysis_wallpaper_data_url', '分析页壁纸'),
      ('settings_wallpaper_data_url', '设置页壁纸（暂不显示）'),
    ];
    final picked = await _choose(
      '页面壁纸',
      choices,
      ((String, String) item) => item.$2,
    );
    if (picked == null || !mounted) return;
    if (picked.$1 == 'settings_wallpaper_data_url') {
      message('设置页壁纸暂不显示；原图片仍保存在本设备。');
      return;
    }
    final profile = displayedProfile;
    final current = switch (picked.$1) {
      'home_wallpaper_data_url' => profile.wallpaper,
      'timetable_background_data_url' => profile.timetableBackground,
      'analysis_wallpaper_data_url' => profile.analysisWallpaper,
      _ => profile.settingsWallpaper,
    };
    await editImage(picked.$1, current);
  }

  Future<void> editImage(String key, String? current) async {
    final title = key == 'avatar_data_url'
        ? '头像'
        : switch (key) {
            'home_wallpaper_data_url' => '首页壁纸',
            'timetable_background_data_url' => '课表背景',
            'analysis_wallpaper_data_url' => '分析页壁纸',
            _ => '设置页壁纸',
          };
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择并自定义裁剪'),
              onTap: () => Navigator.pop(context, 'choose'),
            ),
            if (current != null)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('移除图片'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (choice == 'remove' && mounted) {
      setState(() => profileChanges[key] = null);
      return;
    }
    if (choice != 'choose' || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(pendingLocalPhotoKey, key);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: false,
      );
      if (file != null && mounted) await cropPickedImage(key, file);
    } catch (_) {
      if (mounted) message('图片选择失败，请重试。');
    } finally {
      await prefs.remove(pendingLocalPhotoKey);
    }
  }

  Future<void> cropPickedImage(String key, XFile file) async {
    final title = key == 'avatar_data_url'
        ? '头像'
        : switch (key) {
            'home_wallpaper_data_url' => '首页壁纸',
            'timetable_background_data_url' => '课表背景',
            'analysis_wallpaper_data_url' => '分析页壁纸',
            _ => '设置页壁纸',
          };
    final limit = key == 'avatar_data_url' ? 15_000_000 : 5_000_000;
    if (await file.length() > limit) {
      if (mounted) message('原图不能超过 ${limit ~/ 1000000} MB。');
      return;
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > limit) {
      if (mounted) message('原图不能超过 ${limit ~/ 1000000} MB。');
      return;
    }
    final cropSource = await compute(_prepareCropSource, bytes);
    if (!mounted) return;
    if (cropSource == null) {
      message('请选择不超过 2500 万像素、可解析的 JPEG、PNG 或 WebP 图片。');
      return;
    }
    final processed = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => _ImageCropPage(
          image: cropSource,
          title: title,
          avatar: key == 'avatar_data_url',
        ),
      ),
    );
    if (!mounted || processed == null) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$title预览'),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .5,
          ),
          child: Image.memory(processed, fit: BoxFit.contain),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('使用图片'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      setState(
        () => profileChanges[key] =
            'data:image/jpeg;base64,${base64Encode(processed)}',
      );
    }
  }

  Future<bool> saveProfile() async {
    if (busy) return false;
    final body = <String, dynamic>{
      'display_name': draftName ?? data?.profile.name ?? '航的助手',
      ...profileChanges,
    };
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      final updated = await widget.api.saveLocalProfile(
        body,
        fallback: data?.profile ?? const Profile('航的助手', null, null),
      );
      if (!mounted) return false;
      setState(() {
        data = SettingsData(
          updated,
          data?.terms ?? const [],
          data?.periods ?? const [],
          DateTime.now(),
        );
        profileChanges.clear();
        draftName = null;
        notice = '已保存到此设备。';
      });
      widget.onProfileChanged?.call(updated);
      return true;
    } on ApiFailure catch (failure) {
      if (mounted) setState(() => error = failure.message);
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _imports(bool dark) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        '课程表和成绩只通过你主动选择的导出文件导入。',
        style: TextStyle(fontSize: 13, color: Color(0xff64748b)),
      ),
      _sectionTitle('本地文件导入'),
      _group([
        _row(
          '课程表',
          '导入打印的 .xls 课表',
          Icons.calendar_month_outlined,
          onTap: importTimetable,
        ),
        _row(
          '成绩分析',
          '导入 .xls 或 HTML 成绩文件',
          Icons.school_outlined,
          onTap: importGrades,
        ),
        const ListTile(title: Text('原始文件'), subtitle: Text('仅用于本次解析，不会保存')),
      ], dark),
      const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text(
          '课程表支持教务系统导出的 .xls 打印课表；成绩支持 .xls 或 HTML 文件。',
          style: TextStyle(fontSize: 12, color: Color(0xff64748b)),
        ),
      ),
    ],
  );

  Future<(String, Uint8List)?> pickDocument(List<String> extensions) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    if (file == null) return null;
    final length = file.lengthSync() ?? await file.length();
    if (length != null && length > 2_000_000) {
      message('文件不能超过 2 MB。');
      return null;
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > 2_000_000) {
      message('文件不能超过 2 MB。');
      return null;
    }
    return (file.name, bytes);
  }

  Future<void> importTimetable() async {
    if (!online) {
      message('当前无法同步，暂不能导入文件。');
      return;
    }
    try {
      final file = await pickDocument(['xls']);
      if (file == null) return;
      final result = await action(
        () => widget.api.importTimetable(file.$1, file.$2),
      );
      if (result == null || !mounted) return;
      setState(
        () => notice =
            '已导入 ${result['courses_imported']} 门课程，并生成 ${result['sessions_generated']} 条安排。',
      );
      await refresh();
    } catch (_) {
      if (mounted) setState(() => error = '文件选择失败，请重试。');
    }
  }

  Future<void> importGrades() async {
    if (!online) {
      message('当前无法同步，暂不能导入文件。');
      return;
    }
    final termController = TextEditingController();
    final specify = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入文件学期'),
        content: TextField(
          controller: termController,
          maxLength: 11,
          decoration: const InputDecoration(hintText: '留空则自动识别，例如 2025-2026-2'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('选择文件'),
          ),
        ],
      ),
    );
    final term = termController.text.trim();
    termController.dispose();
    if (specify != true || !mounted) return;
    if (term.isNotEmpty && !RegExp(r'^20\d{2}-20\d{2}-[12]$').hasMatch(term)) {
      message('学期格式应为 2025-2026-2。');
      return;
    }
    try {
      final file = await pickDocument(['xls', 'html', 'htm']);
      if (file == null) return;
      final preview = await action(
        () => widget.api.previewGrades(
          file.$1,
          file.$2,
          termId: term.isEmpty ? null : term,
        ),
      );
      if (preview == null || !mounted) return;
      await showGradePreview(preview);
    } catch (_) {
      if (mounted) setState(() => error = '文件选择失败，请重试。');
    }
  }

  Future<void> showGradePreview(Map<String, dynamic> preview) async {
    final grades = (preview['grades'] as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
    await showModalBottomSheet<void>(
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
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '成绩导入预览',
                        style: TextStyle(
                          fontSize: 21,
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Text(
                  '识别到 ${grades.length} 门成绩，归入 ${preview['source_term_id']}。确认后将替换该学期现有成绩。',
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (var i = 0; i < grades.length; i++)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              TextFormField(
                                initialValue:
                                    grades[i]['course_name']?.toString() ?? '',
                                decoration: const InputDecoration(
                                  labelText: '课程名称',
                                ),
                                onChanged: (value) =>
                                    grades[i]['course_name'] = value,
                              ),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextFormField(
                                      initialValue: grades[i]['score']
                                          ?.toString(),
                                      decoration: const InputDecoration(
                                        labelText: '成绩',
                                      ),
                                      onChanged: (value) => grades[i]['score'] =
                                          value.isEmpty ? null : value,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextFormField(
                                      initialValue: grades[i]['credits']
                                          ?.toString(),
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(
                                        labelText: '学分',
                                      ),
                                      onChanged: (value) =>
                                          grades[i]['credits'] = num.tryParse(
                                            value,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextFormField(
                                      initialValue: grades[i]['grade_point']
                                          ?.toString(),
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(
                                        labelText: '绩点',
                                      ),
                                      onChanged: (value) =>
                                          grades[i]['grade_point'] =
                                              num.tryParse(value),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () async {
                      if (grades.any(
                        (row) =>
                            row['course_name']?.toString().trim().isEmpty !=
                            false,
                      )) {
                        message('课程名称不能为空。');
                        return;
                      }
                      final result = await action(
                        () => widget.api.confirmGrades({
                          ...preview,
                          'grades': grades,
                        }),
                      );
                      if (result == null || !mounted || !sheetContext.mounted)
                        return;
                      Navigator.pop(sheetContext);
                      setState(
                        () => notice =
                            '已导入 ${result['grades_imported']} 门 ${result['source_term_id']} 的成绩。',
                      );
                      await refresh();
                    },
                    child: const Text('确认导入成绩'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _analysis(bool dark) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _sectionTitle('模型服务'),
      _group([
        _row(
          '服务预设',
          'OpenAI 兼容服务',
          Icons.cloud_outlined,
          trailing: provider == 'APIKEY.FAN' ? 'APIKEY.FAN' : '自定义',
          onTap: () async {
            final picked = await _choose('服务预设', [
              'APIKEY.FAN',
              '自定义服务',
            ], (String item) => item);
            if (picked == 'APIKEY.FAN' && mounted) {
              setState(() {
                provider = 'APIKEY.FAN';
                baseUrl = 'https://api.apikey.fan/v1';
                models = [];
              });
            }
          },
        ),
        _row(
          '服务名称',
          '由服务提供方标识',
          Icons.badge_outlined,
          trailing: provider,
          onTap: () =>
              editAiText('服务名称', provider, (value) => provider = value),
        ),
        _row(
          '服务地址',
          '使用 HTTPS 地址',
          Icons.link_outlined,
          trailing: baseUrl.replaceFirst(RegExp(r'^https?://'), ''),
          onTap: () => editAiText('服务地址', baseUrl, (value) => baseUrl = value),
        ),
        _row(
          'API Key',
          '仅提交后端加密保存',
          Icons.key_outlined,
          trailing: apiKey.isNotEmpty ? '待保存' : ai?.keyHint ?? '未配置',
          onTap: () => editAiText(
            'API Key',
            '',
            (value) => apiKey = value,
            secret: true,
          ),
        ),
      ], dark),
      _sectionTitle('模型'),
      _group([
        _row(
          '当前模型',
          '用于成绩分析',
          Icons.auto_awesome_outlined,
          trailing: model.isEmpty ? '请选择' : model,
          onTap: chooseAiModel,
        ),
        _row('获取模型列表', '读取服务支持的模型', Icons.sync, onTap: fetchModels),
        _row('测试当前配置', '验证服务是否可用', Icons.check_circle_outline, onTap: testAi),
      ], dark),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: busy ? null : saveAi,
        child: Text(busy ? '处理中…' : '保存配置'),
      ),
      if (ai?.configured == true) ...[
        _sectionTitle('危险操作'),
        _group([
          _row(
            '清除模型服务配置',
            '不影响成绩和分析历史',
            Icons.delete_outline,
            color: const Color(0xffdc2626),
            onTap: clearAi,
          ),
          _row(
            '清除历史分析',
            '不会影响成绩或模型配置',
            Icons.history,
            color: const Color(0xffdc2626),
            onTap: clearHistory,
          ),
        ], dark),
      ],
      const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text(
          'API Key 只会在你保存或测试配置时提交给后端，不保存在客户端。',
          style: TextStyle(fontSize: 12, color: Color(0xff64748b)),
        ),
      ),
    ],
  );

  Future<void> editAiText(
    String title,
    String initial,
    ValueChanged<String> update, {
    bool secret = false,
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: secret,
          autofocus: true,
          decoration: InputDecoration(labelText: title),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('完成编辑'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null && value.isNotEmpty && mounted)
      setState(() {
        update(value);
        models = [];
      });
  }

  Future<void> chooseAiModel() async {
    if (models.isEmpty) {
      message('请先获取模型列表。');
      return;
    }
    final picked = await _choose('选择模型', models, (String value) => value);
    if (picked == null || !mounted) return;
    if (ai?.configured == true &&
        apiKey.isEmpty &&
        provider == ai?.provider &&
        baseUrl == ai?.baseUrl) {
      final result = await action(
        () => widget.api.selectAiModel(picked),
        success: '模型已切换。',
      );
      if (result == null || !mounted) return;
      setState(() {
        ai = result;
        model = result.model ?? picked;
      });
    } else {
      setState(() => model = picked);
    }
  }

  Future<void> fetchModels() async {
    if (ai?.configured == true &&
        apiKey.isEmpty &&
        provider == ai?.provider &&
        baseUrl == ai?.baseUrl) {
      final result = await action(widget.api.refreshAiModels);
      if (result != null && mounted) {
        setState(() {
          ai = result;
          models = result.models;
          model = result.model ?? '';
          notice = '已读取 ${models.length} 个可用模型。';
        });
      }
    } else {
      if (apiKey.length < 8) {
        message('请先填写至少 8 位 API Key。');
        return;
      }
      final result = await action(
        () => widget.api.lookupAiModels(provider, baseUrl, apiKey),
      );
      if (result != null && mounted) {
        setState(() {
          models = result;
          if (!models.contains(model)) model = models.firstOrNull ?? '';
          notice = '已读取 ${models.length} 个可用模型。';
        });
      }
    }
  }

  Future<void> testAi() async {
    if (apiKey.length < 8 || model.isEmpty) {
      message('请填写 API Key 并选择模型。');
      return;
    }
    final result = await action(
      () => widget.api.testAiSettings(provider, baseUrl, model, apiKey),
    );
    if (result != null && mounted) setState(() => notice = result);
  }

  Future<void> saveAi() async {
    if (apiKey.length < 8 || model.isEmpty || !baseUrl.startsWith('https://')) {
      message('请填写 HTTPS 服务地址、至少 8 位 API Key，并选择模型。');
      return;
    }
    final result = await action(
      () => widget.api.saveAiSettings(provider, baseUrl, model, apiKey),
      success: '模型配置已保存。',
    );
    if (result != null && mounted)
      setState(() {
        ai = result;
        apiKey = '';
        models = result.models;
      });
  }

  Future<bool> confirmDanger(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认清除', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> clearAi() async {
    if (!await confirmDanger(
      '清除模型服务配置？',
      '地址、模型和 API Key 会被移除，无法恢复；成绩与分析历史不受影响。',
    ))
      return;
    await action(widget.api.clearAiSettings, success: '模型服务配置已清除。');
    if (notice != null) await loadAi();
  }

  Future<void> clearHistory() async {
    if (!await confirmDanger('清除全部 AI 分析历史？', '已保存的分析文字会被删除；课程、成绩和模型配置不受影响。'))
      return;
    await action(widget.api.clearAiHistory, success: '历史分析已清除。');
  }

  Widget _about(bool dark) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        key: const Key('about-brand-hero'),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 21),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: dark
                ? [const Color(0xff171719), const Color(0xff171719)]
                : [const Color(0xffeff6ff), const Color(0xffeef2ff)],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: dark ? Colors.white12 : Colors.white),
          boxShadow: [
            BoxShadow(
              color: dark ? const Color(0x38000000) : const Color(0x172563eb),
              blurRadius: 16,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white.withValues(alpha: .85)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x3b2563eb),
                    blurRadius: 14,
                    offset: Offset(0, 7),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(17),
                child: Image.asset(
                  'assets/icon/login_icon.png',
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Hand Helper',
                    style: TextStyle(
                      fontSize: 12,
                      color: dark
                          ? const Color(0xffaebed3)
                          : const Color(0xff52647c),
                    ),
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    '航的助手',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 3),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: dark ? Colors.white10 : const Color(0xa1ffffff),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      child: Text(
                        appVersion ?? '读取版本中…',
                        key: const Key('about-version'),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: dark
                              ? const Color(0xffbfdbfe)
                              : const Color(0xff416080),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      _group([
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 15, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '应用说明',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 7),
              Text(
                '为个人使用场景设计的课程表与成绩分析助手。课程和成绩通过你主动导入的文件获取。',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.55,
                  color: dark
                      ? const Color(0xffa1a1a6)
                      : const Color(0xff64748b),
                ),
              ),
            ],
          ),
        ),
        const ListTile(
          leading: Icon(Icons.person_outline, size: 20),
          title: Text('使用范围'),
          subtitle: Text('仅供本人使用'),
        ),
        const ListTile(
          leading: Icon(Icons.storage_outlined, size: 20),
          title: Text('数据方式'),
          subtitle: Text('主动导入文件，由现有后端解析并保存'),
        ),
      ], dark),
      _sectionTitle('帮助中心'),
      _group(const [
        ExpansionTile(
          title: Text('导入打印课表'),
          children: [
            Padding(
              padding: EdgeInsets.all(16),
              child: Text('在教务系统保存 .xls 打印课表，进入“数据与导入”选择文件；首次导入后设置学期第一周周一。'),
            ),
          ],
        ),
        ExpansionTile(
          title: Text('导入成绩分析'),
          children: [
            Padding(
              padding: EdgeInsets.all(16),
              child: Text('选择 .xls 或 HTML 成绩文件，检查预览并确认导入。'),
            ),
          ],
        ),
        ExpansionTile(
          title: Text('使用 AI 成绩分析'),
          children: [
            Padding(
              padding: EdgeInsets.all(16),
              child: Text('先配置 HTTPS 模型服务、模型和 API Key，再到分析页生成建议。'),
            ),
          ],
        ),
      ], dark),
      _sectionTitle('隐私与安全'),
      _group(const [
        ListTile(
          title: Text('数据保护'),
          subtitle: Text('登录凭据不会展示；原始教务文件只用于当次解析，API Key 不写入客户端缓存。'),
        ),
      ], dark),
    ],
  );
}

Uint8List? _prepareCropSource(Uint8List bytes) {
  final source = img.decodeImage(bytes);
  if (source == null || source.width * source.height > 25_000_000) return null;
  final oriented = img.bakeOrientation(source);
  final longest = math.max(oriented.width, oriented.height);
  final preview = longest > 3200
      ? img.copyResize(
          oriented,
          width: oriented.width >= oriented.height ? 3200 : null,
          height: oriented.height > oriented.width ? 3200 : null,
        )
      : oriented;
  return Uint8List.fromList(img.encodeJpg(preview, quality: 90));
}

Uint8List? _finishCroppedImage((Uint8List, bool) input) {
  final cropped = img.decodeImage(input.$1);
  if (cropped == null) return null;
  final avatar = input.$2;
  final resized = img.copyResize(
    cropped,
    width: avatar ? 512 : 900,
    height: avatar ? 512 : 1600,
  );
  for (final quality in [86, 75, 64, 52]) {
    final encoded = img.encodeJpg(resized, quality: quality);
    if (encoded.length <= 1_000_000) return encoded;
  }
  return null;
}

class _ImageCropPage extends StatefulWidget {
  const _ImageCropPage({
    required this.image,
    required this.title,
    required this.avatar,
  });
  final Uint8List image;
  final String title;
  final bool avatar;

  @override
  State<_ImageCropPage> createState() => _ImageCropPageState();
}

class _ImageCropPageState extends State<_ImageCropPage> {
  final CropController controller = CropController();
  bool cropping = false;
  bool ready = false;

  Future<void> onCropped(CropResult result) async {
    switch (result) {
      case CropSuccess(:final croppedImage):
        final image = await compute(_finishCroppedImage, (
          croppedImage,
          widget.avatar,
        ));
        if (!mounted) return;
        if (image == null) {
          setState(() => cropping = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('图片处理失败或处理后超过 1 MB，请缩小裁剪范围后重试。')),
          );
          return;
        }
        Navigator.of(context).pop(image);
      case CropFailure():
        if (!mounted) return;
        setState(() => cropping = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('裁剪失败，请重试。')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('裁剪${widget.title}')),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: Crop(
              image: widget.image,
              controller: controller,
              aspectRatio: widget.avatar ? 1 : 9 / 16,
              interactive: true,
              fixCropRect: true,
              progressIndicator: const Center(
                child: CircularProgressIndicator(),
              ),
              onStatusChanged: (status) {
                if (mounted) setState(() => ready = status == CropStatus.ready);
              },
              onCropped: onCropped,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              children: [
                Text(
                  widget.avatar
                      ? '拖动或双指缩放，调整 1:1 头像范围'
                      : '拖动或双指缩放，调整 9:16 壁纸范围',
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: cropping || !ready
                        ? null
                        : () {
                            setState(() => cropping = true);
                            controller.crop();
                          },
                    child: cropping
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('完成裁剪'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
