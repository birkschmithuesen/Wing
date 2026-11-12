import 'dart:convert';
import 'dart:io';

import '../model.dart';
import '../rules/resume_durable_identity.dart' as rule;
import '../proof_process.dart';

const _part = 'lib/core/services/notification_resume_part.dart';
const _good = '''class ProfileWorkspaceController {
  void loadNotificationApproval(key) { if (gateway.resumeDurableId(resumed) != key) return; }
  void _loadNotificationInput(candidate) { if (gateway.resumeDurableId(resumed) != candidate) return; }
  void activeList(row) { if (row['session_key'] != session) return; }
}''';
const _bad = '''class ProfileWorkspaceController {
  void loadNotificationApproval(key) { if (resumed['session_key'] != key) return; }
  void _loadNotificationInput(candidate) { if (resumed['session_key'] != candidate) return; }
}''';

class _Case {
  const _Case(
    this.name,
    this.files,
    this.exit, {
    this.expected = const [],
    this.libraries = const {},
    this.cli = false,
  });
  final String name;
  final Map<String, String> files;
  final int exit;
  final List<(String, int, String)> expected;
  final Map<String, String> libraries;
  final bool cli;
}

const _cases = [
  _Case(
    'original-two-sites',
    {rule.owner: _bad},
    1,
    cli: true,
    expected: [
      (
        rule.owner,
        2,
        'ProfileWorkspaceController.loadNotificationApproval:session_key',
      ),
      (
        rule.owner,
        3,
        'ProfileWorkspaceController._loadNotificationInput:session_key',
      ),
    ],
  ),
  _Case(
    'current-projection-and-active-list',
    {rule.owner: _good},
    0,
    cli: true,
  ),
  _Case('unrelated-homonyms', {rule.owner: _good, 'lib/other.dart': _bad}, 0),
  _Case(
    'actual-part',
    {
      rule.owner: "part 'notification_resume_part.dart';",
      _part: "part of 'profile_workspace_controller.dart';\n$_bad",
    },
    1,
    libraries: {_part: rule.owner},
    expected: [
      (
        _part,
        3,
        'ProfileWorkspaceController.loadNotificationApproval:session_key',
      ),
      (
        _part,
        4,
        'ProfileWorkspaceController._loadNotificationInput:session_key',
      ),
    ],
  ),
  _Case(
    'other-current-wire-field',
    {
      rule.owner: '''class ProfileWorkspaceController {
  void loadNotificationApproval(key) { if (resumed[('stored_session_id')] != key) return; }
  void _loadNotificationInput(candidate) { if (gateway.resumeDurableId(resumed) != candidate) return; }
}''',
    },
    1,
    expected: [
      (
        rule.owner,
        2,
        'ProfileWorkspaceController.loadNotificationApproval:stored_session_id',
      ),
    ],
  ),
  _Case(
    'missing-method',
    {
      rule.owner:
          'class ProfileWorkspaceController { void loadNotificationApproval(key) {} }',
    },
    2,
    cli: true,
  ),
];

List<String> tuples(List<Finding> findings) => [
  for (final finding in findings)
    jsonEncode([finding.id, finding.file, finding.line, finding.subject]),
]..sort();

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  final cliExits = <int>{};
  for (final fixture in _cases) {
    final directory = Directory.systemTemp.createTempSync('wing-resume-id-');
    try {
      final roles = <String, Object>{};
      for (final entry in fixture.files.entries) {
        final file = File('${directory.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
        roles[entry.key] = {
          'role': 'application',
          'feature': 'notification-resume',
          'library': fixture.libraries[entry.key] ?? entry.key,
        };
      }
      final rolePath = '${directory.path}/roles.json';
      File(
        rolePath,
      ).writeAsStringSync(jsonEncode({'schema': 1, 'files': roles}));
      var actual = 0;
      var findings = <Finding>[];
      try {
        findings = rule.check(Snapshot.load(directory.path, rolePath));
        actual = findings.isEmpty ? 0 : 1;
      } on FormatException {
        actual = 2;
      }
      final expected = [
        for (final tuple in fixture.expected)
          jsonEncode([rule.id, tuple.$1, tuple.$2, tuple.$3]),
      ]..sort();
      if (actual != fixture.exit ||
          jsonEncode(tuples(findings)) != jsonEncode(expected)) {
        throw StateError(
          '${fixture.name}: expected ${fixture.exit}/$expected, got $actual/${tuples(findings)}',
        );
      }
      if (fixture.cli) {
        if (!cliExits.add(fixture.exit)) {
          throw StateError('Duplicate CLI representative');
        }
        final result = await runProofProcess(proofDartExecutable, [
          'run',
          'tools/architecture/rules/resume_durable_identity.dart',
          '--root',
          directory.path,
          '--roles',
          rolePath,
          '--strict',
          '--json',
        ]);
        if (result.exitCode != fixture.exit) {
          throw StateError(
            '${fixture.name}: CLI ${result.exitCode}: ${result.stdout} ${result.stderr}',
          );
        }
        if (fixture.exit == 2) {
          if (!(result.stderr as String).contains('[ARCH_INPUT]')) {
            throw StateError('Missing CLI input diagnostic');
          }
        } else {
          final diagnostics =
              (jsonDecode(result.stdout as String) as Map)['problems'] as List;
          final actualTuples = [
            for (final row in diagnostics)
              jsonEncode([row['id'], row['file'], row['line'], row['subject']]),
          ]..sort();
          if (jsonEncode(actualTuples) != jsonEncode(expected)) {
            throw StateError('CLI diagnostic identity/location/count mismatch');
          }
        }
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  }
  if (cliExits.length != 3) throw StateError('Missing CLI exits1/0/2');
  stdout.writeln(
    '${rule.id}: ${_cases.length} detector fixtures; three CLI representatives passed',
  );
}
