import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'production deleted_draft_cleanup_boundary guard passes the complete authored scope',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/rules/deleted_draft_cleanup_boundary.dart',
        '--root',
        '.',
        '--json',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'durable cleanup capability guard passes its independent CLI fixtures',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/deleted_draft_cleanup_boundary_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
