import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/rules/browser_row_work.dart' as rule;

void main() {
  test(
    'browser row refresh avoids the connection-wide index accessor',
    () async {
      expect(await rule.check(Directory.current), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'browser-row fixtures and real source/AOT CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/browser_row_work_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
