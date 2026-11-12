import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'production memory_view_protocol guard passes the complete authored scope',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/rules/memory_view_protocol.dart',
        '--root',
        '.',
        '--json',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'memory views cannot issue protocol requests or parse wire identities',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/memory_view_protocol_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
