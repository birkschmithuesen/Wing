import 'dart:convert';
import 'dart:io';

import '../dart_sdk.dart';
import '../model.dart';
import '../rules/workspace_entry_key_owner.dart' as rule;
import 'app_preferences_view_test.dart' as support;
import '../proof_process.dart';

const mainView = 'lib/main.dart';
const ownerPart = 'lib/core/services/app_preferences_workspace_entry.dart';
const prefsImport =
    "import 'package:shared_preferences/shared_preferences.dart';\n";
const codecSource =
    "class WorkspaceEntryCodec { static const storageKey = 'last_connection_id'; }";
const _cases = [
  (
    name: 'raw literal key outside owner',
    source:
        '${prefsImport}class HomeScreenState { Object? read(SharedPreferences p) => p.getString("last_connection_id"); }',
    exit: 1,
    subjects: ['SharedPreferences.getString'],
    members: ['getString'],
    extra: <String, String>{},
  ),
  (
    name: 'original constant raw read and write',
    source:
        '${prefsImport}class HomeScreenState { static const _lastConnectionKey = "last_connection_id"; Object? read(SharedPreferences p) => p.getString(_lastConnectionKey); Future<void> save(SharedPreferences p) async { await p.setString(_lastConnectionKey, "work"); } }',
    exit: 1,
    subjects: ['SharedPreferences.getString', 'SharedPreferences.setString'],
    members: ['getString', 'setString'],
    extra: <String, String>{},
  ),
  (
    name: 'prefixed canonical key capture',
    source:
        "import 'package:wing/core/models/workspace_entry.dart' as facts;\nclass HomeScreenState { Object key() => facts.WorkspaceEntryCodec.storageKey; }",
    exit: 1,
    subjects: ['WorkspaceEntryCodec.storageKey'],
    members: ['storageKey'],
    extra: <String, String>{},
  ),
  (
    name: 'owned actual part and unrelated APIs',
    source:
        '${prefsImport}class HomeScreenState {}\nclass WorkspaceEntryCodec { static const storageKey = "last_connection_id"; }\nclass OtherPreferences { Object getString(String key) => key; }\nObject unrelated(OtherPreferences p) => p.getString("last_connection_id");\nObject unrelatedCapture() => WorkspaceEntryCodec.storageKey;\nString display() => "last_connection_id";\nObject? permission(SharedPreferences p) => p.getBool("startup_permission_requested");',
    exit: 0,
    subjects: <String>[],
    members: <String>[],
    extra: <String, String>{},
  ),
  (
    name: 'missing key authority fails input',
    source: 'class HomeScreenState {}',
    exit: 2,
    subjects: <String>[],
    members: <String>[],
    extra: <String, String>{},
  ),
  (
    name: 'literal-backed constant alias across declared sources',
    source:
        "import 'package:shared_preferences/shared_preferences.dart'; import 'key_alias.dart' as keys;\nclass HomeScreenState { Object? read(SharedPreferences p) => p.getString(keys.entryAlias); }",
    exit: 1,
    subjects: ['SharedPreferences.getString'],
    members: ['getString'],
    extra: {
      'lib/key_alias.dart':
          'const entryKey = "last_connection_id"; const entryAlias = entryKey;',
    },
  ),
];

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  final sdk = dartSdkPath(Directory.current.path);
  final cliExits = <int>{};
  for (final fixture in _cases) {
    final workspace = support.Workspace()
      ..load(
        support.Case(
          fixture.name,
          'class AppSettingsContent {}',
          extra: {
            rule.codec: codecSource,
            rule.owner: fixture.exit == 2
                ? 'class OtherOwner {}'
                : "import '../models/workspace_entry.dart';\n$prefsImport"
                      "part 'app_preferences_workspace_entry.dart';\nclass AppPreferences {}",
            if (fixture.exit != 2)
              ownerPart:
                  "part of 'app_preferences.dart';\nObject? ownedRead(SharedPreferences p) => p.getString(WorkspaceEntryCodec.storageKey);",
            mainView: fixture.source,
            ...fixture.extra,
          },
        ),
      );
    try {
      var actual = 0;
      var findings = <Finding>[];
      try {
        findings = await rule.check(workspace.snapshot, sdkPath: sdk);
        actual = findings.isEmpty ? 0 : 1;
      } on FormatException {
        actual = 2;
      }
      if (actual != fixture.exit ||
          findings.length != fixture.subjects.length) {
        throw StateError(
          '${fixture.name}: expected ${fixture.exit}, got $actual $findings',
        );
      }
      for (var i = 0; i < findings.length; i++) {
        final finding = findings[i];
        final offset = fixture.source.indexOf(fixture.members[i]);
        if (finding.id != rule.id ||
            finding.file != mainView ||
            finding.line != 2 ||
            finding.subject != '${fixture.subjects[i]}@$offset') {
          throw StateError('${fixture.name}: wrong exact diagnostic $finding');
        }
      }
      if ({
        'raw literal key outside owner',
        'owned actual part and unrelated APIs',
        'missing key authority fails input',
      }.contains(fixture.name)) {
        if (!cliExits.add(actual)) {
          throw StateError('Duplicate CLI representative');
        }
        final result = await runProofProcess(proofDartExecutable, [
          'run',
          'tools/architecture/rules/workspace_entry_key_owner.dart',
          '--root',
          workspace.directory.path,
          '--roles',
          workspace.rolesPath,
          '--json',
        ]);
        if (result.exitCode != actual) {
          throw StateError(
            '${fixture.name}: CLI ${result.exitCode}: ${result.stdout} ${result.stderr}',
          );
        }
        if (actual == 2) {
          if (!(result.stderr as String).contains('[ARCH_INPUT]')) {
            throw StateError('Missing CLI input diagnostic');
          }
        } else {
          final problems =
              (jsonDecode(result.stdout as String) as Map)['problems'] as List;
          if (problems.length != findings.length) {
            throw StateError('CLI diagnostic count mismatch');
          }
          for (var i = 0; i < findings.length; i++) {
            final finding = findings[i];
            final problem = problems[i] as Map;
            if (problem['id'] != finding.id ||
                problem['file'] != finding.file ||
                problem['line'] != finding.line ||
                problem['subject'] != finding.subject) {
              throw StateError('CLI diagnostic identity/location mismatch');
            }
          }
        }
      }
    } finally {
      workspace.dispose();
    }
  }
  if (cliExits.length != 3) throw StateError('CLI exits 1/0/2 not exercised');
  stdout.writeln(
    '${rule.id}: ${_cases.length} detector fixtures; three CLI representatives passed',
  );
}
