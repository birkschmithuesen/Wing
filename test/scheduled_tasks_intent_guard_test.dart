import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'task intent and schedule semantics pass their independent pure probe',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/task_edit_intent_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );
}
