import 'dart:convert';
import 'dart:io';

import '../model.dart';
import '../rules/tool_setup_view_dependencies.dart' as rule;
import '../proof_process.dart';

const _view = rule.view;
const _gateway = 'lib/core/services/profile_gateway.dart';
const _repository = 'lib/core/services/administration_repository.dart';
const _owner = 'lib/core/services/profile_tool_setup_session.dart';
const _model = 'lib/core/models/profile_tool_setup.dart';
const _part = 'lib/core/screens/administration/tool_setup_part.dart';
const _page = 'class AdminToolSetupPage {} class AdminToolModelsPage {}';

class _Case {
  const _Case(this.name, this.files, this.exit, {this.libraries = const {}});
  final String name;
  final Map<String, String> files;
  final int exit;
  final int line = 1;
  final Map<String, String> libraries;
}

// Shared namespace robustness remains covered by the unchanged capabilities
// fixtures. These are the tool boundary's relevant cases, not a syntax matrix.
const _cases = [
  _Case('original-direct', {
    _view: "import '../../services/administration_repository.dart';\n$_page",
    _repository: 'class ProfileAdministration {}',
  }, 1),
  _Case('package-prefixed-normalized-gateway', {
    _view:
        "import 'package:wing/core/models/../services/profile_gateway.dart' as raw hide ProfileGateway; $_page",
    _gateway: 'class ProfileGateway {}',
  }, 1),
  _Case('conditional-export-barrel', {
    _view: "import '../../../barrel.dart'; $_page",
    'lib/barrel.dart':
        "export 'safe.dart' if (dart.library.io) 'core/services/administration_repository.dart';",
    'lib/safe.dart': 'class Safe {}',
    _repository: 'class ProfileAdministration {}',
  }, 1),
  _Case(
    'actual-part',
    {
      _view:
          "import '../../services/administration_repository.dart';\npart 'tool_setup_part.dart';",
      _part: "part of 'admin_tool_setup_page.dart'; $_page",
      _repository: 'class ProfileAdministration {}',
    },
    1,
    libraries: {_part: _view},
  ),
  _Case('typed-owner', {
    _view:
        "import '../../services/profile_tool_setup_session.dart'; import '../../models/profile_tool_setup.dart'; $_page",
    _owner:
        "import 'profile_gateway.dart'; import 'administration_repository.dart'; class ProfileToolSetupSession {}",
    _model:
        'class ToolSetupReadiness { const ToolSetupReadiness(this.configured); final bool configured; }',
    _gateway: 'class ProfileGateway {}',
    _repository: 'class ProfileAdministration {}',
  }, 0),
  _Case('homonymous-model-library-and-members', {
    _view:
        "import '../../models/profile_gateway.dart'; class AdminToolSetupPage { void read() {} } class AdminToolModelsPage { void put() {} }",
    'lib/core/models/profile_gateway.dart': 'class ProfileGateway {}',
  }, 0),
  _Case('missing-part', {_view: "part 'tool_setup_part.dart'; $_page"}, 2),
  _Case('missing-conditional-export-even-with-adapter', {
    _view: "import '../../../barrel.dart'; $_page",
    'lib/barrel.dart':
        "export 'core/services/administration_repository.dart' if (dart.library.io) 'missing.dart';",
    _repository: 'class ProfileAdministration {}',
  }, 2),
];

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  final cliExits = <int>{};
  for (final fixture in _cases) {
    final directory = Directory.systemTemp.createTempSync(
      'wing-tool-setup-deps-',
    );
    try {
      final roles = <String, Object>{};
      for (final entry in fixture.files.entries) {
        final file = File('${directory.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
        roles[entry.key] = {
          'role': entry.key == _view ? 'view' : 'utility',
          'feature': 'tool-setup',
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
          'tools/architecture/rules/tool_setup_view_dependencies.dart',
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
