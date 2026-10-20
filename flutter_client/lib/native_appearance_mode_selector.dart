import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The iOS view displays ThemeMode; Flutter remains its only state owner.
class NativeAppearanceModeSelector extends StatefulWidget {
  const NativeAppearanceModeSelector({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final ThemeMode selected;
  final ValueChanged<ThemeMode> onSelected;

  @override
  State<NativeAppearanceModeSelector> createState() =>
      _NativeAppearanceModeSelectorState();
}

class NativeAppearanceModeController {
  NativeAppearanceModeController({
    required MethodChannel channel,
    required ThemeMode Function() selected,
    required ValueChanged<ThemeMode> onSelected,
  }) : _channel = channel,
       _selected = selected,
       _onSelected = onSelected;

  static const viewType = 'hand_helper/appearance_mode_view';
  static const modes = [ThemeMode.light, ThemeMode.dark, ThemeMode.system];

  static int indexOf(ThemeMode mode) => modes.indexOf(mode);

  static String channelName(int viewId) =>
      'hand_helper/appearance_mode/$viewId';

  final MethodChannel _channel;
  final ThemeMode Function() _selected;
  final ValueChanged<ThemeMode> _onSelected;
  int? _lastSentIndex;
  bool _disposed = false;

  void start() {
    _channel.setMethodCallHandler(_onMethodCall);
    unawaited(sync(_selected()));
  }

  Future<void> sync(ThemeMode mode) async {
    if (_disposed) return;
    final index = indexOf(mode);
    if (index == _lastSentIndex) return;
    _lastSentIndex = index;
    try {
      await _channel.invokeMethod<void>('setSelected', index);
    } on MissingPluginException {
      // The native view may have been removed during the detail's close morph.
      if (!_disposed && _lastSentIndex == index) _lastSentIndex = null;
    } on PlatformException {
      if (!_disposed && _lastSentIndex == index) _lastSentIndex = null;
    }
  }

  Future<void> _onMethodCall(MethodCall call) async {
    if (_disposed || call.method != 'selectionChanged') return;
    final index = call.arguments;
    if (index is! int || index < 0 || index >= modes.length) return;
    final mode = modes[index];
    if (mode != _selected()) _onSelected(mode);
  }

  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
  }
}

class _NativeAppearanceModeSelectorState
    extends State<NativeAppearanceModeSelector> {
  NativeAppearanceModeController? _controller;

  @override
  void didUpdateWidget(covariant NativeAppearanceModeSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      final controller = _controller;
      if (controller != null) unawaited(controller.sync(widget.selected));
    }
  }

  void _onPlatformViewCreated(int viewId) {
    if (!mounted) return;
    _controller?.dispose();
    _controller = NativeAppearanceModeController(
      channel: MethodChannel(
        NativeAppearanceModeController.channelName(viewId),
      ),
      selected: () => widget.selected,
      onSelected: (mode) {
        if (mounted) widget.onSelected(mode);
      },
    )..start();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const Key('appearance-mode-native-surface'),
    width: double.infinity,
    height: 56,
    child: UiKitView(
      viewType: NativeAppearanceModeController.viewType,
      creationParams: {
        'selectedIndex': NativeAppearanceModeController.indexOf(
          widget.selected,
        ),
      },
      creationParamsCodec: const StandardMessageCodec(),
      layoutDirection: Directionality.of(context),
      onPlatformViewCreated: _onPlatformViewCreated,
    ),
  );
}
