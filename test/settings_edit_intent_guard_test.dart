import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'settings intent and decimal codec pass the independent pure probe',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/settings_edit_intent_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
