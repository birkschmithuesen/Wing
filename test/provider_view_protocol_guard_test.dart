import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'production provider_view_protocol guard passes the complete authored scope',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/rules/provider_view_protocol.dart',
        '--root',
        '.',
        '--json',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'provider views cannot issue protocol requests or parse wire settings',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/provider_view_protocol_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
