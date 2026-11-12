import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/rules/backup_owner_boundary.dart' as rule;

void main() {
  test(
    'completed backup UI and service keep their named owner boundary',
    () async {
      expect(await rule.check(Directory.current), isEmpty);
    },
  );
  test(
    'actual production backup owner boundary guard passes',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/rules/backup_owner_boundary.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(
        '${result.stdout}${result.stderr}',
        isNot(contains('[${rule.id}')),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'independent backup boundary fixtures and source/AOT CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/backup_owner_boundary_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
