import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/rules/secure_reply_view_wire.dart' as rule;

void main() {
  test('secure prompt view borrows typed reply encoding', () {
    expect(rule.check(Directory.current), isEmpty);
  });
  test(
    'secure reply namespace fixtures and CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/secure_reply_view_wire_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
