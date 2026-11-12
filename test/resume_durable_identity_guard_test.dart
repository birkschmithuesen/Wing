import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/model.dart';
import '../tools/architecture/rules/resume_durable_identity.dart' as rule;

void main() {
  test('captured notification resumes use durable identity projection', () {
    final snapshot = Snapshot.load(
      Directory.current.path,
      'tools/architecture/roles.json',
    );
    expect(rule.check(snapshot), isEmpty);
  });

  test(
    'resume identity guard fixtures and CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/resume_durable_identity_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
