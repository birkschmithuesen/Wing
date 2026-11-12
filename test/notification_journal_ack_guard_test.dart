import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../tools/architecture/dart_sdk.dart';
import '../tools/architecture/proof_process.dart';

void main() {
  test(
    'notification journal ACK guard actual fixtures',
    () async {
      final sdk = dartSdkPath(Directory.current.path);
      final result = await runProofProcess('$sdk/bin/dart', [
        'run',
        'tools/architecture/tests/notification_journal_ack_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
  test(
    'actual production notification journal ACK is preserved',
    () async {
      final sdk = dartSdkPath(Directory.current.path);
      final result = await runProofProcess('$sdk/bin/dart', [
        'run',
        'tools/architecture/rules/notification_journal_ack.dart',
        '--json',
        '--sdk',
        sdk,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect((jsonDecode(result.stdout as String) as Map)['findings'], isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
