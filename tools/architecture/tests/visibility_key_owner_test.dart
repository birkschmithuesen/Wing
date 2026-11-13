import 'dart:convert';
import 'dart:io';

import '../dart_sdk.dart';
import '../model.dart';
import '../rules/visibility_key_owner.dart' as rule;
import '../proof_process.dart';

const caller = 'lib/caller.dart';
const modelImport =
    "import 'package:wing/core/models/session_visibility.dart';";
const model =
    'enum SessionVisibility { chats, all; static String preferenceKey(String id) => id; }';

class Case {
  const Case(
    this.name,
    this.source, {
    this.extra = const {},
    this.count = 0,
    this.input = false,
    this.file = caller,
    this.cli = false,
    this.line = 2,
  });
  final String name, source, file;
  final Map<String, String> extra;
  final int count, line;
  final bool input, cli;
}

class Workspace {
  void load(Case fixture) {
    final sourcesRoot = Directory('${directory.path}/lib');
    if (sourcesRoot.existsSync()) sourcesRoot.deleteSync(recursive: true);
    final sources = {
      rule.definition: model,
      rule.owner: 'class AppPreferences {}',
      caller: fixture.source,
      ...fixture.extra,
    };
    final roles = <String, Object>{};
    for (final entry in sources.entries) {
      final file = File('${directory.path}/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
      roles[entry.key] = {
        'role': 'application',
        'feature': 'app-preferences',
        'library': entry.key,
      };
    }
    File(
      rolesPath,
    ).writeAsStringSync(jsonEncode({'schema': 1, 'files': roles}));
    final original = File('.dart_tool/package_config.json');
    final configuration = jsonDecode(original.readAsStringSync()) as Map;
    final packages = (configuration['packages'] as List).cast<Map>();
    final config = File('${directory.path}/.dart_tool/package_config.json');
    config.parent.createSync(recursive: true);
    config.writeAsStringSync(
      jsonEncode({
        ...configuration,
        'packages': [
          for (final package in packages)
            {
              ...package,
              'rootUri': package['name'] == 'wing'
                  ? directory.uri.toString()
                  : original.uri
                        .resolve(package['rootUri'] as String)
                        .toString(),
            },
        ],
      }),
    );
  }

  final directory = Directory.systemTemp.createTempSync('wing-visibility-key-');
  String get rolesPath => '${directory.path}/roles.json';
  Snapshot get snapshot => Snapshot.load(directory.path, rolesPath);
  void dispose() => directory.deleteSync(recursive: true);
}

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> args) =>
    withProofProcesses(() => _proofMain(args));

