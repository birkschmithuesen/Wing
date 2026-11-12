import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'production overview_view_wire guard passes the complete authored scope',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/rules/overview_view_wire.dart',
        '--root',
        '.',
        '--json',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'completed overview cannot consume raw wire/cache records',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/overview_view_wire_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
