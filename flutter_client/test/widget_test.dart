import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_helper_flutter/api.dart';
import 'package:hand_helper_flutter/analysis_page.dart';
import 'package:hand_helper_flutter/appearance_mode_selector.dart';
import 'package:hand_helper_flutter/container_morph_transition.dart';
import 'package:hand_helper_flutter/floating_tab_bar.dart';
import 'package:hand_helper_flutter/launch_preview.dart';
import 'package:hand_helper_flutter/main.dart';
import 'package:hand_helper_flutter/native_tab_bridge.dart';
import 'package:hand_helper_flutter/passkey_login.dart';
import 'package:hand_helper_flutter/settings_page.dart';
import 'package:hand_helper_flutter/today_page.dart';
import 'package:hand_helper_flutter/timetable_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:passkeys/types.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('greeting has PWA-compatible boundaries', () {
    expect(greeting(9), '早上好');
    expect(greeting(18), '晚上好');
  });

  test('course countdown converts only durations over 60 minutes', () {
    expect(formatCourseCountdown(const Duration(minutes: 59)), '59 分钟');
    expect(formatCourseCountdown(const Duration(minutes: 60)), '60 分钟');
    expect(formatCourseCountdown(const Duration(minutes: 61)), '1 小时 1 分钟');
    expect(formatCourseCountdown(const Duration(minutes: 129)), '2 小时 9 分钟');
    expect(formatCourseCountdown(const Duration(minutes: 120)), '2 小时 0 分钟');
  });

  testWidgets('launch preview waits for local route and then fades', (
    tester,
  ) async {
    late VoidCallback onReady;
    await tester.pumpWidget(
      MaterialApp(
        home: LaunchPreview(
          childBuilder: (ready) {
            onReady = ready;
            return const Scaffold(body: Text('目标页面'));
          },
        ),
      ),
    );
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('目标页面'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(Image), findsOneWidget);
    onReady();
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('PWA-inspired native login fits a small dark screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });
    ThemeMode? nextTheme;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.light),
        darkTheme: ThemeData(brightness: Brightness.dark),
        themeMode: ThemeMode.dark,
        home: LoginPage(
          api: ApiClient(
            client: MockClient((_) async => http.Response('', 500)),
          ),
          onSignedIn: () {},
          onThemeModeChanged: (value) => nextTheme = value,
        ),
      ),
    );
    expect(find.text('欢迎回来'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(
      tester
          .widget<Stack>(
            find
                .descendant(
                  of: find.byType(LoginPage),
                  matching: find.byType(Stack),
                )
                .first,
          )
          .fit,
      StackFit.expand,
    );
    await tester.tap(find.byTooltip('显示密码'));
    await tester.pump();
    expect(find.byTooltip('隐藏密码'), findsOneWidget);
    await tester.tap(find.byTooltip('切换为浅色模式'));
    expect(nextTheme, ThemeMode.light);
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pump();
    await tester.ensureVisible(find.text('登录'));
    await tester.pump();
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('请输入账号和密码'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'login background and header stay fixed when keyboard changes height',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetViewInsets();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: LoginPage(
            api: ApiClient(
              client: MockClient((_) async => http.Response('', 500)),
            ),
            onSignedIn: () {},
            onThemeModeChanged: (_) {},
          ),
        ),
      );
      final logo = find.byType(Image);
      final logoTop = tester.getTopLeft(logo).dy;
      final logoSize = tester.getSize(logo);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.resizeToAvoidBottomInset, isFalse);
      expect(scaffold.backgroundColor, isNot(Colors.transparent));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      expect(tester.getTopLeft(logo).dy, logoTop);
      expect(tester.getSize(logo), logoSize);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'login errors use dialogs without moving the button or clearing input',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final hapticCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') hapticCalls.add(call);
            return null;
          });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: LoginPage(
            api: ApiClient(
              client: MockClient(
                (_) async => http.Response.bytes(
                  utf8.encode(
                    '{"success":false,"error":{"message":"用户名或密码错误"}}',
                  ),
                  401,
                  headers: {'content-type': 'application/json; charset=utf-8'},
                ),
              ),
            ),
            onSignedIn: () {},
            onThemeModeChanged: (_) {},
          ),
        ),
      );
      final button = find.byType(FilledButton);
      final buttonFrame = find.byKey(
        const Key('login-submit-button-container'),
      );
      final initialTop = tester.getTopLeft(button).dy;
      final initialWidth = tester.getSize(buttonFrame).width;
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('请输入账号和密码'), findsOneWidget);
      expect(tester.getTopLeft(button).dy, initialTop);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      await tester.enterText(find.byType(TextField).at(0), 'user');
      await tester.enterText(find.byType(TextField).at(1), 'wrong');
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 230));
      expect(tester.getSize(buttonFrame).width, 56);
      expect(
        tester.getSize(find.byType(CircularProgressIndicator)),
        const Size(20, 20),
      );
      expect(tester.getTopLeft(button).dy, initialTop);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 650));
      });
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('用户名或密码错误'), findsOneWidget);
      expect(tester.getSize(buttonFrame).width, initialWidth);
      expect(hapticCalls, hasLength(1));
      expect(tester.getTopLeft(button).dy, initialTop);
      expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        'user',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        'wrong',
      );
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'native login sends the API Origin required by HTTPS CSRF check',
    () async {
      SharedPreferences.setMockInitialValues({});
      final client = ApiClient(
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/v1/auth/login');
          expect(request.headers['Origin'], Uri.parse(apiBaseUrl).origin);
          return http.Response('{"success":true,"data":{}}', 200);
        }),
      );
      await client.login('test-user', 'test-password');
    },
  );

  test(
    'passkey login reuses the WebAuthn envelope and stores the session',
    () async {
      SharedPreferences.setMockInitialValues({});
      const credential = <String, dynamic>{
        'id': 'credential-id',
        'rawId': 'credential-id',
        'type': 'public-key',
        'response': <String, dynamic>{
          'clientDataJSON': 'client-data',
          'authenticatorData': 'auth-data',
          'signature': 'signature',
          'userHandle': 'user-handle',
        },
        'clientExtensionResults': <String, dynamic>{},
      };
      final paths = <String>[];
      final client = ApiClient(
        client: MockClient((request) async {
          paths.add(request.url.path);
          expect(request.method, 'POST');
          expect(request.headers['Origin'], Uri.parse(apiBaseUrl).origin);
          if (request.url.path == '/api/v1/auth/passkey/options') {
            return http.Response(
              jsonEncode({
                'success': true,
                'data': {
                  'challenge_id': 'challenge-123456789',
                  'public_key': {
                    'rpId': 'hand.zhangzh.cc',
                    'challenge': 'base64url-challenge',
                    'userVerification': 'required',
                  },
                },
              }),
              200,
            );
          }
          expect(request.url.path, '/api/v1/auth/passkey/verify');
          expect(jsonDecode(request.body), {
            'challenge_id': 'challenge-123456789',
            'credential': credential,
          });
          return http.Response(
            '{"success":true,"data":{"authenticated":true,"username":"owner"}}',
            200,
            headers: {
              'set-cookie':
                  'hand_helper_session=passkey-session; Path=/; HttpOnly',
            },
          );
        }),
      );
      await client.loginWithPasskey((publicKey) async {
        expect(publicKey, {
          'rpId': 'hand.zhangzh.cc',
          'challenge': 'base64url-challenge',
          'userVerification': 'required',
        });
        return credential;
      });
      expect(paths, [
        '/api/v1/auth/passkey/options',
        '/api/v1/auth/passkey/verify',
      ]);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('session_cookie'),
        'hand_helper_session=passkey-session',
      );
      expect(prefs.getString('local_schedule_owner_v1'), 'user:owner');
    },
  );

  test('native passkey model preserves the backend WebAuthn field layout', () {
    final request = AuthenticateRequestType.fromJson({
      'rpId': 'hand.zhangzh.cc',
      'challenge': 'YWJjZA',
      'userVerification': 'required',
    });
    expect(request.relyingPartyId, 'hand.zhangzh.cc');
    expect(request.challenge, 'YWJjZA');
    expect(request.userVerification, 'required');
    final credential = AuthenticateResponseType(
      id: 'credential-id',
      rawId: 'credential-id',
      clientDataJSON: 'client-data',
      authenticatorData: 'auth-data',
      signature: 'signature',
      userHandle: 'user-handle',
    ).toJson();
    expect(credential['type'], 'public-key');
    expect(credential['response'], {
      'clientDataJSON': 'client-data',
      'authenticatorData': 'auth-data',
      'signature': 'signature',
      'userHandle': 'user-handle',
    });
  });

  testWidgets(
    'cancelling the native passkey sheet keeps password login available',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      var verificationCalled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: LoginPage(
            api: ApiClient(
              client: MockClient((request) async {
                if (request.url.path == '/api/v1/auth/passkey/verify') {
                  verificationCalled = true;
                }
                return http.Response(
                  '{"success":true,"data":{"challenge_id":"challenge-123456789","public_key":{"rpId":"hand.zhangzh.cc","challenge":"abc"}}}',
                  200,
                );
              }),
            ),
            passkeyAssertionProvider: (_) async =>
                throw const PasskeyLoginCancelled(),
            onSignedIn: () => fail('cancel must not log in'),
            onThemeModeChanged: (_) {},
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('login-passkey-button')));
      await tester.pumpAndSettle();
      expect(verificationCalled, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('登录'), findsOneWidget);
      expect(find.text('使用通行密钥登录'), findsOneWidget);
    },
  );

  testWidgets(
    'missing passkey shows a localized fallback without submitting verify',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      var verifyCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: LoginPage(
            api: ApiClient(
              client: MockClient((request) async {
                if (request.url.path.endsWith('/verify')) verifyCalls++;
                return http.Response(
                  '{"success":true,"data":{"challenge_id":"challenge-123456789","public_key":{"rpId":"hand.zhangzh.cc","challenge":"abc"}}}',
                  200,
                );
              }),
            ),
            passkeyAssertionProvider: (_) async =>
                throw const PasskeyLoginFailure('这台设备没有可用的通行密钥，请使用账号密码登录。'),
            onSignedIn: () => fail('missing passkey must not log in'),
            onThemeModeChanged: (_) {},
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('login-passkey-button')));
      await tester.pumpAndSettle();
      expect(verifyCalls, 0);
      expect(find.text('这台设备没有可用的通行密钥，请使用账号密码登录。'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.text('登录'), findsOneWidget);
    },
  );

  testWidgets(
    'passkey prompt leaves the password button at its original size',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prompt = Completer<Map<String, dynamic>>();
      await tester.pumpWidget(
        MaterialApp(
          home: LoginPage(
            api: ApiClient(
              client: MockClient(
                (_) async => http.Response(
                  '{"success":true,"data":{"challenge_id":"challenge-123456789","public_key":{"rpId":"hand.zhangzh.cc","challenge":"abc"}}}',
                  200,
                ),
              ),
            ),
            passkeyAssertionProvider: (_) => prompt.future,
            onSignedIn: () => fail('cancel must not log in'),
            onThemeModeChanged: (_) {},
          ),
        ),
      );
      final passwordButton = find.byKey(
        const Key('login-submit-button-container'),
      );
      final originalWidth = tester.getSize(passwordButton).width;
      await tester.tap(find.byKey(const Key('login-passkey-button')));
      await tester.pump();
      expect(tester.getSize(passwordButton).width, originalWidth);
      expect(find.text('正在验证…'), findsOneWidget);
      prompt.completeError(const PasskeyLoginCancelled());
      await tester.pumpAndSettle();
      expect(find.text('使用通行密钥登录'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  test(
    'passkey verification rejection does not create a signed-in session',
    () async {
      SharedPreferences.setMockInitialValues({});
      final client = ApiClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/options')) {
            return http.Response(
              '{"success":true,"data":{"challenge_id":"challenge-123456789","public_key":{"rpId":"hand.zhangzh.cc","challenge":"abc"}}}',
              200,
            );
          }
          return http.Response.bytes(
            utf8.encode('{"success":false,"error":{"message":"通行密钥验证失败，请重试"}}'),
            401,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await expectLater(
        client.loginWithPasskey((_) async => {'id': 'invalid'}),
        throwsA(
          isA<ApiFailure>().having((e) => e.unauthorized, 'unauthorized', true),
        ),
      );
      expect(await client.hasStoredSession(), isFalse);
    },
  );

  test(
    'today snapshot survives transport failure and is isolated across logins',
    () async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=first',
      });
      final directory = await Directory.systemTemp.createTemp(
        'hand-helper-today-cache-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final cache = TodayCache(directoryProvider: () async => directory);
      final scheduleStore = LocalScheduleStore(
        directoryProvider: () async => directory,
      );
      final date = dateKey(DateTime.now());
      final nextDate = dateKey(DateTime.now().add(const Duration(days: 1)));
      var title = '原安排';
      final online = ApiClient(
        cache: cache,
        localScheduleStore: scheduleStore,
        client: MockClient((request) async {
          if (request.url.path == '/api/v1/auth/login') {
            return http.Response(
              '{"success":true,"data":{}}',
              200,
              headers: {'set-cookie': 'session=second; Path=/'},
            );
          }
          final data = switch (request.url.path) {
            '/api/v1/profile' => {
              'display_name': '用户',
              'avatar_data_url': null,
              'home_wallpaper_data_url': null,
            },
            '/api/v1/timetable' => [
              {
                'id': 13,
                'course_name': '明日课程',
                'session_date': nextDate,
                'start_datetime': '${nextDate}T09:00:00',
                'end_datetime': '${nextDate}T10:00:00',
                'classroom': 'A101',
                'teacher': '王老师',
              },
            ],
            _ => [
              {
                'id': 2,
                'title': title,
                'scheduled_date': date,
                'scheduled_time': '19:00',
              },
            ],
          };
          return http.Response.bytes(
            utf8.encode(jsonEncode({'success': true, 'data': data})),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await online.today(DateTime.now());
      await online.importServerSchedulesOnce();
      title = '更新安排';
      await online.today(DateTime.now());
      final offline = ApiClient(
        cache: cache,
        localScheduleStore: scheduleStore,
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      final snapshot = await offline.loadTodaySnapshot();
      expect(snapshot?.data.schedules.single.title, '原安排');
      expect(snapshot?.calendarSessions?.single.date, nextDate);
      await expectLater(offline.hasSession(), throwsA(isA<ApiFailure>()));
      expect(
        (await offline.loadTodaySnapshot())?.isFor(DateTime.now()),
        isTrue,
      );
      await online.login('second-user', 'password');
      expect(await offline.loadTodaySnapshot(), isNull);
      expect(await offline.localSchedules(DateTime.now()), isEmpty);
    },
  );

  test(
    'local schedules persist offline, migrate once and stay account-scoped',
    () async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=first',
      });
      final directory = await Directory.systemTemp.createTemp(
        'hand-helper-schedules-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = LocalScheduleStore(
        directoryProvider: () async => directory,
      );
      final requests = <String>[];
      final date = DateTime.now().add(const Duration(days: 1));
      final serverItem = CustomSchedule(7, '旧服务器安排', dateKey(date), '08:00');
      final online = ApiClient(
        localScheduleStore: store,
        localManualCourseStore: LocalManualCourseStore(
          directoryProvider: () async => directory,
        ),
        client: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          if (request.url.path == '/api/v1/auth/login') {
            return http.Response(
              '{"success":true,"data":{}}',
              200,
              headers: {'set-cookie': 'session=next; Path=/'},
            );
          }
          if (request.url.path == '/api/v1/auth/me') {
            return http.Response(
              '{"success":true,"data":{"username":"first-user"}}',
              200,
            );
          }
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'success': true,
                'data': [
                  {
                    'id': serverItem.id,
                    'title': serverItem.title,
                    'scheduled_date': serverItem.date,
                    'scheduled_time': serverItem.time,
                  },
                ],
              }),
            ),
            200,
          );
        }),
      );
      expect(await online.hasSession(), isTrue);
      await online.importServerSchedulesOnce();
      await online.deleteSchedule(7);
      await online.importServerSchedulesOnce();
      expect(await online.localSchedules(date), isEmpty);
      await online.saveSchedule(title: '本机明日安排', date: date, time: '09:30');
      final offline = ApiClient(
        localScheduleStore: store,
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      final saved = (await offline.localSchedules(date)).single;
      expect(saved.title, '本机明日安排');
      expect(saved.id, lessThan(0));
      await offline.saveSchedule(
        id: saved.id,
        title: '离线改期',
        date: DateTime.now(),
        time: '10:00',
      );
      expect(await offline.localSchedules(date), isEmpty);
      expect(
        (await offline.localSchedules(DateTime.now())).single.title,
        '离线改期',
      );
      await online.login('second-user', 'password');
      expect(await online.localSchedules(DateTime.now()), isEmpty);
      await online.login('first-user', 'password');
      expect(
        (await online.localSchedules(DateTime.now())).single.title,
        '离线改期',
      );
      await online.deleteSchedule(saved.id);
      expect(await online.localSchedules(DateTime.now()), isEmpty);
      expect(requests, [
        'GET /api/v1/auth/me',
        'GET /api/v1/custom-schedules',
        'POST /api/v1/auth/login',
        'POST /api/v1/auth/login',
      ]);
    },
  );

  testWidgets('today hero fits a phone and follows the PWA empty state', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=online',
    });
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var requestCount = 0;
    final client = ApiClient(
      cache: _EmptyTodayCache(),
      localProfileStore: _MemoryLocalProfileStore(),
      localScheduleStore: _MemoryLocalScheduleStore(),
      client: MockClient((request) async {
        requestCount++;
        final data = switch (request.url.path) {
          '/api/v1/profile' => {
            'display_name': '用户',
            'avatar_data_url': null,
            'home_wallpaper_data_url': null,
          },
          '/api/v1/timetable' => <Object>[],
          _ => <Object>[],
        };
        return http.Response.bytes(
          utf8.encode(jsonEncode({'success': true, 'data': data})),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayPage(
            api: client,
            onUnauthorized: () {},
            onProfile: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Keep the rendered labels in failures to distinguish loading from API errors.
    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .toList();
    expect(tester.takeException(), isNull);
    expect(labels, contains('今日安排'));
    expect(find.text('今天暂无课程或安排'), findsNothing);
    expect(find.text('今天的课程已经结束'), findsNothing);
    expect(requestCount, 2);
    await tester.drag(find.byType(ListView), const Offset(0, 250));
    await tester.pumpAndSettle();
    expect(requestCount, 2);
    expect(find.byType(RefreshIndicator), findsNothing);
  });

  testWidgets(
    'today avatar morph starts at the real image and keeps one provider',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final avatar = _avatarDataUrl(width: 2, height: 1);
      final changes = ValueNotifier<Profile?>(null);
      addTearDown(changes.dispose);
      await _pumpTodayAvatar(tester, avatar: avatar, changes: changes);
      final source = find.byKey(const Key('today-avatar-source'));
      final sourceImage = find.descendant(
        of: source,
        matching: find.byType(Image),
      );
      final provider = tester.widget<Image>(sourceImage).image;
      final start = tester.getRect(source);
      changes.value = Profile('测试', avatar, null);
      await tester.pump();
      expect(tester.widget<Image>(sourceImage).image, same(provider));

      await tester.tap(source);
      await tester.pump();
      final surface = find.byKey(const Key('today-avatar-morph-surface'));
      expect(surface, findsOneWidget);
      expect(tester.getRect(surface), start);
      expect(
        tester
            .widget<ContainerMorphTransition>(
              find.byType(ContainerMorphTransition),
            )
            .startRect,
        start,
      );
      final preview = find.byKey(const Key('today-avatar-morph-photo'));
      expect(preview, findsOneWidget);
      expect(tester.widget<Image>(preview).image, same(provider));
      final startScale = tester.widget<Transform>(
        find.ancestor(of: preview, matching: find.byType(Transform)).first,
      );
      expect(startScale.transform.storage[0], closeTo(2, .001));
      await tester.pump(const Duration(milliseconds: 260));
      final end = tester.getRect(surface);
      expect(end.width, end.height);
      expect(end.center.dx, closeTo(180, .01));
      expect(end.left, greaterThanOrEqualTo(20));
      expect(tester.widget<Image>(preview).image, same(provider));
      // A legacy landscape avatar continuously reveals the full image rather
      // than abruptly swapping from cover to contain at the end.
      final scale = tester.widget<Transform>(
        find.ancestor(of: preview, matching: find.byType(Transform)).first,
      );
      expect(scale.transform.storage[0], closeTo(1, .001));
      expect(tester.takeException(), isNull);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'today avatar preview fits ${dark ? 'dark' : 'light'} small screen',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await _pumpTodayAvatar(
          tester,
          avatar: _avatarDataUrl(width: 1, height: 1),
          dark: dark,
        );
        await tester.tap(find.byKey(const Key('today-avatar-source')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 260));
        final rect = tester.getRect(
          find.byKey(const Key('today-avatar-morph-surface')),
        );
        expect(rect.width, rect.height);
        expect(rect.left, greaterThanOrEqualTo(20));
        expect(rect.right, lessThanOrEqualTo(300));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom + 62, lessThanOrEqualTo(568));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final fraction in [.25, .5, .75]) {
    testWidgets('today avatar reverses without a jump at $fraction progress', (
      tester,
    ) async {
      await _pumpTodayAvatar(
        tester,
        avatar: _avatarDataUrl(width: 2, height: 1),
      );
      final source = find.byKey(const Key('today-avatar-source'));
      final start = tester.getRect(source);
      await tester.tap(source);
      await tester.pump();
      await tester.pump(Duration(milliseconds: (260 * fraction).round()));
      final surface = find.byKey(const Key('today-avatar-morph-surface'));
      final before = tester.getRect(surface);
      final beforeRadius =
          (tester.widget<RepaintBoundary>(surface).child! as ClipRRect)
              .borderRadius;
      final scrimColor = tester
          .widget<ColoredBox>(
            find.descendant(
              of: find.byKey(const Key('today-avatar-morph-scrim')),
              matching: find.byType(ColoredBox),
            ),
          )
          .color;
      final preview = find.byKey(const Key('today-avatar-morph-photo'));
      final image = tester.widget<Image>(preview).image;
      await tester.tapAt(const Offset(5, 400));
      await tester.pump();
      expect(tester.getRect(surface), before);
      expect(
        (tester.widget<RepaintBoundary>(surface).child! as ClipRRect)
            .borderRadius,
        beforeRadius,
      );
      expect(
        tester
            .widget<ColoredBox>(
              find.descendant(
                of: find.byKey(const Key('today-avatar-morph-scrim')),
                matching: find.byType(ColoredBox),
              ),
            )
            .color,
        scrimColor,
      );
      expect(tester.widget<Image>(preview).image, same(image));
      await tester.pump(const Duration(milliseconds: 300));
      expect(surface, findsNothing);
      expect(tester.getRect(source), start);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('today avatar close, system back, repeats and source loss', (
    tester,
  ) async {
    final avatar = _avatarDataUrl(width: 1, height: 1);
    final changes = ValueNotifier<Profile?>(null);
    addTearDown(changes.dispose);
    await _pumpTodayAvatar(tester, avatar: avatar, changes: changes);
    final source = find.byKey(const Key('today-avatar-source'));
    await tester.tap(source);
    await tester.tap(source, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.byType(ContainerMorphTransition), findsOneWidget);
    await tester.tap(find.byKey(const Key('today-avatar-morph-close')));
    await tester.pumpAndSettle();
    expect(find.byType(ContainerMorphTransition), findsNothing);

    await tester.tap(source);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(ContainerMorphTransition), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(ContainerMorphTransition), findsNothing);

    await tester.tap(source);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    final surface = find.byKey(const Key('today-avatar-morph-surface'));
    final inFlight = tester.getRect(surface);
    changes.value = const Profile('测试', null, null);
    await tester.pump();
    await tester.tapAt(const Offset(5, 400));
    await tester.pump();
    expect(tester.getRect(surface), inFlight);
    expect(
      find.byKey(const Key('today-avatar-morph-fade-close')),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(surface, findsNothing);
    final nextAvatar = _avatarDataUrl(width: 2, height: 2);
    changes.value = Profile('测试', nextAvatar, null);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    final updatedProvider = tester
        .widget<Image>(
          find.descendant(of: source, matching: find.byType(Image)),
        )
        .image;
    await tester.tap(source);
    await tester.pump();
    expect(
      tester
          .widget<Image>(find.byKey(const Key('today-avatar-morph-photo')))
          .image,
      same(updatedProvider),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'today avatar scrim keeps bottom navigation visible but blocked',
    (tester) async {
      var tabTaps = 0;
      await _pumpTodayAvatar(
        tester,
        avatar: _avatarDataUrl(width: 1, height: 1),
        onDockTap: () => tabTaps++,
      );
      await tester.tap(find.byKey(const Key('today-avatar-source')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      final dock = find.byKey(const Key('test-bottom-tab'));
      expect(dock, findsOneWidget);
      await tester.tap(dock, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(tabTaps, 0);
      expect(find.byType(ContainerMorphTransition), findsNothing);
      expect(dock, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('PWA-style schedule dialog disables empty save', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ScheduleSheet(api: ApiClient())),
      ),
    );
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存安排'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('schedule edit protects dirty input on button and scrim', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'session_cookie': 'session=test'});
    final api = ApiClient(localScheduleStore: _MemoryLocalScheduleStore());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (_) => ScheduleSheet(
                  api: api,
                  schedule: CustomSchedule(
                    1,
                    '原安排',
                    dateKey(DateTime.now()),
                    '09:00',
                  ),
                ),
              ),
              child: const Text('打开编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开编辑'));
    await tester.pumpAndSettle();
    expect(find.text('编辑安排'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '修改后的安排');
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的更改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('编辑安排'), findsOneWidget);
    await tester.tapAt(const Offset(5, 300));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的更改？'), findsOneWidget);
    await tester.tap(find.text('放弃更改'));
    await tester.pumpAndSettle();
    expect(find.text('编辑安排'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('date and time pickers consume back before schedule form', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'session_cookie': 'session=test'});
    final api = ApiClient(localScheduleStore: _MemoryLocalScheduleStore());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (_) => ScheduleSheet(api: api),
              ),
              child: const Text('打开安排'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开安排'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日期'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(find.text('保存安排'), findsOneWidget);
    await tester.tap(find.text('时间'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsNothing);
    expect(find.text('保存安排'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('保存安排'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('schedule save blocks scrim and back until storage finishes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'session_cookie': 'session=test'});
    final store = _BlockingLocalScheduleStore();
    final api = ApiClient(localScheduleStore: store);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (_) => ScheduleSheet(api: api),
              ),
              child: const Text('打开安排'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开安排'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '保存中的安排');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存安排'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('保存安排'));
    await tester.pump();
    await tester.pump();
    expect(find.text('保存中…'), findsOneWidget);
    await tester.tapAt(const Offset(5, 300));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('保存中…'), findsOneWidget);
    store.release.complete();
    await tester.pumpAndSettle();
    expect(find.text('保存安排'), findsNothing);
    expect(store.records.values.single.title, '保存中的安排');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'add schedule morph uses button rect and adapts to a small screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpTodaySchedule(tester);
      final button = find.widgetWithText(TextButton, '添加安排');
      final start = tester.getRect(button);
      await tester.tap(button);
      await tester.pump();
      await tester.pump();
      final surface = find.byKey(const Key('today-add-schedule-surface'));
      expect(surface, findsOneWidget);
      final transition = tester.widget<ContainerMorphTransition>(
        find.byType(ContainerMorphTransition),
      );
      expect(transition.startRect, start);
      expect(tester.getRect(surface), start);
      expect(find.byType(ScheduleSheet), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 260));
      final end = tester.getRect(surface);
      expect(end.center.dx, closeTo(160, 1));
      expect(end.top, greaterThanOrEqualTo(16));
      expect(end.bottom, lessThanOrEqualTo(552));
      expect(end.height, lessThan(520));
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(5, 280));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();
      expect(surface, findsNothing);
    },
  );

  for (final fraction in [.25, .5, .75]) {
    testWidgets('add schedule reverses continuously at $fraction', (
      tester,
    ) async {
      await _pumpTodaySchedule(tester);
      await tester.tap(find.widgetWithText(TextButton, '添加安排'));
      await tester.pump();
      await tester.pump();
      await tester.pump(Duration(milliseconds: (260 * fraction).round()));
      final surface = find.byKey(const Key('today-add-schedule-surface'));
      final before = tester.getRect(surface);
      await tester.tapAt(const Offset(5, 300));
      await tester.pump();
      expect(tester.getRect(surface), before);
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();
      expect(surface, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'add schedule keyboard stays visible and saving refreshes Today',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetViewInsets();
      });
      final store = await _pumpTodaySchedule(tester);
      await tester.tap(find.widgetWithText(TextButton, '添加安排'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      final surface = find.byKey(const Key('today-add-schedule-surface'));
      expect(tester.getRect(surface).top, greaterThanOrEqualTo(12));
      expect(tester.getRect(surface).bottom, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField), '新增本地安排');
      await tester.pump();
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存安排'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();
      expect(surface, findsNothing);
      expect(store.records.values.single.title, '新增本地安排');
      expect(find.text('新增本地安排'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('add schedule dirty system back confirms before closing', (
    tester,
  ) async {
    await _pumpTodaySchedule(tester);
    await tester.tap(find.widgetWithText(TextButton, '添加安排'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.enterText(find.byType(TextField), '尚未保存');
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的更改？'), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today-add-schedule-surface')), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃更改'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today-add-schedule-surface')), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, '添加安排'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(ContainerMorphTransition), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('add schedule picker takes system back before morph', (
    tester,
  ) async {
    await _pumpTodaySchedule(tester);
    await tester.tap(find.widgetWithText(TextButton, '添加安排'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.tap(find.text('日期'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(find.byKey(const Key('today-add-schedule-surface')), findsOneWidget);
    await tester.tap(find.text('时间'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsNothing);
    expect(find.byKey(const Key('today-add-schedule-surface')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('add schedule pending save cannot be closed', (tester) async {
    final store = _BlockingLocalScheduleStore();
    await _pumpTodaySchedule(tester, scheduleStore: store);
    await tester.tap(find.widgetWithText(TextButton, '添加安排'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));
    await tester.enterText(find.byType(TextField), '等待写入');
    await tester.pump();
    await tester.tap(find.text('保存安排'));
    await tester.pump();
    await tester.pump();
    expect(find.text('保存中…'), findsOneWidget);
    await tester.tapAt(const Offset(5, 300));
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byKey(const Key('today-add-schedule-surface')), findsOneWidget);
    store.release.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today-add-schedule-surface')), findsNothing);
    expect(find.text('等待写入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('add schedule blocks dock and duplicate modal opening', (
    tester,
  ) async {
    var dockTaps = 0;
    await _pumpTodaySchedule(tester, onDockTap: () => dockTaps++);
    await tester.tap(find.widgetWithText(TextButton, '添加安排'));
    await tester.pump();
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('test-bottom-tab')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(dockTaps, 0);
    await tester.pumpAndSettle();
    expect(find.byType(ContainerMorphTransition), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, '添加安排'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(ContainerMorphTransition), findsOneWidget);
    await tester.tapAt(
      tester.getCenter(find.widgetWithText(TextButton, '添加安排')),
    );
    await tester.pump();
    expect(find.byType(ContainerMorphTransition), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(ContainerMorphTransition), findsOneWidget);
    await tester.tapAt(const Offset(5, 300));
    await tester.pumpAndSettle();
    expect(find.byType(ContainerMorphTransition), findsNothing);
    expect(dockTaps, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('add schedule fades out if source becomes inactive', (
    tester,
  ) async {
    final selected = ValueNotifier<bool>(true);
    addTearDown(selected.dispose);
    await _pumpTodaySchedule(tester, selected: selected);
    await tester.tap(find.widgetWithText(TextButton, '添加安排'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    final surface = find.byKey(const Key('today-add-schedule-surface'));
    final before = tester.getRect(surface);
    selected.value = false;
    await tester.pump();
    await tester.tapAt(const Offset(5, 300));
    await tester.pump();
    expect(tester.getRect(surface), before);
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pumpAndSettle();
    expect(surface, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dark add schedule form scrolls with large text on short screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpTodaySchedule(tester, dark: true, textScale: 1.8);
      await tester.tap(find.widgetWithText(TextButton, '添加安排'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 260));
      final rect = tester.getRect(
        find.byKey(const Key('today-add-schedule-surface')),
      );
      expect(rect.top, greaterThanOrEqualTo(12));
      expect(rect.bottom, lessThanOrEqualTo(468));
      final formScroll = find.descendant(
        of: find.byType(ScheduleSheet),
        matching: find.byType(SingleChildScrollView),
      );
      final scrollable = find
          .descendant(of: formScroll, matching: find.byType(Scrollable))
          .first;
      expect(
        tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
        greaterThan(0),
      );
      await tester.drag(formScroll.first, const Offset(0, -160));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('today renders course and swipeable schedule in dark mode', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=online',
    });
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime.now();
    final date = dateKey(now);
    final client = ApiClient(
      cache: _EmptyTodayCache(),
      localProfileStore: _MemoryLocalProfileStore(),
      localScheduleStore: _MemoryLocalScheduleStore(),
      client: MockClient((request) async {
        final data = switch (request.url.path) {
          '/api/v1/profile' => {
            'display_name': '用户',
            'avatar_data_url': null,
            'home_wallpaper_data_url': null,
          },
          '/api/v1/timetable' => [
            {
              'id': 1,
              'course_name': '机器学习',
              'session_date': date,
              'start_datetime': '${date}T08:30:00',
              'end_datetime': '${date}T10:05:00',
              'classroom': '汇学楼201',
              'teacher': '张老师',
            },
          ],
          _ => [
            {
              'id': 2,
              'title': '完成实验报告',
              'scheduled_date': date,
              'scheduled_time': '19:00',
            },
          ],
        };
        return http.Response.bytes(
          utf8.encode(jsonEncode({'success': true, 'data': data})),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          splashFactory: NoSplash.splashFactory,
        ),
        home: Scaffold(
          body: TodayPage(
            api: client,
            onUnauthorized: () {},
            onProfile: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    final labels = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .toList();
    expect(labels, contains('机器学习'));
    expect(find.text('完成实验报告'), findsOneWidget);
    expect(find.text('今天有 1 项自定义安排'), findsOneWidget);
    await tester.drag(find.text('完成实验报告'), const Offset(-220, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.text('编辑安排'), findsOneWidget);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final hasWallpaper in [false, true]) {
      for (final dark in [false, true]) {
        testWidgets(
          'schedule actions stay clipped until swipe on ${platform.name} '
          'with ${hasWallpaper ? 'wallpaper' : 'default background'} '
          'in ${dark ? 'dark' : 'light'} mode',
          (tester) async {
            debugDefaultTargetPlatformOverride = platform;
            addTearDown(() => debugDefaultTargetPlatformOverride = null);
            SharedPreferences.setMockInitialValues({
              'session_cookie': 'session=schedule-swipe',
            });
            tester.view.physicalSize = const Size(1080, 2400);
            tester.view.devicePixelRatio = 3;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final date = dateKey(DateTime.now());
            final profile = Profile(
              '测试',
              null,
              hasWallpaper ? _avatarDataUrl(width: 2, height: 2) : null,
            );
            final snapshot = TodaySnapshot(
              TodayData(profile, const [], [
                CustomSchedule(7, '完成实验报告', date, '19:00'),
              ]),
              date,
              DateTime.now(),
            );
            final client = ApiClient(
              cache: _FixtureTodayCache(snapshot),
              localProfileStore: _MemoryLocalProfileStore(),
              localScheduleStore: _MemoryLocalScheduleStore(),
              client: MockClient(
                (_) async => throw const SocketException('offline'),
              ),
            );
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(
                  brightness: dark ? Brightness.dark : Brightness.light,
                  splashFactory: NoSplash.splashFactory,
                ),
                home: Scaffold(
                  body: TodayPage(
                    api: client,
                    onUnauthorized: () {},
                    onProfile: (_) {},
                  ),
                ),
              ),
            );
            for (var i = 0; i < 15; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            final card = find.byKey(const Key('today-entry-card'));
            final actions = find.byKey(
              const Key('today-schedule-actions-clip'),
            );
            expect(card, findsOneWidget);
            final gradient =
                (tester.widget<Container>(card).decoration! as BoxDecoration)
                        .gradient!
                    as LinearGradient;
            expect(gradient.colors.first.a < 1, hasWallpaper);
            expect(tester.getSize(actions).width, 0);
            expect(find.text('编辑').hitTestable(), findsNothing);
            expect(find.text('删除').hitTestable(), findsNothing);
            await tester.tapAt(tester.getCenter(card));
            await tester.pump();
            expect(find.byType(AlertDialog), findsNothing);

            await tester.drag(card, const Offset(-220, 0));
            await tester.pumpAndSettle();
            expect(tester.getSize(actions).width, 168);
            expect(find.text('编辑').hitTestable(), findsOneWidget);
            expect(find.text('删除').hitTestable(), findsOneWidget);
            final shiftedCard = tester.getRect(card);
            await tester.tapAt(
              Offset(shiftedCard.right - 20, shiftedCard.center.dy),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 110));
            final actionRect = tester.getRect(actions);
            expect(actionRect.width, greaterThan(0));
            expect(
              actionRect.width,
              closeTo(actionRect.right - tester.getRect(card).right, 1),
            );
            expect(find.text('删除').hitTestable(), findsNothing);
            await tester.pumpAndSettle();
            expect(tester.getSize(actions).width, 0);
            expect(find.text('编辑').hitTestable(), findsNothing);
            await tester.drag(card, const Offset(-220, 0));
            await tester.pumpAndSettle();
            await tester.tap(find.text('删除'));
            await tester.pumpAndSettle();
            expect(find.textContaining('删除“完成实验报告”'), findsOneWidget);
            await tester.tap(find.text('取消'));
            await tester.pumpAndSettle();

            await tester.drag(card, const Offset(-220, 0));
            await tester.pumpAndSettle();
            await tester.tap(find.text('编辑'));
            await tester.pumpAndSettle();
            expect(find.text('编辑安排'), findsOneWidget);
            expect(tester.takeException(), isNull);
            debugDefaultTargetPlatformOverride = null;
          },
        );
      }
    }
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final hasWallpaper in [false, true]) {
      testWidgets(
        'Shell closes schedule actions on tab exit on ${platform.name} '
        'with ${hasWallpaper ? 'wallpaper' : 'default background'}',
        (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          const channel = MethodChannel('hand_helper/native_tab');
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          if (platform == TargetPlatform.iOS) {
            messenger.setMockMethodCallHandler(channel, (_) async => null);
            addTearDown(
              () => messenger.setMockMethodCallHandler(channel, null),
            );
          }
          SharedPreferences.setMockInitialValues({
            'session_cookie': 'session=schedule-tab',
          });
          tester.view.physicalSize = const Size(1080, 2400);
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final date = dateKey(DateTime.now());
          final profile = Profile(
            '测试',
            null,
            hasWallpaper ? _avatarDataUrl(width: 2, height: 2) : null,
          );
          final client = ApiClient(
            cache: _FixtureTodayCache(
              TodaySnapshot(
                TodayData(profile, const [], [
                  CustomSchedule(7, '完成实验报告', date, '19:00'),
                ]),
                date,
                DateTime.now(),
              ),
            ),
            localProfileStore: _MemoryLocalProfileStore(),
            localScheduleStore: _MemoryLocalScheduleStore(),
            client: MockClient(
              (_) async => throw const SocketException('offline'),
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Shell(
                api: client,
                onUnauthorized: () {},
                themeMode: ThemeMode.light,
                onThemeModeChanged: (_) {},
              ),
            ),
          );
          for (var i = 0; i < 15; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          final todayState = tester.state(find.byType(TodayPage));
          final card = find.byKey(const Key('today-entry-card'));
          final actions = find.byKey(const Key('today-schedule-actions-clip'));
          final gradient =
              (tester.widget<Container>(card).decoration! as BoxDecoration)
                      .gradient!
                  as LinearGradient;
          expect(gradient.colors.first.a < 1, hasWallpaper);

          Future<void> selectTab(int index) async {
            if (platform == TargetPlatform.iOS) {
              await messenger.handlePlatformMessage(
                channel.name,
                const StandardMethodCodec().encodeMethodCall(
                  MethodCall('selectTab', index),
                ),
                (_) {},
              );
            } else {
              tester
                  .widget<FloatingTabBar>(find.byType(FloatingTabBar))
                  .onSelected(index);
            }
          }

          await tester.drag(card, const Offset(-220, 0));
          await tester.pumpAndSettle();
          expect(tester.getSize(actions).width, 168);
          await selectTab(1);
          await tester.pump();
          await selectTab(0);
          await tester.pumpAndSettle();
          expect(tester.state(find.byType(TodayPage)), same(todayState));
          expect(tester.getSize(actions).width, 0);
          expect(find.text('编辑').hitTestable(), findsNothing);
          expect(find.text('删除').hitTestable(), findsNothing);
          final semantics = tester.ensureSemantics();
          expect(find.semantics.byLabel('编辑'), findsNothing);
          expect(find.semantics.byLabel('删除'), findsNothing);
          semantics.dispose();
          await tester.tapAt(tester.getCenter(card));
          await tester.pump();
          expect(find.byType(AlertDialog), findsNothing);

          await tester.drag(card, const Offset(-220, 0));
          await tester.pumpAndSettle();
          expect(find.text('删除').hitTestable(), findsOneWidget);
          // Switch twice without waiting for the close animation to finish.
          await selectTab(1);
          await selectTab(0);
          await tester.pumpAndSettle();
          expect(tester.getSize(actions).width, 0);
          expect(find.text('删除').hitTestable(), findsNothing);
          final gesture = await tester.startGesture(tester.getCenter(card));
          await gesture.moveBy(const Offset(-100, 0));
          await tester.pump();
          expect(tester.getSize(actions).width, greaterThan(0));
          await selectTab(1);
          await selectTab(0);
          await gesture.moveBy(const Offset(-60, 0));
          await gesture.up();
          await tester.pumpAndSettle();
          expect(tester.getSize(actions).width, 0);
          expect(find.text('编辑').hitTestable(), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          debugDefaultTargetPlatformOverride = null;
        },
      );
    }
  }

  testWidgets('active course reminder aligns with Today course cards', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime.now();
    final date = dateKey(now);
    final client = ApiClient(
      cache: _FixtureTodayCache(
        TodaySnapshot(
          TodayData(const Profile('用户', null, null), [
            CourseSession(
              1,
              '机器学习',
              date,
              now.subtract(const Duration(minutes: 5)),
              now.add(const Duration(minutes: 15)),
              'A101',
              '张老师',
            ),
          ], const []),
          date,
          now,
        ),
      ),
      timetableCache: _EmptyTimetableCache(),
      localProfileStore: _MemoryLocalProfileStore(),
      localScheduleStore: _MemoryLocalScheduleStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayPage(
            api: client,
            onUnauthorized: () {},
            onProfile: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final reminder = find.byKey(const Key('today-course-status'));
    final card = find.byKey(const Key('today-entry-card')).first;
    expect(reminder, findsOneWidget);
    expect(card, findsOneWidget);
    expect(
      tester.getTopLeft(reminder).dx,
      closeTo(tester.getTopLeft(card).dx, .1),
    );
    expect(
      tester.getSize(reminder).width,
      closeTo(tester.getSize(card).width, .1),
    );
    expect(tester.getSize(reminder).height, greaterThanOrEqualTo(62));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Today uses device-time hour and minute countdown', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    final now = DateTime.now();
    final date = dateKey(now);
    final start = now.add(const Duration(minutes: 129));
    final client = ApiClient(
      cache: _FixtureTodayCache(
        TodaySnapshot(
          TodayData(const Profile('用户', null, null), [
            CourseSession(
              1,
              '机器学习',
              date,
              start,
              start.add(const Duration(minutes: 45)),
              null,
              null,
            ),
          ], const []),
          date,
          now,
        ),
      ),
      timetableCache: _EmptyTimetableCache(),
      localProfileStore: _MemoryLocalProfileStore(),
      localScheduleStore: _MemoryLocalScheduleStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayPage(
            api: client,
            onUnauthorized: () {},
            onProfile: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('2 小时 9 分钟后上课'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed Today reminder stays compact', (tester) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    final now = DateTime.now();
    final date = dateKey(now);
    final client = ApiClient(
      cache: _FixtureTodayCache(
        TodaySnapshot(
          TodayData(const Profile('用户', null, null), [
            CourseSession(
              1,
              '已结束课程',
              date,
              now.subtract(const Duration(hours: 2)),
              now.subtract(const Duration(hours: 1)),
              null,
              null,
            ),
          ], const []),
          date,
          now,
        ),
      ),
      timetableCache: _EmptyTimetableCache(),
      localProfileStore: _MemoryLocalProfileStore(),
      localScheduleStore: _MemoryLocalScheduleStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayPage(
            api: client,
            onUnauthorized: () {},
            onProfile: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final reminder = find.byKey(const Key('today-complete-status'));
    final card = find.byKey(const Key('today-entry-card')).first;
    expect(reminder, findsOneWidget);
    expect(
      tester.getSize(reminder).width,
      lessThan(tester.getSize(card).width),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('offline Today keeps courses and allows local arrangements', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    final date = dateKey(DateTime.now());
    final snapshot = TodaySnapshot(
      TodayData(
        const Profile('用户', null, null),
        [
          CourseSession(
            1,
            '机器学习',
            date,
            DateTime.now().subtract(const Duration(hours: 2)),
            DateTime.now().subtract(const Duration(hours: 1)),
            '汇学楼',
            '张老师',
          ),
        ],
        [CustomSchedule(2, '完成实验报告', date, '19:00')],
      ),
      date,
      DateTime.now(),
    );
    final client = ApiClient(
      cache: _FixtureTodayCache(snapshot),
      localProfileStore: _MemoryLocalProfileStore(),
      localScheduleStore: _MemoryLocalScheduleStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayPage(
            api: client,
            onUnauthorized: () {},
            onProfile: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    expect(
      find.text('机器学习'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((item) => item.data)
          .join(' | '),
    );
    expect(find.text('完成实验报告'), findsOneWidget);
    expect(find.textContaining('离线 · 上次更新'), findsNothing);
    await tester.tap(find.text('添加安排'));
    await tester.pump();
    await tester.pump();
    expect(find.text('添加安排'), findsWidgets);
    expect(find.text('保存安排'), findsOneWidget);
  });

  testWidgets('yesterday snapshot does not claim today is empty', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final snapshot = TodaySnapshot(
      TodayData(const Profile('用户', null, null), const [], [
        CustomSchedule(2, '昨天的安排', dateKey(yesterday), '19:00'),
      ]),
      dateKey(yesterday),
      yesterday,
    );
    final client = ApiClient(
      cache: _FixtureTodayCache(snapshot),
      localProfileStore: _MemoryLocalProfileStore(),
      localScheduleStore: _MemoryLocalScheduleStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayPage(
            api: client,
            onUnauthorized: () {},
            onProfile: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('课程数据暂不可用'), findsOneWidget);
    expect(find.text('昨天的安排'), findsNothing);
    expect(find.text('今天的课程已经结束'), findsNothing);
  });

  testWidgets('offline Today matches cached timetable by device date', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    final now = DateTime.now();
    final date = dateKey(now);
    final yesterday = now.subtract(const Duration(days: 1));
    final start = DateTime(now.year, now.month, now.day, 9);
    final end = DateTime(now.year, now.month, now.day, 10);
    final todayCache = _FixtureTodayCache(
      TodaySnapshot(
        TodayData(const Profile('用户', null, null), const [], [
          CustomSchedule(2, '昨天的安排', dateKey(yesterday), '19:00'),
        ]),
        dateKey(yesterday),
        yesterday,
      ),
    );
    final timetableCache = _FixtureTimetableCache(
      TimetableData(
        [const TermInfo(1, '2026-2027-1', '当前学期', '2026-09-07', true)],
        const [],
        null,
        {
          1: [
            TimetableCourse(
              8,
              '本机今日课程',
              date,
              start,
              end,
              'A101',
              '王老师',
              null,
              null,
              null,
              1,
              now.weekday,
              1,
              1,
            ),
            TimetableCourse(
              9,
              '昨天的课程',
              dateKey(yesterday),
              yesterday,
              yesterday,
              null,
              null,
              null,
              null,
              null,
              1,
              yesterday.weekday,
              1,
              1,
            ),
          ],
        },
        now,
      ),
    );
    final client = ApiClient(
      cache: todayCache,
      timetableCache: timetableCache,
      localManualCourseStore: _MemoryLocalManualCourseStore(),
      localProfileStore: _MemoryLocalProfileStore(),
      localScheduleStore: _MemoryLocalScheduleStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayPage(
            api: client,
            onUnauthorized: () {},
            onProfile: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('本机今日课程'), findsOneWidget);
    expect(find.text('昨天的课程'), findsNothing);
    expect(find.text('昨天的安排'), findsNothing);
    expect(find.text('课程数据暂不可用'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offline Today matches full calendar saved by Today request', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    final now = DateTime.now();
    final date = dateKey(now);
    final yesterday = now.subtract(const Duration(days: 1));
    final start = DateTime(now.year, now.month, now.day, 9);
    final end = DateTime(now.year, now.month, now.day, 10);
    final client = ApiClient(
      cache: _FixtureTodayCache(
        TodaySnapshot(
          TodayData(const Profile('用户', null, null), const [], [
            CustomSchedule(2, '昨天的安排', dateKey(yesterday), '19:00'),
          ]),
          dateKey(yesterday),
          yesterday,
          calendarSessions: [
            CourseSession(5, '跨天缓存课程', date, start, end, 'B202', '李老师'),
          ],
        ),
      ),
      timetableCache: _EmptyTimetableCache(),
      localProfileStore: _MemoryLocalProfileStore(),
      localScheduleStore: _MemoryLocalScheduleStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayPage(
            api: client,
            onUnauthorized: () {},
            onProfile: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('跨天缓存课程'), findsOneWidget);
    expect(find.text('昨天的安排'), findsNothing);
    expect(find.text('课程数据暂不可用'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offline with no snapshot still renders the native Today shell', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    final client = ApiClient(
      cache: _EmptyTodayCache(),
      localProfileStore: _MemoryLocalProfileStore(),
      localScheduleStore: _MemoryLocalScheduleStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayPage(
            api: client,
            onUnauthorized: () {},
            onProfile: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('航的助手'), findsOneWidget);
    expect(find.text('今日安排'), findsOneWidget);
    expect(find.text('课程数据暂不可用'), findsOneWidget);
    expect(find.text('今天的课程已经结束'), findsNothing);
    expect(find.text('重试'), findsOneWidget);
  });

  test('timetable caches all weeks and isolates a new login', () async {
    SharedPreferences.setMockInitialValues({'session_cookie': 'session=first'});
    final directory = await Directory.systemTemp.createTemp(
      'hand-helper-timetable-cache-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final cache = TimetableCache(directoryProvider: () async => directory);
    final manualStore = LocalManualCourseStore(
      directoryProvider: () async => directory,
    );
    final seen = <String>[];
    final client = ApiClient(
      timetableCache: cache,
      localManualCourseStore: manualStore,
      client: MockClient((request) async {
        seen.add(request.url.toString());
        if (request.url.path == '/api/v1/auth/login') {
          return http.Response(
            '{"success":true,"data":{}}',
            200,
            headers: {'set-cookie': 'session=second; Path=/'},
          );
        }
        final data = switch (request.url.path) {
          '/api/v1/terms' => [
            {
              'id': 1,
              'source_term_id': '2026-2027-1',
              'display_name': '2026-2027 第一学期',
              'start_date': '2026-09-07',
              'is_current': true,
            },
            {
              'id': 2,
              'source_term_id': '2026-2027-2',
              'display_name': '2026-2027 第二学期',
              'start_date': '2027-02-22',
              'is_current': false,
            },
          ],
          '/api/v1/settings/period-times' => [
            {'period_number': 1, 'start_time': '08:30', 'end_time': '09:15'},
          ],
          '/api/v1/profile' => {
            'display_name': '测试',
            'timetable_background_data_url': null,
          },
          '/api/v1/timetable' =>
            request.url.queryParameters['term_id'] == '1'
                ? [
                    {
                      'id': 4,
                      'course_name': '跨周课程',
                      'session_date': '2026-10-12',
                      'start_datetime': '2026-10-12T08:30:00',
                      'end_datetime': '2026-10-12T09:15:00',
                      'classroom': 'A101',
                      'teacher': '王老师',
                    },
                  ]
                : <Object>[],
          _ => throw StateError('Unexpected ${request.url}'),
        };
        return http.Response.bytes(
          utf8.encode(jsonEncode({'success': true, 'data': data})),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final fresh = await client.timetable().catchError(
      (Object error) => throw StateError('$error; requests: $seen'),
    );
    expect(fresh.coursesByTerm[1]?.single.name, '跨周课程');
    expect(fresh.coursesByTerm[2], isEmpty);
    final offline = ApiClient(
      timetableCache: cache,
      localManualCourseStore: manualStore,
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    final saved = await offline.loadTimetableSnapshot();
    expect(saved?.terms.length, 2);
    expect(saved?.coursesByTerm[1]?.single.date, '2026-10-12');
    await client.login('another', 'password');
    expect(await offline.loadTimetableSnapshot(), isNull);
  });

  test('selected timetable term is local and cleared on a new login', () async {
    SharedPreferences.setMockInitialValues({'session_cookie': 'session=first'});
    final client = ApiClient(
      client: MockClient((request) async {
        expect(request.url.path, '/api/v1/auth/login');
        return http.Response(
          '{"success":true,"data":{}}',
          200,
          headers: {'set-cookie': 'session=second; Path=/'},
        );
      }),
    );
    await client.saveSelectedTimetableTerm('2027-2028-1');
    expect(await ApiClient().selectedTimetableTerm(), '2027-2028-1');
    await client.login('second-user', 'password');
    expect(await client.selectedTimetableTerm(), isNull);
  });

  testWidgets('timetable restores selected term after tab-style recreation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final data = TimetableData(
      [
        const TermInfo(1, '2024-2025-1', '2024-2025 第一学期', null, false),
        TermInfo(2, academicTermSourceId(DateTime.now()), '当期学期', null, false),
        const TermInfo(3, '2099-2100-1', '其他学期', null, false),
      ],
      defaultPeriods,
      null,
      const {},
      DateTime.now(),
    );
    final client = ApiClient(
      timetableCache: _FixtureTimetableCache(data),
      localManualCourseStore: _MemoryLocalManualCourseStore(),
      localProfileStore: _MemoryLocalProfileStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    Widget page() => MaterialApp(
      home: Scaffold(
        body: TimetablePage(api: client, onUnauthorized: () {}),
      ),
    );
    await tester.pumpWidget(page());
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('当期学期'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('其他学期').last);
    await tester.pumpAndSettle();
    expect(await client.selectedTimetableTerm(), '2099-2100-1');
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpWidget(page());
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('其他学期'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('manual courses can be saved, edited and deleted offline', () async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=test',
      'local_schedule_owner_v1': 'user:test',
    });
    final directory = await Directory.systemTemp.createTemp(
      'hand-helper-manual-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final monday = mondayOf(DateTime.now());
    final term = TermInfo(7, 'test-term', '测试学期', dateKey(monday), true);
    final cache = _FixtureTimetableCache(
      TimetableData(
        [term],
        defaultPeriods,
        null,
        {7: <TimetableCourse>[]},
        DateTime.now(),
      ),
    );
    final store = LocalManualCourseStore(
      directoryProvider: () async => directory,
    );
    final client = ApiClient(
      timetableCache: cache,
      localManualCourseStore: store,
      localProfileStore: _MemoryLocalProfileStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await client.saveManualCourse(
      term: term,
      name: '实验课',
      weeks: '1,3周',
      weekday: 2,
      startPeriod: 3,
      endPeriod: 4,
    );
    final saved = (await client.loadTimetableSnapshot())!.coursesByTerm[7]!;
    expect(saved.length, 2);
    expect(saved.every((course) => course.source == 'LOCAL'), isTrue);
    final offline = ApiClient(
      timetableCache: cache,
      localManualCourseStore: LocalManualCourseStore(
        directoryProvider: () async => directory,
      ),
      localProfileStore: _MemoryLocalProfileStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    expect(
      (await offline.loadTimetableSnapshot())!.coursesByTerm[7]!.length,
      2,
    );
    await offline.saveManualCourse(
      id: saved.first.manualId,
      term: term,
      name: '实验课已改',
      weeks: '1周',
      weekday: 2,
      startPeriod: 3,
      endPeriod: 4,
    );
    final edited = (await offline.loadTimetableSnapshot())!.coursesByTerm[7]!;
    expect(edited.single.name, '实验课已改');
    await offline.deleteManualCourse(edited.single.manualId!);
    expect((await offline.loadTimetableSnapshot())!.coursesByTerm[7], isEmpty);
  });

  test(
    'cached server manual course migrates once and is not resurrected',
    () async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=test',
        'local_schedule_owner_v1': 'user:test',
      });
      final directory = await Directory.systemTemp.createTemp(
        'hand-helper-manual-migrate-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final monday = mondayOf(DateTime.now());
      final day = dateKey(monday);
      final start = DateTime(monday.year, monday.month, monday.day, 8, 30);
      final term = TermInfo(7, 'test-term', '测试学期', day, true);
      final cache = _FixtureTimetableCache(
        TimetableData(
          [term],
          defaultPeriods,
          null,
          {
            7: [
              TimetableCourse(
                42,
                '旧手动课',
                day,
                start,
                start.add(const Duration(minutes: 45)),
                null,
                null,
                '1周',
                'MANUAL',
                9,
                7,
                1,
                1,
                1,
              ),
            ],
          },
          DateTime.now(),
        ),
      );
      final client = ApiClient(
        timetableCache: cache,
        localManualCourseStore: LocalManualCourseStore(
          directoryProvider: () async => directory,
        ),
        localProfileStore: _MemoryLocalProfileStore(),
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      final first = (await client.loadTimetableSnapshot())!.coursesByTerm[7]!;
      expect(first, hasLength(1));
      expect(first.single.source, 'LOCAL');
      expect(first.single.manualId, isNegative);
      await client.deleteManualCourse(first.single.manualId!);
      expect((await client.loadTimetableSnapshot())!.coursesByTerm[7], isEmpty);
      final restarted = ApiClient(
        timetableCache: cache,
        localManualCourseStore: LocalManualCourseStore(
          directoryProvider: () async => directory,
        ),
        localProfileStore: _MemoryLocalProfileStore(),
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      expect(
        (await restarted.loadTimetableSnapshot())!.coursesByTerm[7],
        isEmpty,
      );
    },
  );

  testWidgets(
    'manual week picker confirms presets and discards cancelled edits',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=test',
      });
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final monday = mondayOf(DateTime.now());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ManualCourseEditor(
              api: ApiClient(),
              term: TermInfo(1, 'test-term', '测试学期', dateKey(monday), true),
              periods: defaultPeriods,
              initialWeek: 6,
            ),
          ),
        ),
      );
      String summary() => tester
          .widget<Text>(find.byKey(const Key('manual-week-summary')))
          .data!;
      expect(summary(), '第 6 周');
      await tester.tap(find.byKey(const Key('manual-week-trigger')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('单周'));
      await tester.pumpAndSettle();
      expect(find.text('已选择 10 / 20 周'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(summary(), '第 6 周');

      await tester.tap(find.byKey(const Key('manual-week-trigger')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('双周'));
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(summary(), '第 2、4、6、8、10、12、14、16、18、20 周');

      await tester.tap(find.byKey(const Key('manual-week-trigger')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.text('请至少选择一个上课周次'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(summary(), '第 2、4、6、8、10、12、14、16、18、20 周');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline timetable keeps course editing and week navigation available',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=offline',
      });
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final monday = mondayOf(DateTime.now());
      final date = dateKey(monday);
      final start = DateTime(monday.year, monday.month, monday.day, 8, 30);
      final data = TimetableData(
        [TermInfo(1, 'test-term', '测试学期', date, true)],
        defaultPeriods,
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==',
        {
          1: [
            TimetableCourse(
              1,
              '离线课程',
              date,
              start,
              start.add(const Duration(minutes: 45)),
              '教室 A',
              '王老师',
              '1周',
              'LOCAL',
              -1,
              1,
              1,
              1,
              1,
            ),
          ],
        },
        DateTime.now(),
      );
      final client = ApiClient(
        timetableCache: _FixtureTimetableCache(data),
        localManualCourseStore: _MemoryLocalManualCourseStore(),
        localProfileStore: _MemoryLocalProfileStore(),
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimetablePage(api: client, onUnauthorized: () {}),
          ),
        ),
      );
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      expect(find.text('离线课程'), findsOneWidget);
      expect(find.textContaining('离线 · 上次更新'), findsNothing);
      final fixedBackdrop = tester.element(
        find.byKey(const Key('timetable-fixed-backdrop')),
      );
      final imageFinder = find.descendant(
        of: find.byKey(const Key('timetable-fixed-backdrop')),
        matching: find.byType(Image),
      );
      final imageProvider = tester.widget<Image>(imageFinder).image;
      expect(
        find.ancestor(
          of: find.byKey(const Key('timetable-fixed-backdrop')),
          matching: find.byType(PageView),
        ),
        findsNothing,
      );
      await tester.tap(find.text('离线课程'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('timetable-detail-scroll')),
          matching: find.text('离线课程'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('timetable-detail-scroll')),
          matching: find.text('教室 A'),
        ),
        findsOneWidget,
      );
      expect(find.text('编辑'), findsOneWidget);
      await tester.tap(find.byKey(const Key('timetable-detail-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下一周或开学周'));
      await tester.pumpAndSettle();
      expect(
        identical(
          tester.element(find.byKey(const Key('timetable-fixed-backdrop'))),
          fixedBackdrop,
        ),
        isTrue,
      );
      expect(
        identical(tester.widget<Image>(imageFinder).image, imageProvider),
        isTrue,
      );
      expect(find.text('离线课程'), findsNothing);
      await tester.tap(find.byTooltip('上一周'));
      await tester.pumpAndSettle();
      expect(find.text('离线课程'), findsOneWidget);
      await tester.timedDrag(
        find.byType(PageView),
        const Offset(-55, 0),
        const Duration(milliseconds: 700),
      );
      await tester.pumpAndSettle();
      expect(find.text('离线课程'), findsOneWidget);
      await tester.timedDrag(
        find.byType(PageView),
        const Offset(-105, 0),
        const Duration(milliseconds: 700),
      );
      await tester.pumpAndSettle();
      expect(find.text('离线课程'), findsNothing);
      await tester.timedDrag(
        find.byType(PageView),
        const Offset(105, 0),
        const Duration(milliseconds: 700),
      );
      await tester.pumpAndSettle();
      expect(find.text('离线课程'), findsOneWidget);
      await tester.timedDrag(
        find.byType(PageView),
        const Offset(0, -120),
        const Duration(milliseconds: 700),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<PageView>(find.byType(PageView)).controller!.page,
        closeTo(1000, .001),
      );
    },
  );

  testWidgets(
    'offline timetable without snapshot is not misreported as empty',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=offline',
      });
      final client = ApiClient(
        timetableCache: _EmptyTimetableCache(),
        localProfileStore: _MemoryLocalProfileStore(),
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimetablePage(api: client, onUnauthorized: () {}),
          ),
        ),
      );
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      expect(find.text('课表尚未缓存，请联网后重试'), findsOneWidget);
      expect(find.textContaining('请在“设置'), findsNothing);
    },
  );

  testWidgets(
    'timetable morph clips a partially hidden source until it fades out',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=offline',
      });
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final monday = mondayOf(DateTime.now());
      final date = dateKey(monday);
      final start = DateTime(monday.year, monday.month, monday.day, 9, 25);
      final client = ApiClient(
        timetableCache: _FixtureTimetableCache(
          TimetableData(
            [TermInfo(1, 'term', '测试学期', date, true)],
            defaultPeriods,
            null,
            {
              1: [
                TimetableCourse(
                  21,
                  '顶部跨节课程',
                  date,
                  start,
                  start.add(const Duration(minutes: 130)),
                  'A101',
                  '老师',
                  '1周',
                  null,
                  null,
                  1,
                  1,
                  2,
                  4,
                ),
              ],
            },
            DateTime.now(),
          ),
        ),
        localManualCourseStore: _MemoryLocalManualCourseStore(),
        localProfileStore: _MemoryLocalProfileStore(),
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimetablePage(api: client, onUnauthorized: () {}),
          ),
        ),
      );
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final card = find
          .ancestor(of: find.text('顶部跨节课程'), matching: find.byType(InkWell))
          .first;
      final grid = find
          .ancestor(of: card, matching: find.byType(SingleChildScrollView))
          .first;
      final viewport = tester.getRect(grid);
      await tester.drag(grid, const Offset(0, -105));
      await tester.pumpAndSettle();
      final source = tester.getRect(card);
      expect(source.top, lessThan(viewport.top));
      expect(source.bottom, greaterThan(viewport.top + 20));
      await tester.tapAt(Offset(source.center.dx, viewport.top + 16));
      await tester.pump();
      final morph = tester.widget<ContainerMorphTransition>(
        find.byType(ContainerMorphTransition),
      );
      expect(morph.startRect, source);
      final clip = find.byKey(const Key('timetable-detail-viewport-clip'));
      Rect visibleClip() =>
          tester.widget<ClipRect>(clip).clipper!.getClip(tester.getSize(clip));
      expect(visibleClip().top, closeTo(viewport.top, 0.1));
      expect(visibleClip().left, 0);
      expect(visibleClip().right, 360);
      await tester.pump(const Duration(milliseconds: 90));
      expect(visibleClip().top, closeTo(viewport.top, 0.1));
      expect(
        tester
            .widget<ContainerMorphTransition>(
              find.byType(ContainerMorphTransition),
            )
            .progress,
        lessThan(1),
      );
      // The first pump starts the ticker; elapsed time begins on that frame.
      await tester.pump(const Duration(milliseconds: 259));
      expect(
        tester
            .widget<ContainerMorphTransition>(
              find.byType(ContainerMorphTransition),
            )
            .progress,
        lessThan(1),
      );
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        tester
            .widget<ContainerMorphTransition>(
              find.byType(ContainerMorphTransition),
            )
            .progress,
        1,
      );
      expect(visibleClip().top, 0);
      expect(visibleClip().bottom, 800);
      await tester.tap(find.byKey(const Key('timetable-detail-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(visibleClip().top, closeTo(viewport.top, 0.1));
      expect(
        tester
            .widget<ContainerMorphTransition>(
              find.byType(ContainerMorphTransition),
            )
            .startRect,
        source,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timetable-detail-surface')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'timetable morph follows one and multi-period cards and closes safely',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=offline',
      });
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final haptics = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'HapticFeedback.vibrate') haptics.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final monday = mondayOf(DateTime.now());
      final date = dateKey(monday);
      final start = DateTime(monday.year, monday.month, monday.day, 8, 30);
      final courses = [
        TimetableCourse(
          11,
          '单节课程',
          date,
          start,
          start.add(const Duration(minutes: 45)),
          'A101',
          '老师',
          '1周',
          null,
          null,
          1,
          1,
          1,
          1,
        ),
        TimetableCourse(
          12,
          '跨节课程',
          date,
          start.add(const Duration(minutes: 55)),
          start.add(const Duration(minutes: 165)),
          'B202',
          '老师',
          '1周',
          null,
          null,
          1,
          1,
          2,
          4,
        ),
      ];
      final client = ApiClient(
        timetableCache: _FixtureTimetableCache(
          TimetableData(
            [TermInfo(1, 'term', '测试学期', date, true)],
            defaultPeriods,
            null,
            {1: courses},
            DateTime.now(),
          ),
        ),
        localManualCourseStore: _MemoryLocalManualCourseStore(),
        localProfileStore: _MemoryLocalProfileStore(),
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      var dockTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            extendBody: true,
            body: TimetablePage(api: client, onUnauthorized: () {}),
            bottomNavigationBar: TextButton(
              key: const Key('test-dock'),
              onPressed: () => dockTaps++,
              child: const Text('底栏'),
            ),
          ),
        ),
      );
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('单节课程'), findsOneWidget);
      expect(find.text('跨节课程'), findsOneWidget);
      Future<Rect> open(String title) async {
        final card = find
            .ancestor(of: find.text(title), matching: find.byType(InkWell))
            .first;
        final rect = tester.getRect(card);
        await tester.tap(find.text(title));
        await tester.pump();
        final surface = find.byKey(const Key('timetable-detail-surface'));
        expect(tester.getRect(surface), rect);
        expect(
          tester
              .widget<Material>(
                find
                    .descendant(of: surface, matching: find.byType(Material))
                    .first,
              )
              .color!
              .a,
          1.0,
        );
        final hapticsBeforeRepeat = haptics.length;
        await tester.tapAt(rect.center);
        expect(haptics.length, hapticsBeforeRepeat);
        await tester.pumpAndSettle();
        final end = tester.getRect(surface);
        expect(end.width, greaterThan(rect.width));
        expect(end.width, lessThan(360));
        expect(end.height, lessThan(400));
        expect(end.top, greaterThan(0));
        expect(end.bottom, lessThan(700));
        final lastValue = find.descendant(
          of: find.byKey(const Key('timetable-detail-scroll')),
          matching: find.text('1周'),
        );
        expect(end.bottom - tester.getRect(lastValue).bottom, lessThan(70));
        expect(
          (tester.widget<RepaintBoundary>(surface).child! as ClipRRect)
              .borderRadius,
          BorderRadius.circular(22),
        );
        expect(find.byKey(const Key('test-dock')), findsOneWidget);
        return rect;
      }

      final firstRect = await open('单节课程');
      final firstEndRect = tester.getRect(
        find.byKey(const Key('timetable-detail-surface')),
      );
      await tester.tap(find.byKey(const Key('timetable-detail-close')));
      await tester.pump();
      final closingMorph = tester.widget<ContainerMorphTransition>(
        find.byType(ContainerMorphTransition),
      );
      expect(closingMorph.startRect, firstRect);
      expect(closingMorph.endRect, firstEndRect);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timetable-detail-surface')), findsNothing);
      await open('跨节课程');
      await tester.tapAt(tester.getCenter(find.byKey(const Key('test-dock'))));
      await tester.pumpAndSettle();
      expect(dockTaps, 0);
      expect(find.byKey(const Key('timetable-detail-surface')), findsNothing);
      await open('跨节课程');
      await tester.tapAt(const Offset(8, 400));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timetable-detail-surface')), findsNothing);
      await open('单节课程');
      final countBeforeBack = haptics.length;
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timetable-detail-surface')), findsNothing);
      expect(haptics.length, countBeforeBack);
      await open('单节课程');
      tester
          .widget<PageView>(find.byType(PageView))
          .controller!
          .jumpToPage(1001);
      await tester.pump();
      await tester.tap(find.byKey(const Key('timetable-detail-close')));
      await tester.pump();
      expect(
        find.byKey(const Key('timetable-detail-fade-close')),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('timetable-detail-surface')), findsNothing);
      expect(
        haptics.map((call) => call.arguments),
        everyElement('HapticFeedbackType.lightImpact'),
      );
      expect(haptics.length, 9);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('timetable opening reverses continuously at 25, 50 and 75%', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final haptics = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') haptics.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final monday = mondayOf(DateTime.now());
    final date = dateKey(monday);
    final start = DateTime(monday.year, monday.month, monday.day, 9, 25);
    final client = ApiClient(
      timetableCache: _FixtureTimetableCache(
        TimetableData(
          [TermInfo(1, 'term', '测试学期', date, true)],
          defaultPeriods,
          null,
          {
            1: [
              TimetableCourse(
                21,
                '可中断跨节课程',
                date,
                start,
                start.add(const Duration(minutes: 130)),
                'A101',
                '老师',
                '1周',
                null,
                null,
                1,
                1,
                2,
                4,
              ),
            ],
          },
          DateTime.now(),
        ),
      ),
      localManualCourseStore: _MemoryLocalManualCourseStore(),
      localProfileStore: _MemoryLocalProfileStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimetablePage(api: client, onUnauthorized: () {}),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final card = find
        .ancestor(of: find.text('可中断跨节课程'), matching: find.byType(InkWell))
        .first;
    final grid = find
        .ancestor(of: card, matching: find.byType(SingleChildScrollView))
        .first;
    final viewport = tester.getRect(grid);
    await tester.drag(grid, const Offset(0, -105));
    await tester.pumpAndSettle();
    final source = tester.getRect(card);
    expect(source.top, lessThan(viewport.top));
    final surface = find.byKey(const Key('timetable-detail-surface'));
    final clip = find.byKey(const Key('timetable-detail-viewport-clip'));
    final scrim = find.byKey(const Key('timetable-detail-scrim'));

    List<double> layerOpacities() => find
        .descendant(of: surface, matching: find.byType(Opacity))
        .evaluate()
        .map((element) => (element.widget as Opacity).opacity)
        .toList();
    double scrimAlpha() =>
        (tester.widget<GestureDetector>(scrim).child! as ColoredBox).color.a;
    BorderRadius radius() =>
        (tester.widget<RepaintBoundary>(surface).child! as ClipRRect)
                .borderRadius
            as BorderRadius;
    Rect clipRect() =>
        tester.widget<ClipRect>(clip).clipper!.getClip(tester.getSize(clip));

    for (final fraction in <double>[.25, .5, .75]) {
      for (final trigger in <String>[
        'scrim',
        'back',
        if (fraction >= .75) 'close',
      ]) {
        await tester.tapAt(Offset(source.center.dx, viewport.top + 16));
        await tester.pump();
        await tester.pump(); // Start the controller ticker after measurement.
        await tester.pump(Duration(milliseconds: (260 * fraction).round()));
        final beforeRect = tester.getRect(surface);
        final beforeRadius = radius();
        final beforeOpacity = layerOpacities();
        final beforeScrim = scrimAlpha();
        final beforeClip = clipRect();
        final beforeProgress = tester
            .widget<ContainerMorphTransition>(
              find.byType(ContainerMorphTransition),
            )
            .progress;
        expect(
          tester
              .widget<ContainerMorphTransition>(
                find.byType(ContainerMorphTransition),
              )
              .courseDetailTextHandoff,
          isTrue,
        );
        if (fraction == .25) {
          expect(
            tester
                .widget<Opacity>(
                  find.byKey(const Key('timetable-detail-source-text')),
                )
                .opacity,
            greaterThan(.5),
          );
        } else {
          expect(
            tester
                .widget<Opacity>(
                  find.byKey(const Key('timetable-detail-source-text')),
                )
                .opacity,
            0,
          );
        }
        expect(beforeProgress, closeTo(fraction, .01));
        expect(beforeClip.top, greaterThanOrEqualTo(0));
        final hapticsBefore = haptics.length;
        if (trigger == 'back') {
          await tester.binding.handlePopRoute();
          expect(haptics.length, hapticsBefore);
        } else if (trigger == 'close') {
          await tester.tap(find.byKey(const Key('timetable-detail-close')));
          expect(haptics.length, hapticsBefore + 1);
        } else {
          await tester.tapAt(const Offset(8, 400));
          expect(haptics.length, hapticsBefore + 1);
        }
        await tester.pump();
        expect(tester.getRect(surface), beforeRect);
        expect(radius(), beforeRadius);
        expect(layerOpacities(), beforeOpacity);
        expect(scrimAlpha(), beforeScrim);
        expect(clipRect(), beforeClip);
        await tester.tapAt(const Offset(8, 400));
        await tester.binding.handlePopRoute();
        expect(
          haptics.length,
          trigger == 'back' ? hapticsBefore : hapticsBefore + 1,
        );
        await tester.pump(const Duration(milliseconds: 20));
        final afterProgress = tester
            .widget<ContainerMorphTransition>(
              find.byType(ContainerMorphTransition),
            )
            .progress;
        expect(afterProgress, lessThan(beforeProgress));
        expect(tester.getRect(surface).top, isNot(equals(beforeRect.top)));
        if (afterProgress <= .35) {
          expect(clipRect().top, closeTo(viewport.top, .1));
        }
        // reverse() consumes only the already-traversed fraction of 260 ms.
        await tester.pump(
          Duration(milliseconds: (260 * fraction).round() - 18),
        );
        await tester.pump();
        expect(surface, findsNothing);
        expect(find.text('可中断跨节课程'), findsOneWidget);
      }
    }
    // After several interrupted routes, a new route can still open normally.
    await tester.tapAt(Offset(source.center.dx, viewport.top + 16));
    await tester.pumpAndSettle();
    expect(surface, findsOneWidget);
    await tester.tap(find.byKey(const Key('timetable-detail-close')));
    await tester.pumpAndSettle();
    expect(surface, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'timetable lost source fades from current frame and early back is safe',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=offline',
      });
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final monday = mondayOf(DateTime.now());
      final date = dateKey(monday);
      final start = DateTime(monday.year, monday.month, monday.day, 8, 30);
      final client = ApiClient(
        timetableCache: _FixtureTimetableCache(
          TimetableData(
            [TermInfo(1, 'term', '测试学期', date, true)],
            defaultPeriods,
            null,
            {
              1: [
                TimetableCourse(
                  31,
                  '失效源课程',
                  date,
                  start,
                  start.add(const Duration(minutes: 45)),
                  'A101',
                  '老师',
                  '1周',
                  null,
                  null,
                  1,
                  1,
                  1,
                  1,
                ),
              ],
            },
            DateTime.now(),
          ),
        ),
        localManualCourseStore: _MemoryLocalManualCourseStore(),
        localProfileStore: _MemoryLocalProfileStore(),
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimetablePage(api: client, onUnauthorized: () {}),
          ),
        ),
      );
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final surface = find.byKey(const Key('timetable-detail-surface'));
      await tester.tap(find.text('失效源课程'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 130));
      final inFlightRect = tester.getRect(surface);
      final inFlightProgress = tester
          .widget<ContainerMorphTransition>(
            find.byType(ContainerMorphTransition),
          )
          .progress;
      expect(inFlightProgress, closeTo(.5, .01));
      tester
          .widget<PageView>(find.byType(PageView))
          .controller!
          .jumpToPage(1001);
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(
        find.byKey(const Key('timetable-detail-fade-close')),
        findsOneWidget,
      );
      expect(tester.getRect(surface), inFlightRect);
      expect(
        tester
            .widget<ContainerMorphTransition>(
              find.byType(ContainerMorphTransition),
            )
            .progress,
        inFlightProgress,
      );
      await tester.binding.handlePopRoute();
      await tester.tapAt(const Offset(8, 400));
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.getRect(surface), inFlightRect);
      final fade = tester.widget<Opacity>(
        find.byKey(const Key('timetable-detail-fade-close')),
      );
      expect(fade.opacity, allOf(greaterThan(0), lessThan(1)));
      await tester.pumpAndSettle();
      expect(surface, findsNothing);
      tester
          .widget<PageView>(find.byType(PageView))
          .controller!
          .jumpToPage(1000);
      await tester.pumpAndSettle();
      await tester.tap(find.text('失效源课程'));
      await tester.pump(); // Detail measurement may only just have completed.
      await tester.binding.handlePopRoute();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(surface, findsNothing);
      await tester.tap(find.text('失效源课程'));
      await tester.pumpAndSettle();
      expect(surface, findsOneWidget);
      await tester.tap(find.byKey(const Key('timetable-detail-close')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('course detail blocks every add path until its route exits', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final monday = mondayOf(DateTime.now());
    final date = dateKey(monday);
    final start = DateTime(monday.year, monday.month, monday.day, 8, 30);
    final client = ApiClient(
      timetableCache: _FixtureTimetableCache(
        TimetableData(
          [TermInfo(1, 'term', '测试学期', date, true)],
          defaultPeriods,
          null,
          {
            1: [
              TimetableCourse(
                -1,
                '本地互斥课程',
                date,
                start,
                start.add(const Duration(minutes: 45)),
                'A101',
                '老师',
                '1周',
                'LOCAL',
                -1,
                1,
                1,
                1,
                1,
              ),
            ],
          },
          DateTime.now(),
        ),
      ),
      localManualCourseStore: _MemoryLocalManualCourseStore(),
      localProfileStore: _MemoryLocalProfileStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TimetablePage(api: client, onUnauthorized: () {}),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final card = find
        .ancestor(of: find.text('本地互斥课程'), matching: find.byType(InkWell))
        .first;
    final grid = find
        .ancestor(of: card, matching: find.byType(SingleChildScrollView))
        .first;
    final gridRect = tester.getRect(grid);
    final emptySlot = Offset(
      gridRect.left + 45 + (gridRect.width - 45) * 2.5 / 7,
      gridRect.top + 66 * 1.5,
    );
    final slotElement = find.byType(InkWell).evaluate().singleWhere((element) {
      final box = element.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return false;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      return rect.contains(emptySlot) && (rect.height - 66).abs() < 1;
    });
    final staleSlotTap = (slotElement.widget as InkWell).onTap!;
    final timetableState = tester.state(find.byType(TimetablePage)) as dynamic;
    final surface = find.byKey(const Key('timetable-detail-surface'));

    await tester.tapAt(emptySlot);
    await tester.pump();
    expect(find.byIcon(Icons.add), findsOneWidget);
    await tester.tap(card);
    await tester.pump();
    expect(surface, findsOneWidget);
    expect(find.byIcon(Icons.add), findsNothing); // Old selection is cleared.
    expect((slotElement.widget as InkWell).onTap, isNull);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 65));
    staleSlotTap(); // Simulate a callback captured before the modal was built.
    await timetableState.editCourse(weekday: 3, period: 2);
    await tester.pump();
    expect(find.byIcon(Icons.add), findsNothing);
    expect(find.byType(ManualCourseEditor), findsNothing);
    await tester.tapAt(emptySlot); // The modal consumes the physical tap.
    await tester.pump();
    expect(surface, findsOneWidget);
    staleSlotTap();
    await timetableState.editCourse(weekday: 3, period: 2);
    await tester.pump();
    expect(find.byType(ManualCourseEditor), findsNothing);
    await tester.pumpAndSettle();
    expect(surface, findsNothing);

    // Both the cached callback and a new physical double tap work only after
    // the detail route has really exited; no pre-armed slot survives it.
    expect(find.byIcon(Icons.add), findsNothing);
    await tester.tapAt(emptySlot);
    await tester.pump();
    expect(find.byIcon(Icons.add), findsOneWidget);
    await tester.tapAt(emptySlot);
    await tester.pumpAndSettle();
    expect(find.byType(ManualCourseEditor), findsOneWidget);
    Navigator.of(tester.element(find.byType(ManualCourseEditor))).pop();
    await tester.pumpAndSettle();

    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.add), findsNothing);
    staleSlotTap();
    await timetableState.editCourse(weekday: 3, period: 2);
    await tester.pump();
    expect(find.byType(ManualCourseEditor), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pump();
    staleSlotTap();
    await timetableState.editCourse(weekday: 3, period: 2);
    await tester.pump();
    expect(find.byType(ManualCourseEditor), findsNothing);
    await tester.pumpAndSettle();
    expect(surface, findsNothing);

    // Editing and deleting a manual course still follow their original path.
    await tester.tap(card);
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.byType(ManualCourseEditor), findsOneWidget);
    Navigator.of(tester.element(find.byType(ManualCourseEditor))).pop();
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('删除“本地互斥课程”'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dark timetable detail scrolls and keeps manual edit and delete',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=offline',
      });
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final monday = mondayOf(DateTime.now());
      final date = dateKey(monday);
      final start = DateTime(monday.year, monday.month, monday.day, 18, 20);
      final course = TimetableCourse(
        -1,
        '夜间课程',
        date,
        start,
        start.add(const Duration(minutes: 45)),
        '很长的教学楼和教室名称 A101',
        '任课教师',
        '1-16周',
        'LOCAL',
        -1,
        1,
        1,
        10,
        10,
      );
      final client = ApiClient(
        timetableCache: _FixtureTimetableCache(
          TimetableData(
            [TermInfo(1, 'term', '测试学期', date, true)],
            defaultPeriods,
            null,
            {
              1: [course],
            },
            DateTime.now(),
          ),
        ),
        localManualCourseStore: _MemoryLocalManualCourseStore(),
        localProfileStore: _MemoryLocalProfileStore(),
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery.withClampedTextScaling(
            minScaleFactor: 1.3,
            maxScaleFactor: 1.3,
            child: child!,
          ),
          home: Scaffold(
            body: TimetablePage(api: client, onUnauthorized: () {}),
          ),
        ),
      );
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.ensureVisible(find.text('夜间课程'));
      await tester.pumpAndSettle();
      final card = find
          .ancestor(of: find.text('夜间课程'), matching: find.byType(InkWell))
          .first;
      final sourceRect = tester.getRect(card);
      await tester.tap(find.text('夜间课程'));
      await tester.pump();
      expect(
        tester.getRect(find.byKey(const Key('timetable-detail-surface'))),
        sourceRect,
      );
      await tester.pumpAndSettle();
      final surface = find.byKey(const Key('timetable-detail-surface'));
      expect(tester.getRect(surface).height, lessThan(640));
      expect(find.byKey(const Key('timetable-detail-scroll')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('编辑'));
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(find.byType(ManualCourseEditor), findsOneWidget);
      Navigator.of(tester.element(find.byType(ManualCourseEditor))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('夜间课程'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('删除'));
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.textContaining('删除“夜间课程”'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('course detail measures long manual content on a small screen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final monday = mondayOf(DateTime.now());
    final date = dateKey(monday);
    final start = DateTime(monday.year, monday.month, monday.day, 18, 20);
    const name = '名称很长、需要在浮层内多次换行才能完整显示的手动添加课程';
    final course = TimetableCourse(
      -1,
      name,
      date,
      start,
      start.add(const Duration(minutes: 45)),
      '名称很长、需要换行显示的教学楼和教室 A101，位于校园另一侧的多媒体教学区域',
      '任课教师姓名较长需要换行，联合授课教师姓名也需要完整显示',
      '1-16周',
      'LOCAL',
      -1,
      1,
      1,
      10,
      10,
    );
    final client = ApiClient(
      timetableCache: _FixtureTimetableCache(
        TimetableData(
          [TermInfo(1, 'term', '测试学期', date, true)],
          defaultPeriods,
          null,
          {
            1: [course],
          },
          DateTime.now(),
        ),
      ),
      localManualCourseStore: _MemoryLocalManualCourseStore(),
      localProfileStore: _MemoryLocalProfileStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: 1.3,
          maxScaleFactor: 1.3,
          child: child!,
        ),
        home: Scaffold(
          body: TimetablePage(api: client, onUnauthorized: () {}),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.ensureVisible(find.text(name));
    await tester.pumpAndSettle();
    final card = find
        .ancestor(of: find.text(name), matching: find.byType(InkWell))
        .first;
    final sourceRect = tester.getRect(card);
    await tester.tap(find.text(name));
    await tester.pump();
    final surface = find.byKey(const Key('timetable-detail-surface'));
    expect(tester.getRect(surface), sourceRect);
    await tester.pumpAndSettle();
    final endRect = tester.getRect(surface);
    expect(endRect.height, lessThanOrEqualTo(520));
    expect(endRect.bottom, lessThanOrEqualTo(540));
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('timetable-detail-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    await tester.ensureVisible(find.text('删除'));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThan(0));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('删除“$name”'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('analysis snapshot stores grades, summary and history per term and isolates login', () async {
    SharedPreferences.setMockInitialValues({'session_cookie': 'session=first'});
    final directory = await Directory.systemTemp.createTemp(
      'hand-helper-analysis-cache-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final cache = AnalysisCache(directoryProvider: () async => directory);
    final client = ApiClient(
      analysisCache: cache,
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/auth/login') {
          return http.Response(
            '{"success":true,"data":{}}',
            200,
            headers: {'set-cookie': 'session=second; Path=/'},
          );
        }
        if (request.method == 'DELETE' &&
            request.url.path == '/api/v1/grades') {
          return http.Response('{"success":true,"data":{}}', 200);
        }
        final data = switch (request.url.path) {
          '/api/v1/terms' => [
            {
              'id': 4,
              'source_term_id': '2026-2027-1',
              'display_name': '本学期',
              'start_date': '2026-09-07',
              'is_current': true,
            },
            {
              'id': 5,
              'source_term_id': '2026-2027-2',
              'display_name': '下学期',
              'start_date': null,
              'is_current': false,
            },
          ],
          '/api/v1/profile' => {
            'display_name': '测试',
            'analysis_wallpaper_data_url': null,
          },
          '/api/v1/grades' =>
            request.url.queryParameters['term_id'] == '4'
                ? [
                    {
                      'id': 7,
                      'course_name': '机器学习',
                      'course_type': '必修',
                      'credits': 3.0,
                      'score': '92',
                      'final_exam_score': '90',
                      'usual_score': '94',
                      'grade_point': 4.0,
                      'exam_type': '考试',
                      'makeup_flag': false,
                      'retake_flag': false,
                    },
                  ]
                : <Object>[],
          '/api/v1/grades/summary' => {
            'earned_credits': 3.0,
            'average_score': 92.0,
            'gpa': 4.0,
            'failed_courses': 0,
            'gpa_note': null,
          },
          '/api/v1/grades/ai-analyses' =>
            request.url.queryParameters['term_id'] == '4'
                ? [
                    {
                      'id': 8,
                      'term_id': 4,
                      'content': '## 建议\n- 继续学习',
                      'provider': '测试服务',
                      'model': 'test-model',
                      'created_at': '2026-10-11T10:00:00',
                    },
                  ]
                : <Object>[],
          _ => throw StateError('Unexpected ${request.url}'),
        };
        return http.Response.bytes(
          utf8.encode(jsonEncode({'success': true, 'data': data})),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    final fresh = await client.analysisData();
    expect(fresh.gradesByTerm[4]?.single.name, '机器学习');
    expect(fresh.gradesByTerm[5], isEmpty);
    expect(fresh.summariesByTerm[4]?.gpa, 4.0);
    expect(fresh.historyByTerm[4]?.single.model, 'test-model');
    final offline = ApiClient(
      analysisCache: cache,
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    expect(
      (await offline.loadAnalysisSnapshot())?.gradesByTerm[4]?.single.score,
      '92',
    );
    await client.deleteGrades(4);
    final afterDelete = await offline.loadAnalysisSnapshot();
    expect(afterDelete?.gradesByTerm.containsKey(4), isFalse);
    expect(afterDelete?.summariesByTerm.containsKey(4), isFalse);
    expect(afterDelete?.historyByTerm.containsKey(4), isFalse);
    expect(afterDelete?.gradesByTerm.containsKey(5), isTrue);
    await client.login('another', 'password');
    expect(await offline.loadAnalysisSnapshot(), isNull);
  });

  testWidgets(
    'offline Analysis shows grades and history without enabling mutations',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=offline',
      });
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final data = AnalysisData(
        [const TermInfo(4, '2026-2027-1', '本学期', '2026-09-07', true)],
        {
          4: [
            const GradeRecord(
              7,
              '机器学习',
              '必修',
              3,
              '92',
              '90',
              '94',
              4,
              '考试',
              false,
              false,
            ),
          ],
        },
        {4: const GradeSummary(3, 92, 4, 0, null)},
        {
          4: [
            GradeAnalysis(
              8,
              4,
              '## 建议\n- 继续学习',
              '测试服务',
              'test-model',
              DateTime(2026, 10, 11),
              true,
            ),
          ],
        },
        null,
        DateTime.now(),
      );
      final client = ApiClient(
        analysisCache: _FixtureAnalysisCache(data),
        localProfileStore: _MemoryLocalProfileStore(),
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnalysisPage(api: client, onUnauthorized: () {}),
          ),
        ),
      );
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      expect(find.text('成绩概览'), findsOneWidget);
      expect(find.text('机器学习'), findsOneWidget);
      expect(find.textContaining('离线 · 上次更新'), findsNothing);
      expect(find.text('删除本学期成绩'), findsNothing);
      await tester.ensureVisible(find.text('生成 AI 成绩分析'));
      await tester.tap(find.text('生成 AI 成绩分析'));
      await tester.pump();
      expect(find.text('当前无法同步，暂不能生成分析。'), findsOneWidget);
      await tester.ensureVisible(find.text('机器学习'));
      await tester.tap(find.text('机器学习'));
      await tester.pumpAndSettle();
      expect(find.text('成绩详情'), findsOneWidget);
      await tester.tap(find.byKey(const Key('analysis-detail-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('历史分析'));
      await tester.pumpAndSettle();
      expect(find.text('test-model'), findsOneWidget);
      await tester.tap(find.text('test-model'));
      await tester.pumpAndSettle();
      expect(find.text('分析结果'), findsOneWidget);
      expect(find.text('建议'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '重新生成'))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'Analysis term picker scrolls on a short screen without overflow',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=offline',
      });
      tester.view.physicalSize = const Size(960, 1800);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final terms = List.generate(
        20,
        (index) => TermInfo(
          index + 1,
          'term-${index + 1}',
          '学期 ${index + 1}',
          null,
          index == 0,
        ),
      );
      final client = ApiClient(
        localProfileStore: _MemoryLocalProfileStore(),
        analysisCache: _FixtureAnalysisCache(
          AnalysisData(
            terms,
            const {},
            const {},
            const {},
            null,
            DateTime.now(),
          ),
        ),
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnalysisPage(api: client, onUnauthorized: () {}),
          ),
        ),
      );
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final termLabel = find.text('学期 1');
      final picker = find
          .ancestor(of: find.text('当前学期'), matching: find.byType(InkWell))
          .first;
      final arrow = find.descendant(
        of: picker,
        matching: find.byIcon(Icons.chevron_right),
      );
      expect(tester.getRect(picker).right - tester.getRect(arrow).right, 15);
      expect(tester.widget<Text>(termLabel).textAlign, TextAlign.right);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('当前学期'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('学期 20'),
        300,
        scrollable: find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('学期 20'));
      await tester.pumpAndSettle();
      expect(find.text('学期 20'), findsOneWidget);
    },
  );

  testWidgets('grade morph follows scrolled row, dock, back and haptics', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    tester.view.physicalSize = const Size(1080, 1800);
    tester.view.devicePixelRatio = 3;
    final hapticCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') hapticCalls.add(call);
          return null;
        });
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    final grades = [
      const GradeRecord(
        1,
        '第一门',
        '必修',
        2,
        '91',
        '90',
        '92',
        4,
        '考试',
        false,
        false,
      ),
      const GradeRecord(
        2,
        '第二门',
        '必修',
        2,
        '92',
        '90',
        '94',
        4,
        '考试',
        false,
        false,
      ),
      const GradeRecord(
        3,
        '第三门',
        '选修',
        3,
        '93',
        '90',
        '96',
        4,
        '考试',
        false,
        false,
      ),
    ];
    final client = ApiClient(
      cache: _EmptyTodayCache(),
      analysisCache: _FixtureAnalysisCache(
        AnalysisData(
          [const TermInfo(4, '2026-2027-1', '本学期', '2026-09-07', true)],
          {4: grades},
          {4: const GradeSummary(7, 92, 4, 0, null)},
          const {},
          null,
          DateTime.now(),
        ),
      ),
      localProfileStore: _MemoryLocalProfileStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Shell(
          api: client,
          onUnauthorized: () {},
          themeMode: ThemeMode.system,
          onThemeModeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tab-2')));
    await tester.pumpAndSettle();
    hapticCalls.clear(); // Tab selection has its own feedback.

    var expectedHaptics = 0;
    for (final (index, grade) in grades.indexed) {
      final row = find.byKey(Key('analysis-grade-row-${grade.id}'));
      await tester.scrollUntilVisible(
        row,
        200,
        scrollable: find
            .descendant(
              of: find.byType(AnalysisPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      final sourceTopLeft = tester.getTopLeft(row);
      final sourceSize = tester.getSize(row);
      final scrollable = tester.widget<ListView>(
        find
            .descendant(
              of: find.byType(AnalysisPage),
              matching: find.byType(ListView),
            )
            .first,
      );
      expect(scrollable.controller?.offset, greaterThan(0));
      await tester.tap(row);
      await tester.pump();
      await tester.pump();
      expectedHaptics++;
      expect(hapticCalls, hasLength(expectedHaptics));
      expect(
        find.byKey(const Key('analysis-transform-surface')),
        findsOneWidget,
      );
      final surface = find.byKey(const Key('analysis-transform-surface'));
      expect(tester.getTopLeft(surface), sourceTopLeft);
      expect(tester.getSize(surface), sourceSize);
      final clip = tester.widget<RepaintBoundary>(surface).child! as ClipRRect;
      final radius = clip.borderRadius as BorderRadius;
      expect(
        radius.topLeft,
        index == 0 ? const Radius.circular(18) : Radius.zero,
      );
      expect(
        radius.bottomLeft,
        index == grades.length - 1 ? const Radius.circular(18) : Radius.zero,
      );
      expect((clip.child! as Material).color?.a, 1);
      expect(tester.widget<Opacity>(row).opacity, 0);
      expect(
        tester
            .widget<AnimatedSlide>(find.byKey(const Key('settings-dock-slide')))
            .offset,
        const Offset(0, 1.25),
      );
      final staleTap = tester.widget<InkWell>(
        find.descendant(of: row, matching: find.byType(InkWell)),
      );
      staleTap.onTap!();
      expect(hapticCalls, hasLength(expectedHaptics));
      await tester.pumpAndSettle();
      expect(find.text('成绩详情'), findsOneWidget);
      expect(find.byKey(const Key('analysis-detail-scroll')), findsOneWidget);
      final beforeReturnTopLeft = tester.getTopLeft(row);
      if (index == 1) {
        await tester.binding.handlePopRoute();
        expect(hapticCalls, hasLength(expectedHaptics));
      } else {
        await tester.tap(find.byKey(const Key('analysis-detail-back')));
        expectedHaptics++;
        expect(hapticCalls, hasLength(expectedHaptics));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(tester.getSize(surface).width, lessThan(360));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('analysis-transform-surface')), findsNothing);
      expect(tester.getTopLeft(row), beforeReturnTopLeft);
      expect(
        tester
            .widget<AnimatedSlide>(find.byKey(const Key('settings-dock-slide')))
            .offset,
        Offset.zero,
      );
      expect(
        tester
            .widget<IgnorePointer>(
              find.byKey(const Key('settings-dock-interaction')),
            )
            .ignoring,
        isFalse,
      );
    }
    final lastRow = find.byKey(const Key('analysis-grade-row-3'));
    await tester.scrollUntilVisible(
      lastRow,
      200,
      scrollable: find
          .descendant(
            of: find.byType(AnalysisPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(lastRow);
    await tester.pumpAndSettle();
    final rootList = tester.widget<ListView>(
      find
          .descendant(
            of: find.byType(AnalysisPage),
            matching: find.byType(ListView),
          )
          .first,
    );
    rootList.controller!.jumpTo(
      0,
    ); // Simulate a list moving while detail is open.
    await tester.pump();
    await tester.tap(find.byKey(const Key('analysis-detail-back')));
    await tester.pump();
    expect(find.byKey(const Key('analysis-fade-close')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('analysis-transform-surface')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark grade detail stays opaque and scrolls on a short screen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    tester.view.physicalSize = const Size(960, 1440);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 72, bottom: 72);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPadding();
    });
    const longName = '一门名称较长、需要在小屏幕上换行显示的课程成绩详情';
    final client = ApiClient(
      analysisCache: _FixtureAnalysisCache(
        AnalysisData(
          [const TermInfo(4, '2026-2027-1', '本学期', '2026-09-07', true)],
          {
            4: [
              const GradeRecord(
                7,
                longName,
                '专业必修',
                3,
                '92',
                '90',
                '94',
                4,
                '考试',
                false,
                false,
              ),
            ],
          },
          {4: const GradeSummary(3, 92, 4, 0, null)},
          const {},
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==',
          DateTime.now(),
        ),
      ),
      localProfileStore: _MemoryLocalProfileStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: AnalysisPage(api: client, onUnauthorized: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const Key('analysis-grade-row-7'));
    await tester.scrollUntilVisible(row, 200);
    await tester.tap(row);
    await tester.pump();
    final surface = find.byKey(const Key('analysis-transform-surface'));
    Material material() =>
        (tester.widget<RepaintBoundary>(surface).child! as ClipRRect).child!
            as Material;
    expect(material().color?.a, 1);
    await tester.pump(const Duration(milliseconds: 120));
    expect(material().color?.a, 1);
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('analysis-detail-scroll')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    final detailScroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('analysis-detail-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(detailScroll.position.pixels, greaterThan(0));
    expect(find.text('补考 / 重修'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'grade detail header shares the body gutter at varied widths and text scales',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=offline',
      });
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      const shortName = '机器学习';
      const longName = '一门需要换行显示名称的专业课程成绩';
      final client = ApiClient(
        analysisCache: _FixtureAnalysisCache(
          AnalysisData(
            [const TermInfo(4, '2026-2027-1', '本学期', '2026-09-07', true)],
            {
              4: [
                const GradeRecord(
                  1,
                  shortName,
                  '必修',
                  3,
                  '92',
                  '90',
                  '94',
                  4,
                  '考试',
                  false,
                  false,
                ),
                const GradeRecord(
                  2,
                  longName,
                  '选修',
                  3,
                  '91',
                  '89',
                  '93',
                  4,
                  '考试',
                  false,
                  false,
                ),
              ],
            },
            {4: const GradeSummary(6, 91.5, 4, 0, null)},
            const {},
            null,
            DateTime.now(),
          ),
        ),
        localProfileStore: _MemoryLocalProfileStore(),
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      for (final (width, scale, dark, gradeId, name) in [
        (320.0, 1.6, false, 1, shortName),
        (360.0, 1.0, true, 1, shortName),
        (430.0, 1.3, false, 2, longName),
        (320.0, 1.6, true, 2, longName),
      ]) {
        tester.view.physicalSize = Size(width, 650);
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey('$width-$scale-$dark-$gradeId'),
            theme: dark ? ThemeData.dark() : ThemeData.light(),
            home: MediaQuery(
              data: MediaQueryData.fromView(tester.view)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: AnalysisPage(api: client, onUnauthorized: () {}),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final row = find.byKey(Key('analysis-grade-row-$gradeId'));
        await tester.scrollUntilVisible(row, 180);
        await Scrollable.ensureVisible(tester.element(row), alignment: .3);
        await tester.pumpAndSettle();
        await tester.tap(row);
        await tester.pumpAndSettle();
        final header = find.byKey(const Key('analysis-detail-header'));
        final body = find.byKey(const Key('analysis-detail-scroll'));
        final title = find.descendant(of: header, matching: find.text('成绩详情'));
        final courseTitle = find.descendant(
          of: header,
          matching: find.text(name),
        );
        final courseValue = find.descendant(
          of: body,
          matching: find.text(name),
        );
        final creditsValue = find.descendant(
          of: body,
          matching: find.text('3 / 4'),
        );
        final gutter = tester
            .getTopLeft(find.byKey(const Key('analysis-score-card')))
            .dx;
        expect(tester.getTopLeft(title).dx, closeTo(gutter, .1));
        expect(tester.getTopLeft(courseTitle).dx, closeTo(gutter, .1));
        expect(
          tester.getTopLeft(find.byKey(const Key('analysis-detail-back'))).dx,
          closeTo(gutter, .1),
        );
        final courseRow = find
            .ancestor(
              of: find.descendant(of: body, matching: find.text('课程名称')),
              matching: find.byType(Row),
            )
            .first;
        expect(tester.getTopLeft(courseRow).dx, closeTo(gutter, .1));
        expect(
          tester.getTopLeft(courseValue).dx,
          closeTo(tester.getTopLeft(creditsValue).dx, .1),
        );
        expect(tester.takeException(), isNull);
      }
    },
  );

  test(
    'Settings snapshot stores profile and time data without caching AI key',
    () async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=settings',
      });
      final directory = await Directory.systemTemp.createTemp(
        'hand-helper-settings-cache-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final cache = SettingsCache(directoryProvider: () async => directory);
      final localStore = LocalProfileStore(
        directoryProvider: () async => directory,
      );
      final client = ApiClient(
        settingsCache: cache,
        localProfileStore: localStore,
        client: MockClient((request) async {
          final data = switch (request.url.path) {
            '/api/v1/terms' => [
              {
                'id': 1,
                'source_term_id': '2026-2027-1',
                'display_name': '当前学期',
                'start_date': '2026-09-07',
                'is_current': true,
              },
            ],
            '/api/v1/settings/period-times' => [
              {'period_number': 1, 'start_time': '08:00', 'end_time': '08:45'},
            ],
            _ => throw StateError('Unexpected ${request.url}'),
          };
          return http.Response.bytes(
            utf8.encode(jsonEncode({'success': true, 'data': data})),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await client.saveLocalProfile({
        'display_name': '测试用户',
      }, fallback: const Profile('航的助手', null, null));
      final fresh = await client.settingsData();
      expect(fresh.profile.name, '测试用户');
      expect(fresh.terms.single.startDate, '2026-09-07');
      expect(fresh.periods.single.end, '08:45');
      final offline = ApiClient(
        settingsCache: cache,
        localProfileStore: localStore,
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      expect((await offline.loadSettingsSnapshot())?.profile.name, '测试用户');
      final raw = await File(
        '${directory.path}${Platform.pathSeparator}settings_snapshot_v1.json',
      ).readAsString();
      expect(raw.contains('api_key'), isFalse);
    },
  );

  test(
    'Settings reuses existing scoped snapshots before its first online visit',
    () async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=offline',
      });
      final now = DateTime.now();
      final timetable = TimetableData(
        [const TermInfo(1, '2026-2027-1', '当前学期', '2026-09-07', true)],
        [const PeriodInfo(1, '08:00', '08:45')],
        'data:image/jpeg;base64,background',
        const {},
        now,
      );
      final client = ApiClient(
        settingsCache: _EmptySettingsCache(),
        cache: _FixtureTodayCache(
          TodaySnapshot(
            const TodayData(
              Profile('本地姓名', 'data:image/png;base64,avatar', null),
              [],
              [],
            ),
            dateKey(now),
            now,
          ),
        ),
        timetableCache: _FixtureTimetableCache(timetable),
        localManualCourseStore: _MemoryLocalManualCourseStore(),
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      final snapshot = await client.loadSettingsSnapshot();
      expect(snapshot?.profile.name, '本地姓名');
      expect(snapshot?.terms.single.name, '当前学期');
      expect(snapshot?.periods.single.end, '08:45');
      expect(snapshot?.profile.timetableBackground, timetable.background);
    },
  );

  test(
    'Settings server mutations and file upload keep API paths and Origin',
    () async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=settings',
      });
      final visited = <String>[];
      final client = ApiClient(
        client: MockClient((request) async {
          visited.add('${request.method} ${request.url.path}');
          expect(request.headers['Origin'], request.url.origin);
          final data = switch (request.url.path) {
            '/api/v1/terms/4/start-date' => {'sessions_generated': 10},
            '/api/v1/settings/period-times/1' => {'sessions_generated': 10},
            '/api/v1/ai/settings' => {
              'configured': true,
              'provider': 'APIKEY.FAN',
              'base_url': 'https://api.apikey.fan/v1',
              'model': 'model-a',
              'api_key_hint': '****',
              'available_models': ['model-a'],
              'models_synced_at': null,
              'requires_apikey_fan_migration': false,
            },
            '/api/v1/timetable/import-file' => {
              'term_id': '2026-2027-1',
              'courses_imported': 3,
              'sessions_generated': 30,
            },
            '/api/v1/grades/import-confirm' => {
              'term_id': 4,
              'source_term_id': '2026-2027-1',
              'grades_imported': 1,
            },
            _ => throw StateError('Unexpected ${request.url}'),
          };
          if (request.url.path == '/api/v1/timetable/import-file') {
            expect(
              request.headers['content-type'],
              contains('multipart/form-data'),
            );
            expect(utf8.decode(request.bodyBytes), contains('sample.xls'));
          }
          return http.Response.bytes(
            utf8.encode(jsonEncode({'success': true, 'data': data})),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await client.updateTermStart(4, '2026-09-07');
      await client.updatePeriod(1, '08:00', '08:45');
      expect(
        (await client.saveAiSettings(
          'APIKEY.FAN',
          'https://api.apikey.fan/v1',
          'model-a',
          'secret-key',
        )).configured,
        isTrue,
      );
      expect(
        (await client.importTimetable(
          'sample.xls',
          Uint8List.fromList([1, 2, 3]),
        ))['courses_imported'],
        3,
      );
      expect(
        (await client.confirmGrades({
          'source_term_id': '2026-2027-1',
          'grades': [],
        }))['grades_imported'],
        1,
      );
      expect(visited, [
        'PUT /api/v1/terms/4/start-date',
        'PUT /api/v1/settings/period-times/1',
        'PUT /api/v1/ai/settings',
        'POST /api/v1/timetable/import-file',
        'POST /api/v1/grades/import-confirm',
      ]);
    },
  );

  test(
    'local profile stays on device, is account-isolated and survives relogin',
    () async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=first',
        'local_schedule_owner_v1': 'user:first',
      });
      final directory = await Directory.systemTemp.createTemp(
        'hand-helper-local-profile-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = LocalProfileStore(directoryProvider: () async => directory);
      final requests = <String>[];
      final client = ApiClient(
        localProfileStore: store,
        localManualCourseStore: LocalManualCourseStore(
          directoryProvider: () async => directory,
        ),
        cache: TodayCache(directoryProvider: () async => directory),
        client: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          if (request.url.path == '/api/v1/auth/login') {
            return http.Response(
              '{"success":true,"data":{}}',
              200,
              headers: {'set-cookie': 'session=second; Path=/'},
            );
          }
          final data = switch (request.url.path) {
            '/api/v1/timetable' => <Object>[],
            '/api/v1/custom-schedules' => <Object>[],
            _ => <Object>[],
          };
          return http.Response.bytes(
            utf8.encode(jsonEncode({'success': true, 'data': data})),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      expect((await client.today(DateTime.now())).profile.name, '航的助手');
      final saved = await client.saveLocalProfile({
        'display_name': '本机姓名',
        'avatar_data_url': 'data:image/jpeg;base64,avatar',
        'home_wallpaper_data_url': 'data:image/jpeg;base64,home',
        'timetable_background_data_url': 'data:image/jpeg;base64,timetable',
        'analysis_wallpaper_data_url': 'data:image/jpeg;base64,analysis',
        'settings_wallpaper_data_url': 'data:image/jpeg;base64,settings',
      }, fallback: const Profile('航的助手', null, null));
      expect(saved.name, '本机姓名');
      expect((await client.today(DateTime.now())).profile.name, '本机姓名');
      expect(
        (await client.loadTodaySnapshot())?.data.profile.wallpaper,
        'data:image/jpeg;base64,home',
      );
      expect(await client.localProfile(), isNotNull);
      expect(requests.where((path) => path == 'PUT /api/v1/profile'), isEmpty);
      expect(requests.where((path) => path == 'GET /api/v1/profile'), isEmpty);
      final offline = ApiClient(
        localProfileStore: store,
        timetableCache: _FixtureTimetableCache(
          TimetableData(const [], const [], null, const {}, DateTime.now()),
        ),
        localManualCourseStore: _MemoryLocalManualCourseStore(),
        analysisCache: _FixtureAnalysisCache(
          AnalysisData(
            const [],
            const {},
            const {},
            const {},
            null,
            DateTime.now(),
          ),
        ),
        settingsCache: _FixtureSettingsCache(
          SettingsData(
            const Profile('网页版姓名', null, null),
            const [],
            const [],
            DateTime.now(),
          ),
        ),
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      expect(
        (await offline.loadTimetableSnapshot())?.background,
        'data:image/jpeg;base64,timetable',
      );
      expect(
        (await offline.loadAnalysisSnapshot())?.background,
        'data:image/jpeg;base64,analysis',
      );
      expect(
        (await offline.loadSettingsSnapshot())?.profile.settingsWallpaper,
        'data:image/jpeg;base64,settings',
      );
      final timetable = await client.timetable();
      final analysis = await client.analysisData();
      final settings = await client.settingsData();
      expect(timetable.background, 'data:image/jpeg;base64,timetable');
      expect(analysis.background, 'data:image/jpeg;base64,analysis');
      expect(
        settings.profile.settingsWallpaper,
        'data:image/jpeg;base64,settings',
      );
      expect(requests.where((path) => path == 'GET /api/v1/profile'), isEmpty);
      await client.login('second', 'password');
      expect(await client.localProfile(), isNull);
      await client.saveLocalProfile({
        'display_name': '第二次本机名',
      }, fallback: const Profile('航的助手', null, null));
      await client.logout();
      expect(await client.localProfile(), isNull);
      await client.login('first', 'password');
      expect((await client.localProfile())?.name, '本机姓名');
      expect(
        (await client.localProfile())?.timetableBackground,
        'data:image/jpeg;base64,timetable',
      );
    },
  );

  test(
    'legacy session-scoped wallpapers migrate to the stable local account',
    () async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=legacy',
        'today_cache_scope': 'legacy-session',
        'local_schedule_owner_v1': 'user:owner',
      });
      final directory = await Directory.systemTemp.createTemp(
        'hand-helper-profile-migration-',
      );
      addTearDown(() => directory.delete(recursive: true));
      await File(
        '${directory.path}${Platform.pathSeparator}local_profile_v1.json',
      ).writeAsString(
        jsonEncode({
          'version': 1,
          'base_url': apiBaseUrl,
          'scope': 'legacy-session',
          'profile': const Profile(
            '旧本机资料',
            null,
            'data:image/jpeg;base64,home',
          ).toJson(),
        }),
      );
      final client = ApiClient(
        localProfileStore: LocalProfileStore(
          directoryProvider: () async => directory,
        ),
        client: MockClient((request) async {
          expect(request.url.path, '/api/v1/auth/login');
          return http.Response(
            '{"success":true,"data":{}}',
            200,
            headers: {'set-cookie': 'session=next; Path=/'},
          );
        }),
      );
      expect(
        (await client.localProfile())?.wallpaper,
        'data:image/jpeg;base64,home',
      );
      await client.login('owner', 'password');
      expect((await client.localProfile())?.name, '旧本机资料');
      await client.login('another', 'password');
      expect(await client.localProfile(), isNull);
      await client.login('owner', 'password');
      expect(
        (await client.localProfile())?.wallpaper,
        'data:image/jpeg;base64,home',
      );
    },
  );

  testWidgets('saved local wallpaper updates an already visited timetable tab', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
      'local_schedule_owner_v1': 'user:owner',
    });
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const image =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==';
    const profile = Profile('本机用户', null, null, timetableBackground: image);
    final store = _MemoryLocalProfileStore()..profile = profile;
    final client = ApiClient(
      localProfileStore: store,
      cache: _EmptyTodayCache(),
      timetableCache: _FixtureTimetableCache(
        TimetableData(
          [const TermInfo(1, 'term', '当前学期', '2026-09-07', true)],
          defaultPeriods,
          image,
          const {},
          DateTime.now(),
        ),
      ),
      localManualCourseStore: _MemoryLocalManualCourseStore(),
      settingsCache: _FixtureSettingsCache(
        SettingsData(profile, const [], const [], DateTime.now()),
      ),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Shell(
          api: client,
          onUnauthorized: () {},
          themeMode: ThemeMode.system,
          onThemeModeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tab-1')));
    await tester.pumpAndSettle();
    final backdrop = find.byKey(const Key('timetable-fixed-backdrop'));
    expect(
      find.descendant(of: backdrop, matching: find.byType(Image)),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('tab-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('个性化设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('页面壁纸'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课表背景'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除图片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存更改'));
    await tester.pumpAndSettle();
    expect(store.profile?.timetableBackground, isNull);
    await tester.tap(find.widgetWithText(TextButton, '设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tab-1')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: backdrop, matching: find.byType(Image)),
      findsNothing,
    );
    expect(
      find.descendant(of: backdrop, matching: find.byType(CustomPaint)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Today and Analysis react to local wallpaper changes without reload',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=offline',
      });
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const image =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==';
      final changes = ValueNotifier<Profile?>(null);
      addTearDown(changes.dispose);
      final client = ApiClient(
        cache: _EmptyTodayCache(),
        analysisCache: _FixtureAnalysisCache(
          AnalysisData(
            const [],
            const {},
            const {},
            const {},
            null,
            DateTime.now(),
          ),
        ),
        localProfileStore: _MemoryLocalProfileStore()
          ..profile = const Profile('本机用户', null, null),
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TodayPage(
              api: client,
              onUnauthorized: () {},
              onProfile: (_) {},
              localProfileChanges: changes,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ShaderMask), findsNothing);
      changes.value = const Profile('本机用户', null, image);
      await tester.pump();
      expect(find.byType(ShaderMask), findsOneWidget);
      changes.value = const Profile('本机用户', null, null);
      await tester.pump();
      expect(find.byType(ShaderMask), findsNothing);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnalysisPage(
              api: client,
              onUnauthorized: () {},
              localProfileChanges: changes,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      changes.value = const Profile(
        '本机用户',
        null,
        null,
        analysisWallpaper: image,
      );
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline Settings keeps navigation and local appearance without writes',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=offline',
      });
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final snapshot = SettingsData(
        const Profile('测试用户', null, null),
        [const TermInfo(1, '2026-2027-1', '当前学期', '2026-09-07', true)],
        [const PeriodInfo(1, '08:00', '08:45')],
        DateTime.now(),
      );
      ThemeMode? changed;
      Profile? savedProfile;
      final store = _MemoryLocalProfileStore();
      final client = ApiClient(
        settingsCache: _FixtureSettingsCache(snapshot),
        localProfileStore: store,
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsPage(
              api: client,
              onUnauthorized: () {},
              onSignedOut: () {},
              themeMode: ThemeMode.system,
              onThemeModeChanged: (value) => changed = value,
              onProfileChanged: (value) => savedProfile = value,
            ),
          ),
        ),
      );
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      expect(find.text('账号安全'), findsOneWidget);
      expect(find.text('个性化设置'), findsOneWidget);
      expect(find.textContaining('离线'), findsNothing);
      expect(find.textContaining('无法连接服务器'), findsNothing);
      await tester.tap(find.text('个性化设置'));
      await tester.pumpAndSettle();
      expect(find.text('外观模式'), findsOneWidget);
      await tester.ensureVisible(find.text('深色'));
      await tester.tap(find.text('深色'));
      expect(changed, ThemeMode.dark);
      expect(find.text('保存更改'), findsOneWidget);
      await tester.tap(find.text('显示姓名'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).last, '离线本机名');
      await tester.tap(find.text('完成编辑'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存更改'));
      await tester.tap(find.text('保存更改'));
      await tester.pumpAndSettle();
      expect(savedProfile?.name, '离线本机名');
      expect(store.profile?.name, '离线本机名');
      expect(find.text('已保存到此设备。'), findsOneWidget);
    },
  );

  testWidgets('About header uses the app logo and installed version', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    PackageInfo.setMockInitialValues(
      appName: '航的助手',
      packageName: 'com.zhangzh.hangassistant.flutter',
      version: '9.8.7',
      buildNumber: '42',
      buildSignature: '',
    );
    final client = ApiClient(
      settingsCache: _FixtureSettingsCache(
        SettingsData(
          const Profile('测试用户', null, null),
          const [],
          const [],
          DateTime.now(),
        ),
      ),
      localProfileStore: _MemoryLocalProfileStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            api: client,
            onUnauthorized: () {},
            onSignedOut: () {},
            themeMode: ThemeMode.system,
            onThemeModeChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于助手'));
    await tester.pumpAndSettle();
    final hero = find.byKey(const Key('about-brand-hero'));
    expect(hero, findsOneWidget);
    expect(
      find.descendant(
        of: hero,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Image &&
              widget.image is AssetImage &&
              (widget.image as AssetImage).assetName ==
                  'assets/icon/login_icon.png',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: hero, matching: find.text('Hand Helper')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('about-version')), findsOneWidget);
    expect(find.text('v9.8.7'), findsOneWidget);
    expect(find.text('Flutter 0.1.0'), findsNothing);
    expect(find.text('应用说明'), findsOneWidget);
    expect(find.textContaining('为个人使用场景设计的课程表与成绩分析助手'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings wallpaper stays stored but is not painted', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    const image =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg==';
    final client = ApiClient(
      settingsCache: _FixtureSettingsCache(
        SettingsData(
          const Profile('测试用户', null, null, settingsWallpaper: image),
          const [],
          const [],
          DateTime.now(),
        ),
      ),
      localProfileStore: _MemoryLocalProfileStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            api: client,
            onUnauthorized: () {},
            onSignedOut: () {},
            themeMode: ThemeMode.system,
            onThemeModeChanged: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('个性化设置'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('设置页暂不显示壁纸'), findsOneWidget);
    await tester.tap(find.text('显示姓名'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 1000);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(find.text('完成编辑'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Settings detail hides the primary dock and restores it on return',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=offline',
      });
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = ApiClient(
        cache: _EmptyTodayCache(),
        settingsCache: _FixtureSettingsCache(
          SettingsData(
            const Profile('测试用户', null, null),
            const [],
            const [],
            DateTime.now(),
          ),
        ),
        localProfileStore: _MemoryLocalProfileStore(),
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Shell(
            api: client,
            onUnauthorized: () {},
            themeMode: ThemeMode.system,
            onThemeModeChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('primary-tab-bar')), findsOneWidget);
      final tabElement = tester.element(
        find.byKey(const Key('primary-tab-bar')),
      );
      await tester.tap(find.byKey(const Key('tab-3')));
      await tester.pumpAndSettle();
      expect(
        tester.element(find.byKey(const Key('primary-tab-bar'))),
        same(tabElement),
      );
      await tester.tap(find.text('个性化设置'));
      await tester.pump();
      expect(find.byKey(const Key('settings-source-layer')), findsOneWidget);
      final initialSurface = tester.widget<RepaintBoundary>(
        find.byKey(const Key('settings-transform-surface')),
      );
      final initialRadius =
          (initialSurface.child! as ClipRRect).borderRadius as BorderRadius;
      expect(initialRadius.topLeft, Radius.zero);
      expect(initialRadius.bottomLeft, const Radius.circular(18));
      expect(
        ((initialSurface.child! as ClipRRect).child! as Material).color?.a,
        1,
      );
      expect(
        find.byKey(const Key('settings-detail-header-layer')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings-detail-body-layer')),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump(const Duration(milliseconds: 120));
      final headerOpacity = tester
          .widget<Opacity>(
            find.byKey(const Key('settings-detail-header-layer')),
          )
          .opacity;
      final bodyOpacity = tester
          .widget<Opacity>(find.byKey(const Key('settings-detail-body-layer')))
          .opacity;
      expect(headerOpacity, greaterThan(bodyOpacity));
      expect(
        tester
            .widget<Opacity>(find.byKey(const Key('settings-source-layer')))
            .opacity,
        0,
      );
      final movingSurface = tester.widget<RepaintBoundary>(
        find.byKey(const Key('settings-transform-surface')),
      );
      expect(
        ((movingSurface.child! as ClipRRect).child! as Material).color?.a,
        1,
      );
      expect(find.byKey(const Key('settings-content-root')), findsOneWidget);
      expect(
        find.byKey(const Key('settings-content-personal')),
        findsOneWidget,
      );
      final transitioningWidth = tester
          .getSize(find.byKey(const Key('settings-transform-surface')))
          .width;
      expect(transitioningWidth, greaterThan(0));
      expect(transitioningWidth, lessThan(360));
      expect(find.byKey(const Key('primary-tab-bar')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-content-root')), findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(const Key('settings-transform-surface')))
            .width,
        360,
      );
      expect(find.byKey(const Key('primary-tab-bar')), findsOneWidget);
      expect(
        tester
            .widget<AnimatedSlide>(find.byKey(const Key('settings-dock-slide')))
            .offset,
        const Offset(0, 1.25),
      );
      await tester.tap(find.byKey(const Key('settings-detail-back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        find.byKey(const Key('settings-content-personal')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const Key('settings-detail-body-layer')),
            )
            .opacity,
        greaterThan(.5),
      );
      expect(find.byKey(const Key('settings-content-root')), findsOneWidget);
      expect(
        tester
            .widget<AnimatedSlide>(find.byKey(const Key('settings-dock-slide')))
            .offset,
        const Offset(0, 1.25),
      );
      await tester.pump(const Duration(milliseconds: 90));
      expect(
        tester
            .widget<AnimatedSlide>(find.byKey(const Key('settings-dock-slide')))
            .offset,
        Offset.zero,
      );
      expect(
        tester
            .widget<IgnorePointer>(
              find.byKey(const Key('settings-dock-interaction')),
            )
            .ignoring,
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-content-personal')), findsNothing);
      expect(find.byKey(const Key('primary-tab-bar')), findsOneWidget);
      expect(
        tester
            .widget<AnimatedSlide>(find.byKey(const Key('settings-dock-slide')))
            .offset,
        Offset.zero,
      );
      expect(
        tester
            .widget<IgnorePointer>(
              find.byKey(const Key('settings-dock-interaction')),
            )
            .ignoring,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('container morph preserves geometry and content handoff', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    expect(
      ContainerMorphTransition.duration,
      const Duration(milliseconds: 300),
    );

    Future<void> showFrame(double progress, {bool closing = false}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  ContainerMorphTransition(
                    progress: progress,
                    isClosing: closing,
                    detailInteractive: progress == 1 && !closing,
                    startRect: const Rect.fromLTWH(20, 100, 200, 72),
                    endSize: const Size(360, 800),
                    startBorderRadius: BorderRadius.circular(18),
                    closedColor: const Color(0xfffefefe),
                    openColor: const Color(0xfff4f7fb),
                    sourceContent: const Text('入口'),
                    detailHeader: const SizedBox(height: 80, child: Text('标题')),
                    detailBody: const Text('正文'),
                    surfaceKey: const Key('morph-surface'),
                    sourceLayerKey: const Key('morph-source'),
                    detailHeaderLayerKey: const Key('morph-header'),
                    detailBodyLayerKey: const Key('morph-body'),
                  ),
                ],
              ),
            ),
          ),
        );

    await showFrame(0);
    final surface = find.byKey(const Key('morph-surface'));
    expect(tester.getTopLeft(surface), const Offset(20, 100));
    expect(tester.getSize(surface), const Size(200, 72));
    expect(
      (tester.widget<RepaintBoundary>(surface).child! as ClipRRect)
          .borderRadius,
      BorderRadius.circular(18),
    );
    expect(
      tester.widget<Opacity>(find.byKey(const Key('morph-source'))).opacity,
      1,
    );
    expect(
      tester.widget<Opacity>(find.byKey(const Key('morph-header'))).opacity,
      0,
    );
    expect(
      tester.widget<Opacity>(find.byKey(const Key('morph-body'))).opacity,
      0,
    );

    await showFrame(.4);
    expect(tester.getSize(surface).width, greaterThan(200));
    expect(tester.getSize(surface).width, lessThan(360));
    expect(
      tester.widget<Opacity>(find.byKey(const Key('morph-source'))).opacity,
      0,
    );
    expect(
      tester.widget<Opacity>(find.byKey(const Key('morph-header'))).opacity,
      greaterThan(
        tester.widget<Opacity>(find.byKey(const Key('morph-body'))).opacity,
      ),
    );

    await showFrame(1);
    expect(tester.getTopLeft(surface), Offset.zero);
    expect(tester.getSize(surface), const Size(360, 800));
    expect(
      find.descendant(of: surface, matching: find.byType(SafeArea)),
      findsOneWidget,
    );
    expect(
      (tester.widget<RepaintBoundary>(surface).child! as ClipRRect)
          .borderRadius,
      BorderRadius.zero,
    );
    expect(
      tester.widget<Opacity>(find.byKey(const Key('morph-body'))).opacity,
      1,
    );

    await showFrame(.4, closing: true);
    expect(
      tester.widget<Opacity>(find.byKey(const Key('morph-source'))).opacity,
      0,
    );
    expect(
      tester.widget<Opacity>(find.byKey(const Key('morph-body'))).opacity,
      greaterThan(0),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('container morph supports a rounded inset destination', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              ContainerMorphTransition(
                progress: 1,
                isClosing: false,
                detailInteractive: true,
                startRect: const Rect.fromLTWH(20, 100, 50, 70),
                endSize: const Size(300, 400),
                endRect: const Rect.fromLTWH(30, 180, 300, 400),
                startBorderRadius: BorderRadius.circular(9),
                endBorderRadius: BorderRadius.circular(22),
                detailSafeArea: false,
                closedColor: Colors.blue,
                openColor: Colors.white,
                sourceContent: const Text('课程'),
                detailHeader: const Text('课程详情'),
                detailBody: const Text('正文'),
                surfaceKey: const Key('inset-morph'),
              ),
            ],
          ),
        ),
      ),
    );
    final surface = find.byKey(const Key('inset-morph'));
    expect(tester.getTopLeft(surface), const Offset(30, 180));
    expect(tester.getSize(surface), const Size(300, 400));
    expect(
      (tester.widget<RepaintBoundary>(surface).child! as ClipRRect)
          .borderRadius,
      BorderRadius.circular(22),
    );
    expect(
      find.descendant(of: surface, matching: find.byType(SafeArea)),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('course text handoff keeps default phases unchanged', (
    tester,
  ) async {
    Future<({List<double> opacity, Rect rect, BorderRadius radius})> frame(
      double progress, {
      bool courseTiming = false,
      bool closing = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                ContainerMorphTransition(
                  progress: progress,
                  isClosing: closing,
                  detailInteractive: false,
                  startRect: const Rect.fromLTWH(20, 100, 60, 90),
                  endSize: const Size(300, 400),
                  endRect: const Rect.fromLTWH(30, 180, 300, 400),
                  startBorderRadius: BorderRadius.circular(9),
                  endBorderRadius: BorderRadius.circular(22),
                  closedColor: Colors.blue,
                  openColor: Colors.white,
                  sourceContent: const Text('课程'),
                  detailHeader: const Text('课程详情'),
                  detailBody: const Text('正文'),
                  courseDetailTextHandoff: courseTiming,
                  surfaceKey: const Key('handoff-surface'),
                  sourceLayerKey: const Key('handoff-source'),
                  detailHeaderLayerKey: const Key('handoff-header'),
                  detailBodyLayerKey: const Key('handoff-body'),
                ),
              ],
            ),
          ),
        ),
      );
      final surface = find.byKey(const Key('handoff-surface'));
      return (
        opacity: [
          tester
              .widget<Opacity>(find.byKey(const Key('handoff-source')))
              .opacity,
          tester
              .widget<Opacity>(find.byKey(const Key('handoff-header')))
              .opacity,
          tester.widget<Opacity>(find.byKey(const Key('handoff-body'))).opacity,
        ],
        rect: tester.getRect(surface),
        radius:
            (tester.widget<RepaintBoundary>(surface).child! as ClipRRect)
                    .borderRadius
                as BorderRadius,
      );
    }

    final earlyOriginal = await frame(.27);
    final earlyAdjusted = await frame(.27, courseTiming: true);
    expect(earlyOriginal.opacity[1], 0);
    expect(earlyAdjusted.opacity[1], greaterThan(0));

    final original = await frame(.32);
    final adjusted = await frame(.32, courseTiming: true);
    expect(original.opacity[0], 0);
    expect(original.opacity[2], 0);
    expect(adjusted.opacity[0], greaterThan(0));
    expect(adjusted.opacity[1], greaterThan(original.opacity[1]));
    expect(adjusted.opacity[2], greaterThan(0));
    expect(adjusted.rect, original.rect);
    expect(adjusted.radius, original.radius);

    final later = await frame(.34, courseTiming: true);
    expect(later.opacity[0], 0); // Before the viewport clip starts revealing.
    expect(later.opacity[1], greaterThan(0));
    expect(later.opacity[2], greaterThan(0));
    final reversed = await frame(.32, courseTiming: true, closing: true);
    expect(reversed.opacity, adjusted.opacity);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings navigation haptics follow accepted taps only', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    final hapticCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') hapticCalls.add(call);
          return null;
        });
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    final client = ApiClient(
      localProfileStore: _MemoryLocalProfileStore(),
      settingsCache: _FixtureSettingsCache(
        SettingsData(
          const Profile('测试用户', null, null),
          const [],
          const [],
          DateTime.now(),
        ),
      ),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            api: client,
            onUnauthorized: () {},
            onSignedOut: () {},
            themeMode: ThemeMode.system,
            onThemeModeChanged: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final entry = tester.widget<ListTile>(
      find.ancestor(of: find.text('个性化设置'), matching: find.byType(ListTile)),
    );
    await tester.tap(find.text('个性化设置'));
    expect(hapticCalls.map((call) => call.arguments), [
      'HapticFeedbackType.lightImpact',
    ]);
    entry.onTap!(); // A stale or repeated tap during expansion is ignored.
    expect(hapticCalls, hasLength(1));
    await tester.pumpAndSettle();
    final back = tester.widget<TextButton>(
      find.byKey(const Key('settings-detail-back')),
    );
    await tester.tap(find.byKey(const Key('settings-detail-back')));
    expect(hapticCalls, hasLength(2));
    back.onPressed!(); // A second tap during collapse is ignored.
    expect(hapticCalls, hasLength(2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于助手'));
    expect(hapticCalls, hasLength(3));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(hapticCalls, hasLength(3));
    expect(
      hapticCalls.map((call) => call.arguments),
      everyElement('HapticFeedbackType.lightImpact'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark settings transition surface stays opaque', (tester) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = ApiClient(
      settingsCache: _FixtureSettingsCache(
        SettingsData(
          const Profile('测试用户', null, null),
          const [],
          const [],
          DateTime.now(),
        ),
      ),
      localProfileStore: _MemoryLocalProfileStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: SettingsPage(
            api: client,
            onUnauthorized: () {},
            onSignedOut: () {},
            themeMode: ThemeMode.dark,
            onThemeModeChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('时间设置'));
    await tester.pump();
    Material surfaceMaterial() {
      final boundary = tester.widget<RepaintBoundary>(
        find.byKey(const Key('settings-transform-surface')),
      );
      return (boundary.child! as ClipRRect).child! as Material;
    }

    expect(surfaceMaterial().color?.a, 1);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
    expect(surfaceMaterial().color?.a, 1);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('dock supports drag selection and dark appearance', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          bottomNavigationBar: StatefulBuilder(
            builder: (context, update) => FloatingTabBar(
              selectedIndex: selected,
              onSelected: (index) => update(() => selected = index),
            ),
          ),
        ),
      ),
    );
    final surface = find.byKey(const Key('tab-bar-surface'));
    expect(tester.getSize(surface), const Size(296, 56));
    expect(
      tester.getCenter(surface).dx,
      tester.getSize(find.byType(Scaffold)).width / 2,
    );
    for (var index = 0; index < 4; index++) {
      expect(tester.getSize(find.byKey(Key('tab-$index'))).height, 48);
      expect(tester.getSize(find.byKey(Key('tab-$index'))).width, 72);
    }
    expect(find.text('今日'), findsNothing);
    expect(find.text('课程表'), findsNothing);
    expect(find.text('分析'), findsNothing);
    expect(find.text('设置'), findsNothing);
    expect(
      tester.widget<Semantics>(find.byKey(const Key('tab-0'))).properties.label,
      '今日',
    );
    final start = tester.getCenter(find.byKey(const Key('tab-0')));
    final target = tester.getCenter(find.byKey(const Key('tab-2')));
    await tester.dragFrom(start, target - start);
    await tester.pumpAndSettle();
    expect(selected, 2);
    expect(
      tester
          .widget<Semantics>(find.byKey(const Key('tab-2')))
          .properties
          .selected,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('dock fits narrow screens without shrinking touch targets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: FloatingTabBar(
            selectedIndex: 0,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    final surface = find.byKey(const Key('tab-bar-surface'));
    expect(tester.getSize(surface).width, 256);
    expect(tester.getCenter(surface).dx, 140);
    for (var index = 0; index < 4; index++) {
      expect(tester.getSize(find.byKey(Key('tab-$index'))).width, 62);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('appearance selector fills its card and remains tap-only', (
    tester,
  ) async {
    var selected = ThemeMode.system;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: StatefulBuilder(
                  builder: (context, update) => AppearanceModeSelector(
                    selected: selected,
                    onSelected: (mode) => update(() => selected = mode),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final surface = find.byKey(const Key('appearance-mode-surface'));
    expect(tester.getSize(surface), const Size(336, 56));
    expect(
      tester.getCenter(surface).dx,
      tester.getSize(find.byType(Scaffold)).width / 2,
    );
    for (var index = 0; index < 3; index++) {
      expect(
        tester.getSize(find.byKey(Key('appearance-mode-$index'))).height,
        48,
      );
    }
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(selected, ThemeMode.dark);
    expect(
      tester
          .widget<Semantics>(find.byKey(const Key('appearance-mode-1')))
          .properties
          .selected,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  test(
    'iOS avatar channel sends a full-color circular image and reset',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      const channel = MethodChannel('hand_helper/native_tab');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(channel, null);
      });
      final source = img.Image(width: 4, height: 4, numChannels: 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          source.setPixelRgba(x, y, 220, 40, 60, 255);
        }
      }
      final dataUrl =
          'data:image/png;base64,${base64Encode(img.encodePng(source))}';
      final prepared = await NativeTabBridge.prepareAvatar(dataUrl);
      expect(prepared, isNotNull);
      final image = img.decodePng(prepared!)!;
      expect(image.width, 96);
      expect(image.height, 96);
      expect(image.getPixel(0, 0).a, 0);
      expect(image.getPixel(48, 48).r, greaterThan(150));
      expect(image.getPixel(48, 48).g, lessThan(100));
      NativeTabBridge.setAvatar(prepared);
      NativeTabBridge.setAvatar(null);
      await Future<void>.delayed(Duration.zero);
      final avatarCalls = calls
          .where((call) => call.method == 'setAvatar')
          .toList();
      expect(avatarCalls, hasLength(2));
      expect(avatarCalls.first.arguments, isA<Uint8List>());
      expect(avatarCalls.last.arguments, isNull);
      expect(await NativeTabBridge.prepareAvatar('invalid'), isNull);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      NativeTabBridge.setAvatar(prepared);
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call.method == 'setAvatar'), hasLength(2));
    },
  );

  test('iOS avatar preserves a transparent circle from an RGB JPEG', () async {
    final source = img.Image(width: 160, height: 96, numChannels: 3);
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        source.setPixelRgb(x, y, 210, 50, 85);
      }
    }
    final dataUrl =
        'data:image/jpeg;base64,${base64Encode(img.encodeJpg(source))}';
    final prepared = await NativeTabBridge.prepareAvatar(dataUrl);
    expect(prepared, isNotNull);
    // PNG must retain an alpha channel even though the source JPEG has none.
    final image = img.decodePng(prepared!)!;
    expect(image.width, 96);
    expect(image.height, 96);
    expect(image.hasAlpha, isTrue);
    var minX = image.width;
    var minY = image.height;
    var maxX = -1;
    var maxY = -1;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        if (image.getPixel(x, y).a == 0) continue;
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
    expect((minX, minY, maxX, maxY), (0, 0, 95, 95));
    for (final point in [
      (0, 0),
      (95, 0),
      (0, 95),
      (95, 95),
      (8, 8),
      (87, 8),
      (8, 87),
      (87, 87),
    ]) {
      expect(image.getPixel(point.$1, point.$2).a, 0);
    }
    for (final point in [(48, 48), (48, 1), (1, 48), (94, 48)]) {
      final pixel = image.getPixel(point.$1, point.$2);
      expect(pixel.a, greaterThan(200));
      expect(pixel.r, greaterThan(150));
      expect(pixel.g, lessThan(100));
    }
  });

  testWidgets('iOS Shell updates avatar and clears it across account changes', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel('hand_helper/native_tab');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    });
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=avatar',
    });
    ApiClient client() => ApiClient(
      cache: _EmptyTodayCache(),
      localProfileStore: _MemoryLocalProfileStore(),
      localScheduleStore: _MemoryLocalScheduleStore(),
      localManualCourseStore: _MemoryLocalManualCourseStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    final first = client();
    Widget shell(ApiClient api) => MaterialApp(
      home: Shell(
        api: api,
        onUnauthorized: () {},
        themeMode: ThemeMode.system,
        onThemeModeChanged: (_) {},
      ),
    );
    await tester.pumpWidget(shell(first));
    await tester.pumpAndSettle();
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('selectTab', 3),
      ),
      (_) {},
    );
    await tester.pump();
    final settings = tester.widget<SettingsPage>(find.byType(SettingsPage));
    settings.onProfileChanged!(
      Profile('甲', _avatarDataUrl(width: 4, height: 4), null),
    );
    for (
      var i = 0;
      i < 100 &&
          !calls.any(
            (call) => call.method == 'setAvatar' && call.arguments is Uint8List,
          );
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(
      calls.any(
        (call) => call.method == 'setAvatar' && call.arguments is Uint8List,
      ),
      isTrue,
    );
    settings.onProfileChanged!(const Profile('甲', null, null));
    await tester.pump();
    expect(
      calls.lastWhere((call) => call.method == 'setAvatar').arguments,
      isNull,
    );

    settings.onProfileChanged!(
      Profile('甲', _avatarDataUrl(width: 8, height: 8), null),
    );
    await tester.pumpWidget(shell(client()));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pump();
    expect(
      calls.lastWhere((call) => call.method == 'setAvatar').arguments,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(
      calls.lastWhere((call) => call.method == 'setAvatar').arguments,
      isNull,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'iOS Shell follows native tab selection and hides it on dispose',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      const channel = MethodChannel('hand_helper/native_tab');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(channel, null);
      });
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=offline',
      });
      final client = ApiClient(
        cache: _EmptyTodayCache(),
        localManualCourseStore: _MemoryLocalManualCourseStore(),
        localProfileStore: _MemoryLocalProfileStore(),
        client: MockClient((_) async => throw const SocketException('offline')),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Shell(
            api: client,
            onUnauthorized: () {},
            themeMode: ThemeMode.system,
            onThemeModeChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FloatingTabBar), findsNothing);
      Map<Object?, Object?> state() =>
          calls.lastWhere((call) => call.method == 'sync').arguments
              as Map<Object?, Object?>;
      expect(state()['visible'], isTrue);
      expect(state()['selected'], 0);
      expect(state()['appearance'], 'system');

      final viewport = tester.getSize(find.byType(IndexedStack));
      final todayList = find
          .descendant(
            of: find.byType(TodayPage),
            matching: find.byType(ListView),
          )
          .first;
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('tabMetrics', 96.0),
        ),
        (_) {},
      );
      await tester.pump();
      expect(tester.getSize(find.byType(IndexedStack)), viewport);
      expect(
        (tester.widget<ListView>(todayList).padding! as EdgeInsets).bottom,
        120,
      );
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('selectTab', 1),
        ),
        (_) {},
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(state()['selected'], 1);
      expect(find.byType(FloatingTabBar), findsNothing);

      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('selectTab', 3),
        ),
        (_) {},
      );
      await tester.pump();
      final settings = tester.widget<SettingsPage>(find.byType(SettingsPage));
      settings.onSectionChanged!(true);
      await tester.pump();
      expect(state()['detailOpen'], isTrue);
      final syncCount = calls.where((call) => call.method == 'sync').length;
      settings.onSectionChanged!(true);
      settings.onSectionClosingChanged!(true);
      await tester.pump();
      expect(calls.where((call) => call.method == 'sync').length, syncCount);
      settings.onSectionChanged!(false);
      await tester.pump();
      expect(state()['detailOpen'], isTrue);
      settings.onSectionClosingChanged!(false);
      await tester.pump();
      expect(state()['detailOpen'], isFalse);
      expect(tester.getSize(find.byType(IndexedStack)), viewport);

      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('selectTab', 2),
        ),
        (_) {},
      );
      await tester.pump();
      final analysis = tester.widget<AnalysisPage>(find.byType(AnalysisPage));
      analysis.onDetailChanged!(true);
      await tester.pump();
      expect(state()['detailOpen'], isTrue);
      analysis.onDetailClosingChanged!(true);
      analysis.onDetailChanged!(false);
      await tester.pump();
      expect(state()['detailOpen'], isTrue);
      analysis.onDetailClosingChanged!(false);
      await tester.pump();
      expect(state()['detailOpen'], isFalse);
      expect(tester.getSize(find.byType(IndexedStack)), viewport);

      await tester.pumpWidget(
        MaterialApp(
          home: Shell(
            api: client,
            onUnauthorized: () {},
            themeMode: ThemeMode.light,
            onThemeModeChanged: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(state()['appearance'], 'light');

      await tester.pumpWidget(
        MaterialApp(
          home: Shell(
            api: client,
            onUnauthorized: () {},
            themeMode: ThemeMode.dark,
            onThemeModeChanged: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(state()['appearance'], 'dark');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(state()['visible'], isFalse);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('iOS native tab padding clears when keyboard covers content', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    double? padding;
    Widget page(double keyboard) => MediaQuery(
      data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: keyboard)),
      child: NativeTabMetrics(
        bottomOverlap: 96,
        child: Builder(
          builder: (context) {
            padding = NativeTabMetrics.contentBottomPadding(
              context,
              android: 105,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpWidget(page(0));
    expect(padding, 120);
    await tester.pumpWidget(page(300));
    expect(padding, 24);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS login initializes the UIKit host appearance', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel('hand_helper/native_tab');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
    });
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const App(initialThemeMode: ThemeMode.light));
    await tester.pump();
    expect(
      calls.where((call) => call.method == 'setAppearance').last.arguments,
      'light',
    );
    expect(find.byType(FloatingTabBar), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android Shell retains FloatingTabBar selection', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    final client = ApiClient(
      cache: _EmptyTodayCache(),
      localManualCourseStore: _MemoryLocalManualCourseStore(),
      localProfileStore: _MemoryLocalProfileStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Shell(
          api: client,
          onUnauthorized: () {},
          themeMode: ThemeMode.system,
          onThemeModeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FloatingTabBar), findsOneWidget);
    tester.widget<FloatingTabBar>(find.byType(FloatingTabBar)).onSelected(1);
    await tester.pump();
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 1);
    expect(
      tester.widget<FloatingTabBar>(find.byType(FloatingTabBar)).selectedIndex,
      1,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Shell preserves timetable week after switching tabs', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final monday = mondayOf(DateTime.now());
    final date = dateKey(monday);
    final start = DateTime(monday.year, monday.month, monday.day, 8, 30);
    final data = TimetableData(
      [TermInfo(1, 'test-term', '测试学期', date, true)],
      defaultPeriods,
      null,
      {
        1: [
          TimetableCourse(
            1,
            '本周课程',
            date,
            start,
            start.add(const Duration(minutes: 45)),
            '教室 A',
            '王老师',
            '1周',
            'LOCAL',
            -1,
            1,
            1,
            1,
            1,
          ),
        ],
      },
      DateTime.now(),
    );
    final client = ApiClient(
      cache: _EmptyTodayCache(),
      timetableCache: _FixtureTimetableCache(data),
      localManualCourseStore: _MemoryLocalManualCourseStore(),
      localProfileStore: _MemoryLocalProfileStore(),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Shell(
          api: client,
          onUnauthorized: () {},
          themeMode: ThemeMode.system,
          onThemeModeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tab-1')));
    await tester.pumpAndSettle();
    expect(find.text('本周课程'), findsOneWidget);
    await tester.tap(find.byTooltip('下一周或开学周'));
    await tester.pumpAndSettle();
    expect(find.text('本周课程'), findsNothing);
    await tester.tap(find.byKey(const Key('tab-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tab-1')));
    await tester.pumpAndSettle();
    expect(find.text('本周课程'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsaved personalization confirms top and Android back', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=offline',
    });
    final hapticCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') hapticCalls.add(call);
          return null;
        });
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    final store = _MemoryLocalProfileStore();
    final client = ApiClient(
      localProfileStore: store,
      settingsCache: _FixtureSettingsCache(
        SettingsData(
          const Profile('原姓名', null, null),
          const [],
          const [],
          DateTime.now(),
        ),
      ),
      client: MockClient((_) async => throw const SocketException('offline')),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            api: client,
            onUnauthorized: () {},
            onSignedOut: () {},
            themeMode: ThemeMode.system,
            onThemeModeChanged: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('个性化设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示姓名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, '新姓名');
    await tester.tap(find.text('完成编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-detail-back')));
    await tester.pumpAndSettle();
    expect(find.text('有未保存的更改'), findsOneWidget);
    expect(hapticCalls, hasLength(2)); // Entry and top return.
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('新姓名'), findsOneWidget);
    expect(hapticCalls, hasLength(2));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('有未保存的更改'), findsOneWidget);
    expect(hapticCalls, hasLength(2)); // System back adds no app haptic.
    await tester.tap(find.text('放弃更改'));
    await tester.pumpAndSettle();
    expect(hapticCalls, hasLength(2)); // Collapse adds no late haptic.
    expect(find.text('个性化设置'), findsOneWidget);
    expect(store.profile?.name, '原姓名');

    await tester.tap(find.text('个性化设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示姓名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, '保存姓名');
    await tester.tap(find.text('完成编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-detail-back')));
    await tester.pumpAndSettle();
    expect(hapticCalls, hasLength(4));
    await tester.tap(find.text('保存并返回'));
    await tester.pumpAndSettle();
    expect(hapticCalls, hasLength(4));
    expect(store.profile?.name, '保存姓名');
    expect(find.text('个性化设置'), findsOneWidget);
    expect(find.text('有未保存的更改'), findsNothing);
    await tester.tap(find.text('个性化设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示姓名'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-detail-back')));
    await tester.pumpAndSettle();
    expect(hapticCalls, hasLength(6));
    expect(find.text('有未保存的更改'), findsNothing);
    expect(find.text('个性化设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

String _avatarDataUrl({required int width, required int height}) {
  final image = img.Image(width: width, height: height);
  return 'data:image/png;base64,${base64Encode(img.encodePng(image))}';
}

Future<_MemoryLocalScheduleStore> _pumpTodaySchedule(
  WidgetTester tester, {
  _MemoryLocalScheduleStore? scheduleStore,
  bool dark = false,
  double textScale = 1,
  ValueNotifier<bool>? selected,
  VoidCallback? onDockTap,
}) async {
  SharedPreferences.setMockInitialValues({
    'session_cookie': 'session=schedule',
  });
  final store = scheduleStore ?? _MemoryLocalScheduleStore();
  final profile = _MemoryLocalProfileStore()
    ..profile = const Profile('测试', null, null);
  final client = ApiClient(
    cache: _EmptyTodayCache(),
    localProfileStore: profile,
    localScheduleStore: store,
    client: MockClient(
      (_) async => http.Response.bytes(
        utf8.encode(jsonEncode({'success': true, 'data': <Object>[]})),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        bottomNavigationBar: onDockTap == null
            ? null
            : TextButton(
                key: const Key('test-bottom-tab'),
                onPressed: onDockTap,
                child: const Text('测试底栏'),
              ),
        body: selected == null
            ? TodayPage(api: client, onUnauthorized: () {}, onProfile: (_) {})
            : ValueListenableBuilder<bool>(
                valueListenable: selected,
                builder: (context, active, _) => TickerMode(
                  enabled: active,
                  child: TodayPage(
                    api: client,
                    onUnauthorized: () {},
                    onProfile: (_) {},
                  ),
                ),
              ),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  expect(find.widgetWithText(TextButton, '添加安排'), findsOneWidget);
  expect(tester.takeException(), isNull);
  return store;
}

Future<void> _pumpTodayAvatar(
  WidgetTester tester, {
  required String avatar,
  ValueNotifier<Profile?>? changes,
  bool dark = false,
  VoidCallback? onDockTap,
}) async {
  SharedPreferences.setMockInitialValues({'session_cookie': 'session=avatar'});
  final store = _MemoryLocalProfileStore()
    ..profile = Profile('测试', avatar, null);
  final client = ApiClient(
    cache: _EmptyTodayCache(),
    localProfileStore: store,
    localScheduleStore: _MemoryLocalScheduleStore(),
    client: MockClient(
      (_) async => http.Response.bytes(
        utf8.encode(jsonEncode({'success': true, 'data': <Object>[]})),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
      home: Scaffold(
        bottomNavigationBar: onDockTap == null
            ? null
            : TextButton(
                key: const Key('test-bottom-tab'),
                onPressed: onDockTap,
                child: const Text('测试底栏'),
              ),
        body: TodayPage(
          api: client,
          onUnauthorized: () {},
          onProfile: (_) {},
          localProfileChanges: changes,
        ),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  expect(find.byKey(const Key('today-avatar-source')), findsOneWidget);
  expect(tester.takeException(), isNull);
}

class _FixtureTodayCache extends TodayCache {
  _FixtureTodayCache(this.snapshot);
  final TodaySnapshot snapshot;
  @override
  Future<TodaySnapshot?> read({
    required String baseUrl,
    required String scope,
  }) async => snapshot;
}

class _EmptyTodayCache extends TodayCache {
  @override
  Future<TodaySnapshot?> read({
    required String baseUrl,
    required String scope,
  }) async => null;

  @override
  Future<void> write({
    required String baseUrl,
    required String scope,
    required String date,
    required Map<String, dynamic> profile,
    required List<dynamic> sessions,
    required List<dynamic> schedules,
    List<dynamic>? timetableSessions,
  }) async {}
}

class _FixtureTimetableCache extends TimetableCache {
  _FixtureTimetableCache(this.snapshot);
  final TimetableData snapshot;
  @override
  Future<TimetableData?> read({
    required String baseUrl,
    required String scope,
  }) async => snapshot;
}

class _EmptyTimetableCache extends TimetableCache {
  @override
  Future<TimetableData?> read({
    required String baseUrl,
    required String scope,
  }) async => null;
}

class _FixtureAnalysisCache extends AnalysisCache {
  _FixtureAnalysisCache(this.snapshot);
  final AnalysisData snapshot;
  @override
  Future<AnalysisData?> read({
    required String baseUrl,
    required String scope,
  }) async => snapshot;
}

class _FixtureSettingsCache extends SettingsCache {
  _FixtureSettingsCache(this.snapshot);
  final SettingsData snapshot;
  @override
  Future<SettingsData?> read({
    required String baseUrl,
    required String scope,
  }) async => snapshot;
}

class _EmptySettingsCache extends SettingsCache {
  @override
  Future<SettingsData?> read({
    required String baseUrl,
    required String scope,
  }) async => null;
}

class _MemoryLocalProfileStore extends LocalProfileStore {
  Profile? profile;
  @override
  Future<Profile?> read({
    required String baseUrl,
    required String scope,
  }) async => profile;
  @override
  Future<void> write({
    required String baseUrl,
    required String scope,
    required Profile profile,
  }) async {
    this.profile = profile;
  }

  @override
  Future<void> clear() async {
    profile = null;
  }
}

class _MemoryLocalScheduleStore extends LocalScheduleStore {
  final records = <int, CustomSchedule>{};
  bool importedSnapshot = false;
  bool importedServer = false;
  int nextId = -1;

  @override
  Future<List<CustomSchedule>> forDate(
    String baseUrl,
    String owner,
    DateTime day,
  ) async => records.values.where((item) => item.date == dateKey(day)).toList();

  @override
  Future<void> import(
    String baseUrl,
    String owner,
    List<CustomSchedule> incoming, {
    required bool fromServer,
  }) async {
    if (fromServer ? importedServer : importedSnapshot) return;
    for (final item in incoming) {
      records.putIfAbsent(item.id, () => item);
    }
    if (fromServer) {
      importedServer = true;
    } else {
      importedSnapshot = true;
    }
  }

  @override
  Future<bool> needsServerImport(String baseUrl, String owner) async =>
      !importedServer;

  @override
  Future<void> save(
    String baseUrl,
    String owner, {
    int? id,
    required String title,
    required DateTime date,
    required String time,
  }) async {
    final actualId = id ?? nextId--;
    records[actualId] = CustomSchedule(actualId, title, dateKey(date), time);
  }

  @override
  Future<void> delete(String baseUrl, String owner, int id) async {
    records.remove(id);
  }
}

class _BlockingLocalScheduleStore extends _MemoryLocalScheduleStore {
  final release = Completer<void>();

  @override
  Future<void> save(
    String baseUrl,
    String owner, {
    int? id,
    required String title,
    required DateTime date,
    required String time,
  }) async {
    await release.future;
    await super.save(
      baseUrl,
      owner,
      id: id,
      title: title,
      date: date,
      time: time,
    );
  }
}

class _MemoryLocalManualCourseStore extends LocalManualCourseStore {
  @override
  Future<void> importLegacy(
    String key,
    List<TermInfo> terms,
    Map<int, List<TimetableCourse>> coursesByTerm, {
    required bool online,
  }) async {}

  @override
  Future<List<LocalManualCourse>> all(String key) async => const [];

  @override
  Future<void> moveOwner(
    String baseUrl,
    String oldOwner,
    String newOwner,
  ) async {}
}
