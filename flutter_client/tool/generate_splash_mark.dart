import 'dart:io';

import 'package:image/image.dart' as img;

/// Builds density-specific Android splash assets from the approved mark.
///
/// The transparent 288 dp canvas keeps the artwork within the Android 12+
/// splash safe region. Its visible mark is 100 dp, matching LaunchPreview.
void main() {
  final sourceFile = File('assets/icon/splash_mark.png');
  final source = img.decodePng(sourceFile.readAsBytesSync());
  if (source == null) {
    throw StateError('Could not decode ${sourceFile.path}');
  }

  const densities = <String, double>{
    'mdpi': 1,
    'hdpi': 1.5,
    'xhdpi': 2,
    'xxhdpi': 3,
    'xxxhdpi': 4,
  };
  for (final entry in densities.entries) {
    final canvasSize = (288 * entry.value).round();
    final markSize = (100 * entry.value).round();
    final mark = img.copyResize(
      source,
      width: markSize,
      height: markSize,
      interpolation: img.Interpolation.average,
    );
    final canvas = img.Image(
      width: canvasSize,
      height: canvasSize,
      numChannels: 4,
    );
    img.fill(canvas, color: img.ColorRgba8(0, 0, 0, 0));
    img.compositeImage(
      canvas,
      mark,
      dstX: (canvasSize - markSize) ~/ 2,
      dstY: (canvasSize - markSize) ~/ 2,
    );

    final output = File(
      'android/app/src/main/res/drawable-${entry.key}/splash_mark.png',
    );
    output.parent.createSync(recursive: true);
    output.writeAsBytesSync(img.encodePng(canvas));
    stdout.writeln('${output.path}: ${canvasSize}x$canvasSize');
  }
}
