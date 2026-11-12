import 'dart:convert';
import 'dart:io';

import '../dart_sdk.dart';
import '../model.dart';
import '../rules/activity_density.dart' as rule;
import '../proof_process.dart';

const _tool = 'lib/core/widgets/profile_tool_call.dart';
const _agents = 'lib/core/widgets/profile_saved_agents.dart';
const _canonical = "import 'compact_activity_row.dart';";
const _fixtures = <({String name, String imports, String body, String extra, int exit})>[
  (
    name: 'direct',
    imports: _canonical,
    body: 'return CompactActivityRow();',
    extra: '',
    exit: 0,
  ),
  (name: 'expression-body', imports: _canonical, body: '', extra: '', exit: 0),
  (
    name: 'prefixed',
    imports: "import 'compact_activity_row.dart' as dense;",
    body: 'return dense.CompactActivityRow();',
    extra: '',
    exit: 0,
  ),
  (
    name: 'barrel',
    imports: "import 'density_export.dart';",
    body: 'return CompactActivityRow();',
    extra: '',
    exit: 0,
  ),
  (
    name: 'typedef',
    imports: _canonical,
    body: 'return Dense();',
    extra: 'typedef Dense = CompactActivityRow;',
    exit: 0,
  ),
  (
    name: 'parentheses',
    imports: _canonical,
    body: 'return (CompactActivityRow.new());',
    extra: '',
    exit: 0,
  ),
  (
    name: 'detail-spacing',
    imports: _canonical,
    body: 'return CompactActivityRow(details: [Padding(48)]);',
    extra: '',
    exit: 0,
  ),
  (
    name: 'callback-return',
    imports: _canonical,
    body: 'return CompactActivityRow(callback: () { return Padding(48); });',
    extra: '',
    exit: 0,
  ),
  (
    name: 'local-function-return',
    imports: _canonical,
    body:
        'Object other() { return Padding(48); } other(); return CompactActivityRow();',
    extra: '',
    exit: 0,
  ),
  (
    name: 'padding',
    imports: _canonical,
    body: 'return Padding(48, child: CompactActivityRow());',
    extra: '',
    exit: 1,
  ),
  (
    name: 'alternate-tile',
    imports: _canonical,
    body: 'return ExpansionTile();',
    extra: '',
    exit: 1,
  ),
  (
    name: 'minimum-height',
    imports: _canonical,
    body: 'return ConstrainedBox(48, child: CompactActivityRow());',
    extra: '',
    exit: 1,
  ),
  (
    name: 'one-padded-branch',
    imports: _canonical,
    body:
        'if (context == null) { return Padding(4, child: CompactActivityRow()); } return CompactActivityRow();',
    extra: '',
    exit: 1,
  ),
  (
    name: 'helper',
    imports: _canonical,
    body: 'return make();',
    extra: 'Object make() => CompactActivityRow();',
    exit: 1,
  ),
  (
    name: 'constructor-tearoff',
    imports: _canonical,
    body: 'final make = CompactActivityRow.new; return make();',
    extra: '',
    exit: 1,
  ),
  (
    name: 'local-homonym',
    imports: "import 'compact_activity_row.dart' hide CompactActivityRow;",
    body: 'return CompactActivityRow();',
    extra: 'class CompactActivityRow {}',
    exit: 1,
  ),
  (
    name: 'imported-homonym',
    imports: "import 'density_imposter.dart';",
    body: 'return CompactActivityRow();',
    extra: '',
    exit: 1,
  ),
  (
    name: 'padding-typedef',
    imports: _canonical,
    body: 'return Dense(4, child: CompactActivityRow());',
    extra: 'typedef Dense = Padding;',
    exit: 1,
  ),
  (
    name: 'syntax',
    imports: _canonical,
    body: 'return CompactActivityRow(;',
    extra: '',
    exit: 2,
  ),
  (
    name: 'unresolved',
    imports: _canonical,
    body: 'return MissingWidget();',
    extra: '',
    exit: 2,
  ),
  (name: 'missing-method', imports: _canonical, body: '', extra: '', exit: 2),
  (name: 'missing-owner', imports: _canonical, body: '', extra: '', exit: 2),
  (
    name: 'conditional-import',
    imports:
        "import 'compact_activity_row.dart' if (dart.library.io) 'density_imposter.dart';",
    body: 'return CompactActivityRow();',
    extra: '',
    exit: 2,
  ),
  (
    name: 'part-owner',
    imports: "part of 'compact_activity_row.dart';",
    body: 'return CompactActivityRow();',
    extra: '',
    exit: 2,
  ),
];

Future<void> main(List<String> args) =>
    withProofProcesses(() => _proofMain(args));

