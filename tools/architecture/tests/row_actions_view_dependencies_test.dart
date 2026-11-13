import 'dart:convert';
import 'dart:io';

import '../model.dart';
import '../rules/row_actions_view_dependencies.dart' as rule;
import '../proof_process.dart';

const _view = rule.view;
const _adapter = 'lib/core/services/profile_workspace_controller.dart';
const _otherAdapter = 'lib/core/services/profile_gateway.dart';
const _owner = 'lib/core/services/chat_browser_data.dart';
const _model = 'lib/core/models/browser_actions.dart';
const _part = 'lib/core/screens/row_actions_part.dart';
const _page = 'class _ChatProjectSheet {}';

class _Case {
  const _Case(this.name, this.files, this.exit, {this.libraries = const {}});
  final String name;
  final Map<String, String> files;
  final int exit;
  final int line = 1;
  final Map<String, String> libraries;
}

// Accepted capabilities fixtures retain the shared namespace robustness.
// This is the completed boundary's relevant set, not another variants matrix.
const _cases = [
  _Case('original-direct', {
    _view: "import '../services/profile_workspace_controller.dart';\n$_page",
    _adapter: 'class ProfileWorkspaceController {}',
  }, 1),
  _Case('second-adapter-barrel', {
    _view: "import '../../barrel.dart'; $_page",
    'lib/barrel.dart': "export 'core/services/profile_gateway.dart';",
    _otherAdapter: 'class ProfileGateway {}',
  }, 1),
  _Case(
    'actual-part',
    {
      _view:
          "import '../services/profile_workspace_controller.dart';\npart 'row_actions_part.dart';",
      _part: "part of 'profile_row_actions.dart'; $_page",
      _adapter: 'class ProfileWorkspaceController {}',
    },
    1,
    libraries: {_part: _view},
  ),
  _Case('typed-owner', {
    _view:
        "import '../services/chat_browser_data.dart'; import '../models/browser_actions.dart'; $_page",
    _owner:
        "import 'profile_workspace_controller.dart'; import 'profile_gateway.dart'; class ChatBrowserData {}",
    _model:
        'class AdministrationLogSnapshot { const AdministrationLogSnapshot(this.lines); final List<String> lines; }',
    _adapter: 'class ProfileWorkspaceController {}',
    _otherAdapter: 'class ProfileGateway {}',
    'lib/core/screens/profile_workspace_screen.dart':
        "import '../services/profile_workspace_controller.dart'; void compose(ProfileWorkspaceController server) {}",
  }, 0),
  _Case('homonymous-model-and-members', {
    _view:
        "import '../models/profile_workspace_controller.dart'; $_page class OtherView { void read() {} void search() {} }",
    'lib/core/models/profile_workspace_controller.dart':
        'class ProfileWorkspaceController {}',
  }, 0),
  _Case('missing-part', {_view: "part 'row_actions_part.dart'; $_page"}, 2),
];

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  final cliExits = <int>{};
  for (final fixture in _cases) {
    final directory = Directory.systemTemp.createTempSync(
      'wing-row_actions-deps-',
    );
    try {
      final roles = <String, Object>{};
      for (final entry in fixture.files.entries) {
        final file = File('${directory.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
        roles[entry.key] = {
          'role': entry.key == _view ? 'view' : 'utility',
          'feature': 'row_actions',
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
                  findings.single.file != _view ||
                  findings.single.line != fixture.line))) {
        throw StateError(
          '${fixture.name}: expected ${fixture.exit}, got $actual / $findings',
        );
      }
      if ({
        'original-direct',
        'typed-owner',
        'missing-part',
      }.contains(fixture.name)) {
        if (!cliExits.add(fixture.exit)) {
          throw StateError('Duplicate CLI representative');
        }
        final result = await runProofProcess(proofDartExecutable, [
          'run',
          'tools/architecture/rules/row_actions_view_dependencies.dart',
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
                    (diagnostics.single as Map)['file'] != _view ||
                    (diagnostics.single as Map)['line'] != fixture.line) {
            throw StateError('CLI diagnostic identity/location mismatch');
          }
        }
      }
    } finally {
      directory.deleteSync(recursive: true);
    }
  }
  if (cliExits.length != 3) {
    throw StateError('CLI exits 1/0/2 were not all proved');
  }
  stdout.writeln(
    '${rule.id}: ${_cases.length} detector fixtures; three CLI representatives passed',
  );
}
