import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/rules/owned_model_mutation.dart' as rule;

void main() {
  test('completed model owners invoke explicit owned mutations', () async {
    expect(await rule.check(Directory.current), isEmpty);
  });
  test(
    'owned mutation fixtures prove actual CLI exits 1/0/2',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/owned_model_mutation_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
