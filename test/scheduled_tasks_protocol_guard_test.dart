import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'task views cannot issue or capture protocol requests',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/task_view_protocol_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
