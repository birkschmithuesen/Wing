import 'dart:convert';
import 'dart:io';

import '../model.dart';
import '../rules/supervision_view_dependencies.dart' as rule;
import '../proof_process.dart';

const _view = 'lib/core/widgets/profile_subagent_panel.dart';
const _goal = 'lib/core/widgets/profile_goal_panel.dart';
const _work = 'lib/core/widgets/profile_background_work_panel.dart';
const _adapter = 'lib/core/services/profile_workspace_controller.dart';
const _owner = 'lib/core/services/profile_supervision_session.dart';
const _part = 'lib/core/widgets/supervision_part.dart';
const _page = 'class ProfileSubagentPanel {}';
const _goalPage = 'class ProfileGoalPanel {}';
const _workPage = 'class ProfileBackgroundWorkPanel {}';

class _Case {
  const _Case(
    this.name,
    this.files,
    this.exit, {
    this.libraries = const {},
    this.file = _view,
  });
  final String name;
  final Map<String, String> files;
  final int exit;
  final int line = 1;
  final String file;
  final Map<String, String> libraries;
}

// Shared helper namespace proofs are retained separately; these cases bind
// the exact completed panels and their real former raw dependency.
const _cases = [
  _Case('original-direct', {
    _view: "import '../services/profile_workspace_controller.dart';\n$_page",
    _adapter: 'class ProfileWorkspaceController {}',
  }, 1),
  _Case(
    'original-goal',
    {
      _goal:
          "import '../services/profile_workspace_controller.dart';\n$_goalPage",
      _adapter: 'class ProfileWorkspaceController {}',
    },
    1,
    file: _goal,
  ),
  _Case(
    'original-work',
    {
      _work:
          "import '../services/profile_workspace_controller.dart';\n$_workPage",
      _adapter: 'class ProfileWorkspaceController {}',
    },
    1,
    file: _work,
  ),
  _Case('raw-barrel', {
    _view:
        "import '../../barrel.dart' as raw show ProfileWorkspaceController;\n$_page",
    'lib/barrel.dart':
        "export 'core/services/profile_workspace_controller.dart';",
    _adapter: 'class ProfileWorkspaceController {}',
  }, 1),
  _Case(
    'actual-part',
    {
      _view: "part 'supervision_part.dart';",
      _part: "part of 'profile_subagent_panel.dart';\n$_page",
    },
    0,
    libraries: {_part: _view},
  ),
  _Case('typed-owner', {
    _view: "import '../services/profile_supervision_session.dart';\n$_page",
    _owner:
        "import 'profile_workspace_controller.dart'; class ProfileSupervisionSession {}",
    _adapter: 'class ProfileWorkspaceController {}',
  }, 0),
  _Case('homonymous-library', {
    _view: "import '../models/profile_workspace_controller.dart';\n$_page",
    'lib/core/models/profile_workspace_controller.dart':
        'class ProfileWorkspaceController {}',
  }, 0),
  _Case('missing-part', {_view: "part 'supervision_part.dart'; $_page"}, 2),
];

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  const representatives = {
    'original-direct': 1,
    'typed-owner': 0,
    'missing-part': 2,
  };
  final exercised = <String, int>{};
  for (final fixture in _cases) {
    final directory = Directory.systemTemp.createTempSync(
      'wing-supervision-deps-',
    );
    try {
      final roles = <String, Object>{};
      for (final entry in <String, String>{
        _view: _page,
        _goal: _goalPage,
        _work: _workPage,
        ...fixture.files,
      }.entries) {
        final file = File('${directory.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
        roles[entry.key] = {
          'role':
              rule.views.containsKey(entry.key) ||
                  fixture.libraries.containsKey(entry.key)
              ? 'view'
              : 'utility',
          'feature': 'supervision',
          'library': fixture.libraries[entry.key] ?? entry.key,
        };
      }
      final rolePath = '${directory.path}/roles.json';
      File(
        rolePath,
      ).writeAsStringSync(jsonEncode({'schema': 1, 'files': roles}));
      var actual = 0;
      var findings = <Finding>[];
      try {
        final snapshot = Snapshot.load(directory.path, rolePath);
        findings = rule.check(snapshot);
        actual = findings.isEmpty ? 0 : 1;
      } on FormatException {
        actual = 2;
      }
      if (actual != fixture.exit ||
          (actual == 1 &&
              (findings.length != 1 ||
                  findings.single.id != rule.id ||
                  findings.single.file != fixture.file ||
                  findings.single.line != fixture.line))) {
        throw StateError(
          '${fixture.name}: expected ${fixture.exit}, got $actual / $findings',
        );
      }
      if (representatives.containsKey(fixture.name)) {
        if (exercised.containsKey(fixture.name) ||
            representatives[fixture.name] != fixture.exit) {
          throw StateError('Duplicate or altered CLI representative');
        }
        exercised[fixture.name] = fixture.exit;
        final result = await runProofProcess(proofDartExecutable, [
          'run',
          'tools/architecture/rules/supervision_view_dependencies.dart',
          '--root',
          directory.path,
          '--roles',
          rolePath,
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
          final json = jsonDecode(result.stdout as String) as Map;
          final diagnostics = json['problems'] as List;
          if (fixture.exit == 0
              ? diagnostics.isNotEmpty
              : diagnostics.length != 1 ||
                    (diagnostics.single as Map)['id'] != rule.id ||
                    (diagnostics.single as Map)['file'] != fixture.file ||
                    (diagnostics.single as Map)['line'] != fixture.line) {
            throw StateError('CLI diagnostic identity/location mismatch');
          }
        }
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  }
  if (exercised.length != representatives.length ||
      representatives.entries.any(
        (entry) => exercised[entry.key] != entry.value,
      )) {
    throw StateError('CLI exits 1/0/2 were not all proved');
  }
  stdout.writeln(
    '${rule.id}: ${_cases.length} detector fixtures; three CLI representatives passed',
  );
}
