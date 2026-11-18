import 'dart:async';
import 'dart:ui' show FrameTiming;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// Included in the UI only in the separately built, opt-in test app.
class MotionProbe {
  static const available = bool.fromEnvironment('MOTION_PROBE');
  static const _channel = MethodChannel('hand_helper/motion_probe');
  static bool enabled = false;
  static final List<int> _buildMicros = [];
  static final List<int> _rasterMicros = [];
  static final List<int> _totalMicros = [];
  static final List<String> _dartSamples = [];
  static Stopwatch? _stopwatch;
  static int? _animationStartUs;
  static int _sampleID = 0;

  static void _finishDart(bool interrupted) {
    final watch = _stopwatch;
    if (watch == null) return;
    final end = watch.elapsedMicroseconds;
    if (_dartSamples.length == 100) _dartSamples.removeAt(0);
    _dartSamples.add('id=$_sampleID interrupted=$interrupted start_us=${_animationStartUs ?? 'n/a'} end_us=$end');
    watch.stop();
    _stopwatch = null;
  }

  static void _frames(List<FrameTiming> frames) {
    for (final frame in frames) {
      if (_buildMicros.length >= 5000) break;
      _buildMicros.add(frame.buildDuration.inMicroseconds);
      _rasterMicros.add(frame.rasterDuration.inMicroseconds);
      _totalMicros.add(frame.totalSpan.inMicroseconds);
    }
  }

  static Future<void> setEnabled(bool value) async {
    if (!available || value == enabled) return;
    if (value) {
      SchedulerBinding.instance.addTimingsCallback(_frames);
    } else {
      SchedulerBinding.instance.removeTimingsCallback(_frames);
      _finishDart(true);
    }
    enabled = value;
    await _channel.invokeMethod<void>('enable', value);
  }

  static void event(String event) {
    if (available && enabled) {
      if (event == 'tap') {
        _finishDart(true);
        _sampleID++;
        _animationStartUs = null;
        _stopwatch = Stopwatch()..start();
      } else if (event == 'start') {
        _animationStartUs = _stopwatch?.elapsedMicroseconds;
      } else if (event == 'complete' || event == 'cancel') {
        _finishDart(event == 'cancel');
      }
      unawaited(_channel.invokeMethod<void>('event', event));
    }
  }

  static Future<void> clear() async {
    _buildMicros.clear(); _rasterMicros.clear(); _totalMicros.clear();
    _stopwatch?.stop(); _stopwatch = null; _dartSamples.clear(); _sampleID = 0;
    await _channel.invokeMethod<void>('clear');
  }

  static Future<String> report() async {
    final native = await _channel.invokeMethod<String>('report') ?? 'native report unavailable';
    String maxMs(List<int> values) => values.isEmpty
        ? 'n/a'
        : (values.reduce((a, b) => a > b ? a : b) / 1000).toStringAsFixed(2);
    return '$native\nFlutter FrameTiming: entire enabled session, asynchronous batches; not animation-only'
        '\nengine_frames=${_buildMicros.length} max_build_ms=${maxMs(_buildMicros)}'
        ' max_raster_ms=${maxMs(_rasterMicros)} max_total_ms=${maxMs(_totalMicros)}'
        '\nDart Stopwatch: tap handler to controller start/completed; not visible-frame time'
        '\n${_dartSamples.join('\n')}';
  }
}
