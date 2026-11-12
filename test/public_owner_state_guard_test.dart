import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/rules/public_owner_state.dart' as rule;

void main() {
  test('completed owner observations have no public writers', () {
    expect(rule.check(Directory.current), isEmpty);
  });

  test(
    'independent owner declaration fixtures and CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/public_owner_state_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
