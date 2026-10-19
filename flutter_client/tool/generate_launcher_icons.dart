import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as image;

/// Regenerates platform launcher icons from the checked-in 1024px artwork.
/// Run from the Flutter project root: dart run tool/generate_launcher_icons.dart
void main() {
  final sourceFile = File('assets/icon/app_icon.png');
  final source = image.decodePng(sourceFile.readAsBytesSync());
  if (source == null ||
      source.width != 1024 ||
      source.height != 1024 ||
      source.numChannels != 3) {
    throw StateError('Expected an opaque RGB 1024x1024 source icon.');
  }

  void writeIcon(String path, int size) {
    final resized = image.copyResize(
      source,
      width: size,
      height: size,
      interpolation: image.Interpolation.average,
    );
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(image.encodePng(resized));
  }

  const androidSizes = <String, int>{
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };
  for (final entry in androidSizes.entries) {
    writeIcon(
      'android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png',
      entry.value,
    );
  }

  const appIconDirectory = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
  final manifest = jsonDecode(
    File('$appIconDirectory/Contents.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final generated = <String, int>{};
  for (final raw in manifest['images'] as List) {
    final item = Map<String, dynamic>.from(raw as Map);
    final filename = item['filename'] as String?;
    if (filename == null) continue;
    final points = double.parse((item['size'] as String).split('x').first);
    final scale = int.parse((item['scale'] as String).replaceAll('x', ''));
    final pixels = (points * scale).round();
    if (generated[filename] == pixels) continue;
    if (generated.containsKey(filename)) {
      throw StateError('Conflicting dimensions for $filename.');
    }
    generated[filename] = pixels;
    writeIcon('$appIconDirectory/$filename', pixels);
  }
  stdout.writeln(
    'Generated ${androidSizes.length} Android and '
    '${generated.length} iOS launcher icons.',
  );
}
