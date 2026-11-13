import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'colour views delegate storage to their injected owner',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/profile_colours_view_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test(
    'actual production colour view boundary passes',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/rules/profile_colours_view.dart',
        '--json',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(
        jsonDecode(result.stdout as String),
        containsPair('findings', isEmpty),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
