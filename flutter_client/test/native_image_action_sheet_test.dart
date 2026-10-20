import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_helper_flutter/native_image_action_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('hand_helper/native_image_action_sheet');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final sheet = NativeImageActionSheet(channel: channel);

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('sends the measured anchor, availability and request ID', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 'choose';
    });
    expect(
      await sheet.show(
        requestId: 19,
        title: '头像',
        canRemove: false,
        anchor: const Rect.fromLTWH(12, 84, 300, 72),
        flutterViewSize: const Size(390, 844),
      ),
      'choose',
    );
    expect(calls.single.method, 'showImageActions');
    expect(calls.single.arguments, {
      'requestId': 19,
      'title': '头像',
      'canRemove': false,
      'anchor': {'x': 12.0, 'y': 84.0, 'width': 300.0, 'height': 72.0},
      'flutterViewSize': {'width': 390.0, 'height': 844.0},
    });
  });

  test(
    'cancel, remove and matching dismissal retain explicit semantics',
    () async {
      final calls = <MethodCall>[];
      Object? answer;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'showImageActions' ? answer : null;
      });
      Future<String?> show() => sheet.show(
        requestId: 20,
        title: '首页壁纸',
        canRemove: true,
        anchor: const Rect.fromLTWH(10, 20, 80, 40),
        flutterViewSize: const Size(100, 200),
      );
      answer = null;
      expect(await show(), isNull);
      answer = 'remove';
      expect(await show(), 'remove');
      await sheet.dismiss(20);
      expect(calls.last.method, 'dismissImageActions');
      expect(calls.last.arguments, {'requestId': 20});
    },
  );

  test('rejects unexpected native actions', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => 'remove');
    expect(
      sheet.show(
        requestId: 21,
        title: '头像',
        canRemove: false,
        anchor: const Rect.fromLTWH(1, 1, 10, 10),
        flutterViewSize: const Size(100, 100),
      ),
      throwsFormatException,
    );
  });
}
