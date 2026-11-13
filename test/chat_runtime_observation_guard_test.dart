import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/rules/chat_runtime_observation.dart' as rule;

void main() {
  test(
    'ProfileChat exposes passive canonical runtime observations',
    () async {
      expect(await rule.check(Directory.current), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'finite runtime declaration fixtures and CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/chat_runtime_observation_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
