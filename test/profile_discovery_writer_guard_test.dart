import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../tools/architecture/model.dart';
import '../tools/architecture/rules/profile_discovery_writer.dart' as rule;

void main() {
  test('Canonical profile discovery has one owner writer', () {
    expect(
      rule.check(
        Snapshot.load(Directory.current.path, 'tools/architecture/roles.json'),
      ),
      isEmpty,
    );
  });
  test(
    'Independent discovery writer fixtures and CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/profile_discovery_writer_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
