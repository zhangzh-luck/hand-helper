import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_helper_flutter/api.dart';
import 'package:hand_helper_flutter/native_term_start_date_picker.dart';
import 'package:hand_helper_flutter/settings_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _channel = MethodChannel('hand_helper/native_term_start_date');
const _timeChannel = MethodChannel('hand_helper/native_period_time');

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_timeChannel, null);
  });

  test(
    'date channel sends components and validates the 2010–2100 range',
    () async {
      final calls = <MethodCall>[];
      final results = <Object?>[
        {'year': 2010, 'month': 1, 'day': 1},
        {'year': 2100, 'month': 1, 'day': 1},
        {'year': 2100, 'month': 1, 'day': 2},
        {'year': 2026, 'month': 2, 'day': 30},
      ];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            return results.removeAt(0);
          });
      final picker = NativeTermStartDatePicker();
      expect(
        await picker.pickDate(
          initialDate: DateTime(2026, 10, 19),
          requestId: 91,
        ),
        DateTime(2010, 1, 1),
      );
      expect(calls.first.method, 'pickDate');
      expect(calls.first.arguments, {
        'initialYear': 2026,
        'initialMonth': 10,
        'initialDay': 19,
        'requestId': 91,
      });
      expect(
        await picker.pickDate(
          initialDate: DateTime(2026, 10, 19),
          requestId: 92,
        ),
        DateTime(2100, 1, 1),
      );
      await expectLater(
        picker.pickDate(initialDate: DateTime(2026, 10, 19), requestId: 93),
        throwsFormatException,
      );
      await expectLater(
        picker.pickDate(initialDate: DateTime(2026, 10, 19), requestId: 94),
        throwsFormatException,
      );
    },
  );

  testWidgets('iOS date cancel, same day, Monday validation and save failure', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final calls = <MethodCall>[];
    final results = <Object?>[
      null,
      {'year': 2026, 'month': 10, 'day': 19},
      {'year': 2026, 'month': 10, 'day': 20},
      {'year': 2026, 'month': 10, 'day': 26},
      {'year': 2026, 'month': 11, 'day': 2},
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return results.removeAt(0);
        });
    final server = _DateSettingsServer();
    await _pumpSettings(tester, server);
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.text('第一周周一'));
      await tester.pumpAndSettle();
      expect(calls[i].method, 'pickDate');
      expect((calls[i].arguments as Map)['initialDay'], i < 4 ? 19 : 26);
      if (i == 2) {
        expect(find.text('请选择星期一作为第一周的开始日期。'), findsOneWidget);
      }
      if (i == 3) {
        expect(server.putCount, 1);
      }
      if (i == 4) {
        expect(find.text('模拟保存失败', skipOffstage: false), findsOneWidget);
      }
    }
    expect(server.putCount, 2);
    expect(server.startDate, '2026-10-26');
    expect(find.text('时间设置'), findsWidgets);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS rapid taps and disposal ignore a late date result', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final pending = Completer<Object?>();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          if (call.method == 'pickDate') return pending.future;
          return null;
        });
    final server = _DateSettingsServer();
    await _pumpSettings(tester, server);
    await tester.tap(find.text('第一周周一'));
    await tester.pump();
    await tester.tap(find.text('第一周周一'));
    await tester.pump();
    expect(calls.where((call) => call.method == 'pickDate'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(
      calls.where((call) => call.method == 'dismissDatePicker'),
      hasLength(1),
    );
    expect(
      (calls.last.arguments as Map)['requestId'],
      (calls.first.arguments as Map)['requestId'],
    );
    pending.complete({'year': 2026, 'month': 10, 'day': 26});
    await tester.pump();
    expect(server.putCount, 0);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS back dismisses the native date before closing Morph', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final pending = Completer<Object?>();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          if (call.method == 'pickDate') return pending.future;
          return null;
        });
    final server = _DateSettingsServer();
    await _pumpSettings(tester, server);
    await tester.tap(find.text('第一周周一'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings-detail-back')));
    await tester.pump();
    expect(calls.map((call) => call.method), ['pickDate', 'dismissDatePicker']);
    expect(find.byKey(const Key('settings-transform-surface')), findsOneWidget);
    pending.complete({'year': 2026, 'month': 10, 'day': 26});
    await tester.pumpAndSettle();
    expect(server.putCount, 0);
    expect(find.text('第一周周一'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS ignores a date result after another term is selected', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final pending = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'pickDate') return pending.future;
          return null;
        });
    final server = _DateSettingsServer();
    await _pumpSettings(tester, server);
    await tester.tap(find.text('第一周周一'));
    await tester.pump();
    await tester.tap(find.text('学期'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一学期'));
    await tester.pumpAndSettle();
    pending.complete({'year': 2026, 'month': 10, 'day': 26});
    await tester.pump();
    expect(server.putCount, 0);
    expect(find.text('下一学期'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS date and period time pickers exclude each other', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final dateResult = Completer<Object?>();
    final timeResult = Completer<Object?>();
    var dateCalls = 0;
    var timeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'pickDate') {
            dateCalls++;
            return dateResult.future;
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_timeChannel, (call) async {
          if (call.method == 'pickTime') {
            timeCalls++;
            return timeResult.future;
          }
          return null;
        });
    await _pumpSettings(tester, _DateSettingsServer());
    await tester.tap(find.text('第一周周一'));
    await tester.pump();
    await tester.tap(find.text('上课时间'));
    await tester.pump();
    expect(dateCalls, 1);
    expect(timeCalls, 0);
    dateResult.complete(null);
    await tester.pump();
    await tester.tap(find.text('上课时间'));
    await tester.pump();
    await tester.tap(find.text('第一周周一'));
    await tester.pump();
    expect(dateCalls, 1);
    expect(timeCalls, 1);
    timeResult.complete(null);
    await tester.pump();
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'Android retains the Material date picker and does not call iOS',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      var nativeCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (_) async {
            nativeCalls++;
            return null;
          });
      await _pumpSettings(tester, _DateSettingsServer());
      await tester.tap(find.text('第一周周一'));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      expect(nativeCalls, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );
}

Future<void> _pumpSettings(
  WidgetTester tester,
  _DateSettingsServer server,
) async {
  SharedPreferences.setMockInitialValues({'session_cookie': 'session=test'});
  final client = ApiClient(
    client: MockClient(server.respond),
    settingsCache: _DateSettingsCache(server),
    localProfileStore: _DateProfileStore(),
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

class _DateSettingsServer {
  String startDate = '2026-10-19';
  int putCount = 0;

  Future<http.Response> respond(http.Request request) async {
    final path = request.url.path;
    if (path == '/api/v1/terms/1/start-date' && request.method == 'PUT') {
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
      startDate = body['start_date'] as String;
      return http.Response(jsonEncode({'success': true, 'data': {}}), 200);
    }
    final data = switch (path) {
      '/api/v1/terms' => [
        {
          'id': 1,
          'source_term_id': '2026-2027-1',
          'display_name': '当前学期',
          'start_date': startDate,
          'is_current': true,
        },
        {
          'id': 2,
          'source_term_id': '2026-2027-2',
          'display_name': '下一学期',
          'start_date': '2027-02-22',
          'is_current': false,
        },
      ],
      '/api/v1/settings/period-times' => [
        {'period_number': 1, 'start_time': '08:30', 'end_time': '09:15'},
      ],
      _ => throw StateError('Unexpected request: ${request.method} $path'),
    };
    return http.Response.bytes(
      utf8.encode(jsonEncode({'success': true, 'data': data})),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
}

class _DateSettingsCache extends SettingsCache {
  _DateSettingsCache(this.server);
  final _DateSettingsServer server;

  @override
  Future<SettingsData?> read({
    required String baseUrl,
    required String scope,
  }) async => SettingsData(
    const Profile('测试用户', null, null),
    [
      TermInfo(1, '2026-2027-1', '当前学期', server.startDate, true),
      const TermInfo(2, '2026-2027-2', '下一学期', '2027-02-22', false),
    ],
    const [PeriodInfo(1, '08:30', '09:15')],
    DateTime.now(),
  );

  @override
  Future<void> write({
    required String baseUrl,
    required String scope,
    required Map<String, dynamic> profile,
    required List<dynamic> terms,
    required List<dynamic> periods,
  }) async {}
}

class _DateProfileStore extends LocalProfileStore {
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
