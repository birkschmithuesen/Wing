import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'draft ownership guard passes its independent CLI fixtures',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/view_draft_write_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
