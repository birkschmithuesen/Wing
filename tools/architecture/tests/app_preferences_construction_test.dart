import 'dart:convert';
import 'dart:io';

import '../dart_sdk.dart';
import '../model.dart';
import '../rules/app_preferences_construction.dart' as rule;
import '../proof_process.dart';

const caller = 'lib/caller.dart';
const ownerImport = "import 'package:wing/core/services/app_preferences.dart';";
const ownerModel =
    'class AppPreferences { AppPreferences([Object? preferences]); AppPreferences.named([Object? preferences]); }';

class Case {
  const Case(
    this.name,
    this.source, {
    this.extra = const {},
    this.count = 0,
    this.input = false,
    this.file = caller,
    this.line = 2,
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
      rule.definition: ownerModel,
      rule.bootstrap: 'void createApplicationDependencies() {}',
      caller: fixture.source,
      ...fixture.extra,
    };
    final roles = <String, Object>{};
    for (final entry in sources.entries) {
      final file = File('${directory.path}/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        entry.value.replaceAll('{{ROOT}}', directory.uri.toString()),
      );
      if (entry.key.startsWith('lib/')) {
        roles[entry.key] = {
          'role': 'application',
          'feature': 'app-preferences',
          'library': entry.key,
        };
      }
    }
    File(
      rolesPath,
    ).writeAsStringSync(jsonEncode({'schema': 1, 'files': roles}));
    final original = File('.dart_tool/package_config.json');
    final configuration = jsonDecode(original.readAsStringSync()) as Map;
    final config = File('${directory.path}/.dart_tool/package_config.json');
    config.parent.createSync(recursive: true);
    config.writeAsStringSync(
      jsonEncode({
        ...configuration,
        'packages': [
          for (final package in (configuration['packages'] as List).cast<Map>())
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

  final directory = Directory.systemTemp.createTempSync(
    'wing-preferences-construction-',
  );
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
      'direct consumer',
      cli: true,
      '$ownerImport\nfinal owner = AppPreferences();',
      count: 1,
    ),
    const Case(
      'explicit new',
      '$ownerImport\nfinal owner = new AppPreferences();',
      count: 1,
    ),
    const Case(
      'prefixed consumer',
      "import 'package:wing/core/services/app_preferences.dart' as p;\nfinal owner = p.AppPreferences();",
      count: 1,
    ),
    const Case(
      'type alias',
      '$ownerImport\ntypedef Choice = AppPreferences;\nfinal owner = Choice();',
      count: 1,
      line: 3,
    ),
    const Case(
      'chained aliases',
      '$ownerImport\ntypedef A = AppPreferences;\ntypedef B = A;\nfinal owner = B();',
      count: 1,
      line: 4,
    ),
    const Case(
      'barrel',
      "import 'package:wing/bridge.dart';\nfinal owner = AppPreferences();",
      count: 1,
      extra: {
        'lib/bridge.dart': "export 'core/services/app_preferences.dart';",
      },
    ),
    const Case(
      'captured constructor',
      '$ownerImport\nfinal create = AppPreferences.new;',
      count: 1,
    ),
    const Case(
      'prefixed alias captured constructor',
      "import 'package:wing/core/services/app_preferences.dart' as p;\ntypedef Choice = p.AppPreferences;\nfinal create = Choice.new;",
      count: 1,
      line: 3,
    ),
    const Case(
      'named constructor',
      '$ownerImport\nfinal owner = AppPreferences.named();',
      count: 1,
    ),
    const Case(
      'named constructor capture',
      '$ownerImport\nfinal create = AppPreferences.named;',
      count: 1,
    ),
    const Case(
      'ordinary main method is not bootstrap',
      '$ownerImport\nclass Consumer { void main() { AppPreferences(); } }',
      count: 1,
    ),
    const Case(
      'main library is not blanket exempt',
      'class Consumer {}',
      count: 1,
      file: rule.bootstrap,
      line: 3,
      extra: {
        rule.bootstrap:
            '$ownerImport\nvoid createApplicationDependencies() {}\nclass App { void initState() { AppPreferences(); } }',
      },
    ),
    const Case(
      'bootstrap sibling function',
      'class Consumer {}',
      count: 1,
      file: rule.bootstrap,
      line: 3,
      extra: {
        rule.bootstrap:
            '$ownerImport\nvoid createApplicationDependencies() {}\nAppPreferences other() => AppPreferences();',
      },
    ),
    const Case(
      'explicit superclass',
      '$ownerImport\nclass Consumer extends AppPreferences { Consumer() : super(); }',
      count: 1,
    ),
    const Case(
      'implicit superclass',
      '$ownerImport\nclass Consumer extends AppPreferences { Consumer(); }',
      count: 1,
    ),
    const Case(
      'super parameter',
      '$ownerImport\nclass Consumer extends AppPreferences { Consumer(super.preferences); }',
      count: 1,
    ),
    const Case(
      'implicit default subclass constructor',
      '$ownerImport\nclass Consumer extends AppPreferences {}',
      count: 1,
    ),
    const Case(
      'mixin application superclass',
      '$ownerImport\nmixin Helper {}\nclass Consumer = AppPreferences with Helper;',
      count: 1,
      line: 3,
    ),
    const Case(
      'factory redirect',
      'class Consumer {}',
      count: 1,
      file: rule.definition,
      line: 1,
      extra: {
        rule.definition:
            'class AppPreferences { AppPreferences(); factory AppPreferences.redirect() = AppPreferences; }',
      },
    ),
    const Case(
      'canonical owner self factory call',
      'class Consumer {}',
      count: 1,
      file: rule.definition,
      line: 1,
      extra: {
        rule.definition:
            'class AppPreferences { AppPreferences(); static AppPreferences create() => AppPreferences(); }',
      },
    ),
    const Case(
      'URI caller part',
      "$ownerImport\npart 'caller_part.dart';",
      count: 1,
      file: 'lib/caller_part.dart',
      extra: {
        'lib/caller_part.dart':
            "part of 'caller.dart';\nfinal owner = AppPreferences();",
      },
    ),
    const Case(
      'named caller part',
      "library caller;\n$ownerImport\npart 'caller_part.dart';",
      count: 1,
      file: 'lib/caller_part.dart',
      extra: {
        'lib/caller_part.dart':
            'part of caller;\nfinal create = AppPreferences.new;',
      },
    ),
    const Case(
      'owner definition in actual part',
      '$ownerImport\nfinal owner = AppPreferences();',
      count: 1,
      extra: {
        rule.definition: "part 'preferences_part.dart';",
        'lib/core/services/preferences_part.dart':
            "part of 'app_preferences.dart';\n$ownerModel",
      },
    ),
    const Case(
      'actual bootstrap construction',
      'class Consumer {}',
      extra: {
        rule.bootstrap:
            '$ownerImport\nvoid createApplicationDependencies() { AppPreferences(); }',
      },
    ),
    const Case(
      'actual bootstrap capture',
      'class Consumer {}',
      extra: {
        rule.bootstrap:
            '$ownerImport\nvoid createApplicationDependencies() { final create = AppPreferences.new; create(); }',
      },
    ),
    const Case(
      'application bootstrap actual part',
      'class Consumer {}',
      extra: {
        rule.bootstrap: "$ownerImport\npart '../../bootstrap_part.dart';",
        'lib/bootstrap_part.dart':
            "part of 'core/services/application_startup.dart';\nvoid createApplicationDependencies() { AppPreferences(); }",
      },
    ),
    const Case(
      'borrowing and invoking supplied callback',
      '$ownerImport\nvoid use(AppPreferences owner, AppPreferences Function() supplied) { supplied(); }',
    ),
    const Case(
      'bootstrap dynamic count is outside placement property',
      'class Consumer {}',
      extra: {
        rule.bootstrap:
            '$ownerImport\nvoid createApplicationDependencies() { for (var i = 0; i < 2; i++) { AppPreferences(); } }',
      },
    ),
    const Case(
      'unrelated same-name constructor',
      'class AppPreferences { AppPreferences(); }\nfinal owner = AppPreferences();',
    ),
    const Case(
      'foreign same-name capture',
      "import 'package:wing/other.dart';\nfinal create = AppPreferences.new;",
      extra: {'lib/other.dart': 'class AppPreferences { AppPreferences(); }'},
    ),
    const Case(
      'local callback shadow',
      'Object use(Object Function() AppPreferences) { return AppPreferences(); }',
    ),
    const Case(
      'unresolved construction',
      '$ownerImport\nfinal owner = AppPreferences(unknown);',
      input: true,
    ),
    const Case(
      'conditional provenance',
      "import 'package:wing/core/services/app_preferences.dart' if (dart.library.io) 'package:wing/other.dart';\nfinal owner = AppPreferences();",
      input: true,
      extra: {'lib/other.dart': ownerModel},
    ),
    const Case(
      'orphan caller part',
      "part of 'main.dart';\nfinal owner = AppPreferences();",
      input: true,
    ),
    const Case(
      'mismatched caller part',
      "$ownerImport\npart 'caller_part.dart';",
      input: true,
      extra: {
        'lib/caller_part.dart':
            "part of 'other.dart';\nfinal owner = AppPreferences();",
      },
    ),
    const Case(
      'missing bootstrap declaration',
      'class Consumer {}',
      input: true,
      extra: {rule.bootstrap: 'class Main {}'},
    ),
    const Case(
      'missing canonical owner declaration',
      cli: true,
      'class Consumer {}',
      input: true,
      extra: {rule.definition: 'class Other {}'},
    ),
    const Case(
      'orphan canonical owner library',
      'class Consumer {}',
      input: true,
      extra: {rule.definition: "part of 'other.dart';\n$ownerModel"},
    ),
    const Case(
      'authored alias outside parsed lib cannot silently pass',
      "import '{{ROOT}}tools/owner_alias.dart';\nfinal owner = BorrowedOwner();",
      input: true,
      extra: {
        'tools/owner_alias.dart':
            "$ownerImport\ntypedef BorrowedOwner = AppPreferences;",
      },
    ),
    const Case(
      'outside-lib part retains true production library provenance',
      "$ownerImport\npart '{{ROOT}}tools/caller_part.dart';",
      input: true,
      extra: {
        'tools/caller_part.dart':
            "part of 'package:wing/caller.dart';\nfinal owner = AppPreferences();",
      },
    ),
    const Case('malformed source', 'class Consumer {', input: true),
    const Case(
      'deferred nested capture is outside direct application bootstrap',
      'class Consumer {}',
      count: 1,
      file: rule.bootstrap,
      line: 3,
      extra: {
        rule.bootstrap:
            '$ownerImport\ntypedef Borrowed = AppPreferences;\nvoid createApplicationDependencies() { final capture = () => Borrowed.new; capture()(); }',
      },
    ),
    const Case(
      'forbidden capture beside permitted bootstrap call',
      'class Consumer {}',
      count: 1,
      file: rule.bootstrap,
      line: 3,
      extra: {
        rule.bootstrap:
            '$ownerImport\nvoid createApplicationDependencies() { AppPreferences(); }\nfinal capture = AppPreferences.new;',
      },
    ),
    const Case(
      'permitted body semantic errors belong to SDK analysis',
      'class Consumer {}',
      extra: {
        rule.bootstrap:
            '$ownerImport\nvoid createApplicationDependencies() { AppPreferences(unknown); }',
      },
    ),
    const Case(
      'conditional bootstrap candidates remain unsupported',
      'class Consumer {}',
      input: true,
      extra: {
        rule.bootstrap:
            "import 'package:wing/core/services/app_preferences.dart' if (dart.library.io) 'package:wing/other.dart';\nvoid createApplicationDependencies() { AppPreferences(); }",
        'lib/other.dart': ownerModel,
      },
    ),
    const Case(
      'actual application dependency factory record',
      cli: true,
      'class Consumer {}',
      extra: {
        rule.bootstrap:
            '$ownerImport\nFuture<({AppPreferences appPreferences})> createApplicationDependencies() async { final preferences = Object(); return (appPreferences: AppPreferences(preferences)); }',
      },
    ),
    const Case(
      'application factory alias capture',
      'class Consumer {}',
      extra: {
        rule.bootstrap:
            '$ownerImport\ntypedef Borrowed = AppPreferences;\nvoid createApplicationDependencies() { final capture = Borrowed.new; capture(); }',
      },
    ),
    const Case(
      'main delegates to application factory without construction',
      'class Consumer {}',
      extra: {
        'lib/main.dart':
            "import 'core/services/application_startup.dart';\nvoid main() { createApplicationDependencies(); }",
        rule.bootstrap:
            '$ownerImport\nvoid createApplicationDependencies() { AppPreferences(); }',
      },
    ),
    const Case(
      'main construction is outside application factory',
      'class Consumer {}',
      count: 1,
      file: 'lib/main.dart',
      extra: {
        'lib/main.dart': '$ownerImport\nvoid main() { AppPreferences(); }',
      },
    ),
    const Case(
      'same named function in another library',
      '$ownerImport\nvoid createApplicationDependencies() { AppPreferences(); }',
      count: 1,
    ),
    const Case(
      'same named class method in application library',
      'class Consumer {}',
      count: 1,
      file: rule.bootstrap,
      line: 3,
      extra: {
        rule.bootstrap:
            '$ownerImport\nvoid createApplicationDependencies() {}\nclass Other { void createApplicationDependencies() { AppPreferences(); } }',
      },
    ),
    const Case(
      'same named local function inside application factory',
      'class Consumer {}',
      count: 1,
      file: rule.bootstrap,
      extra: {
        rule.bootstrap:
            '$ownerImport\nvoid createApplicationDependencies() { void createApplicationDependencies() { AppPreferences(); } createApplicationDependencies(); }',
      },
    ),
  ];
  // All 52 resolved API fixtures retain their full identity/location assertions.
  // CLI source/AOT runs need one representative per exit, plus invalid SDK.
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
          '${fixture.name}: wrong finding count',
        );
        require(
          findings.every(
            (finding) =>
                finding.id == rule.id &&
                finding.file == fixture.file &&
                finding.line == fixture.line,
          ),
          '${fixture.name}: wrong diagnostic provenance/location: $findings',
        );
      }
      for (final (executable, prefix) in [
        if (fixture.cli)
          (
            proofDartExecutable,
            [
              'run',
              'tools/architecture/rules/app_preferences_construction.dart',
            ],
          ),
        if (fixture.cli && compiled != null) (compiled, <String>[]),
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
        if (expected == 2) {
          require(
            '${result.stderr}'.contains('[${rule.id} INPUT]'),
            '${fixture.name}: missing input diagnostic',
          );
        } else {
          final rows =
              ((jsonDecode(result.stdout as String) as Map)['findings'] as List)
                  .cast<Map>();
          require(
            rows.length == fixture.count &&
                rows.every(
                  (finding) =>
                      finding['id'] == rule.id &&
                      finding['file'] == fixture.file &&
                      finding['line'] == fixture.line,
                ),
            '${fixture.name}: wrong CLI diagnostic',
          );
        }
        if (expected == 0) {
          final invalid = await runProofProcess(executable, [
            ...prefix,
            '--root',
            workspace.directory.path,
            '--roles',
            workspace.rolesPath,
            '--sdk',
            '${workspace.directory.path}/missing-sdk',
          ]);
          require(
            invalid.exitCode == 2,
            '${fixture.name}: invalid SDK accepted clean scope',
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
