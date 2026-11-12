import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/tests/dart_main_roots_test.dart' as fixtures;

void main() {
  test(
    'Dart main roots: parsed fixtures and actual standalone CLI',
    () async {
      await fixtures.prove();
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
  test(
    'actual production Dart mains have inventoried roots',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/rules/dart_main_roots.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('0 uncovered main declarations'));
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
