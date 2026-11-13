import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/src/dart/analysis/file_byte_store.dart';

import 'package:flutter_test/flutter_test.dart';

import '../tools/architecture/model.dart';
import '../tools/architecture/semantic_context.dart';
import '../tools/architecture/rules/workspace_entry_key_owner.dart' as rule;

void main() {
  test('remembered entry key belongs to shared app preferences', () async {
    final snapshot = Snapshot.load(
      Directory.current.path,
      'tools/architecture/roles.json',
    );
    expect(await rule.check(snapshot), isEmpty);
  });
  test('summary writes finish before the fixture lifetime ends', () async {
    final root = Directory.systemTemp.createTempSync('wing-summary-lifetime-');
    try {
      final store = SynchronousSummaryByteStore(
        root.path,
        tempNameSuffix: 'test',
      );
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      expect(store.putGet('ab-summary', bytes), bytes);
      // A new reader must see the validated bytes as soon as putGet returns.
      // No event-loop yield or disposal delay may be needed to commit them.
      expect(FileByteStore(root.path).get('ab-summary'), bytes);
      root.deleteSync(recursive: true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(root.existsSync(), isFalse);
    } finally {
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  });
  test(
    'key ownership fixtures and CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/workspace_entry_key_owner_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
