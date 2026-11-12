import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'settings owner construction stays at bootstrap',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/app_preferences_construction_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'actual production settings-owner construction guard passes',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/rules/app_preferences_construction.dart',
        '--json',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(
        jsonDecode(result.stdout as String),
        containsPair('findings', isEmpty),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
