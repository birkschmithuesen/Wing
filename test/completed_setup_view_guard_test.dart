import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/rules/completed_setup_view.dart' as rule;

void main() {
  test(
    'completed setup view delegates candidate, auth and verification work',
    () async {
      expect(await rule.check(Directory.current), isEmpty);
    },
    // Resolving the production view includes the Flutter SDK on a cold cache.
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'independent setup-view fixtures and source/AOT CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/completed_setup_view_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
