import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'canonical provider values enforce metadata and bounded device-code contract',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/provider_values_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
