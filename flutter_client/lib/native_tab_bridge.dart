import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;

/// The iOS scene owns the actual UITabBar. Android never calls this channel.
class NativeTabBridge {
  NativeTabBridge._();

  static const _channel = MethodChannel('hand_helper/native_tab');
  static bool get enabled => defaultTargetPlatform == TargetPlatform.iOS;
  static ValueChanged<int>? _onSelected;
  static ValueChanged<double>? _onMetrics;
  static VoidCallback? _onReady;

  static void attach({
    required ValueChanged<int> onSelected,
    required ValueChanged<double> onMetrics,
    required VoidCallback onReady,
  }) {
    if (!enabled) return;
    _onSelected = onSelected;
    _onMetrics = onMetrics;
    _onReady = onReady;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'selectTab') {
        final index = call.arguments;
        if (index is int && index >= 0 && index < 4) {
          _onSelected?.call(index);
        }
      } else if (call.method == 'requestState') {
        _onReady?.call();
        unawaited(_requestMetrics());
      } else if (call.method == 'tabMetrics') {
        final height = call.arguments;
        if (height is num && height >= 0) {
          _onMetrics?.call(height.toDouble());
        }
      }
    });
    unawaited(_requestMetrics());
  }

  static void detach() {
    if (!enabled) return;
    _onSelected = null;
    _onMetrics = null;
    _onReady = null;
    _channel.setMethodCallHandler(null);
    unawaited(_invoke('setAvatar', null));
    unawaited(
      _invoke('sync', {'visible': false, 'selected': 0, 'detailOpen': false}),
    );
  }

  static void sync({
    required int selected,
    required bool detailOpen,
    required String appearance,
  }) {
    if (!enabled) return;
    unawaited(
      _invoke('sync', {
        'visible': true,
        'selected': selected,
        'detailOpen': detailOpen,
        'appearance': appearance,
      }),
    );
  }

  static void setAppearance(String appearance) {
    if (!enabled) return;
    unawaited(_invoke('setAppearance', appearance));
  }

  /// Prepares a small, full-color circular image off the UI isolate. A null
  /// result asks UIKit to restore its SF Symbol instead of retaining old data.
  static Future<Uint8List?> prepareAvatar(String source) =>
      compute(_prepareAvatar, source);

  static void setAvatar(Uint8List? image) {
    if (!enabled) return;
    unawaited(_invoke('setAvatar', image));
  }

  static Future<void> _invoke(String method, Object? arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // A host without the native tab (for example a Flutter widget test).
    } on PlatformException catch (error) {
      debugPrint('Native tab channel error: $error');
    }
  }

  static Future<void> _requestMetrics() async {
    try {
      final height = await _channel.invokeMethod<double>('getMetrics');
      if (height != null && height >= 0) _onMetrics?.call(height);
    } on MissingPluginException {
      // Widget tests have no UIKit host.
    } on PlatformException catch (error) {
      debugPrint('Native tab metrics error: $error');
    }
  }
}

Uint8List? _prepareAvatar(String source) {
  try {
    final comma = source.indexOf(',');
    if (!source.startsWith('data:image/') ||
        comma < 0 ||
        !source.substring(0, comma).contains(';base64')) {
      return null;
    }
    final decoded = img.decodeImage(base64Decode(source.substring(comma + 1)));
    if (decoded == null) return null;
    // JPEG avatars have no alpha channel. The crop mask needs an RGBA target,
    // otherwise its transparent corners are discarded when PNG is encoded.
    final circular = img.copyResizeCropSquare(
      img.bakeOrientation(decoded).convert(numChannels: 4),
      size: 96,
      interpolation: img.Interpolation.average,
      radius: 48,
      antialias: true,
    );
    return Uint8List.fromList(img.encodePng(circular));
  } catch (_) {
    return null;
  }
}

/// The measured system bar overlap stays constant while detail pages animate.
class NativeTabMetrics extends InheritedWidget {
  const NativeTabMetrics({
    super.key,
    required this.bottomOverlap,
    required super.child,
  });

  final double bottomOverlap;

  static double contentBottomPadding(
    BuildContext context, {
    required double android,
  }) {
    if (!NativeTabBridge.enabled) return android;
    // Flutter already shrinks the Scaffold for the keyboard. The UIKit bar is
    // hidden then, so reserving its overlap would leave an empty strip.
    if (MediaQuery.viewInsetsOf(context).bottom > 0) return 24;
    final overlap =
        context
            .dependOnInheritedWidgetOfExactType<NativeTabMetrics>()
            ?.bottomOverlap ??
        0;
    return overlap + 24;
  }

  @override
  bool updateShouldNotify(NativeTabMetrics oldWidget) =>
      bottomOverlap != oldWidget.bottomOverlap;
}