Future<void> _proofMain(List<String> args) async {
  if (args.isNotEmpty && (args.length != 2 || args.first != '--compiled')) {
    throw const FormatException('Expected --compiled PATH');
  }
  final sdk = dartSdkPath(Directory.current.path);
  final root = Directory.systemTemp.createTempSync('wing-density-fixtures-');
  final cliRepresentatives = <int>{};
  try {
    void write(String path, String source) {
      final file = File('${root.path}/$path');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(source);
    }

    // Absolute SDK package URLs also make this input usable by the compiled CLI.
    final config = File('.dart_tool/package_config.json');
    final packages = jsonDecode(config.readAsStringSync()) as Map;
    for (final package in packages['packages'] as List) {
      package['rootUri'] = config.absolute.uri
          .resolve(package['rootUri'] as String)
          .toString();
    }
    write('.dart_tool/package_config.json', jsonEncode(packages));
    write(rule.rowPath, '''
class CompactActivityRow {
  CompactActivityRow({List<Object> details = const [], Object Function()? callback});
}
class Padding { Padding(double padding, {Object? child}); }
class ConstrainedBox { ConstrainedBox(double height, {Object? child}); }
class ExpansionTile {}
// Unrelated UI is allowed to retain normal touch-friendly padding.
Object settingsTile() => Padding(48);
''');
    write(
      'lib/core/widgets/density_export.dart',
      "export 'compact_activity_row.dart';",
    );
    write(
      'lib/core/widgets/density_imposter.dart',
      'class CompactActivityRow {}',
    );
    const paths = [
      rule.rowPath,
      _tool,
      _agents,
      'lib/core/widgets/density_export.dart',
      'lib/core/widgets/density_imposter.dart',
    ];
    final roles = '${root.path}/roles.json';
    File(roles).writeAsStringSync(
      jsonEncode({
        'schema': 1,
        'files': {
          for (final path in paths)
            path: {'role': 'view', 'feature': 'chat-activity', 'library': path},
        },
      }),
    );
    for (final fixture in _fixtures) {
      for (final target in [_tool, _agents]) {
        for (final path in [_tool, _agents]) {
          final owner = path == _tool
              ? 'ProfileToolCall'
              : 'ProfileSavedAgents';
          final method = path == _tool ? 'build' : '_buildAgent';
          final active = path == target;
          write(
            path,
            active && fixture.name == 'missing-owner'
                ? 'class Other {}'
                : '''
${active ? fixture.imports : _canonical}
class $owner {
  ${active && fixture.name == 'missing-method'
                      ? ''
                      : active && fixture.name == 'expression-body'
                      ? 'Object $method(Object? context) => CompactActivityRow();'
                      : 'Object $method(Object? context) { ${active ? fixture.body : 'return CompactActivityRow();'} }'}
}
${active ? fixture.extra : ''}
''',
          );
        }
        var exit = 0;
        var findings = <Finding>[];
        try {
          findings = await rule.check(
            Snapshot.load(root.path, roles),
            sdkPath: sdk,
          );
          exit = findings.isEmpty ? 0 : 1;
        } on FormatException {
          exit = 2;
        }
        if (exit != fixture.exit ||
            exit == 1 &&
                (findings.length != 1 ||
                    findings.single.id != rule.id ||
                    findings.single.file != target ||
                    findings.single.line != 3)) {
          throw StateError('${fixture.name} / $target: $exit $findings');
        }
        if (!cliRepresentatives.add(fixture.exit)) continue;
        final result = await runProofProcess(
          args.isEmpty ? proofDartExecutable : args.last,
          [
            if (args.isEmpty) ...[
              'run',
              'tools/architecture/rules/activity_density.dart',
            ],
            '--root',
            root.path,
            '--roles',
            roles,
            '--json',
          ],
        );
        if (result.exitCode != fixture.exit) {
          throw StateError(
            'CLI ${fixture.name}: ${result.exitCode} ${result.stdout} ${result.stderr}',
          );
        }
        if (fixture.exit == 2) {
          if (!(result.stderr as String).contains('[ARCH_INPUT]')) {
            throw StateError('Missing input diagnostic');
          }
        } else {
          final data = jsonDecode(result.stdout as String) as Map;
          final problems = data['problems'] as List;
          if (problems.length != (fixture.exit == 0 ? 0 : 1) ||
              fixture.exit == 1 &&
                  (problems.single['id'] != rule.id ||
                      problems.single['file'] != target ||
                      problems.single['line'] != 3)) {
            throw StateError('Incorrect CLI diagnostic: $data');
          }
        }
      }
    }
    if (cliRepresentatives.length != 3) {
      throw StateError('Missing CLI exit proof');
    }
    stdout.writeln(
      '${_fixtures.length * 2} density fixtures; CLI 0/1/2 passed',
    );
  } finally {
    root.deleteSync(recursive: true);
  }
}
