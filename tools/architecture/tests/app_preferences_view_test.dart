import 'dart:convert';
import 'dart:io';

import '../dart_sdk.dart';
import '../model.dart';
import '../rules/app_preferences_view.dart' as rule;
import '../proof_process.dart';

const app = 'lib/core/screens/app_settings_content.dart';
const importPrefs =
    "import 'package:shared_preferences/shared_preferences.dart';";
String read(String expression, {String imports = importPrefs}) =>
    '$imports\nclass AppSettingsContent {\n  final SharedPreferences preferences;\n  AppSettingsContent(this.preferences);\n  Object? load() => $expression;\n}';

class Case {
  const Case(
    this.name,
    this.source, {
    this.extra = const {},
    this.count = 0,
    this.input = false,
    this.line = 5,
    this.file = app,
    this.cli = false,
  });
  final String name, source, file;
  final Map<String, String> extra;
  final int count, line;
  final bool input, cli;
}

class Workspace {
  void load(Case fixture) {
    // Recreate fixture inputs while retaining analyzer-owned SDK summaries.
    for (final name in ['lib', 'tools']) {
      final input = Directory('${directory.path}/$name');
      if (input.existsSync()) input.deleteSync(recursive: true);
    }
    final sources = {
      for (final entry in rule.completedViews.entries)
        entry.key: 'class ${entry.value} {}',
      app: fixture.source,
      ...fixture.extra,
    };
    final roles = <String, Object>{};
    for (final entry in sources.entries) {
      final file = File('${directory.path}/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
      roles[entry.key] = {
        'role': 'view',
        'feature': 'app-preferences',
        'library': entry.key,
      };
    }
    File(
      rolesPath,
    ).writeAsStringSync(jsonEncode({'schema': 1, 'files': roles}));
    // Resolve the actual pinned package's declarations; no guessed SharedPrefs
    // mock can establish canonical provenance or package re-export behavior.
    final original = File('.dart_tool/package_config.json');
    final configuration = jsonDecode(original.readAsStringSync()) as Map;
    final packages = (configuration['packages'] as List).cast<Map>();
    final absolute = [
      for (final package in packages)
        {
          ...package,
          'rootUri': package['name'] == 'wing'
              ? directory.uri.toString()
              : original.uri.resolve(package['rootUri'] as String).toString(),
        },
    ];
    final config = File('${directory.path}/.dart_tool/package_config.json');
    config.parent.createSync(recursive: true);
    config.writeAsStringSync(
      jsonEncode({...configuration, 'packages': absolute}),
    );
  }

  final directory = Directory.systemTemp.createTempSync('wing-app-prefs-view-');
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
    Case('direct read', read("preferences.getString('key')"), count: 1),
    Case('write', read("preferences.setBool('key', true)"), count: 1),
    Case(
      'two occurrences stay distinct',
      read("[preferences.getString('a'), preferences.getString('b')]"),
      count: 2,
    ),
    Case('reload', read('preferences.reload()'), count: 1),
    Case(
      'static prefix',
      "import 'package:shared_preferences/shared_preferences.dart' as storage;\nclass AppSettingsContent { Object? load() => storage.SharedPreferences.getInstance(); }",
      count: 1,
      line: 2,
    ),
    Case(
      'typedef static',
      '$importPrefs\ntypedef Store = SharedPreferences;\nclass AppSettingsContent { Object? load() => Store.getInstance(); }',
      count: 1,
      line: 3,
    ),
    Case(
      'barrel re-export',
      read(
        "preferences.getString('key')",
        imports: "import 'package:wing/bridge.dart';",
      ),
      extra: {
        'lib/bridge.dart':
            "export 'package:shared_preferences/shared_preferences.dart';",
      },
      count: 1,
    ),
    Case('cascade', read("preferences..getString('key')"), count: 1),
    Case('capture tearoff', read('preferences.getString'), count: 1),
    Case(
      'capture Function.apply',
      read("Function.apply(preferences.getString, ['key'])"),
      count: 1,
    ),
    Case(
      'bare inherited closure',
      '$importPrefs\nabstract class Base implements SharedPreferences {}\nabstract class AppSettingsContent extends Base { Object? capture() => () => getString(\'key\'); }',
      count: 1,
      line: 3,
    ),
    Case(
      'helper extension direct read',
      '$importPrefs\nclass AppSettingsContent {}\nextension Reads on SharedPreferences { Object? read() => getString(\'key\'); }',
      count: 1,
      line: 3,
    ),
    Case(
      'same-name extension',
      "class AppSettingsContent { Object? read() => Local('text').getString('key'); }\nextension Local on String { String getString(String key) => this; }",
    ),
    Case(
      'unrelated class same name',
      "class SharedPreferences { Object? getString(String key) => key; }\nclass AppSettingsContent { Object? read(SharedPreferences value) => value.getString('key'); }",
    ),
    Case(
      'bare method shadow',
      "class AppSettingsContent { String getString(String key) => key; Object? read() => getString('key'); }",
    ),
    Case(
      'parameter shadow',
      "class AppSettingsContent { Object? read(String Function(String) getString) => getString('key'); }",
    ),
    Case(
      'own callback field',
      "class AppSettingsContent { final String Function(String) getString = (key) => key; Object? read() => getString('key'); }",
    ),
    Case(
      'callback initializer cannot hide capture',
      '$importPrefs\nclass AppSettingsContent {\n  final SharedPreferences preferences;\n  AppSettingsContent(this.preferences);\n  late final getString = preferences.getString;\n  Object? read() => getString(\'key\');\n}',
      count: 1,
    ),
    Case(
      'owner reload and raw voice forwarding',
      '$importPrefs\nclass Owner { Future<void> reload() async {} }\nclass VoiceRoute { VoiceRoute(SharedPreferences preferences); }\nclass AppSettingsContent { final Owner owner; final SharedPreferences voicePreferences; AppSettingsContent(this.owner, this.voicePreferences); Object? read() { owner.reload(); return VoiceRoute(voicePreferences); } }',
    ),
    Case(
      'outside completed scope',
      'class AppSettingsContent {}',
      extra: {
        'lib/unfinished_voice_view.dart':
            '$importPrefs\nclass VoiceView { Object? read(SharedPreferences p) => p.getString(\'key\'); }',
      },
    ),
    Case(
      'actual URI part',
      '$importPrefs\npart \'parts/read.dart\';\nclass AppSettingsContent {}',
      extra: {
        'lib/core/screens/parts/read.dart':
            "part of '../app_settings_content.dart';\nclass _Helper { Object? read(SharedPreferences p) => p.getString('key'); }",
      },
      count: 1,
      file: 'lib/core/screens/parts/read.dart',
      line: 2,
    ),
    Case(
      'actual named part',
      'library completed.preferences;\n$importPrefs\npart \'parts/read.dart\';\nclass AppSettingsContent {}',
      extra: {
        'lib/core/screens/parts/read.dart':
            "part of completed.preferences;\nclass _Helper { Object? read(SharedPreferences p) => p.getString('key'); }",
      },
      count: 1,
      file: 'lib/core/screens/parts/read.dart',
      line: 2,
    ),
    Case(
      'valid named part owner callback',
      'library completed.preferences;\n$importPrefs\npart \'parts/read.dart\';\nclass AppSettingsContent {}',
      extra: {
        'lib/core/screens/parts/read.dart':
            'part of completed.preferences;\nclass Owner { void reload() {} }\nclass _Helper { void read(Owner owner) => owner.reload(); }',
      },
    ),
    Case(
      'dynamic input cannot prove provenance',
      'class AppSettingsContent { Object? read(dynamic value) => value.getString(\'key\'); }',
      input: true,
    ),
    Case(
      'conditional candidate cannot prove all branches',
      read(
        "preferences.getString('key')",
        imports:
            "import 'package:wing/a.dart' if (dart.library.io) 'package:wing/b.dart';",
      ),
      extra: {
        'lib/a.dart':
            "export 'package:shared_preferences/shared_preferences.dart';",
        'lib/b.dart':
            "export 'package:shared_preferences/shared_preferences.dart';",
      },
      input: true,
    ),
    Case('missing completed class fails scope', 'class Other {}', input: true),
    Case(
      'duplicate part ownership cannot hide read',
      '$importPrefs\npart \'parts/read.dart\';\nclass AppSettingsContent {}',
      extra: {
        'lib/other.dart': "part 'core/screens/parts/read.dart';",
        'lib/core/screens/parts/read.dart':
            "part of '../app_settings_content.dart';\nclass _Helper { Object? read(SharedPreferences p) => p.getString('key'); }",
      },
      input: true,
    ),
    Case(
      'Home remembered entry raw read and write',
      'class AppSettingsContent {}',
      extra: {
        rule.homeLibrary:
            '$importPrefs\nclass HomeScreenState { Future<Object?> open(SharedPreferences preferences) async { final previous = preferences.getString("last_connection_id"); await preferences.setString("last_connection_id", "selected"); return previous; } }',
      },
      count: 2,
      file: rule.homeLibrary,
      line: 2,
      cli: true,
    ),
    Case(
      'Home typed owner permits unrelated bootstrap permission and local APIs',
      'class AppSettingsContent {}',
      extra: {
        rule.homeLibrary:
            '$importPrefs\nclass Owner { String? externalConnection() => null; }\nclass HomeScreenState { final Owner owner; HomeScreenState(this.owner); Object? open() => owner.externalConnection(); String getString(String key) => key; }\nclass WingAppState { Object? pendingPermission(SharedPreferences preferences) => preferences.getBool("notification_permission_requested"); }\nFuture<void> bootstrap() async { await SharedPreferences.getInstance(); }',
      },
      cli: true,
    ),
    Case(
      'Home unresolved raw access fails input',
      'class AppSettingsContent {}',
      extra: {
        rule.homeLibrary:
            'class HomeScreenState { Object? open(dynamic preferences) => preferences.getString("last_connection_id"); }',
      },
      input: true,
      cli: true,
    ),
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
          '${fixture.name}: wrong diagnostic count $findings',
        );
        for (final finding in findings) {
          require(
            finding.id == rule.id &&
                finding.file == fixture.file &&
                finding.line == fixture.line,
            '${fixture.name}: wrong provenance/location $finding',
          );
        }
      }
      if (fixture.cli || compiled != null) {
        for (final (executable, prefix) in [
          if (fixture.cli)
            (
              proofDartExecutable,
              ['run', 'tools/architecture/rules/app_preferences_view.dart'],
            ),
          if (compiled != null) (compiled, <String>[]),
        ]) {
          final arguments = [
            ...prefix,
            '--root',
            workspace.directory.path,
            '--roles',
            workspace.rolesPath,
            '--sdk',
            sdk,
            '--json',
          ];
          final result = await runProofProcess(executable, arguments);
          require(
            result.exitCode == expected,
            '${fixture.name}: actual CLI verdict ${result.exitCode}: ${result.stdout}${result.stderr}',
          );
          cliExits[prefix.isEmpty ? 'aot' : 'source']!.add(result.exitCode);
          if (expected != 2) {
            final output = jsonDecode(result.stdout as String) as Map;
            final diagnostics = (output['findings'] as List).cast<Map>();
            require(
              diagnostics.length == fixture.count,
              '${fixture.name}: actual CLI wrong count',
            );
            for (final finding in diagnostics) {
              require(
                finding['id'] == rule.id &&
                    finding['file'] == fixture.file &&
                    finding['line'] == fixture.line,
                '${fixture.name}: actual CLI wrong location',
              );
            }
          } else {
            require(
              '${result.stderr}'.contains('[${rule.id} INPUT]'),
              '${fixture.name}: actual input diagnostic missing',
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
              invalidSdk.exitCode == 2 &&
                  '${invalidSdk.stderr}'.contains('[${rule.id} INPUT]'),
              'Explicit invalid SDK must reject no-candidate input',
            );
          }
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
