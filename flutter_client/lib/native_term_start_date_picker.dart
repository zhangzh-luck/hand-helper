import 'package:flutter/services.dart';

/// The native sheet selects a date; the Monday rule and saving remain in Dart.
class NativeTermStartDatePicker {
  NativeTermStartDatePicker({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('hand_helper/native_term_start_date');

  final MethodChannel _channel;
  static int _nextRequestId = 0;

  static int nextRequestId() => ++_nextRequestId;

  Future<DateTime?> pickDate({
    required DateTime initialDate,
    required int requestId,
  }) async {
    final result = await _channel.invokeMapMethod<String, int>('pickDate', {
      'initialYear': initialDate.year,
      'initialMonth': initialDate.month,
      'initialDay': initialDate.day,
      'requestId': requestId,
    });
    if (result == null) return null;
    final year = result['year'];
    final month = result['month'];
    final day = result['day'];
    if (year == null ||
        year < 2010 ||
        year > 2100 ||
        month == null ||
        month < 1 ||
        month > 12 ||
        day == null ||
        day < 1 ||
        day > 31) {
      throw const FormatException('Invalid native date picker result');
    }
    final date = DateTime(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      throw const FormatException('Invalid native date picker result');
    }
    // Match showDatePicker(firstDate: DateTime(2010), lastDate: DateTime(2100)).
    if (date.isAfter(DateTime(2100))) {
      throw const FormatException('Native date picker result exceeds range');
    }
    return date;
  }

  Future<void> dismiss(int requestId) async {
    await _channel.invokeMethod<void>('dismissDatePicker', {
      'requestId': requestId,
    });
  }
}
