import 'dart:convert';
import 'dart:io';
import '../model.dart';
import '../rules/profile_discovery_writer.dart' as rule;
import '../proof_process.dart';

class _Case {
  const _Case(
    this.name,
    this.source,
    this.exit, {
    this.lines = const [1],
    this.cli = false,
    this.files = const {},
    this.file = rule.library,
  });
  final String name, source;
  final int exit;
  final List<int> lines;
  final bool cli;
  final Map<String, String> files;
  final String file;
}

const _field = 'ProfileDiscovery? _discovery;';
const _cases = [
  _Case(
    'original two discovery writers',
    'class ProfileWorkspaceController {\n$_field\nvoid initialize() { _discovery = ProfileDiscovery(profiles: profiles); }\nvoid switchProfile() { _discovery = ProfileDiscovery(profiles: profiles); }\n}',
    1,
    lines: [3, 4],
    cli: true,
  ),
  _Case(
    'sole adoption writer retains real fact checks',
    'class ProfileWorkspaceController { $_field void _adoptDiscovery(profiles) { final previous = _discovery; if (previous != null && previous.currentName == profiles.currentName && previous.activeName == profiles.activeName && listEquals(previous.profiles, profiles.profiles)) return; _discovery = ProfileDiscovery(profiles: List.unmodifiable(profiles.profiles), currentName: profiles.currentName, activeName: profiles.activeName); } void initialize() { _adoptDiscovery(profiles); } void switchProfile() { _adoptDiscovery(profiles); } }',
    0,
    cli: true,
  ),
  _Case(
    'newly named writer',
    'class ProfileWorkspaceController { $_field void elsewhere() { _discovery = null; } }',
    1,
  ),
  _Case(
    'explicit field beside parameter shadow',
    'class ProfileWorkspaceController { $_field void elsewhere(_discovery) { this._discovery = null; } }',
    1,
  ),
  _Case(
    'parameter assignment belongs to local',
    'class ProfileWorkspaceController { $_field void elsewhere(_discovery) { _discovery = null; } }',
    0,
  ),
  _Case(
    'block local assignment belongs to local',
    'class ProfileWorkspaceController { $_field void elsewhere() { var _discovery = null; _discovery = Object(); } }',
    0,
  ),
  _Case(
    'nested closure parameter belongs to local',
    'class ProfileWorkspaceController { $_field void elsewhere() { listen((_discovery) { _discovery = null; }); } }',
    0,
  ),
  _Case(
    'sibling local cannot hide actual writer',
    'class ProfileWorkspaceController { $_field void local() { var _discovery = null; _discovery = Object(); } void elsewhere() { _discovery = null; } }',
    1,
  ),
  _Case(
    'other receiver is outside canonical literal field',
    'class ProfileWorkspaceController { $_field void elsewhere(Other other) { other._discovery = null; } } class Other { Object? _discovery; }',
    0,
  ),
  _Case(
    'other class homonym is outside owner',
    'class ProfileWorkspaceController { $_field } class Other { Object? _discovery; void elsewhere() { _discovery = null; } }',
    0,
  ),
  _Case(
    'adopter explicit own field ignores parameter shadow',
    'class ProfileWorkspaceController { $_field void _adoptDiscovery(_discovery) { this._discovery = null; } }',
    0,
  ),
  _Case(
    'static helper is not owner adoption',
    'class ProfileWorkspaceController { $_field static void _adoptDiscovery() { _discovery = null; } }',
    1,
  ),
  _Case(
    'initialized field adds a writer',
    'class ProfileWorkspaceController { ProfileDiscovery? _discovery = ProfileDiscovery(); }',
    1,
  ),
  _Case(
    'constructor initializer adds a writer',
    'class ProfileWorkspaceController { $_field ProfileWorkspaceController() : _discovery = null; }',
    1,
  ),
  _Case(
    'field formal adds a writer',
    'class ProfileWorkspaceController { $_field ProfileWorkspaceController(this._discovery); }',
    1,
  ),
  _Case(
    'ambiguous local initializer fails input',
    'class ProfileWorkspaceController { $_field void elsewhere() { var _discovery = (_discovery = null); } }',
    2,
  ),
  _Case(
    'unproved catch shadow fails input',
    'class ProfileWorkspaceController { $_field void elsewhere() { try {} catch (_discovery) { _discovery = null; } } }',
    2,
  ),
  _Case('missing canonical owner', 'class Other {}', 2, cli: true),
  _Case('missing canonical field', 'class ProfileWorkspaceController {}', 2),
  _Case(
    'unsupported part scope',
    "part of 'other.dart'; class ProfileWorkspaceController { $_field }",
    2,
  ),
  _Case(
    'legitimate reciprocal parts contain no writes',
    "part 'profile_workspace_notifications.dart'; part 'profile_workspace_deleted_drafts.dart'; class ProfileWorkspaceController { $_field void _adoptDiscovery() { _discovery = null; } }",
    0,
    files: {
      'lib/core/services/profile_workspace_notifications.dart':
          "part of 'profile_workspace_controller.dart'; extension Notification on ProfileWorkspaceController { Object? get data => _discovery; }",
      'lib/core/services/profile_workspace_deleted_drafts.dart':
          "part of 'profile_workspace_controller.dart'; extension Cleanup on ProfileWorkspaceController { void retry() {} }",
    },
  ),
  _Case(
    'reciprocal part extension cannot bypass writer',
    "part 'profile_workspace_notifications.dart'; class ProfileWorkspaceController { $_field }",
    1,
    lines: [3],
    file: 'lib/core/services/profile_workspace_notifications.dart',
    files: {
      'lib/core/services/profile_workspace_notifications.dart':
          "part of 'profile_workspace_controller.dart';\n extension Notification on ProfileWorkspaceController {\n void reset() { _discovery = null; } }",
    },
  ),
  _Case(
    'part extension adopter homonym cannot exempt writer',
    "part 'profile_workspace_notifications.dart'; class ProfileWorkspaceController { $_field }",
    1,
    file: 'lib/core/services/profile_workspace_notifications.dart',
    files: {
      'lib/core/services/profile_workspace_notifications.dart':
          "part of 'profile_workspace_controller.dart'; extension Notification on ProfileWorkspaceController { void _adoptDiscovery() { this._discovery = null; } }",
    },
  ),
  _Case(
    'typed canonical top-level part receiver is a writer',
    "part 'profile_workspace_notifications.dart'; class ProfileWorkspaceController { $_field }",
    1,
    file: 'lib/core/services/profile_workspace_notifications.dart',
    files: {
      'lib/core/services/profile_workspace_notifications.dart':
          "part of 'profile_workspace_controller.dart'; void reset(ProfileWorkspaceController owner) { owner._discovery = null; }",
    },
  ),
  _Case(
    'part unrelated receiver and own homonym are valid',
    "part 'profile_workspace_notifications.dart'; class ProfileWorkspaceController { $_field } class Other { Object? _discovery; }",
    0,
    files: {
      'lib/core/services/profile_workspace_notifications.dart':
          "part of 'profile_workspace_controller.dart'; void reset(Other other) { other._discovery = null; } extension OtherReset on Other { void reset() { this._discovery = null; } }",
    },
  ),
  _Case(
    'missing reciprocal part fails input',
    "part 'missing.dart'; class ProfileWorkspaceController { $_field }",
    2,
  ),
  _Case(
    'nonreciprocal part fails input',
    "part 'profile_workspace_notifications.dart'; class ProfileWorkspaceController { $_field }",
    2,
    files: {
      'lib/core/services/profile_workspace_notifications.dart':
          "part of 'elsewhere.dart';",
    },
  ),
  _Case(
    'orphan reciprocal part fails input',
    'class ProfileWorkspaceController { $_field }',
    2,
    files: {
      'lib/core/services/profile_workspace_notifications.dart':
          "part of 'profile_workspace_controller.dart';",
    },
  ),
  _Case(
    'part dynamic receiver fails input instead of guessing',
    "part 'profile_workspace_notifications.dart'; class ProfileWorkspaceController { $_field }",
    2,
    files: {
      'lib/core/services/profile_workspace_notifications.dart':
          "part of 'profile_workspace_controller.dart'; void reset(dynamic owner) { owner._discovery = null; }",
    },
  ),
  _Case(
    'part catch shadow cannot impersonate typed owner',
    "part 'profile_workspace_notifications.dart'; class ProfileWorkspaceController { $_field }",
    2,
    files: {
      'lib/core/services/profile_workspace_notifications.dart':
          "part of 'profile_workspace_controller.dart'; void reset(ProfileWorkspaceController owner) { try {} catch (owner) { owner._discovery = null; } }",
    },
  ),
  _Case(
    'type parameter cannot impersonate unrelated own-field class',
    "part 'profile_workspace_notifications.dart'; class ProfileWorkspaceController { $_field } class Other { Object? _discovery; }",
    2,
    files: {
      'lib/core/services/profile_workspace_notifications.dart':
          "part of 'profile_workspace_controller.dart'; void reset<Other extends ProfileWorkspaceController>(Other owner) { owner._discovery = null; }",
    },
  ),
  _Case(
    'type parameter cannot impersonate canonical owner spelling',
    "part 'profile_workspace_notifications.dart'; class ProfileWorkspaceController { $_field } class Other { Object? _discovery; }",
    2,
    files: {
      'lib/core/services/profile_workspace_notifications.dart':
          "part of 'profile_workspace_controller.dart'; void reset<ProfileWorkspaceController extends Other>(ProfileWorkspaceController owner) { owner._discovery = null; }",
    },
  ),
  _Case('malformed source', 'class ProfileWorkspaceController {', 2),
];

