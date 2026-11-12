import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/rules/completed_model_view.dart' as rule;

void main() {
  test(
    'completed production model and Health views use their typed owner',
    () async {
      expect(await rule.check(Directory.current), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'independent completed-view fixtures and source/compiled CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/completed_model_view_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
