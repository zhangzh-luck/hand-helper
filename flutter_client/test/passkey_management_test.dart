import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_helper_flutter/api.dart';
import 'package:hand_helper_flutter/passkey_login.dart';
import 'package:hand_helper_flutter/passkey_management_page.dart';
import 'package:hand_helper_flutter/settings_page.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _ok(Object? data) => http.Response(
  jsonEncode({'success': true, 'data': data}),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _error(int status, String message) => http.Response(
  jsonEncode({
    'success': false,
    'error': {'message': message},
  }),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _credential(int id, String label) => {
  'id': id,
  'label': label,
  'device_type': 'multi_device',
  'backed_up': true,
  'created_at': '2026-10-18T10:20:00',
  'last_used_at': id == 1 ? '2026-10-18T11:30:00' : null,
};

void main() {
  test('registration reuses challenge_id and credential JSON; deletion confirms password', () async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=existing',
    });
    final paths = <String>[];
    final client = ApiClient(
      client: MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        expect(request.headers['cookie'], 'session=existing');
        if (request.method != 'GET') {
          expect(request.headers['origin'], apiBaseUrl);
        }
        if (request.url.path.endsWith('/registration/options')) {
          expect(jsonDecode(request.body), {
            'password': 'secret',
            'label': '手机',
          });
          return _ok({
            'challenge_id': 'challenge-123456789',
            'public_key': {
              'challenge': 'abc',
              'rp': {'id': 'hand.zhangzh.cc'},
            },
            'label': '手机',
          });
        }
        if (request.url.path.endsWith('/registration/verify')) {
          expect(jsonDecode(request.body), {
            'challenge_id': 'challenge-123456789',
            'credential': {'id': 'credential-id', 'type': 'public-key'},
            'label': '手机',
          });
          return _ok(_credential(2, '手机'));
        }
        if (request.method == 'DELETE') {
          expect(request.url.path, '/api/v1/auth/passkeys/2');
          expect(jsonDecode(request.body), {'password': 'secret'});
          return _ok({'deleted': true});
        }
        return _ok([_credential(1, '网页版')]);
      }),
    );
    final listed = await client.listPasskeys();
    expect(listed.single.label, '网页版');
    expect(listed.single.lastUsedAt, isNotNull);
    await client.registerPasskey(
      label: ' 手机 ',
      password: 'secret',
      createCredential: (options) async {
        expect(options['challenge'], 'abc');
        return {'id': 'credential-id', 'type': 'public-key'};
      },
    );
    await client.deletePasskey(2, 'secret');
    expect(paths, [
      'GET /api/v1/auth/passkeys',
      'POST /api/v1/auth/passkey/registration/options',
      'POST /api/v1/auth/passkey/registration/verify',
      'DELETE /api/v1/auth/passkeys/2',
    ]);
  });

  test('wrong confirmation password does not erase Session Cookie', () async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=existing',
    });
    final client = ApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/registration/options') ||
            request.method == 'DELETE') {
          return _error(401, '当前密码错误');
        }
        expect(request.headers['cookie'], 'session=existing');
        return _ok([_credential(1, '保留的密钥')]);
      }),
    );
    await expectLater(
      client.registerPasskey(
        label: '手机',
        password: 'wrong',
        createCredential: (_) async =>
            fail('wrong password must not open Credential Manager'),
      ),
      throwsA(
        isA<ApiFailure>().having((e) => e.unauthorized, 'unauthorized', false),
      ),
    );
    await expectLater(
      client.deletePasskey(1, 'wrong'),
      throwsA(
        isA<ApiFailure>().having((e) => e.unauthorized, 'unauthorized', false),
      ),
    );
    expect(await client.hasStoredSession(), isTrue);
    expect((await client.listPasskeys()).single.label, '保留的密钥');
  });

  test('expired Session Cookie still invalidates the session', () async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=expired',
    });
    final client = ApiClient(
      client: MockClient((_) async => _error(401, '登录状态已失效，请重新登录')),
    );
    await expectLater(
      client.deletePasskey(1, 'secret'),
      throwsA(
        isA<ApiFailure>().having((e) => e.unauthorized, 'unauthorized', true),
      ),
    );
    expect(await client.hasStoredSession(), isFalse);
  });

  testWidgets('settings account opens the native passkey management page', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final client = ApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/passkeys')) return _ok([]);
        return _ok([]);
      }),
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
    await tester.tap(find.text('账号安全'));
    await tester.pumpAndSettle();
    expect(find.text('通行密钥管理'), findsOneWidget);
    await tester.tap(find.text('通行密钥管理'));
    await tester.pumpAndSettle();
    expect(find.text('尚未添加通行密钥'), findsOneWidget);
    expect(find.byKey(const Key('passkey-add-button')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-detail-back')), findsOneWidget);
    expect(find.byKey(const Key('passkey-add-button')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'network failure shows retry instead of an empty credential list',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=existing',
      });
      var requests = 0;
      final client = ApiClient(
        client: MockClient((_) async {
          requests++;
          if (requests == 1) throw const SocketException('offline');
          return _ok([_credential(1, '恢复后的密钥')]);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PasskeyManagementPage(api: client, onUnauthorized: () {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('无法连接服务器，请检查网络后重试。'), findsOneWidget);
      expect(find.text('尚未添加通行密钥'), findsNothing);
      await tester.tap(find.byKey(const Key('passkey-retry')));
      await tester.pumpAndSettle();
      expect(find.text('恢复后的密钥'), findsOneWidget);
    },
  );

  testWidgets(
    'add, cancel removal, wrong password and confirmed removal refresh the list',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=existing',
      });
      final items = <Map<String, dynamic>>[_credential(1, '网页版')];
      var deleteCalls = 0;
      var registerCalls = 0;
      final client = ApiClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/registration/options')) {
            return _ok({
              'challenge_id': 'challenge-123456789',
              'public_key': {
                'challenge': 'abc',
                'rp': {'id': 'hand.zhangzh.cc'},
              },
            });
          }
          if (request.url.path.endsWith('/registration/verify')) {
            registerCalls++;
            items.add(_credential(2, '手机'));
            return _ok(_credential(2, '手机'));
          }
          if (request.method == 'DELETE') {
            deleteCalls++;
            if (jsonDecode(request.body)['password'] == 'wrong') {
              return _error(401, '当前密码错误');
            }
            items.removeWhere((item) => item['id'] == 2);
            return _ok({'deleted': true});
          }
          return _ok(items);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PasskeyManagementPage(
            api: client,
            onUnauthorized: () => fail('valid session should be kept'),
            registrationProvider: (_) async => {'id': 'credential-id'},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('网页版'), findsOneWidget);
      await tester.tap(find.byKey(const Key('passkey-add-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('passkey-label-field')),
        '手机',
      );
      await tester.enterText(
        find.byKey(const Key('passkey-register-password')),
        'secret',
      );
      await tester.tap(find.byKey(const Key('passkey-register-confirm')));
      await tester.pumpAndSettle();
      expect(registerCalls, 1);
      expect(find.text('手机'), findsOneWidget);
      await tester.tap(find.byKey(const Key('passkey-remove-2')));
      await tester.pumpAndSettle();
      expect(find.textContaining('移除“手机”'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(deleteCalls, 0);
      await tester.tap(find.byKey(const Key('passkey-remove-2')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('passkey-remove-password')),
        'wrong',
      );
      await tester.tap(find.byKey(const Key('passkey-remove-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('当前密码错误'), findsOneWidget);
      expect(await client.hasStoredSession(), isTrue);
      await tester.enterText(
        find.byKey(const Key('passkey-remove-password')),
        'secret',
      );
      await tester.tap(find.byKey(const Key('passkey-remove-confirm')));
      await tester.pumpAndSettle();
      expect(deleteCalls, 2);
      expect(find.text('手机'), findsNothing);
      expect(find.text('网页版'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'registration cancellation and unsupported device are recoverable',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'session_cookie': 'session=existing',
      });
      var attempt = 0;
      var verificationCalls = 0;
      final client = ApiClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/registration/options')) {
            return _ok({
              'challenge_id': 'challenge-123456789',
              'public_key': {'challenge': 'abc'},
            });
          }
          if (request.url.path.endsWith('/registration/verify')) {
            verificationCalls++;
          }
          return _ok([]);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PasskeyManagementPage(
            api: client,
            onUnauthorized: () {},
            registrationProvider: (_) async {
              attempt++;
              if (attempt == 1) throw const PasskeyRegistrationCancelled();
              throw const PasskeyRegistrationFailure('当前设备不支持通行密钥。');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('passkey-add-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('passkey-register-password')),
        'secret',
      );
      await tester.tap(find.byKey(const Key('passkey-register-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('已取消创建通行密钥。'), findsOneWidget);
      await tester.tap(find.byKey(const Key('passkey-register-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('当前设备不支持通行密钥。'), findsOneWidget);
      expect(verificationCalls, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('尚未添加通行密钥'), findsOneWidget);
    },
  );

  testWidgets('wrong registration password never invokes Credential Manager', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=existing',
    });
    var credentialCalls = 0;
    final client = ApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/registration/options')) {
          return _error(401, '当前密码错误');
        }
        return _ok([]);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PasskeyManagementPage(
          api: client,
          onUnauthorized: () => fail('wrong password must not sign out'),
          registrationProvider: (_) async {
            credentialCalls++;
            return {};
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('passkey-add-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('passkey-register-password')),
      'wrong',
    );
    await tester.tap(find.byKey(const Key('passkey-register-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('当前密码错误'), findsOneWidget);
    expect(credentialCalls, 0);
    expect(await client.hasStoredSession(), isTrue);
  });

  testWidgets('deletion in flight cannot be repeated or dismissed by back', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=existing',
    });
    final deletion = Completer<http.Response>();
    var deleteCalls = 0;
    final client = ApiClient(
      client: MockClient((request) async {
        if (request.method == 'DELETE') {
          deleteCalls++;
          return deletion.future;
        }
        return _ok([_credential(1, '网页版')]);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PasskeyManagementPage(api: client, onUnauthorized: () {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('passkey-remove-1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('passkey-remove-password')),
      'secret',
    );
    await tester.tap(find.byKey(const Key('passkey-remove-confirm')));
    await tester.pump();
    expect(find.text('正在移除…'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.textContaining('移除“网页版”'), findsOneWidget);
    expect(deleteCalls, 1);
    deletion.complete(_ok({'deleted': true}));
    await tester.pumpAndSettle();
    expect(find.textContaining('移除“网页版”'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('busy registration blocks duplicate submit and system back', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'session_cookie': 'session=existing',
    });
    final prompt = Completer<Map<String, dynamic>>();
    var optionsCalls = 0;
    var verifyCalls = 0;
    final client = ApiClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/registration/options')) {
          optionsCalls++;
          return _ok({
            'challenge_id': 'challenge-123456789',
            'public_key': {'challenge': 'abc'},
          });
        }
        if (request.url.path.endsWith('/registration/verify')) verifyCalls++;
        return _ok([]);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PasskeyManagementPage(
          api: client,
          onUnauthorized: () {},
          registrationProvider: (_) => prompt.future,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('passkey-add-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('passkey-register-password')),
      'secret',
    );
    await tester.tap(find.byKey(const Key('passkey-register-confirm')));
    await tester.pump();
    await tester.pump();
    expect(find.text('正在验证…'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('添加通行密钥'), findsAtLeastNWidgets(1));
    expect(optionsCalls, 1);
    expect(verifyCalls, 0);
    prompt.completeError(const PasskeyRegistrationCancelled());
    await tester.pumpAndSettle();
    expect(find.text('已取消创建通行密钥。'), findsOneWidget);
  });
}
