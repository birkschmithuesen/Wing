import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../tools/architecture/model.dart';
import '../tools/architecture/rules/retired_answer_versions_namespace.dart'
    as rule;

void main() {
  test('Workspace no longer carries the retired answer namespace', () {
    expect(
      rule.check(
        Snapshot.load(Directory.current.path, 'tools/architecture/roles.json'),
      ),
      isEmpty,
    );
  });
  test(
    'Retired answer namespace fixtures and CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/retired_answer_versions_namespace_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
