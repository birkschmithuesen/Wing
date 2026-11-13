import 'dart:convert';
import 'dart:io';
import '../model.dart';
import '../rules/workspace_canonical_state.dart' as rule;
import '../proof_process.dart';

String owner(
  String name, {
  String? replace,
  String? addition,
  String? ancestry,
}) {
  final parent =
      ancestry ??
      (name == 'ProfileWorkspaceController' ? ' extends ChangeNotifier' : '');
  return 'class $name$parent {\n'
      "${name == 'ProfileWorkspaceController' ? 'final Object? _discovery = null;\n' : ''}"
      '${rule.observations[name]!.map((field) => field == replace ? 'Object? $field;' : "Object? get $field => ${name == 'ProfileWorkspaceController' && field == 'discovery' ? '_discovery' : 'null'};").join('\n')}\n'
      '${addition ?? ''}\n}';
}

String source({String? replace, String? addition, String? ancestry}) =>
    "import 'package:flutter/foundation.dart';\n"
    '${owner('ProfileChat', replace: replace, addition: addition, ancestry: ancestry)}\n'
    '${owner('ProfileWorkspaceData')}\n${owner('ProfileWorkspaceController')}';

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  final cases = <({String name, String text, int exit})>[
    (name: 'readonly', text: source(), exit: 0),
    (
      name: 'explicit-retained-field',
      text: source().replaceAll('=> _discovery;', '=> this._discovery;'),
      exit: 0,
    ),
    (name: 'original-field', text: source(replace: 'title'), exit: 1),
    (
      name: 'new-mutable-bag',
      text: source(addition: 'final values = <String>[];'),
      exit: 1,
    ),
    (
      name: 'allocated-discovery',
      text: source().replaceFirst(
        'get discovery => _discovery;',
        'get discovery => Object();',
      ),
      exit: 1,
    ),
    (
      name: 'setter',
      text: source(addition: 'set title(Object? value) {}'),
      exit: 1,
    ),
    (name: 'ancestry', text: source(ancestry: ' extends Unknown'), exit: 2),
    (
      name: 'shadowed-notifier',
      text:
          '${source()}\ntypedef ChangeNotifier = WritableBase;\nclass WritableBase { set external(Object? value) {} }',
      exit: 2,
    ),
    (
      name: 'missing-observation',
      text: source().replaceFirst('Object? get title => null;', ''),
      exit: 2,
    ),
    (name: 'missing-part', text: "part 'missing.dart';\n${source()}", exit: 2),
  ];
  final proved = <int>{};
  for (final fixture in cases) {
    final root = Directory.systemTemp.createTempSync('wing-canonical-state-');
    try {
      final file = File('${root.path}/${rule.library}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(fixture.text);
      final rolePath = '${root.path}/roles.json';
      File(rolePath).writeAsStringSync(
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
      var exit = 0;
      var findings = <Finding>[];
      try {
        findings = rule.check(Snapshot.load(root.path, rolePath));
        exit = findings.isEmpty ? 0 : 1;
      } on FormatException {
        exit = 2;
      }
      if (exit != fixture.exit ||
          exit == 1 &&
              (findings.length != 1 ||
                  findings.single.id != rule.id ||
                  findings.single.file != rule.library ||
                  findings.single.line !=
                      fixture.text
                          .substring(
                            0,
                            fixture.text.indexOf(switch (fixture.name) {
                              'original-field' => 'Object? title;',
                              'new-mutable-bag' => 'final values',
                              'setter' => 'set title',
                              'allocated-discovery' => 'Object? get discovery',
                              _ => throw StateError(
                                'Unexpected violation fixture',
                              ),
                            }),
                          )
                          .split('\n')
                          .length)) {
        throw StateError(
          '${fixture.name}: expected ${fixture.exit}, got $exit / $findings',
        );
      }
      if (proved.add(fixture.exit)) {
        final result = await runProofProcess(proofDartExecutable, [
          'run',
          'tools/architecture/rules/workspace_canonical_state.dart',
          '--root',
          root.path,
          '--roles',
          rolePath,
          '--json',
        ]);
        if (result.exitCode != fixture.exit ||
            fixture.exit == 2 &&
                !(result.stderr as String).contains('[ARCH_INPUT]')) {
          throw StateError(
            '${fixture.name}: unexpected CLI result ${result.exitCode}',
          );
        }
        if (fixture.exit != 2) {
          final problems =
              (jsonDecode(result.stdout as String) as Map)['problems'] as List;
          if (problems.length != findings.length ||
              findings.isNotEmpty &&
                  ((problems.single as Map)['id'] != rule.id ||
                      (problems.single as Map)['line'] !=
                          findings.single.line)) {
            throw StateError(
              '${fixture.name}: CLI diagnostic identity/location mismatch',
            );
          }
        }
      }
    } finally {
      root.deleteSync(recursive: true);
    }
  }
  if (proved.length != 3) throw StateError('CLI 0/1/2 representatives missing');
  stdout.writeln(
    '${rule.id}: ${cases.length} detector fixtures and three CLI representatives passed',
  );
}
