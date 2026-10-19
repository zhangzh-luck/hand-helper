import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The iOS scene owns the actual UITabBar. Android never calls this channel.
class NativeTabBridge {
  NativeTabBridge._();

  static const _channel = MethodChannel('hand_helper/native_tab');
  static bool get enabled => defaultTargetPlatform == TargetPlatform.iOS;
  static ValueChanged<int>? _onSelected;
  static VoidCallback? _onReady;

  static void attach({
    required ValueChanged<int> onSelected,
    required VoidCallback onReady,
  }) {
    if (!enabled) return;
    _onSelected = onSelected;
    _onReady = onReady;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'selectTab') {
        final index = call.arguments;
        if (index is int && index >= 0 && index < 4) {
          _onSelected?.call(index);
        }
      } else if (call.method == 'requestState') {
        _onReady?.call();
      }
    });
  }

  static void detach() {
    if (!enabled) return;
    _onSelected = null;
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
    required bool dark,
  }) {
    if (!enabled) return;
    unawaited(
      _invoke('sync', {
        'visible': true,
        'selected': selected,
        'detailOpen': detailOpen,
        'dark': dark,
      }),
    );
  }

  static void setAvatar(String? dataUrl) {
    if (!enabled) return;
    unawaited(_invoke('setAvatar', dataUrl));
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
}
