import 'package:flutter/services.dart';

/// UIKit owns only the action menu; image editing and persistence stay in Dart.
class NativeImageActionSheet {
  NativeImageActionSheet({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('hand_helper/native_image_action_sheet');

  final MethodChannel _channel;
  static int _nextRequestId = 0;

  static int nextRequestId() => ++_nextRequestId;

  Future<String?> show({
    required int requestId,
    required String title,
    required bool canRemove,
    required Rect anchor,
    required Size flutterViewSize,
  }) async {
    final choice = await _channel.invokeMethod<String>('showImageActions', {
      'requestId': requestId,
      'title': title,
      'canRemove': canRemove,
      'anchor': {
        'x': anchor.left,
        'y': anchor.top,
        'width': anchor.width,
        'height': anchor.height,
      },
      'flutterViewSize': {
        'width': flutterViewSize.width,
        'height': flutterViewSize.height,
      },
    });
    if (choice != null && choice != 'choose' && choice != 'remove') {
      throw const FormatException('Invalid native image action');
    }
    if (choice == 'remove' && !canRemove) {
      throw const FormatException('Unexpected native remove action');
    }
    return choice;
  }

  Future<void> dismiss(int requestId) => _channel.invokeMethod<void>(
    'dismissImageActions',
    {'requestId': requestId},
  );
}