Future<void> _proofMain(List<String> args) async {
  String? compiled;
  if (args.isNotEmpty) {
    if (args.length != 2 ||
        args.first != '--compiled' ||
        !File(args.last).existsSync()) {
      throw const FormatException('Use [--compiled EXISTING_BINARY]');
    }
    compiled = File(args.last).absolute.path;
  }
  final sdk = dartSdkPath(Directory.current.path);
  final cases = [
    const Case(
      'direct use',
      "$modelImport\nString read() => SessionVisibility.preferenceKey('id');",
      count: 1,
      cli: true,
    ),
    const Case(
      'tearoff',
      '$modelImport\nfinal derive = SessionVisibility.preferenceKey;',
      count: 1,
    ),
    const Case(
      'prefix',
      "import 'package:wing/core/models/session_visibility.dart' as m;\nfinal derive = m.SessionVisibility.preferenceKey;",
      count: 1,
    ),
    const Case(
      'typedef',
      '$modelImport\ntypedef Choice = SessionVisibility;\nfinal derive = Choice.preferenceKey;',
      count: 1,
      line: 3,
    ),
    const Case(
      'barrel',
      "import 'package:wing/bridge.dart';\nfinal derive = SessionVisibility.preferenceKey;",
      count: 1,
      extra: {
        'lib/bridge.dart': "export 'core/models/session_visibility.dart';",
      },
    ),
    const Case(
      'two actual accesses',
      "$modelImport\nfinal a = SessionVisibility.preferenceKey; final b = SessionVisibility.preferenceKey('id');",
      count: 2,
    ),
    const Case(
      'captured alias use',
      "$modelImport\nString read() { final derive = SessionVisibility.preferenceKey; return derive('id'); }",
      count: 1,
    ),
    const Case(
      'qualified return',
      '$modelImport\nObject get derive => SessionVisibility.preferenceKey;',
      count: 1,
    ),
    const Case(
      'caller part',
      "library caller;\n$modelImport\npart 'caller_part.dart';",
      count: 1,
      file: 'lib/caller_part.dart',
      extra: {
        'lib/caller_part.dart':
            "part of 'caller.dart';\nfinal derive = SessionVisibility.preferenceKey;",
      },
    ),
    const Case(
      'named caller part',
      "library caller;\n$modelImport\npart 'caller_part.dart';",
      count: 1,
      file: 'lib/caller_part.dart',
      extra: {
        'lib/caller_part.dart':
            'part of caller;\nfinal derive = SessionVisibility.preferenceKey;',
      },
    ),
    const Case(
      'definition part provenance',
      "$modelImport\nfinal derive = SessionVisibility.preferenceKey;",
      count: 1,
      extra: {
        rule.definition: "part 'visibility_part.dart';",
        'lib/core/models/visibility_part.dart':
            "part of 'session_visibility.dart';\n$model",
      },
    ),
    const Case(
      'model self-call is not an owner exemption',
      'class Caller {}',
      count: 1,
      file: rule.definition,
      line: 1,
      extra: {
        rule.definition:
            "enum SessionVisibility { chats, all; static String preferenceKey(String id) => id; static String self() => preferenceKey('id'); }",
      },
    ),
    const Case(
      'canonical owner use',
      'class Caller {}',
      extra: {
        rule.owner:
            "$modelImport\nclass AppPreferences { String key(String id) => SessionVisibility.preferenceKey(id); }",
      },
      cli: true,
    ),
    const Case(
      'canonical owner part use',
      'class Caller {}',
      extra: {
        rule.owner:
            "library preferences;\n$modelImport\npart 'preferences_part.dart';\nclass AppPreferences {}",
        'lib/core/services/preferences_part.dart':
            "part of 'app_preferences.dart';\nfinal derive = SessionVisibility.preferenceKey;",
      },
    ),
    const Case(
      'canonical owner named part use',
      'class Caller {}',
      extra: {
        rule.owner:
            "library preferences;\n$modelImport\npart 'preferences_part.dart';\nclass AppPreferences {}",
        'lib/core/services/preferences_part.dart':
            'part of preferences;\nfinal derive = SessionVisibility.preferenceKey;',
      },
    ),
    const Case(
      'enum ordinary use',
      '$modelImport\nfinal choice = SessionVisibility.chats;',
    ),
    const Case(
      'unrelated same name',
      "class SessionVisibility { static String preferenceKey(String id) => id; }\nfinal derive = SessionVisibility.preferenceKey;",
    ),
    const Case(
      'foreign same name',
      "import 'package:wing/other.dart';\nfinal derive = SessionVisibility.preferenceKey;",
      extra: {
        'lib/other.dart':
            'class SessionVisibility { static String preferenceKey(String id) => id; }',
      },
    ),
    const Case(
      'local parameter shadows member',
      "$modelImport\nString read(String Function(String) preferenceKey) => preferenceKey('id');",
    ),
    const Case(
      'local getter unrelated',
      "class Caller { String preferenceKey(String id) => id; String read() => preferenceKey('id'); }",
    ),
    const Case(
      'unrelated cascade',
      "class Caller { void preferenceKey(String id) {} }\nfinal value = Caller()..preferenceKey('id');",
    ),
    const Case(
      'static method through cascade',
      "$modelImport\nfinal value = SessionVisibility.chats..preferenceKey('id');",
      count: 1,
    ),
    const Case(
      'literal key outside narrow property',
      "final raw = 'session_visibility_v2_id';",
    ),
    const Case(
      'unresolved member',
      'final derive = unknown.preferenceKey;',
      input: true,
      cli: true,
    ),
    const Case(
      'conditional provenance',
      "import 'package:wing/core/models/session_visibility.dart' if (dart.library.io) 'package:wing/other.dart';\nfinal derive = SessionVisibility.preferenceKey;",
      input: true,
      extra: {'lib/other.dart': model},
    ),
    const Case(
      'mismatched caller part',
      "$modelImport\npart 'caller_part.dart';",
      input: true,
      extra: {
        'lib/caller_part.dart':
            "part of 'other.dart';\nfinal derive = SessionVisibility.preferenceKey;",
      },
    ),
    const Case('malformed source', 'class Caller {', input: true),
  ];
  final cliExits = <String, Set<int>>{
    'source': {},
    if (compiled != null) 'aot': {},
  };
  var passed = 0;
  final workspace = Workspace();
  try {
    for (final fixture in cases) {
      workspace.load(fixture);
      List<Finding>? findings;
      var actual = 0;
      try {
        findings = await rule.check(
          workspace.snapshot,
          workspace.directory.path,
          sdkPath: sdk,
        );
        actual = findings.isEmpty ? 0 : 1;
      } on FormatException {
        actual = 2;
      }
      final expected = fixture.input
          ? 2
          : fixture.count == 0
          ? 0
          : 1;
      require(
        actual == expected,
        '${fixture.name}: expected $expected, got $actual: $findings',
      );
      if (!fixture.input) {
        require(
          findings!.length == fixture.count,
          '${fixture.name}: wrong diagnostic count',
        );
        for (final finding in findings) {
          require(
            finding.id == rule.id &&
                finding.file == fixture.file &&
                finding.line == fixture.line,
            '${fixture.name}: wrong provenance/location',
          );
        }
      }
      for (final (executable, prefix) in [
        if (fixture.cli)
          (
            proofDartExecutable,
            ['run', 'tools/architecture/rules/visibility_key_owner.dart'],
          ),
        if (compiled != null) (compiled, <String>[]),
      ]) {
        final result = await runProofProcess(executable, [
          ...prefix,
          '--root',
          workspace.directory.path,
          '--roles',
          workspace.rolesPath,
          '--sdk',
          sdk,
          '--json',
        ]);
        require(
          result.exitCode == expected,
          '${fixture.name}: actual CLI ${result.exitCode}: ${result.stdout}${result.stderr}',
        );
        cliExits[prefix.isEmpty ? 'aot' : 'source']!.add(result.exitCode);
        if (expected != 2) {
          final json = jsonDecode(result.stdout as String) as Map;
          final rows = (json['findings'] as List).cast<Map>();
          require(
            rows.length == fixture.count &&
                rows.every(
                  (row) =>
                      row['id'] == rule.id &&
                      row['file'] == fixture.file &&
                      row['line'] == fixture.line,
                ),
            '${fixture.name}: wrong CLI diagnostic',
          );
        } else {
          require(
            '${result.stderr}'.contains('[${rule.id} INPUT]'),
            '${fixture.name}: missing input diagnostic',
          );
        }
        if (expected == 0) {
          final invalidSdk = await runProofProcess(executable, [
            ...prefix,
            '--root',
            workspace.directory.path,
            '--roles',
            workspace.rolesPath,
            '--sdk',
            '${workspace.directory.path}/missing-sdk',
          ]);
          require(
            invalidSdk.exitCode == 2,
            '${fixture.name}: invalid SDK must reject clean path',
          );
        }
      }
      passed++;
    }
  } finally {
    workspace.dispose();
  }
  require(
    cliExits.values.every((exits) => exits.containsAll({0, 1, 2})),
    'Every enabled CLI mode must prove rejection, acceptance and input failure',
  );
  stdout.writeln(
    '${rule.id}: $passed API fixtures; actual source${compiled == null ? '' : '+AOT'} CLI invalid1/valid0/input2 and invalid SDK2 passed.',
  );
}
