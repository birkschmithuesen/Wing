import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/model.dart';
import '../tools/architecture/rules/workspace_canonical_state.dart' as rule;

void main() {
  test('canonical workspace facts have no external writers', () {
    final root = Directory.current.path;
    expect(
      rule.check(Snapshot.load(root, '$root/tools/architecture/roles.json')),
      isEmpty,
    );
  });

  test(
    'canonical state declaration fixtures and CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/workspace_canonical_state_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
