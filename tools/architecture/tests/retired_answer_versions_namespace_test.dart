import 'dart:convert';
import 'dart:io';

import '../model.dart';
import '../rules/retired_answer_versions_namespace.dart' as rule;
import '../proof_process.dart';

class _Case {
  const _Case(
    this.name,
    this.source,
    this.exit, {
    this.count = 0,
    this.cli = false,
    this.other,
    this.parts = const {},
    this.file = rule.library,
  });
  final String name, file;
  final String? source, other;
  final int exit, count;
  final Map<String, String> parts;
  final bool cli;
}

const cases = [
  _Case(
    'original obsolete cleanup',
    "void cleanup() { for (final key in preferences.getKeys()) { if (key.startsWith('answer_versions_v1_')) preferences.remove(key); } }",
    1,
    count: 1,
    cli: true,
  ),
  _Case(
    'current reading namespace',
    "const key = 'workspace_reading_v1_connection';",
    0,
    cli: true,
  ),
  _Case('missing canonical physical source', null, 2, cli: true),
  _Case(
    'actual retired key suffix',
    "const key = 'answer_versions_v1_connection_chat';",
    1,
    count: 1,
  ),
  _Case(
    'interpolated retired key',
    r"final key = 'answer_versions_v1_$chat';",
    1,
    count: 1,
  ),
  _Case(
    'actual interpolation literal fragment',
    r"final key = '${scope}answer_versions_v1_$chat';",
    1,
    count: 1,
  ),
  _Case(
    'adjacent literal fragments',
    "const key = 'answer_versions_' 'v1_';",
    1,
    count: 1,
  ),
  _Case(
    'adjacent complete prefix yields one finding',
    "const key = 'answer_versions_v1_' 'chat';",
    1,
    count: 1,
  ),
  _Case(
    'escaped literal value',
    r"const key = 'answer_versions_v1_\u0063hat';",
    1,
    count: 1,
  ),
  _Case(
    'nested interpolation expression literal',
    r'''final key = '${'answer_versions_v1_chat'}';''',
    1,
    count: 1,
  ),
  _Case(
    'raw retired prefix',
    "const key = r'answer_versions_v1_';",
    1,
    count: 1,
  ),
  _Case(
    'comments do not read or write preferences',
    "// answer_versions_v1_\n/* answer_versions_v1_ */ void current() {}",
    0,
  ),
  _Case(
    'unrelated owner source valid',
    'void current() {}',
    0,
    other: "const key = 'answer_versions_v1_chat';",
  ),
  _Case(
    'nearby unrelated literal namespace',
    "const key = 'workspace_answer_versions_v1_';",
    0,
  ),
  _Case(
    'new reading interpolation valid',
    r"final key = 'workspace_reading_v1_$scope';",
    0,
  ),
  _Case(
    'ordinary owner without literals valid',
    'class ProfileWorkspaceController {}',
    0,
  ),
  _Case('malformed source', 'class ProfileWorkspaceController {', 2),
  _Case(
    'actual reciprocal no-prefix part',
    "part 'extra.dart';",
    0,
    parts: {
      'lib/core/services/extra.dart':
          "part of 'profile_workspace_controller.dart'; const key='workspace_reading_v1_';",
    },
  ),
  _Case(
    'retired literal moved to actual part',
    "part 'extra.dart';",
    1,
    count: 1,
    file: 'lib/core/services/extra.dart',
    parts: {
      'lib/core/services/extra.dart':
          "part of 'profile_workspace_controller.dart'; const key='answer_versions_v1_chat';",
    },
  ),
  _Case('missing namespace part', "part 'extra.dart';", 2),
  _Case(
    'nonreciprocal namespace part',
    "part 'extra.dart';",
    2,
    parts: {'lib/core/services/extra.dart': 'class Other {}'},
  ),
  _Case(
    'orphan canonical part',
    'void current() {}',
    2,
    parts: {
      'lib/core/services/extra.dart':
          "part of 'profile_workspace_controller.dart';",
    },
  ),
  _Case('canonical root cannot be a part', "part of 'other.dart';", 2),
];

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  final cliExits = <int>{};
  for (final fixture in cases) {
    final root = Directory.systemTemp.createTempSync(
      'wing-retired-answer-namespace-',
    );
    try {
      final directory = Directory('${root.path}/lib');
      directory.createSync(recursive: true);
      if (fixture.source != null) {
        final file = File('${root.path}/${rule.library}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(fixture.source!);
      }
      if (fixture.other != null) {
        File('${root.path}/lib/other.dart').writeAsStringSync(fixture.other!);
      }
      for (final part in fixture.parts.entries) {
        final file = File('${root.path}/${part.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(part.value);
      }
      final roles = '${root.path}/roles.json';
      File(roles).writeAsStringSync(
        jsonEncode({
          'schema': 1,
          'files': {
            rule.library: {
              'role': 'application',
              'feature': 'workspace',
              'library': rule.library,
            },
          },
        }),
      );
      var status = 0;
      var findings = <Finding>[];
      try {
        findings = rule.check(Snapshot.load(root.path, roles));
        status = findings.isEmpty ? 0 : 1;
      } on FormatException {
        status = 2;
      }
      void identity(Map finding) {
        if (finding['id'] != rule.id ||
            finding['file'] != fixture.file ||
            finding['line'] != 1 ||
            finding['subject'] != rule.prefix) {
          throw StateError(
            '${fixture.name}: wrong diagnostic identity/location $finding',
          );
        }
      }

      if (status != fixture.exit || findings.length != fixture.count) {
        throw StateError(
          '${fixture.name}: expected ${fixture.exit}/${fixture.count}, got $status/$findings',
        );
      }
      for (final finding in findings) {
        identity(finding.toJson());
      }
      if (!fixture.cli) {
        continue;
      }
      if (!cliExits.add(fixture.exit)) {
        throw StateError('Duplicate CLI proof');
      }
      final result = await runProofProcess(proofDartExecutable, [
        'run',
        'tools/architecture/rules/retired_answer_versions_namespace.dart',
        '--root',
        root.path,
        '--roles',
        roles,
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
        final rows =
            (jsonDecode(result.stdout as String) as Map)['problems'] as List;
        if (rows.length != fixture.count) {
          throw StateError('Wrong CLI finding count');
        }
        for (final row in rows) {
          identity(row as Map);
        }
      }
    } finally {
      root.deleteSync(recursive: true);
    }
  }
  if (cliExits.length != 3) {
    throw StateError('CLI exits 0/1/2 missing');
  }
  stdout.writeln(
    '${rule.id}: ${cases.length} parsed fixtures and three CLI representatives passed',
  );
}
