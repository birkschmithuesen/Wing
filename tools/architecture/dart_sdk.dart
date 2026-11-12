import 'dart:convert';
import 'dart:io';

/// Validated SDK provenance for source, Flutter-host and compiled guard runners.
String dartSdkPath(String root, {String? configured}) {
  bool valid(String path) =>
      File('$path/version').existsSync() &&
      File(
        '$path/lib/_internal/sdk_library_metadata/lib/libraries.dart',
      ).existsSync();
  if (configured != null) {
    final path = Directory(configured).absolute.path;
    if (!valid(path)) throw FormatException('Invalid Dart SDK $path');
    return path;
  }
  final running = File(Platform.resolvedExecutable).parent.parent.path;
  if (valid(running)) return running;
  // Flutter's host runner and an AOT guard binary are outside dart-sdk/bin.
  // Read the checkout's SDK dependency location instead of the binary's parent.
  final config = File('$root/.dart_tool/package_config.json');
  if (config.existsSync()) {
    final packages = (jsonDecode(config.readAsStringSync()) as Map)['packages'];
    if (packages is List) {
      for (final package in packages.whereType<Map>()) {
        if (package['name'] != 'flutter' || package['rootUri'] is! String) {
          continue;
        }
        final uri = config.uri.resolve(package['rootUri'] as String);
        if (uri.scheme != 'file') continue;
        final flutter = Directory.fromUri(uri).parent.parent.path;
        final sdk = '$flutter/bin/cache/dart-sdk';
        if (valid(sdk)) return sdk;
      }
    }
  }
  throw const FormatException('Dart SDK unavailable; pass --sdk PATH');
}
