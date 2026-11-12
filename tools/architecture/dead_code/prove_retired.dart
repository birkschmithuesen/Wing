import 'dart:convert';
import 'dart:io';

import '../model.dart';
import '../proof_process.dart';
import 'retired_declarations.dart' as rule;

Future<void> main(List<String> args) => withProofProcesses(() => _prove(args));

Future<void> _prove(List<String> args) async {
  if (args.isNotEmpty &&
      (args.length != 2 ||
          args.first != '--compiled' ||
          !File(args.last).existsSync())) {
    throw const FormatException('Use [--compiled EXISTING_BINARY]');
  }
  final compiled = args.isEmpty ? null : args.last;
  final fixtures =
      jsonDecode(
            File(
              'tools/architecture/dead_code/retired_contract.fixture.json',
            ).readAsStringSync(),
          )
          as Map;
  final manifest = File(
    'tools/architecture/dead_code/retired.json',
  ).readAsStringSync();
  const cliCases = {
    'retired-class': 1,
    'active-raw-transport': 0,
    'unowned-part-fails-closed': 2,
    'field-retirement-keeps-named-constructors': 0,
    'retired-ack-provider-field': 1,
    'manifest-old-schema-fails-closed': 2,
    'manifest-missing-kind-fails-closed': 2,
    'manifest-unsupported-kind-fails-closed': 2,
    'manifest-nonstring-kind-fails-closed': 2,
  };
  final exercisedCliCases = <String, int>{};
  var passed = 0;
  for (final test in fixtures['cases'] as List) {
    final workspace = Directory.systemTemp.createTempSync('wing-retired-');
    try {
      final roles = <String, Object>{};
      for (final entry in (test['files'] as Map).entries) {
        final path = entry.key as String;
        final file = File('${workspace.path}/$path');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value as String);
        roles[path] = {
          'role': 'utility',
          'feature': 'fixture',
          'library': path.endsWith('session_part.dart')
              ? 'lib/core/models/session.dart'
              : path,
        };
      }
      final rolePath = '${workspace.path}/roles.json';
      File(
        rolePath,
      ).writeAsStringSync(jsonEncode({'schema': 1, 'files': roles}));
      final retired = File(
        '${workspace.path}/tools/architecture/dead_code/retired.json',
      );
      retired.parent.createSync(recursive: true);
      retired.writeAsStringSync(
        test.containsKey('manifest') ? jsonEncode(test['manifest']) : manifest,
      );
      List<Finding>? findings;
      var actual = 0;
      try {
        findings = rule.check(Snapshot.load(workspace.path, rolePath));
        actual = findings.isEmpty ? 0 : 1;
      } on FormatException {
        actual = 2;
      }
      if (actual != test['exit']) {
        throw StateError(
          '${test['name']}: expected ${test['exit']}, got $actual',
        );
      }
      if (actual == 1) {
        final expectedFile =
            test['diagnosticFile'] ?? (test['files'] as Map).keys.first;
        if (findings!.length != 1 ||
            findings.single.id != rule.id ||
            findings.single.file != expectedFile ||
            findings.single.line != test['line']) {
          throw StateError('${test['name']}: wrong diagnostic $findings');
        }
      }
      // Every declaration case is proved above through the public rule API.
      // Selected cases also prove CLI exits and schema/kind failure handling.
      if (cliCases.containsKey(test['name'])) {
        if (exercisedCliCases.containsKey(test['name'])) {
          throw StateError('Duplicate CLI representative: ${test['name']}');
        }
        final options = [
          '--root',
          workspace.path,
          '--roles',
          rolePath,
          '--strict',
          '--json',
        ];
        final commands = [
          (
            proofDartExecutable,
            [
              '--packages=.dart_tool/package_config.json',
              'tools/architecture/dead_code/retired_declarations.dart',
              ...options,
            ],
          ),
          if (compiled != null) (compiled, options),
        ];
        for (final command in commands) {
          final result = await runProofProcess(command.$1, command.$2);
          if (result.exitCode != test['exit']) {
            throw StateError('${test['name']}: CLI exit ${result.exitCode}');
          }
          if (actual == 2) {
            if (!(result.stderr as String).contains('[ARCH_INPUT]')) {
              throw StateError('CLI missed the invalid-input diagnostic');
            }
          } else {
            final output = jsonDecode(result.stdout as String) as Map;
            final problems = output['problems'] as List;
            final emitted = output['findings'] as List;
            if (actual == 0) {
              if (problems.isNotEmpty || emitted.isNotEmpty) {
                throw StateError('Valid CLI input emitted a violation');
              }
            } else {
              final expectedFile =
                  test['diagnosticFile'] ?? (test['files'] as Map).keys.first;
              bool exact(Object? row) =>
                  row is Map &&
                  row['id'] == rule.id &&
                  row['file'] == expectedFile &&
                  row['line'] == test['line'];
              if (problems.length != 1 ||
                  emitted.length != 1 ||
                  !exact(problems.single) ||
                  !exact(emitted.single)) {
                throw StateError(
                  'CLI missed the exact declaration identity/location',
                );
              }
            }
          }
        }
        exercisedCliCases[test['name'] as String] = actual;
      }
      passed++;
    } finally {
      workspace.deleteSync(recursive: true);
    }
  }
  if (exercisedCliCases.length != cliCases.length ||
      cliCases.entries.any(
        (entry) => exercisedCliCases[entry.key] != entry.value,
      )) {
    throw StateError('All CLI representatives and exits must be proved');
  }
  stdout.writeln(
    '${rule.id}: $passed fixtures passed; actual ${compiled == null ? 'source' : 'source/AOT'} CLI exits 1/0/2 proved',
  );
}
