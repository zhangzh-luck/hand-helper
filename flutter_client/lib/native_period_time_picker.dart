import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Only the picker UI is native. Period validation and persistence stay in Dart.
class NativePeriodTimePicker {
  NativePeriodTimePicker({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('hand_helper/native_period_time');

  final MethodChannel _channel;
  static int _nextRequestId = 0;

  static int nextRequestId() => ++_nextRequestId;

  Future<TimeOfDay?> pickTime({
    required TimeOfDay initialTime,
    required String title,
    required int requestId,
  }) async {
    final result = await _channel.invokeMapMethod<String, int>('pickTime', {
      'initialHour': initialTime.hour,
      'initialMinute': initialTime.minute,
      'title': title,
      'requestId': requestId,
    });
    if (result == null) return null;
    final hour = result['hour'];
    final minute = result['minute'];
    if (hour == null ||
        hour < 0 ||
        hour > 23 ||
        minute == null ||
        minute < 0 ||
        minute > 59) {
      throw const FormatException('Invalid native time picker result');
    }
    return TimeOfDay(hour: hour, minute: minute);
  }

  Future<void> dismiss(int requestId) async {
    await _channel.invokeMethod<void>('dismissTimePicker', {
      'requestId': requestId,
    });
  }
}
