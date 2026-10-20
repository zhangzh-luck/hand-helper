import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_helper_flutter/appearance_mode_selector.dart';
import 'package:hand_helper_flutter/container_morph_transition.dart';
import 'package:hand_helper_flutter/native_appearance_mode_selector.dart';

void main() {
  testWidgets('Android retains the Flutter icon and Chinese labels', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppearanceModeSelector(
            selected: ThemeMode.system,
            onSelected: _unused,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('appearance-mode-surface')), findsOneWidget);
    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    expect(find.text('系统'), findsOneWidget);
    expect(find.byType(UiKitView), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS embeds one UIKit view and syncs Flutter ThemeMode', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final creations = <Map<Object?, Object?>>[];
    final updates = <MethodCall>[];
    MethodChannel? nativeChannel;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        creations.add(args);
        nativeChannel = MethodChannel(
          NativeAppearanceModeController.channelName(args['id'] as int),
        );
        messenger.setMockMethodCallHandler(nativeChannel!, (call) async {
          updates.add(call);
          return null;
        });
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      if (nativeChannel != null) {
        messenger.setMockMethodCallHandler(nativeChannel!, null);
      }
    });

    var selected = ThemeMode.system;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => AppearanceModeSelector(
              selected: selected,
              onSelected: (mode) => update(() => selected = mode),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(UiKitView), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('appearance-mode-native-surface'))).height,
      56,
    );
    expect(find.text('浅色'), findsNothing);
    expect(creations, hasLength(1));
    expect(
      creations.single['viewType'],
      NativeAppearanceModeController.viewType,
    );
    final params = const StandardMessageCodec().decodeMessage(
      ByteData.sublistView(creations.single['params']! as Uint8List),
    ) as Map<Object?, Object?>;
    expect(params['selectedIndex'], 2);
    expect(updates.last.arguments, 2);

    await messenger.handlePlatformMessage(
      nativeChannel!.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('selectionChanged', 0),
      ),
      (_) {},
    );
    await tester.pump();
    expect(selected, ThemeMode.light);
    expect(updates.last.arguments, 0);
    expect(creations, hasLength(1));

    await messenger.handlePlatformMessage(
      nativeChannel!.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('selectionChanged', 0),
      ),
      (_) {},
    );
    await tester.pump();
    expect(updates.where((call) => call.arguments == 0), hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = null;
  });

  test('native bridge handles rapid changes without a feedback loop', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('hand_helper/appearance_mode/test');
    final updates = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      updates.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    var selected = ThemeMode.system;
    var callbacks = 0;
    final controller = NativeAppearanceModeController(
      channel: channel,
      selected: () => selected,
      onSelected: (mode) {
        callbacks++;
        selected = mode;
      },
    );
    controller.start();
    await controller.sync(ThemeMode.system);
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('selectionChanged', 1),
      ),
      (_) {},
    );
    await controller.sync(selected);
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('selectionChanged', 2),
      ),
      (_) {},
    );
    await controller.sync(selected);
    await controller.sync(ThemeMode.light);
    await controller.sync(ThemeMode.light);
    expect(callbacks, 2);
    expect(updates.map((call) => call.arguments), [2, 1, 2, 0]);
    controller.dispose();
  });

  testWidgets('iOS view stays mounted inside the scrollable Morph and closes', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var creations = 0;
    MethodChannel? nativeChannel;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        creations++;
        final id = (call.arguments as Map)['id'] as int;
        nativeChannel = MethodChannel(
          NativeAppearanceModeController.channelName(id),
        );
        messenger.setMockMethodCallHandler(nativeChannel!, (_) async => null);
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      if (nativeChannel != null) {
        messenger.setMockMethodCallHandler(nativeChannel!, null);
      }
    });

    Widget morph(double progress) => MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            ContainerMorphTransition(
              progress: progress,
              isClosing: progress < 1,
              detailInteractive: progress == 1,
              startRect: const Rect.fromLTWH(20, 30, 140, 60),
              endSize: const Size(500, 900),
              startBorderRadius: BorderRadius.circular(18),
              closedColor: Colors.white,
              openColor: Colors.white,
              sourceContent: const SizedBox.shrink(),
              detailHeader: const SizedBox(height: 50),
              detailBody: ListView(
                children: const [
                  SizedBox(height: 150),
                  AppearanceModeSelector(
                    selected: ThemeMode.system,
                    onSelected: _unused,
                  ),
                  SizedBox(height: 1200),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    await tester.pumpWidget(morph(0));
    await tester.pump();
    expect(creations, 1);
    await tester.pumpWidget(morph(0.5));
    await tester.pumpWidget(morph(1));
    expect(creations, 1);
    expect(
      find.ancestor(
        of: find.byType(UiKitView),
        matching: find.byType(ClipRRect),
      ),
      findsWidgets,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -250));
    await tester.pump();
    expect(creations, 1);
    await tester.pumpWidget(morph(0.5));
    expect(creations, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(find.byType(UiKitView), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

void _unused(ThemeMode _) {}
