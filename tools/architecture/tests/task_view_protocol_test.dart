import 'dart:convert';
import 'dart:io';

import '../model.dart';
import '../fixture_contract.dart';
import '../dart_sdk.dart';
import '../rules/task_view_protocol.dart' as rule;
import '../proof_process.dart';

Future<void> main(List<String> arguments) =>
    withProofProcesses(() => _proofMain(arguments));

/// Pure Dart guard fixtures, materialized outside production analyzer discovery.
/// Run: dart run tools/architecture/tests/task_view_protocol_test.dart
Future<void> _proofMain(List<String> arguments) async {
  String? compiled;
  if (arguments.isNotEmpty) {
    if (arguments.length != 2 ||
        arguments.first != '--compiled' ||
        !File(arguments[1]).existsSync()) {
      throw const FormatException('Use [--compiled EXISTING_BINARY]');
    }
    compiled = File(arguments[1]).absolute.path;
  }
  final sdkPath = dartSdkPath(Directory.current.path);
  const cliCases = {
    'direct',
    'owner-command',
    'dynamic-is-unverifiable',
    'bare-inherited-capability',
    'bare-unrelated-callback',
    'inherited-closure-alias',
    'proven-own-field',
  };
  final fixture =
      jsonDecode(
            File(
              'tools/architecture/fixtures/task_view_protocol.fixture.json',
            ).readAsStringSync(),
          )
          as Map;
  final clock = Stopwatch()..start();
  var passed = 0;
  final workspace = Directory.systemTemp.createTempSync('wing-task-protocol-');
  try {
    for (final entry in validatedProofCases(
      fixture['cases'],
      requiredNames: cliCases,
    )) {
      final sources = Directory('${workspace.path}/lib');
      if (sources.existsSync()) sources.deleteSync(recursive: true);
      final roles = <String, Object>{};
      for (final entry in (entry['files'] as Map).entries) {
        final path = entry.key as String;
        final data = entry.value as Map;
        final file = File('${workspace.path}/$path');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(data['source'] as String);
        roles[path] = {
          'role': data['role'],
          'feature': 'scheduled-tasks',
          'library': data['library'] ?? path,
        };
      }
      final config = File('${workspace.path}/.dart_tool/package_config.json');
      config.parent.createSync(recursive: true);
      config.writeAsStringSync(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'wing',
              'rootUri': '../',
              'packageUri': 'lib/',
              'languageVersion': '3.12',
            },
          ],
        }),
      );
      final rolesPath = '${workspace.path}/roles.json';
      File(
        rolesPath,
      ).writeAsStringSync(jsonEncode({'schema': 1, 'files': roles}));
      final snapshot = Snapshot.load(workspace.path, rolesPath);
      final expected = entry['exit'];
      List<Finding>? findings;
      var actual = 0;
      try {
        findings = await rule.check(snapshot, workspace.path, sdkPath: sdkPath);
        actual = findings.isEmpty ? 0 : 1;
      } on FormatException {
        actual = 2;
      }
      if (actual != expected ||
          findings?.any(
                (f) =>
                    f.id != rule.id || !f.file.startsWith('lib/') || f.line < 1,
              ) ==
              true) {
        throw StateError(
          '${entry['name']}: expected exit $expected, got $actual / $findings',
        );
      }
      if (expected == 1 &&
          (findings!.length != 1 ||
              findings.single.file != entry['diagnosticFile'] ||
              findings.single.line != entry['diagnosticLine'])) {
        throw StateError(
          '${entry['name']}: diagnostic location did not match: $findings',
        );
      }
      // Prove a bad/valid/input fixture through the actual independent CLI;
      // a swallowed exit status must not pass the quality gate.
      if (cliCases.contains(entry['name'])) {
        final result = await runProofProcess(proofDartExecutable, [
          'run',
          'tools/architecture/rules/task_view_protocol.dart',
          '--root',
          workspace.path,
          '--roles',
          rolesPath,
          '--json',
        ]);
        void prove(ProcessResult result) {
          if (result.exitCode != expected) {
            throw StateError(
              '${entry['name']}: executable returned ${result.exitCode}: ${result.stdout} ${result.stderr}',
            );
          }
          if (expected == 1) {
            final output = jsonDecode(result.stdout as String) as Map;
            final diagnostic = (output['findings'] as List).single as Map;
            if (diagnostic['id'] != rule.id ||
                diagnostic['file'] != entry['diagnosticFile'] ||
                diagnostic['line'] != entry['diagnosticLine']) {
              throw StateError(
                'Executable failed intended diagnostic/location proof',
              );
            }
          }
          if (expected == 2 &&
              !(result.stderr as String).contains('[${rule.id} INPUT]')) {
            throw StateError(
              'Unverifiable fixture missed typed input diagnostic',
            );
          }
        }

        prove(result);
        if (compiled != null) {
          final result = await runProofProcess(compiled, [
            '--root',
            workspace.path,
            '--roles',
            rolesPath,
            '--json',
            '--sdk',
            sdkPath,
          ]);
          prove(result);
        }
        if (entry['name'] == 'owner-command') {
          for (final (executable, prefix) in <(String, List<String>)>[
            (
              proofDartExecutable,
              ['run', 'tools/architecture/rules/task_view_protocol.dart'],
            ),
            if (compiled != null) (compiled, <String>[]),
          ]) {
            final invalid = await runProofProcess(executable, [
              ...prefix,
              '--root',
              workspace.path,
              '--roles',
              rolesPath,
              '--json',
              '--sdk',
              '${workspace.path}/invalid-sdk',
            ]);
            if (invalid.exitCode != 2 ||
                !(invalid.stderr as String).contains('[${rule.id} INPUT]')) {
              throw StateError(
                'Explicit invalid SDK must fail before no-candidate shortcut',
              );
            }
          }
        }
      }
      passed++;
    }
  } finally {
    workspace.deleteSync(recursive: true);
  }
  stdout.writeln(
    '${rule.id}: $passed fixtures passed in ${clock.elapsedMilliseconds} ms',
  );
}
