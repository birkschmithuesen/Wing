import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/model.dart';
import '../tools/architecture/rules/activity_density.dart' as rule;

void main() {
  test(
    'tool and saved-agent headers return the canonical compact row',
    () async {
      final snapshot = Snapshot.load(
        Directory.current.path,
        'tools/architecture/roles.json',
      );
      expect(await rule.check(snapshot), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'independent density fixtures and CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/activity_density_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
