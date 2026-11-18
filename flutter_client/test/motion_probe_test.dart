import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_helper_flutter/motion_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('hand_helper/motion_probe');

  test('probe requires opt in and reports native results without course content', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'report') return 'engine=Flutter\nsamples=0';
      return null;
    });
    expect(MotionProbe.available, isTrue);
    MotionProbe.event('tap');
    expect(calls, isEmpty);
    await MotionProbe.setEnabled(true);
    MotionProbe.event('tap');
    MotionProbe.event('start');
    MotionProbe.event('complete');
    await Future<void>.delayed(Duration.zero);
    expect(calls, containsAllInOrder(['enable', 'event']));
    final report = await MotionProbe.report();
    expect(report, contains('samples=0'));
    expect(report, contains('entire enabled session'));
    expect(report, contains('Flutter per-opening FrameTiming'));
    expect(report, contains('id=1 frames='));
    await MotionProbe.setEnabled(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }, skip: !MotionProbe.available);
}