void _findings(String name, List problems, List<int> lines, String file) {
  if (problems.length != lines.length) {
    throw StateError('$name: wrong findings $problems');
  }
  for (var i = 0; i < lines.length; i++) {
    final finding = problems[i] as Map;
    if (finding['id'] != rule.id ||
        finding['file'] != file ||
        finding['subject'] != rule.subject ||
        finding['line'] != lines[i]) {
      throw StateError('$name: wrong identity/location $finding');
    }
  }
}

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  final cliExits = <int>{};
  for (final fixture in _cases) {
    final root = Directory.systemTemp.createTempSync('wing-discovery-writer-');
    try {
      final file = File('${root.path}/${rule.library}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(fixture.source);
      for (final entry in fixture.files.entries) {
        final part = File('${root.path}/${entry.key}');
        part.parent.createSync(recursive: true);
        part.writeAsStringSync(entry.value);
      }
      final roles = '${root.path}/roles.json';
      File(roles).writeAsStringSync(
        jsonEncode({
          'schema': 1,
          'files': {
            for (final path in [rule.library, ...fixture.files.keys])
              path: {
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
        findings = rule.check(Snapshot.load(root.path, roles));
        exit = findings.isEmpty ? 0 : 1;
      } on FormatException {
        exit = 2;
      }
      if (exit != fixture.exit) {
        throw StateError('${fixture.name}: $exit / $findings');
      }
      if (exit == 1) {
        _findings(
          fixture.name,
          findings.map((f) => f.toJson()).toList(),
          fixture.lines,
          fixture.file,
        );
      }
      if (!fixture.cli) continue;
      if (!cliExits.add(fixture.exit)) {
        throw StateError('Duplicate CLI representative');
      }
      final result = await runProofProcess(proofDartExecutable, [
        '--packages=${File('.dart_tool/package_config.json').absolute.uri}',
        File(
          'tools/architecture/rules/profile_discovery_writer.dart',
        ).absolute.path,
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
        final problems =
            (jsonDecode(result.stdout as String) as Map)['problems'] as List;
        if (fixture.exit == 1) {
          _findings(fixture.name, problems, fixture.lines, fixture.file);
        } else if (problems.isNotEmpty) {
          throw StateError('Unexpected CLI findings');
        }
      }
    } finally {
      root.deleteSync(recursive: true);
    }
  }
  if (cliExits.length != 3) throw StateError('CLI exits 0/1/2 missing');
  stdout.writeln(
    '${rule.id}: ${_cases.length} fixtures and three CLI representatives passed',
  );
}
