import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../tools/architecture/model.dart';
import '../tools/architecture/rules/saved_prompt_journal_admission.dart'
    as rule;

void main() {
  test('Saved-prompt staging rechecks admission after its journal', () {
    expect(
      rule.check(
        Snapshot.load(Directory.current.path, 'tools/architecture/roles.json'),
      ),
      isEmpty,
    );
  });
  test(
    'Saved-prompt journal admission fixtures and CLI exits pass',
    () async {
      final result = await Process.run('dart', [
        'run',
        'tools/architecture/tests/saved_prompt_journal_admission_test.dart',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    // This is a subprocess watchdog for three fresh source CLIs, not a rule
    // performance budget. Match the other multi-CLI architecture fixtures.
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
