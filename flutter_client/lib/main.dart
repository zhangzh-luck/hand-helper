import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'analysis_page.dart';
import 'floating_tab_bar.dart';
import 'launch_preview.dart';
import 'native_tab_bridge.dart';
import 'passkey_login.dart';
import 'settings_page.dart';
import 'today_page.dart';
import 'timetable_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (defaultTargetPlatform == TargetPlatform.android) {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
    final picker = ImagePickerPlatform.instance;
    if (picker is ImagePickerAndroid) picker.useAndroidPhotoPicker = true;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  final appearance = (await SharedPreferences.getInstance()).getString(
    'appearance_mode',
  );
  final initialThemeMode = switch (appearance) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
  runApp(App(initialThemeMode: initialThemeMode));
}

String greeting(int hour) => hour < 10
    ? '早上好'
    : hour < 14
    ? '中午好'
    : hour < 18
    ? '下午好'
    : '晚上好';

class App extends StatefulWidget {
  const App({super.key, this.initialThemeMode = ThemeMode.system});
  final ThemeMode initialThemeMode;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  late ThemeMode themeMode = widget.initialThemeMode;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) NativeTabBridge.setAppearance(themeMode.name);
    });
  }

  Future<void> changeTheme(ThemeMode value) async {
    setState(() => themeMode = value);
    NativeTabBridge.setAppearance(value.name);
    await (await SharedPreferences.getInstance()).setString(
      'appearance_mode',
      value.name,
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '航的助手',
    debugShowCheckedModeBanner: false,
    themeMode: themeMode,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff7f9fc),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff2563eb),
        surface: const Color(0xfff7f9fc),
      ),
    ),
    darkTheme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: Colors.black,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff69adff),
        brightness: Brightness.dark,
        surface: Colors.black,
      ),
    ),
    builder: (context, child) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          systemStatusBarContrastEnforced: false,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: dark
              ? Brightness.light
              : Brightness.dark,
          systemNavigationBarContrastEnforced: false,
        ),
        child: child ?? const SizedBox.shrink(),
      );
    },
    home: defaultTargetPlatform == TargetPlatform.android
        ? LaunchPreview(
            childBuilder: (onReady) => AuthGate(
              themeMode: themeMode,
              onThemeModeChanged: changeTheme,
              onInitialResolved: onReady,
            ),
          )
        : AuthGate(themeMode: themeMode, onThemeModeChanged: changeTheme),
  );
}

