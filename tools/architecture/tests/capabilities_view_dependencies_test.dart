import 'dart:convert';
import 'dart:io';

import '../model.dart';
import '../rules/capabilities_view_dependencies.dart' as rule;
import '../proof_process.dart';

const _view = rule.view;
const _gateway = 'lib/core/services/profile_gateway.dart';
const _repository = 'lib/core/services/administration_repository.dart';
const _owner = 'lib/core/services/profile_capabilities_session.dart';
const _part = 'lib/core/screens/capabilities_part.dart';
const _page = 'class ProfileCapabilitiesScreen {}';

class _Case {
  const _Case(
    this.name,
    this.files,
    this.exit, {
    this.line = 1,
    this.libraries = const {},
  });
  final String name;
  final Map<String, String> files;
  final int exit;
  final int line;
  final Map<String, String> libraries;
}

const _cases = [
  _Case('original-direct', {
    _view: "import '../services/profile_gateway.dart';\n$_page",
    _gateway: 'class ProfileGateway {}',
  }, 1),
  _Case('package-prefix', {
    _view:
        "import 'package:wing/core/services/profile_gateway.dart' as raw; $_page",
    _gateway: 'class ProfileGateway {}',
  }, 1),
  _Case('package-dot-segments', {
    _view:
        "import 'package:wing/core/models/../services/profile_gateway.dart'; $_page",
    _gateway: 'class ProfileGateway {}',
  }, 1),
  _Case('relative-dot-segments', {
    _view: "import '../screens/../services/profile_gateway.dart'; $_page",
    _gateway: 'class ProfileGateway {}',
  }, 1),
  _Case('hidden-declared-adapter', {
    _view:
        "import '../services/profile_gateway.dart' hide ProfileGateway; $_page",
    _gateway: 'class ProfileGateway {}',
  }, 1),
  _Case('deferred-adapter', {
    _view: "import '../services/profile_gateway.dart' deferred as raw; $_page",
    _gateway: 'class ProfileGateway {}',
  }, 1),
  _Case('repository-export', {
    _view: "export '../services/administration_repository.dart'; $_page",
    _repository: 'class AdministrationRepository {}',
  }, 1),
  _Case('nested-barrel', {
    _view: "import '../../barrel.dart'; $_page",
    'lib/barrel.dart': "export 'second.dart';",
    'lib/second.dart': "export 'core/services/profile_gateway.dart';",
    _gateway: 'class ProfileGateway {}',
  }, 1),
  _Case(
    'conditional-import',
    {
      _view:
          "import '../services/profile_capabilities_session.dart'\n if (dart.library.io) '../services/profile_gateway.dart'; $_page",
      _owner: 'class ProfileCapabilitiesSession {}',
      _gateway: 'class ProfileGateway {}',
    },
    1,
    line: 2,
  ),
  _Case('conditional-export', {
    _view: "import '../../barrel.dart'; $_page",
    'lib/barrel.dart':
        "export 'safe.dart' if (dart.library.io) 'core/services/administration_repository.dart';",
    'lib/safe.dart': 'class Safe {}',
    _repository: 'class AdministrationRepository {}',
  }, 1),
  _Case(
    'actual-part',
    {
      _view:
          "import '../services/profile_gateway.dart';\npart 'capabilities_part.dart';",
      _part: "part of 'profile_capabilities_screen.dart'; $_page",
      _gateway: 'class ProfileGateway {}',
    },
    1,
    libraries: {_part: _view},
  ),
  _Case(
    'malformed-part-namespace',
    {
      _view: "part 'capabilities_part.dart'; $_page",
      _part:
          "part of 'profile_capabilities_screen.dart';\nimport '../services/profile_gateway.dart';",
      _gateway: 'class ProfileGateway {}',
    },
    2,
    libraries: {_part: _view},
  ),
  _Case('typed-owner', {
    _view: "import '../services/profile_capabilities_session.dart'; $_page",
    _owner:
        "import 'profile_gateway.dart'; class ProfileCapabilitiesSession {}",
    _gateway: 'class ProfileGateway {}',
  }, 0),
  _Case('session-and-immutable-model', {
    _view:
        "import '../services/profile_capabilities_session.dart'; import '../models/capabilities.dart'; $_page",
    _owner:
        "import 'administration_repository.dart'; class ProfileCapabilitiesSession {}",
    _repository: 'class AdministrationRepository {}',
    'lib/core/models/capabilities.dart':
        'class CapabilityObservation { const CapabilityObservation(this.enabled); final bool enabled; }',
  }, 0),
  _Case('homonymous-symbol-and-library', {
    _view:
        "import '../models/profile_gateway.dart'; class ProfileCapabilitiesScreen { void read() {} }",
    'lib/core/models/profile_gateway.dart': 'class ProfileGateway {}',
  }, 0),
  _Case('safe-export-cycle', {
    _view: "import '../../barrel.dart'; $_page",
    'lib/barrel.dart': "export 'second.dart';",
    'lib/second.dart': "export 'barrel.dart'; class Safe {}",
  }, 0),
  _Case('adapter-export-cycle', {
    _view: "import '../../barrel.dart'; $_page",
    'lib/barrel.dart': "export 'second.dart';",
    'lib/second.dart':
        "export 'barrel.dart'; export 'core/services/profile_gateway.dart';",
    _gateway: 'class ProfileGateway {}',
  }, 1),
  _Case(
    'named-part',
    {
      _view: "library capabilities; part 'capabilities_part.dart'; $_page",
      _part: 'part of capabilities; class PresentationState {}',
    },
    0,
    libraries: {_part: _view},
  ),
  _Case('missing-scope', {'lib/other.dart': 'class Other {}'}, 2),
  _Case('missing-class', {_view: 'class Other {}'}, 2),
  _Case(
    'ambiguous-class',
    {
      _view: "part 'capabilities_part.dart'; $_page",
      _part: "part of 'profile_capabilities_screen.dart'; $_page",
    },
    2,
    libraries: {_part: _view},
  ),
  _Case('missing-part', {_view: "part 'capabilities_part.dart'; $_page"}, 2),
  _Case('unsupported-part-namespace', {
    _view: "part 'package:outside/missing.dart'; $_page",
  }, 2),
  _Case(
    'ambiguous-part-owner',
    {
      _view: "part 'capabilities_part.dart'; $_page",
      'lib/core/screens/other.dart':
          "part 'capabilities_part.dart'; class Other {}",
      _part:
          "part of 'profile_capabilities_screen.dart'; class PresentationState {}",
    },
    2,
    libraries: {_part: _view},
  ),
  _Case(
    'mismatched-named-part',
    {
      _view: "library capabilities; part 'capabilities_part.dart'; $_page",
      _part: 'part of other; class PresentationState {}',
    },
    2,
    libraries: {_part: _view},
  ),
  _Case('detached-part', {
    _view: _page,
    _part:
        "part of 'profile_capabilities_screen.dart'; class PresentationState {}",
  }, 2),
  _Case('detached-named-part', {
    _view: 'library capabilities; $_page',
    _part: 'part of capabilities; class PresentationState {}',
  }, 2),
  _Case(
    'manifest-cannot-hide-scope',
    {_view: _page},
    2,
    libraries: {_view: 'lib/other.dart'},
  ),
  _Case('missing-visible-barrel', {
    _view: "import '../../barrel.dart'; $_page",
  }, 2),
  _Case('missing-conditional-export', {
    _view: "import '../../barrel.dart'; $_page",
    'lib/barrel.dart':
        "export 'safe.dart' if (dart.library.io) 'missing.dart';",
    'lib/safe.dart': 'class Safe {}',
  }, 2),
];

Future<void> main() => withProofProcesses(() => _proofMain());

Future<void> _proofMain() async {
  final cliExits = <int>{};
  for (final fixture in _cases) {
    final directory = Directory.systemTemp.createTempSync(
      'wing-capabilities-deps-',
    );
    try {
      final roles = <String, Object>{};
      for (final entry in fixture.files.entries) {
        final file = File('${directory.path}/${entry.key}');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(entry.value);
        roles[entry.key] = {
          'role': entry.key == _view ? 'view' : 'utility',
          'feature': 'capabilities',
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
        'missing-scope',
      }.contains(fixture.name)) {
        if (!cliExits.add(fixture.exit)) {
          throw StateError('Duplicate CLI representative');
        }
        final result = await runProofProcess(proofDartExecutable, [
          'run',
          'tools/architecture/rules/capabilities_view_dependencies.dart',
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
