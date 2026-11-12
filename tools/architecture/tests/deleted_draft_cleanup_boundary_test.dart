import 'dart:convert';
import 'dart:io';

import '../model.dart';
import '../fixture_contract.dart';
import '../rules/deleted_draft_cleanup_boundary.dart' as rule;
import '../proof_process.dart';

Future<void> main(List<String> arguments) =>
    withProofProcesses(() => _proofMain(arguments));

/// Pure Dart guard fixtures, materialized outside production analyzer discovery.
/// Run: dart run tools/architecture/tests/deleted_draft_cleanup_boundary_test.dart
Future<void> _proofMain(List<String> arguments) async {
  String? compiled;
  String? sdk;
  for (var i = 0; i < arguments.length; i++) {
    switch (arguments[i]) {
      case '--compiled':
        compiled = arguments[++i];
      case '--sdk':
        sdk = arguments[++i];
      default:
        throw const FormatException('Unknown fixture-runner option.');
    }
  }
  if (compiled != null && sdk == null) {
    throw const FormatException('Compiled fixture proof requires --sdk.');
  }
  const cliCases = {
    'direct-file',
    'strict-batch',
    'dynamic-is-unverifiable',
    'malformed-source',
  };
  final fixture =
      jsonDecode(
            File(
              'tools/architecture/fixtures/deleted_draft_cleanup_boundary.fixture.json',
            ).readAsStringSync(),
          )
          as Map;
  final clock = Stopwatch()..start();
  var passed = 0;
  final workspace = Directory.systemTemp.createTempSync(
    'wing-cleanup-boundary-',
  );
  try {
    for (final entry in validatedProofCases(
      fixture['cases'],
      requiredNames: cliCases,
    )) {
      if (compiled != null && !cliCases.contains(entry['name'])) continue;
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
          'feature': 'fixture',
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
      final expected = entry['exit'];
      List<Finding>? findings;
      var actual = 0;
      try {
        final snapshot = Snapshot.load(workspace.path, rolesPath);
        findings = await rule.check(snapshot, workspace.path, sdkPath: sdk);
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
      if (expected == 1 && findings!.isEmpty) {
        throw StateError(
          '${entry['name']}: expected the strict cleanup diagnostic.',
        );
      }
      // Prove a bad/valid/input fixture through the actual independent CLI;
      // a swallowed exit status must not pass the quality gate.
      if (cliCases.contains(entry['name'])) {
        final result = await runProofProcess(compiled ?? proofDartExecutable, [
          if (compiled == null) ...[
            'run',
            'tools/architecture/rules/deleted_draft_cleanup_boundary.dart',
          ],
          if (sdk != null) ...['--sdk', sdk],
          '--root',
          workspace.path,
          '--roles',
          rolesPath,
          '--json',
        ]);
        if (result.exitCode != expected) {
          throw StateError(
            '${entry['name']}: CLI returned ${result.exitCode}: ${result.stdout} ${result.stderr}',
          );
        }
        if (expected == 1) {
          final output = jsonDecode(result.stdout as String) as Map;
          final diagnostics = output['findings'] as List;
          if (diagnostics.isEmpty ||
              diagnostics.any((f) => f['id'] != rule.id)) {
            throw StateError('Bad fixture missed the intended diagnostic.');
          }
        }
      }
      if (compiled != null && entry['name'] == 'strict-batch') {
        final invalidSdk = await runProofProcess(compiled, [
          '--root',
          workspace.path,
          '--roles',
          rolesPath,
          '--sdk',
          '${workspace.path}/missing-sdk',
          '--json',
        ]);
        if (invalidSdk.exitCode != 2) {
          throw StateError('Compiled clean path accepted an invalid SDK.');
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
