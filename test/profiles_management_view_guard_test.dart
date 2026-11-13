import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/rules/profiles_management_view.dart' as rule;

void main() {
  test(
    'completed profiles view uses typed owner facts and required factory',
    () async {
      expect(await rule.check(Directory.current), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'independent profile-view fixtures and source/AOT CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/profiles_management_view_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
