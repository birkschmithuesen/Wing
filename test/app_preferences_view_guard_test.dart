import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'completed app settings views use the shared preference owner',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/app_preferences_view_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'actual production preferences-view guard passes',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/rules/app_preferences_view.dart',
        '--json',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect((jsonDecode(result.stdout as String) as Map)['findings'], isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
