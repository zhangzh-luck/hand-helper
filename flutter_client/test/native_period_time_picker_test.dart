import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_helper_flutter/api.dart';
import 'package:hand_helper_flutter/native_period_time_picker.dart';
import 'package:hand_helper_flutter/settings_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('hand_helper/native_period_time');

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test(
    'native time channel transports only validated hour and minute',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            return {'hour': 13, 'minute': 7};
          });
      final picker = NativePeriodTimePicker();
      expect(
        await picker.pickTime(
          initialTime: const TimeOfDay(hour: 8, minute: 30),
          title: '上课时间',
          requestId: 91,
        ),
        const TimeOfDay(hour: 13, minute: 7),
      );
      expect(calls.single.method, 'pickTime');
      expect(calls.single.arguments, {
        'initialHour': 8,
        'initialMinute': 30,
        'title': '上课时间',
        'requestId': 91,
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _channel,
            (_) async => {'hour': 24, 'minute': 0},
          );
      await expectLater(
        picker.pickTime(
          initialTime: const TimeOfDay(hour: 8, minute: 30),
          title: '上课时间',
          requestId: 92,
        ),
        throwsFormatException,
      );
    },
  );

  testWidgets('iOS picker preserves settings validation, save and failure', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final calls = <MethodCall>[];
    final results = <Object?>[
      null,
      {'hour': 8, 'minute': 30},
      {'hour': 9, 'minute': 20},
      {'hour': 8, 'minute': 35},
      {'hour': 8, 'minute': 40},
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return results.removeAt(0);
        });
    final server = _SettingsServer();
    await _pumpSettings(tester, server);
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.text('上课时间'));
      await tester.pumpAndSettle();
      expect(calls[i].method, 'pickTime');
      expect((calls[i].arguments as Map)['title'], '上课时间');
      expect((calls[i].arguments as Map)['initialMinute'], i < 4 ? 30 : 35);
      expect((calls[i].arguments as Map)['initialHour'], 8);
      if (i == 2) expect(find.text('下课时间必须晚于上课时间。'), findsOneWidget);
      if (i == 3) expect(server.putCount, 1);
      if (i == 4) expect(find.text('模拟保存失败'), findsOneWidget);
    }
    expect(server.putCount, 2);
    expect(server.period.start, '08:35');
    expect(find.text('时间设置'), findsWidgets);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS rapid taps and disposal ignore late picker results', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final result = Completer<Object?>();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          if (call.method == 'pickTime') return result.future;
          return null;
        });
    final server = _SettingsServer();
    await _pumpSettings(tester, server);
    await tester.tap(find.text('下课时间'));
    await tester.pump();
    await tester.tap(find.text('下课时间'));
    await tester.pump();
    expect(calls.where((call) => call.method == 'pickTime'), hasLength(1));
    expect((calls.first.arguments as Map)['initialHour'], 9);
    expect((calls.first.arguments as Map)['initialMinute'], 15);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(
      calls.where((call) => call.method == 'dismissTimePicker'),
      hasLength(1),
    );
    result.complete({'hour': 10, 'minute': 5});
    await tester.pump();
    expect(server.putCount, 0);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS settings back dismisses picker before closing Morph', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final result = Completer<Object?>();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          if (call.method == 'pickTime') return result.future;
          return null;
        });
    final server = _SettingsServer();
    await _pumpSettings(tester, server);
    await tester.tap(find.text('上课时间'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-detail-back')));
    await tester.pump();
    expect(calls.map((call) => call.method), ['pickTime', 'dismissTimePicker']);
    expect(
      (calls.last.arguments as Map)['requestId'],
      (calls.first.arguments as Map)['requestId'],
    );
    expect(find.byKey(const Key('settings-transform-surface')), findsOneWidget);
    result.complete({'hour': 8, 'minute': 45});
    await tester.pumpAndSettle();
    expect(server.putCount, 0);
    expect(find.text('上课时间'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android keeps the Material dial without native calls', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    var nativeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (_) async {
          nativeCalls++;
          return null;
        });
    await _pumpSettings(tester, _SettingsServer());
    await tester.tap(find.text('上课时间'));
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
    expect(nativeCalls, 0);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

Future<void> _pumpSettings(WidgetTester tester, _SettingsServer server) async {
  SharedPreferences.setMockInitialValues({'session_cookie': 'session=test'});
  final client = ApiClient(
    client: MockClient(server.respond),
    settingsCache: _TimeSettingsCache(server),
    localProfileStore: _TimeProfileStore(),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(splashFactory: InkRipple.splashFactory),
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
  await tester.tap(find.text('时间设置'));
  await tester.pumpAndSettle();
}

class _SettingsServer {
  PeriodInfo period = const PeriodInfo(1, '08:30', '09:15');
  int putCount = 0;

  Future<http.Response> respond(http.Request request) async {
    final path = request.url.path;
    if (path == '/api/v1/settings/period-times/1' && request.method == 'PUT') {
      putCount++;
      if (putCount == 2) {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'success': false,
              'error': {'message': '模拟保存失败'},
            }),
          ),
          500,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      period = PeriodInfo(
        1,
        body['start_time'] as String,
        body['end_time'] as String,
      );
      return http.Response(jsonEncode({'success': true, 'data': {}}), 200);
    }
    final data = switch (path) {
      '/api/v1/terms' => <Object>[],
      '/api/v1/settings/period-times' => [
        {
          'period_number': 1,
          'start_time': period.start,
          'end_time': period.end,
        },
      ],
      _ => throw StateError('Unexpected request: ${request.method} $path'),
    };
    return http.Response(jsonEncode({'success': true, 'data': data}), 200);
  }
}

class _TimeSettingsCache extends SettingsCache {
  _TimeSettingsCache(this.server);
  final _SettingsServer server;

  @override
  Future<SettingsData?> read({
    required String baseUrl,
    required String scope,
  }) async => SettingsData(const Profile('测试用户', null, null), const [], [
    server.period,
  ], DateTime.now());

  @override
  Future<void> write({
    required String baseUrl,
    required String scope,
    required Map<String, dynamic> profile,
    required List<dynamic> terms,
    required List<dynamic> periods,
  }) async {}
}

class _TimeProfileStore extends LocalProfileStore {
  @override
  Future<Profile?> read({
    required String baseUrl,
    required String scope,
  }) async => null;
  @override
  Future<void> write({
    required String baseUrl,
    required String scope,
    required Profile profile,
  }) async {}
}
