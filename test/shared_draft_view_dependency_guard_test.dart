import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/model.dart';
import '../tools/architecture/rules/shared_draft_view_dependencies.dart'
    as rule;

void main() {
  test('Shared draft review uses its typed captured owner', () {
    final snapshot = Snapshot.load(
      Directory.current.path,
      'tools/architecture/roles.json',
    );
    expect(rule.check(snapshot), isEmpty);
  });

  test(
    'independent share dependency fixtures and CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/shared_draft_view_dependencies_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
