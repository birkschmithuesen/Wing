import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/model.dart';
import '../tools/architecture/rules/row_actions_view_dependencies.dart' as rule;

void main() {
  test('row actions preserves its owner contract', () {
    final snapshot = Snapshot.load(
      Directory.current.path,
      'tools/architecture/roles.json',
    );
    expect(rule.check(snapshot), isEmpty);
  });

  test(
    'independent row_actions fixtures and CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/row_actions_view_dependencies_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