class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
    this.onInitialResolved,
  });
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final VoidCallback? onInitialResolved;
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final api = ApiClient();
  bool? signedIn;
  String? error;

  @override
  void initState() {
    super.initState();
    check();
  }

  Future<void> check() async {
    setState(() {
      signedIn = null;
      error = null;
    });
    final stored = await api.hasStoredSession();
    if (!mounted) return;
    if (!stored) {
      setState(() => signedIn = false);
      widget.onInitialResolved?.call();
      return;
    }
    // A stored session may show its private read-only snapshot immediately.
    // Only a real 401 revokes it; lack of connectivity does not.
    setState(() => signedIn = true);
    widget.onInitialResolved?.call();
    try {
      final valid = await api.hasSession();
      if (mounted) setState(() => signedIn = valid);
    } on ApiFailure catch (e) {
      if (e.unauthorized && mounted) setState(() => signedIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(error!),
              const SizedBox(height: 12),
              FilledButton(onPressed: check, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (signedIn == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!signedIn!) {
      return LoginPage(
        api: api,
        onSignedIn: () => setState(() => signedIn = true),
        onThemeModeChanged: widget.onThemeModeChanged,
      );
    }
    return Shell(
      api: api,
      onUnauthorized: () => setState(() => signedIn = false),
      themeMode: widget.themeMode,
      onThemeModeChanged: widget.onThemeModeChanged,
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.api,
    required this.onSignedIn,
    required this.onThemeModeChanged,
    this.passkeyAssertionProvider,
  });
  final ApiClient api;
  final VoidCallback onSignedIn;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final PasskeyAssertionProvider? passkeyAssertionProvider;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  static const _buttonAnimationDuration = Duration(milliseconds: 220);
  static const _minimumLoadingDuration = Duration(milliseconds: 280);
  final user = TextEditingController();
  final password = TextEditingController();
  final userFocus = FocusNode();
  final passwordFocus = FocusNode();
  bool pending = false;
  bool passkeyPending = false;
  bool showPassword = false;
  bool errorDialogOpen = false;
  bool get loginBusy => pending || passkeyPending;
  @override
  void dispose() {
    user.dispose();
    password.dispose();
    userFocus.dispose();
    passwordFocus.dispose();
    super.dispose();
  }

  Future<void> showLoginError(
    String message, {
    String title = '登录提示',
    bool credentialError = false,
  }) async {
    if (!mounted || errorDialogOpen) return;
    errorDialogOpen = true;
    try {
      final dialog = showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      if (credentialError) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && errorDialogOpen) HapticFeedback.mediumImpact();
        });
      }
      await dialog;
    } finally {
      errorDialogOpen = false;
    }
  }

  Future<void> finishLoading(Stopwatch elapsed) async {
    final remaining = _minimumLoadingDuration - elapsed.elapsed;
    if (remaining > Duration.zero) await Future<void>.delayed(remaining);
  }

  Future<void> submit() async {
    if (loginBusy || errorDialogOpen) return;
    FocusScope.of(context).unfocus();
    if (user.text.trim().isEmpty || password.text.isEmpty) {
      await showLoginError('请输入账号和密码');
      if (mounted) {
        (user.text.trim().isEmpty ? userFocus : passwordFocus).requestFocus();
      }
      return;
    }
    setState(() => pending = true);
    final elapsed = Stopwatch()..start();
    try {
      await widget.api.login(user.text.trim(), password.text);
      await finishLoading(elapsed);
      if (mounted) {
        TextInput.finishAutofillContext();
        widget.onSignedIn();
      }
    } on ApiFailure catch (e) {
      await finishLoading(elapsed);
      if (mounted) setState(() => pending = false);
      await Future<void>.delayed(_buttonAnimationDuration);
      await showLoginError(
        e.message,
        title: e.connection ? '连接失败' : '登录失败',
        credentialError: e.unauthorized,
      );
    } finally {
      if (mounted && pending) setState(() => pending = false);
    }
  }

  Future<void> submitPasskey() async {
    if (loginBusy || errorDialogOpen) return;
    FocusScope.of(context).unfocus();
    setState(() => passkeyPending = true);
    try {
      await widget.api.loginWithPasskey(
        widget.passkeyAssertionProvider ?? requestPasskeyAssertion,
      );
      if (mounted) widget.onSignedIn();
    } on PasskeyLoginCancelled {
      // Cancelling the system sheet is not a failed login.
    } on PasskeyLoginFailure catch (e) {
      if (mounted) setState(() => passkeyPending = false);
      await showLoginError(e.message, title: '通行密钥登录');
    } on ApiFailure catch (e) {
      if (mounted) setState(() => passkeyPending = false);
      await showLoginError(
        e.message,
        title: e.connection ? '连接失败' : '通行密钥登录失败',
        credentialError: e.unauthorized,
      );
    } catch (_) {
      if (mounted) setState(() => passkeyPending = false);
      await showLoginError('通行密钥登录未完成，请重试或使用账号密码登录。');
    } finally {
      if (mounted && passkeyPending) setState(() => passkeyPending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    const blue = Color(0xff0a84ff);
    final foreground = dark ? const Color(0xfff5f5f7) : const Color(0xff172033);
    final muted = dark ? const Color(0xffa1a1a6) : const Color(0xff6b7d96);
    final placeholder = dark
        ? const Color(0xff73737a)
        : const Color(0xff94a3b8);
    return Scaffold(
      backgroundColor: dark ? const Color(0xff080a0f) : const Color(0xfff9fbff),
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: dark
                      ? const [
                          Color(0xff080a0f),
                          Color(0xff10141b),
                          Color(0xff07080b),
                        ]
                      : const [
                          Color(0xfff9fbff),
                          Color(0xfff3f7fc),
                          Color(0xffedf3f9),
                        ],
                ),
              ),
            ),
          ),
          Positioned(
            top: -178,
            left: -150,
            child: _loginGlow(
              dark ? const Color(0x2b0a84ff) : const Color(0x380a84ff),
            ),
          ),
          Positioned(
            right: -172,
            bottom: -154,
            child: _loginGlow(
              dark ? const Color(0x215f56d2) : const Color(0x265b6fff),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxHeight < 700;
                return SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.fromLTRB(
                    22,
                    16,
                    22,
                    28 + MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                            alignment: Alignment.centerRight,
                            child: Tooltip(
                              message: dark ? '切换为浅色模式' : '切换为深色模式',
                              child: Material(
                                color: dark
                                    ? const Color(0x0dffffff)
                                    : const Color(0x7affffff),
                                shape: CircleBorder(
                                  side: BorderSide(
                                    color: dark
                                        ? const Color(0x14ffffff)
                                        : const Color(0x100f172a),
                                  ),
                                ),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: () => widget.onThemeModeChanged(
                                    dark ? ThemeMode.light : ThemeMode.dark,
                                  ),
                                  child: SizedBox(
                                    width: 40,
                                    height: 40,
                                    child: Icon(
                                      dark
                                          ? Icons.light_mode_outlined
                                          : Icons.dark_mode_outlined,
                                      size: 20,
                                      color: dark
                                          ? const Color(0xff69adff)
                                          : blue,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(height: compact ? 19 : 37),
                          Center(
                            child: Container(
                              width: compact ? 64 : 76,
                              height: compact ? 64 : 76,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(
                                  compact ? 19 : 22,
                                ),
                                border: Border.all(
                                  color: dark
                                      ? const Color(0x21ffffff)
                                      : Colors.white,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: dark
                                        ? const Color(0x59000000)
                                        : const Color(0x2b2563eb),
                                    blurRadius: 36,
                                    offset: const Offset(0, 16),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  compact ? 18 : 21,
                                ),
                                child: Image.asset(
                                  'assets/icon/login_icon.png',
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 19),
                          Center(
                            child: Text(
                              '欢迎回来',
                              style: TextStyle(
                                color: dark
                                    ? const Color(0xff69adff)
                                    : const Color(0xff3974bf),
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ),
                          const SizedBox(height: 7),
                          Center(
                            child: Text(
                              '航的助手',
                              style: TextStyle(
                                color: foreground,
                                fontSize: compact ? 27 : 30,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.9,
                              ),
                            ),
                          ),
                          SizedBox(height: compact ? 38 : 60),
                          AutofillGroup(
                            child: Container(
                              decoration: BoxDecoration(
                                color: dark
                                    ? const Color(0xdd1c1c1e)
                                    : const Color(0xc2ffffff),
                                borderRadius: BorderRadius.circular(19),
                                border: Border.all(
                                  color: dark
                                      ? const Color(0x17ffffff)
                                      : const Color(0x120f172a),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: dark
                                        ? const Color(0x47000000)
                                        : const Color(0x0f0f172a),
                                    blurRadius: 24,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: Column(
                                children: [
                                  _loginField(
                                    icon: Icons.person_outline_rounded,
                                    controller: user,
                                    hint: '账号',
                                    dark: dark,
                                    foreground: foreground,
                                    muted: muted,
                                    placeholder: placeholder,
                                    focusNode: userFocus,
                                    textInputAction: TextInputAction.next,
                                    autofillHints: const [
                                      AutofillHints.username,
                                    ],
                                    onSubmitted: (_) =>
                                        passwordFocus.requestFocus(),
                                  ),
                                  Container(
                                    height: 1,
                                    margin: const EdgeInsets.only(left: 51),
                                    color: dark
                                        ? const Color(0x14ffffff)
                                        : const Color(0x140f172a),
                                  ),
                                  _loginField(
                                    icon: Icons.lock_outline_rounded,
                                    controller: password,
                                    hint: '密码',
                                    dark: dark,
                                    foreground: foreground,
                                    muted: muted,
                                    placeholder: placeholder,
                                    focusNode: passwordFocus,
                                    textInputAction: TextInputAction.done,
                                    autofillHints: const [
                                      AutofillHints.password,
                                    ],
                                    obscureText: !showPassword,
                                    onSubmitted: (_) => submit(),
                                    trailing: IconButton(
                                      tooltip: showPassword ? '隐藏密码' : '显示密码',
                                      onPressed: () => setState(
                                        () => showPassword = !showPassword,
                                      ),
                                      icon: Icon(
                                        showPassword
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                        size: 20,
                                        color: muted,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          LayoutBuilder(
                            builder: (context, buttonConstraints) => Align(
                              alignment: Alignment.center,
                              child: AnimatedContainer(
                                key: const Key('login-submit-button-container'),
                                duration: _buttonAnimationDuration,
                                curve: Curves.easeInOutCubic,
                                width: pending
                                    ? 56
                                    : buttonConstraints.maxWidth,
                                height: 56,
                                child: FilledButton(
                                  onPressed: loginBusy ? null : submit,
                                  style: ButtonStyle(
                                    backgroundColor:
                                        const WidgetStatePropertyAll(blue),
                                    foregroundColor:
                                        const WidgetStatePropertyAll(
                                          Colors.white,
                                        ),
                                    padding: const WidgetStatePropertyAll(
                                      EdgeInsets.zero,
                                    ),
                                    minimumSize: const WidgetStatePropertyAll(
                                      Size.zero,
                                    ),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    shape: WidgetStatePropertyAll(
                                      RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(
                                          pending ? 28 : 18,
                                        ),
                                      ),
                                    ),
                                    elevation: const WidgetStatePropertyAll(5),
                                    shadowColor: const WidgetStatePropertyAll(
                                      Color(0x400a84ff),
                                    ),
                                  ),
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 140),
                                    child: pending
                                        ? const SizedBox(
                                            key: ValueKey('loading'),
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white,
                                            ),
                                          )
                                        : const Text(
                                            '登录',
                                            key: ValueKey('label'),
                                            style: TextStyle(
                                              fontSize: 17,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (defaultTargetPlatform ==
                              TargetPlatform.android) ...[
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              key: const Key('login-passkey-button'),
                              onPressed: loginBusy ? null : submitPasskey,
                              icon: const Icon(Icons.key_rounded, size: 20),
                              label: Text(
                                passkeyPending ? '正在验证…' : '使用通行密钥登录',
                              ),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(48),
                                foregroundColor: dark
                                    ? const Color(0xff69adff)
                                    : blue,
                                side: BorderSide(
                                  color: dark
                                      ? const Color(0x5969adff)
                                      : const Color(0x5c0a84ff),
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _loginGlow(Color color) => IgnorePointer(
    child: Container(
      width: 340,
      height: 340,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
      ),
    ),
  );

  Widget _loginField({
    required IconData icon,
    required TextEditingController controller,
    required String hint,
    required bool dark,
    required Color foreground,
    required Color muted,
    required Color placeholder,
    required TextInputAction textInputAction,
    required Iterable<String> autofillHints,
    required ValueChanged<String> onSubmitted,
    FocusNode? focusNode,
    Widget? trailing,
    bool obscureText = false,
  }) => SizedBox(
    height: 60,
    child: Row(
      children: [
        const SizedBox(width: 13),
        SizedBox(width: 26, child: Icon(icon, size: 21, color: muted)),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            autofillHints: autofillHints,
            textInputAction: textInputAction,
            obscureText: obscureText,
            onSubmitted: onSubmitted,
            style: TextStyle(color: foreground, fontSize: 16),
            cursorColor: dark
                ? const Color(0xff69adff)
                : const Color(0xff007aff),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: hint,
              hintStyle: TextStyle(color: placeholder),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
        ?trailing,
        const SizedBox(width: 8),
      ],
    ),
  );
}

class Shell extends StatefulWidget {
  const Shell({
    super.key,
    required this.api,
    required this.onUnauthorized,
    required this.themeMode,
    required this.onThemeModeChanged,
  });
  final ApiClient api;
  final VoidCallback onUnauthorized;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int selected = 0;
  final Set<int> visited = {0};
  final Map<int, Widget> mainPages = {};
  ValueNotifier<Profile?> localProfileChanges = ValueNotifier(null);
  final ValueNotifier<bool> todayTabActive = ValueNotifier(true);
  bool settingsDetailOpen = false;
  bool settingsDetailClosing = false;
  bool analysisDetailOpen = false;
  bool analysisDetailClosing = false;
  String? avatarSource;
  ImageProvider? avatarImage;
  double _nativeBottomOverlap = 0;
  String? _lastNativeState;
  bool _nativeSyncScheduled = false;
  int _avatarGeneration = 0;

  @override
  void initState() {
    super.initState();
    NativeTabBridge.attach(
      onSelected: (index) {
        if (settingsDetailOpen ||
            analysisDetailOpen ||
            settingsDetailClosing ||
            analysisDetailClosing) {
          return;
        }
        select(index);
      },
      onReady: () {
        _lastNativeState = null;
        if (mounted) {
          _sendNativeState();
          _syncNativeAvatar();
        }
      },
      onMetrics: (height) {
        if (!mounted ||
            (height == 0 && _nativeBottomOverlap > 0) ||
            (height - _nativeBottomOverlap).abs() < 0.5) {
          return;
        }
        setState(() => _nativeBottomOverlap = height);
      },
    );
  }

  @override
  void dispose() {
    _avatarGeneration++;
    NativeTabBridge.detach();
    localProfileChanges.dispose();
    todayTabActive.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant Shell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.api, widget.api)) {
      final previousProfileChanges = localProfileChanges;
      localProfileChanges = ValueNotifier(null);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => previousProfileChanges.dispose(),
      );
      mainPages.clear();
      visited
        ..clear()
        ..add(0);
      selected = 0;
      settingsDetailOpen = false;
      settingsDetailClosing = false;
      analysisDetailOpen = false;
      analysisDetailClosing = false;
      avatarSource = null;
      avatarImage = null;
      todayTabActive.value = true;
      _syncNativeAvatar();
    }
    if (oldWidget.themeMode != widget.themeMode ||
        !identical(oldWidget.api, widget.api)) {
      _sendNativeState();
    }
  }

  void updateProfile(Profile value) {
    if (avatarSource == value.avatar) return;
    avatarSource = value.avatar;
    setState(() => avatarImage = dataImage(value.avatar));
    _syncNativeAvatar();
  }

  void _syncNativeAvatar() {
    if (!NativeTabBridge.enabled) return;
    final source = avatarSource;
    final generation = ++_avatarGeneration;
    // Clear immediately so an old account or old image is never displayed
    // while a replacement is being prepared in an isolate.
    NativeTabBridge.setAvatar(null);
    if (source == null) return;
    NativeTabBridge.prepareAvatar(source).then(
      (image) {
        if (!mounted || generation != _avatarGeneration) return;
        NativeTabBridge.setAvatar(image);
      },
      onError: (Object error, StackTrace stack) {
        if (mounted && generation == _avatarGeneration) {
          NativeTabBridge.setAvatar(null);
          debugPrint('Native tab avatar preparation failed: $error');
        }
      },
    );
  }

  void applyLocalProfile(Profile value) {
    localProfileChanges.value = value;
    updateProfile(value);
  }

  void select(int index) {
    if (index == selected) return;
    todayTabActive.value = index == 0;
    setState(() {
      selected = index;
      visited.add(index);
      if (index != 3) {
        settingsDetailOpen = false;
        settingsDetailClosing = false;
      }
      if (index != 2) {
        analysisDetailOpen = false;
        analysisDetailClosing = false;
      }
    });
    _sendNativeState();
  }

  String get _nativeStateKey =>
      '$selected/${settingsDetailOpen || analysisDetailOpen || settingsDetailClosing || analysisDetailClosing}/${widget.themeMode.name}';

  void _sendNativeState() {
    if (!NativeTabBridge.enabled || !mounted) return;
    final state = _nativeStateKey;
    if (state == _lastNativeState) return;
    _lastNativeState = state;
    NativeTabBridge.sync(
      selected: selected,
      detailOpen:
          settingsDetailOpen ||
          analysisDetailOpen ||
          settingsDetailClosing ||
          analysisDetailClosing,
      appearance: widget.themeMode.name,
    );
  }

  void _setSettingsDetailOpen(bool value) {
    if (settingsDetailOpen == value) return;
    setState(() => settingsDetailOpen = value);
    _sendNativeState();
  }

  void _setSettingsDetailClosing(bool value) {
    if (settingsDetailClosing == value) return;
    setState(() => settingsDetailClosing = value);
    _sendNativeState();
  }

  void _setAnalysisDetailOpen(bool value) {
    if (analysisDetailOpen == value) return;
    setState(() => analysisDetailOpen = value);
    _sendNativeState();
  }

  void _setAnalysisDetailClosing(bool value) {
    if (analysisDetailClosing == value) return;
    setState(() => analysisDetailClosing = value);
    _sendNativeState();
  }

  Widget mainPage(int index) => mainPages.putIfAbsent(index, () {
    final mainApi = widget.api;
    return switch (index) {
      0 => TodayPage(
        api: widget.api,
        onUnauthorized: widget.onUnauthorized,
        onProfile: (profile) {
          if (identical(widget.api, mainApi)) updateProfile(profile);
        },
        localProfileChanges: localProfileChanges,
        tabActive: todayTabActive,
      ),
      1 => TimetablePage(
        api: widget.api,
        onUnauthorized: widget.onUnauthorized,
        localProfileChanges: localProfileChanges,
      ),
      2 => AnalysisPage(
        api: widget.api,
        onUnauthorized: widget.onUnauthorized,
        localProfileChanges: localProfileChanges,
        onDetailChanged: _setAnalysisDetailOpen,
        onDetailClosingChanged: _setAnalysisDetailClosing,
      ),
      _ => throw ArgumentError.value(index, 'index'),
    };
  });

  Widget settingsPage() => SettingsPage(
    api: widget.api,
    onUnauthorized: widget.onUnauthorized,
    onSignedOut: widget.onUnauthorized,
    themeMode: widget.themeMode,
    onThemeModeChanged: widget.onThemeModeChanged,
    onProfileChanged: applyLocalProfile,
    onSectionChanged: _setSettingsDetailOpen,
    onSectionClosingChanged: _setSettingsDetailClosing,
  );

  @override
  Widget build(BuildContext context) {
    final detailOpen = settingsDetailOpen || analysisDetailOpen;
    final detailClosing = settingsDetailClosing || analysisDetailClosing;
    if (NativeTabBridge.enabled &&
        _nativeStateKey != _lastNativeState &&
        !_nativeSyncScheduled) {
      _nativeSyncScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _nativeSyncScheduled = false;
        _sendNativeState();
      });
    }
    return Scaffold(
      extendBody: !NativeTabBridge.enabled,
      body: NativeTabMetrics(
        bottomOverlap: _nativeBottomOverlap,
        child: IndexedStack(
          index: selected,
          children: [
            for (var index = 0; index < 4; index++)
              TickerMode(
                enabled: selected == index,
                child: ExcludeFocus(
                  excluding: selected != index,
                  // Keep every visited page, including Settings, mounted so tab
                  // changes do not restart its local loading and image decoding.
                  child: visited.contains(index)
                      ? KeyedSubtree(
                          key: ObjectKey(widget.api),
                          child: RepaintBoundary(
                            child: index == 3
                                ? settingsPage()
                                : mainPage(index),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: NativeTabBridge.enabled
          ? null
          : IgnorePointer(
              key: const Key('settings-dock-interaction'),
              ignoring: detailOpen || detailClosing,
              child: ExcludeSemantics(
                excluding: detailOpen || detailClosing,
                child: AnimatedSlide(
                  key: const Key('settings-dock-slide'),
                  offset: detailOpen ? const Offset(0, 1.25) : Offset.zero,
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  child: AnimatedOpacity(
                    opacity: detailOpen ? 0 : 1,
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 220),
                    child: FloatingTabBar(
                      key: const Key('primary-tab-bar'),
                      selectedIndex: selected,
                      avatar: avatarImage,
                      onSelected: select,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
